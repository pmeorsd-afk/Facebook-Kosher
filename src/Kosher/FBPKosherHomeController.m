// Hebrew Home experience, Blocked Destination screen, and Restricted Fallback screen.

#import "FBPKosherHomeController.h"
#import "FBPKosherPolicyEngine.h"
#import "FBPKosherPolicyStore.h"
#import "FBPKosherCompatibilityMonitor.h"
#import "FBPKosherMarketplaceGuard.h"
#import "FBPKosherNavigationGuard.h"
#import "FBPKosherSearchGuard.h"
#import "FBPKosherNotificationGuard.h"
#import "FBPKosherAdminController.h"
#import "FBPSettingsController.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import "FBPSheet.h"

typedef NS_ENUM(NSInteger, FBPHomeTab) {
    FBPHomeTabFavorites = 0,
    FBPHomeTabGroups = 1,
    FBPHomeTabPages = 2,
};

static __weak UIViewController *gActiveHomeNav = nil;
static __weak UIViewController *gActiveRestrictedNav = nil;

#pragma mark - Home Controller

@interface FBPKosherHomeController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *bannerLabel;
@property (nonatomic, assign) FBPHomeTab currentTab;
@property (nonatomic, copy) NSArray<FBPKosherApprovedSource *> *currentSources;
@property (nonatomic, strong) id policyObserver;
@end

@implementation FBPKosherHomeController

+ (BOOL)isCurrentlyPresented {
    return gActiveHomeNav != nil && gActiveHomeNav.presentingViewController != nil;
}

+ (void)presentAsRootOverlayIfNeeded {
    if (!FBPKosherStrictModeActive()) return;

    UIViewController *top = [FBPSheetPresenter topViewController];
    if (!top) return;

    if (!FBPKosherCompatibilityMonitor.shared.criticalEnforcementHealthy) {
        [FBPKosherRestrictedViewController presentFromViewController:top];
        return;
    }

    if ([self isCurrentlyPresented]) return;
    [self presentFromViewController:top];
}

+ (void)presentFromViewController:(UIViewController *)host {
    if (!host) host = [FBPSheetPresenter topViewController];
    while (host.presentedViewController) host = host.presentedViewController;
    if (!host) return;
    if ([host isKindOfClass:FBPKosherHomeController.class] ||
        ([host isKindOfClass:UINavigationController.class] &&
         [((UINavigationController *)host).topViewController isKindOfClass:FBPKosherHomeController.class])) {
        return;
    }

    FBPKosherHomeController *home = [[FBPKosherHomeController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:home];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    nav.modalInPresentation = YES;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    FBPApplySemanticDirection(nav.view);
    gActiveHomeNav = nav;
    [host presentViewController:nav animated:!FBPEnabled(FBPKeyKosherReducedMotion) completion:nil];
}

+ (void)dismissActiveHomeForApprovedNavigationWithCompletion:(dispatch_block_t)completion {
    UIViewController *nav = gActiveHomeNav;
    if (nav && nav.presentingViewController) {
        [nav dismissViewControllerAnimated:!FBPEnabled(FBPKeyKosherReducedMotion) completion:completion];
    } else if (completion) {
        completion();
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = FBPKosherSurfaceColor();
    self.view.tintColor = FBPKosherAccentColor();
    FBPApplySemanticDirection(self.view);

    self.title = FBPL(@"kosher.home.title");

    UIBarButtonItem *searchBtn =
        [[UIBarButtonItem alloc] initWithImage:[UIImage fbp_symbolNamed:@"magnifyingglass" size:18]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(searchTapped)];
    searchBtn.accessibilityLabel = FBPL(@"kosher.search.title");

    UIBarButtonItem *settingsBtn =
        [[UIBarButtonItem alloc] initWithImage:[UIImage fbp_symbolNamed:@"gearshape.fill" size:18]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(settingsTapped)];
    settingsBtn.accessibilityLabel = FBPL(@"kosher.home.settings");

    UIBarButtonItem *notifBtn =
        [[UIBarButtonItem alloc] initWithImage:[UIImage fbp_symbolNamed:@"bell.fill" size:18]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(notificationsTapped)];
    notifBtn.accessibilityLabel = FBPL(@"kosher.home.notifications");

    self.navigationItem.leftBarButtonItems = @[settingsBtn, notifBtn];
    self.navigationItem.rightBarButtonItems = @[searchBtn];

    _bannerLabel = [[UILabel alloc] init];
    _bannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _bannerLabel.text = FBPL(@"kosher.home.strictBanner");
    _bannerLabel.font = FBPScaledFont(13, UIFontWeightMedium, UIFontTextStyleFootnote);
    _bannerLabel.textColor = FBPKosherAccentColor();
    _bannerLabel.textAlignment = NSTextAlignmentCenter;
    _bannerLabel.numberOfLines = 0;
    [self.view addSubview:_bannerLabel];

    _tabControl = [[UISegmentedControl alloc] initWithItems:@[
        FBPL(@"kosher.home.favorites"),
        FBPL(@"kosher.home.myGroups"),
        FBPL(@"kosher.home.myPages"),
    ]];
    _tabControl.translatesAutoresizingMaskIntoConstraints = NO;
    _tabControl.selectedSegmentIndex = 1; // Default to My Groups
    _currentTab = FBPHomeTabGroups;
    FBPApplySemanticDirection(_tabControl);
    [_tabControl addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_tabControl];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = FBPKosherSurfaceColor();
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 64.0;
    FBPApplySemanticDirection(_tableView);
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_bannerLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6],
        [_bannerLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_bannerLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [_tabControl.topAnchor constraintEqualToAnchor:_bannerLabel.bottomAnchor constant:8],
        [_tabControl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_tabControl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_tabControl.heightAnchor constraintGreaterThanOrEqualToConstant:36],

        [_tableView.topAnchor constraintEqualToAnchor:_tabControl.bottomAnchor constant:6],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    __weak typeof(self) weakSelf = self;
    _policyObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:FBPKosherPolicyDidChangeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *note) {
        [weakSelf reloadSources];
    }];

    [self reloadSources];
}

- (void)dealloc {
    if (_policyObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:_policyObserver];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSources];
}

- (void)tabChanged:(UISegmentedControl *)sender {
    self.currentTab = (FBPHomeTab)sender.selectedSegmentIndex;
    [self reloadSources];
}

- (void)reloadSources {
    FBPKosherPolicyStore *store = FBPKosherPolicyStore.shared;
    if (self.currentTab == FBPHomeTabFavorites) {
        NSMutableArray *favs = [NSMutableArray array];
        for (FBPKosherApprovedSource *s in store.favoriteSources) {
            if (s.kind != FBPKosherSourceKindTrustedDomain) [favs addObject:s];
        }
        self.currentSources = [favs copy];
    } else if (self.currentTab == FBPHomeTabGroups) {
        self.currentSources = [store approvedSourcesOfKind:FBPKosherSourceKindGroup];
    } else {
        NSMutableArray *pages = [[store approvedSourcesOfKind:FBPKosherSourceKindPage] mutableCopy];
        [pages addObjectsFromArray:[store approvedSourcesOfKind:FBPKosherSourceKindProfile]];
        self.currentSources = [pages copy];
    }
    [self.tableView reloadData];
}

- (void)searchTapped {
    [FBPKosherSearchController presentFromViewController:self];
}

- (void)notificationsTapped {
    [FBPKosherNotificationsController presentFromViewController:self];
}

- (void)settingsTapped {
    [FBPSettingsController presentFromViewController:self];
}

- (void)adminTapped {
    [FBPKosherAdminController presentFromViewController:self];
}

#pragma mark - Table DataSource & Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    // Section 0: Approved sources (or empty state), Section 1: Quick Kosher navigation
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        if (self.currentTab == FBPHomeTabFavorites) return FBPL(@"kosher.home.favorites");
        if (self.currentTab == FBPHomeTabGroups) return FBPL(@"kosher.home.myGroups");
        return FBPL(@"kosher.home.myPages");
    }
    return FBPL(@"kosher.home.quickNavHeader");
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) {
        return MAX(1, (NSInteger)self.currentSources.count);
    }
    BOOL showMarketplace = FBPKosherMarketplaceGuard.isMarketplacePermitted;
    return showMarketplace ? 4 : 3;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                    reuseIdentifier:nil];
    cell.backgroundColor = FBPKosherCardColor();
    FBPApplySemanticDirection(cell);

    if (indexPath.section == 0) {
        if (self.currentSources.count == 0) {
            cell.textLabel.text = FBPL(@"kosher.home.emptyTitle");
            cell.textLabel.font = FBPScaledFont(16, UIFontWeightSemibold, UIFontTextStyleHeadline);
            cell.textLabel.textColor = UIColor.whiteColor;
            cell.textLabel.numberOfLines = 0;
            cell.detailTextLabel.text = FBPL(@"kosher.home.emptyAction");
            cell.detailTextLabel.font = FBPScaledFont(14, UIFontWeightRegular, UIFontTextStyleBody);
            cell.detailTextLabel.textColor = FBPKosherAccentColor();
            cell.detailTextLabel.numberOfLines = 0;
            cell.imageView.image = [UIImage fbp_symbolNamed:@"plus.shield.fill" size:22];
            cell.imageView.tintColor = FBPKosherAccentColor();
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.isAccessibilityElement = YES;
            cell.accessibilityLabel = [NSString stringWithFormat:@"%@. %@",
                                       FBPL(@"kosher.home.emptyTitle"),
                                       FBPL(@"kosher.home.emptyAction")];
            return cell;
        }

        FBPKosherApprovedSource *src = self.currentSources[indexPath.row];
        NSString *icon = (src.kind == FBPKosherSourceKindGroup) ? @"person.3.fill"
            : (src.kind == FBPKosherSourceKindPage ? @"doc.text.fill" : @"person.fill");
        cell.textLabel.text = src.displayName;
        cell.textLabel.font = FBPScaledFont(17, UIFontWeightSemibold, UIFontTextStyleHeadline);
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.detailTextLabel.text = FBPBidiIsolateLTR(src.identifier);
        cell.detailTextLabel.font = FBPScaledFont(13, UIFontWeightRegular, UIFontTextStyleSubheadline);
        cell.detailTextLabel.textColor = FBPKosherSecondaryTextColor();
        cell.imageView.image = [UIImage fbp_symbolNamed:icon size:20];
        cell.imageView.tintColor = src.isFavorite ? UIColor.systemYellowColor : FBPKosherAccentColor();
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    // Section 1: Notifications, Admin Setup, Settings, (optional) Marketplace.
    NSInteger row = indexPath.row;
    BOOL showMarketplace = FBPKosherMarketplaceGuard.isMarketplacePermitted;
    if (row == 0) {
        cell.textLabel.text = FBPL(@"kosher.home.notifications");
        cell.detailTextLabel.text = FBPL(@"kosher.home.notificationsDesc");
        cell.imageView.image = [UIImage fbp_symbolNamed:@"bell.fill" size:20];
    } else if (showMarketplace && row == 1) {
        cell.textLabel.text = FBPL(@"kosher.home.marketplace");
        cell.detailTextLabel.text = FBPL(@"kosher.home.marketplaceTextOnlyDesc");
        cell.imageView.image = [UIImage fbp_symbolNamed:@"bag.fill" size:20];
    } else if ((!showMarketplace && row == 1) || (showMarketplace && row == 2)) {
        cell.textLabel.text = FBPL(@"kosher.admin.title");
        cell.detailTextLabel.text = FBPL(@"kosher.home.adminDesc");
        cell.imageView.image = [UIImage fbp_symbolNamed:@"lock.shield.fill" size:20];
    } else {
        cell.textLabel.text = FBPL(@"kosher.home.settings");
        cell.detailTextLabel.text = FBPL(@"kosher.home.settingsDesc");
        cell.imageView.image = [UIImage fbp_symbolNamed:@"gearshape.fill" size:20];
    }
    cell.textLabel.font = FBPScaledFont(16, UIFontWeightSemibold, UIFontTextStyleHeadline);
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.detailTextLabel.font = FBPScaledFont(13, UIFontWeightRegular, UIFontTextStyleSubheadline);
    cell.detailTextLabel.textColor = FBPKosherSecondaryTextColor();
    cell.imageView.tintColor = FBPKosherAccentColor();
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0) {
        if (self.currentSources.count == 0) {
            [self adminTapped];
            return;
        }
        FBPKosherApprovedSource *src = self.currentSources[indexPath.row];
        [FBPKosherNavigationGuard openApprovedSource:src fromViewController:self];
        return;
    }

    BOOL showMarketplace = FBPKosherMarketplaceGuard.isMarketplacePermitted;
    NSInteger row = indexPath.row;
    if (row == 0) {
        [self notificationsTapped];
    } else if (showMarketplace && row == 1) {
        NSURL *mpURL = [NSURL URLWithString:@"https://www.facebook.com/marketplace"];
        [FBPKosherNavigationGuard handleIncomingURL:mpURL fromViewController:self];
    } else if ((!showMarketplace && row == 1) || (showMarketplace && row == 2)) {
        [self adminTapped];
    } else {
        [self settingsTapped];
    }
}

@end

#pragma mark - Blocked Destination Controller

@interface FBPKosherBlockedViewController ()
@property (nonatomic, strong) FBPKosherPolicyResult *policyResult;
@end

@implementation FBPKosherBlockedViewController

+ (instancetype)controllerWithResult:(FBPKosherPolicyResult *)result {
    FBPKosherBlockedViewController *vc = [[FBPKosherBlockedViewController alloc] init];
    vc.policyResult = result;
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    vc.modalInPresentation = YES;
    return vc;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = FBPKosherSurfaceColor();
    self.view.tintColor = FBPKosherAccentColor();
    FBPApplySemanticDirection(self.view);

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    FBPApplySemanticDirection(stack);
    [self.view addSubview:stack];

    UIImageView *icon = [[UIImageView alloc] initWithImage:
        [UIImage fbp_symbolNamed:@"hand.raised.slash.fill" size:54]];
    icon.tintColor = UIColor.systemOrangeColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.heightAnchor constraintEqualToConstant:64].active = YES;
    [stack addArrangedSubview:icon];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = FBPL(@"kosher.blocked.title");
    titleLabel.font = FBPScaledFont(24, UIFontWeightBold, UIFontTextStyleTitle2);
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 0;
    [stack addArrangedSubview:titleLabel];

    UILabel *reasonLabel = [[UILabel alloc] init];
    NSString *reasonText = self.policyResult.localizedReason.length
        ? self.policyResult.localizedReason
        : FBPL(@"kosher.blocked.defaultReason");
    if (self.policyResult.context.destinationType == FBPKosherDestinationMarketplace) {
        reasonText = FBPKosherMarketplaceBlockedMessage();
    }
    reasonLabel.text = reasonText;
    reasonLabel.font = FBPScaledFont(16, UIFontWeightRegular, UIFontTextStyleBody);
    reasonLabel.textColor = FBPKosherSecondaryTextColor();
    reasonLabel.textAlignment = NSTextAlignmentCenter;
    reasonLabel.numberOfLines = 0;
    [stack addArrangedSubview:reasonLabel];

    UIButton *homeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [homeBtn setTitle:FBPL(@"kosher.nav.returnApproved") forState:UIControlStateNormal];
    homeBtn.titleLabel.font = FBPScaledFont(17, UIFontWeightSemibold, UIFontTextStyleHeadline);
    homeBtn.backgroundColor = FBPKosherAccentColor();
    [homeBtn setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    homeBtn.layer.cornerRadius = 14;
    [homeBtn.heightAnchor constraintEqualToConstant:52].active = YES;
    [homeBtn addTarget:self action:@selector(returnHomeTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:homeBtn];

    UIButton *backBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [backBtn setTitle:FBPL(@"kosher.nav.back") forState:UIControlStateNormal];
    backBtn.titleLabel.font = FBPScaledFont(16, UIFontWeightMedium, UIFontTextStyleCallout);
    [backBtn setTitleColor:FBPKosherAccentColor() forState:UIControlStateNormal];
    [backBtn.heightAnchor constraintEqualToConstant:46].active = YES;
    [backBtn addTarget:self action:@selector(backTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:backBtn];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
    ]];
}

- (void)backTapped {
    if (self.navigationController && self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:!FBPEnabled(FBPKeyKosherReducedMotion)];
    } else {
        [self dismissViewControllerAnimated:!FBPEnabled(FBPKeyKosherReducedMotion) completion:nil];
    }
}

- (void)returnHomeTapped {
    [self dismissViewControllerAnimated:!FBPEnabled(FBPKeyKosherReducedMotion) completion:^{
        [FBPKosherHomeController presentAsRootOverlayIfNeeded];
    }];
}

@end

#pragma mark - Restricted Compatibility Fallback Screen

@implementation FBPKosherRestrictedViewController

+ (void)presentFromViewController:(UIViewController *)host {
    if (gActiveRestrictedNav && gActiveRestrictedNav.presentingViewController) return;
    if (!host) host = [FBPSheetPresenter topViewController];
    while (host.presentedViewController) host = host.presentedViewController;
    if (!host) return;

    FBPKosherRestrictedViewController *vc = [[FBPKosherRestrictedViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    nav.modalInPresentation = YES;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    FBPApplySemanticDirection(nav.view);
    gActiveRestrictedNav = nav;
    [host presentViewController:nav animated:NO completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = FBPKosherSurfaceColor();
    self.view.tintColor = FBPKosherAccentColor();
    FBPApplySemanticDirection(self.view);
    self.title = FBPL(@"kosher.home.title");

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    FBPApplySemanticDirection(stack);
    [self.view addSubview:stack];

    UIImageView *icon = [[UIImageView alloc] initWithImage:
        [UIImage fbp_symbolNamed:@"exclamationmark.shield.fill" size:54]];
    icon.tintColor = UIColor.systemRedColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.heightAnchor constraintEqualToConstant:64].active = YES;
    [stack addArrangedSubview:icon];

    UILabel *msg = [[UILabel alloc] init];
    msg.text = FBPKosherCompatibilityMonitor.shared.restrictedStateMessage;
    msg.font = FBPScaledFont(20, UIFontWeightBold, UIFontTextStyleTitle3);
    msg.textColor = UIColor.whiteColor;
    msg.textAlignment = NSTextAlignmentCenter;
    msg.numberOfLines = 0;
    [stack addArrangedSubview:msg];

    UILabel *detail = [[UILabel alloc] init];
    detail.text = FBPL(@"kosher.restricted.explanation");
    detail.font = FBPScaledFont(15, UIFontWeightRegular, UIFontTextStyleBody);
    detail.textColor = FBPKosherSecondaryTextColor();
    detail.textAlignment = NSTextAlignmentCenter;
    detail.numberOfLines = 0;
    [stack addArrangedSubview:detail];

    UIButton *diagBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [diagBtn setTitle:FBPL(@"kosher.admin.viewCompatReport") forState:UIControlStateNormal];
    diagBtn.titleLabel.font = FBPScaledFont(17, UIFontWeightSemibold, UIFontTextStyleHeadline);
    diagBtn.backgroundColor = FBPKosherAccentColor();
    [diagBtn setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    diagBtn.layer.cornerRadius = 14;
    [diagBtn.heightAnchor constraintEqualToConstant:50].active = YES;
    [diagBtn addTarget:self action:@selector(showDiagnostics) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:diagBtn];

    UIButton *adminBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [adminBtn setTitle:FBPL(@"kosher.admin.title") forState:UIControlStateNormal];
    adminBtn.titleLabel.font = FBPScaledFont(16, UIFontWeightMedium, UIFontTextStyleCallout);
    [adminBtn setTitleColor:FBPKosherAccentColor() forState:UIControlStateNormal];
    [adminBtn.heightAnchor constraintEqualToConstant:48].active = YES;
    [adminBtn addTarget:self action:@selector(openAdmin) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:adminBtn];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
    ]];
}

- (void)showDiagnostics {
    NSString *report = FBPKosherCompatibilityMonitor.shared.formattedHebrewDiagnosticsReport;
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:FBPL(@"kosher.admin.viewCompatReport")
                                            message:report
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.ok")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openAdmin {
    [FBPKosherAdminController presentFromViewController:self];
}

@end
