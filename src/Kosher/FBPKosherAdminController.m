// PIN-protected Hebrew administrator management implementation.

#import "FBPKosherAdminController.h"
#import "FBPKosherPolicyStore.h"
#import "FBPKosherPolicyEngine.h"
#import "FBPKosherCompatibilityMonitor.h"
#import "FBPKosherDiagnostics.h"
#import "FBPKosherModeration.h"
#import "FBPKosherHomeController.h"
#import "FBPKosherNavigationGuard.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import "FBPToast.h"

#import <math.h>

typedef NS_ENUM(NSInteger, FBPAdminSection) {
    FBPAdminSectionMode = 0,
    FBPAdminSectionGroups = 1,
    FBPAdminSectionPages = 2,
    FBPAdminSectionProfiles = 3,
    FBPAdminSectionDomains = 4,
    FBPAdminSectionMarketplace = 5,
    FBPAdminSectionNotifications = 6,
    FBPAdminSectionAccessibility = 7,
    FBPAdminSectionDiagnostics = 8,
    FBPAdminSectionSecurity = 9,
};

@interface FBPKosherAdminController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong, nullable) FBPKosherAdminSession *session;
@property (nonatomic, strong) UIView *lockContainer;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITextField *pinField;
@property (nonatomic, strong) UITextField *confirmPinField;
@property (nonatomic, strong) UILabel *lockStatusLabel;
@property (nonatomic, copy) NSString *filterQuery;
@end

@implementation FBPKosherAdminController

+ (void)presentFromViewController:(UIViewController *)host {
    if (!host) return;
    while (host.presentedViewController) host = host.presentedViewController;

    FBPKosherAdminController *vc = [[FBPKosherAdminController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    FBPApplySemanticDirection(nav.view);
    [host presentViewController:nav animated:!FBPEnabled(FBPKeyKosherReducedMotion) completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = FBPKosherSurfaceColor();
    self.view.tintColor = FBPKosherAccentColor();
    FBPApplySemanticDirection(self.view);

    self.title = FBPL(@"kosher.admin.title");
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:FBPL(@"kosher.nav.close")
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(closeTapped)];

    [self buildLockContainer];
    [self buildAdminTable];
    [self refreshAuthState];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        [FBPKosherPolicyStore.shared lockAdminSession];
        self.session = nil;
    }
}

- (void)closeTapped {
    [FBPKosherPolicyStore.shared lockAdminSession];
    self.session = nil;
    [self dismissViewControllerAnimated:!FBPEnabled(FBPKeyKosherReducedMotion) completion:^{
        if (FBPKosherStrictModeActive() && ![FBPKosherNavigationGuard isAuthenticationFlowActive]) {
            [FBPKosherHomeController presentAsRootOverlayIfNeeded];
        }
    }];
}

#pragma mark - Lock / Setup Gate UI

- (void)buildLockContainer {
    _lockContainer = [[UIView alloc] init];
    _lockContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _lockContainer.backgroundColor = FBPKosherSurfaceColor();
    FBPApplySemanticDirection(_lockContainer);
    [self.view addSubview:_lockContainer];

    [NSLayoutConstraint activateConstraints:@[
        [_lockContainer.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_lockContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_lockContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_lockContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)rebuildLockGateContent {
    for (UIView *sub in [_lockContainer.subviews copy]) {
        [sub removeFromSuperview];
    }

    BOOL hasPIN = FBPKosherPolicyStore.shared.hasConfiguredAdminPIN;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14.0;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    FBPApplySemanticDirection(stack);
    [_lockContainer addSubview:stack];

    UIImageView *shield = [[UIImageView alloc] initWithImage:
        [UIImage fbp_symbolNamed:(hasPIN ? @"lock.shield.fill" : @"key.fill") size:44]];
    shield.tintColor = FBPKosherAccentColor();
    shield.contentMode = UIViewContentModeScaleAspectFit;
    shield.translatesAutoresizingMaskIntoConstraints = NO;
    [shield.heightAnchor constraintEqualToConstant:52].active = YES;
    [stack addArrangedSubview:shield];

    UILabel *heading = [[UILabel alloc] init];
    heading.text = hasPIN ? FBPL(@"kosher.admin.unlockHeading") : FBPL(@"kosher.admin.setupHeading");
    heading.font = FBPScaledFont(22, UIFontWeightBold, UIFontTextStyleTitle2);
    heading.textColor = UIColor.whiteColor;
    heading.textAlignment = NSTextAlignmentCenter;
    heading.numberOfLines = 0;
    [stack addArrangedSubview:heading];

    UILabel *sub = [[UILabel alloc] init];
    sub.text = hasPIN ? FBPL(@"kosher.admin.unlockDesc") : FBPL(@"kosher.admin.setupDesc");
    sub.font = FBPScaledFont(14, UIFontWeightRegular, UIFontTextStyleSubheadline);
    sub.textColor = FBPKosherSecondaryTextColor();
    sub.textAlignment = NSTextAlignmentCenter;
    sub.numberOfLines = 0;
    [stack addArrangedSubview:sub];

    _pinField = [[UITextField alloc] init];
    _pinField.secureTextEntry = YES;
    _pinField.keyboardType = UIKeyboardTypeNumberPad;
    _pinField.borderStyle = UITextBorderStyleRoundedRect;
    _pinField.backgroundColor = FBPKosherCardColor();
    _pinField.textColor = UIColor.whiteColor;
    _pinField.placeholder = FBPL(@"kosher.admin.pinPlaceholder");
    _pinField.accessibilityLabel = FBPL(@"kosher.admin.pinPlaceholder");
    _pinField.font = FBPScaledFont(18, UIFontWeightMedium, UIFontTextStyleBody);
    _pinField.textAlignment = NSTextAlignmentCenter;
    [_pinField.heightAnchor constraintEqualToConstant:48].active = YES;
    [stack addArrangedSubview:_pinField];

    if (!hasPIN) {
        _confirmPinField = [[UITextField alloc] init];
        _confirmPinField.secureTextEntry = YES;
        _confirmPinField.keyboardType = UIKeyboardTypeNumberPad;
        _confirmPinField.borderStyle = UITextBorderStyleRoundedRect;
        _confirmPinField.backgroundColor = FBPKosherCardColor();
        _confirmPinField.textColor = UIColor.whiteColor;
        _confirmPinField.placeholder = FBPL(@"kosher.admin.pinConfirmPlaceholder");
        _confirmPinField.accessibilityLabel = FBPL(@"kosher.admin.pinConfirmPlaceholder");
        _confirmPinField.font = FBPScaledFont(18, UIFontWeightMedium, UIFontTextStyleBody);
        _confirmPinField.textAlignment = NSTextAlignmentCenter;
        [_confirmPinField.heightAnchor constraintEqualToConstant:48].active = YES;
        [stack addArrangedSubview:_confirmPinField];
    } else {
        _confirmPinField = nil;
    }

    _lockStatusLabel = [[UILabel alloc] init];
    _lockStatusLabel.font = FBPScaledFont(13, UIFontWeightMedium, UIFontTextStyleFootnote);
    _lockStatusLabel.textColor = UIColor.systemOrangeColor;
    _lockStatusLabel.textAlignment = NSTextAlignmentCenter;
    _lockStatusLabel.numberOfLines = 0;
    [stack addArrangedSubview:_lockStatusLabel];

    NSTimeInterval lockout = FBPKosherPolicyStore.shared.remainingLockoutSeconds;
    if (lockout > 0) {
        _lockStatusLabel.text = [NSString stringWithFormat:FBPL(@"kosher.admin.lockedOutSeconds"), (long)ceil(lockout)];
    }

    UIButton *primary = [UIButton buttonWithType:UIButtonTypeSystem];
    [primary setTitle:(hasPIN ? FBPL(@"kosher.admin.unlockButton") : FBPL(@"kosher.admin.setPinButton"))
             forState:UIControlStateNormal];
    primary.titleLabel.font = FBPScaledFont(17, UIFontWeightSemibold, UIFontTextStyleHeadline);
    primary.backgroundColor = FBPKosherAccentColor();
    [primary setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    primary.layer.cornerRadius = 14;
    [primary.heightAnchor constraintEqualToConstant:50].active = YES;
    [primary addTarget:self
                action:(hasPIN ? @selector(unlockTapped) : @selector(setupInitialPINTapped))
      forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:primary];

    if (hasPIN) {
        UIButton *recover = [UIButton buttonWithType:UIButtonTypeSystem];
        [recover setTitle:FBPL(@"kosher.admin.recoverButton") forState:UIControlStateNormal];
        recover.titleLabel.font = FBPScaledFont(15, UIFontWeightMedium, UIFontTextStyleCallout);
        [recover setTitleColor:FBPKosherAccentColor() forState:UIControlStateNormal];
        [recover.heightAnchor constraintEqualToConstant:44].active = YES;
        [recover addTarget:self action:@selector(recoveryTapped) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:recover];
    }

    UILabel *disclaimer = [[UILabel alloc] init];
    disclaimer.text = FBPL(@"kosher.security.deviceControlNotice");
    disclaimer.font = FBPScaledFont(12, UIFontWeightRegular, UIFontTextStyleCaption1);
    disclaimer.textColor = FBPKosherSecondaryTextColor();
    disclaimer.textAlignment = NSTextAlignmentCenter;
    disclaimer.numberOfLines = 0;
    [stack addArrangedSubview:disclaimer];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:_lockContainer.topAnchor constant:28],
        [stack.leadingAnchor constraintEqualToAnchor:_lockContainer.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:_lockContainer.trailingAnchor constant:-24],
    ]];
}

- (void)setupInitialPINTapped {
    NSString *pin = _pinField.text ?: @"";
    NSString *confirm = _confirmPinField.text ?: @"";
    if (![pin isEqualToString:confirm]) {
        _lockStatusLabel.text = FBPL(@"kosher.admin.pinMismatch");
        return;
    }
    NSString *recoveryCode = nil;
    FBPKosherAdminSession *newSession = nil;
    NSError *err = nil;
    BOOL ok = [FBPKosherPolicyStore.shared configureInitialAdminPIN:pin
                                                   recoveryCodeOut:&recoveryCode
                                                        sessionOut:&newSession
                                                             error:&err];
    if (!ok) {
        _lockStatusLabel.text = err.localizedDescription ?: FBPL(@"kosher.admin.pinInvalidFormat");
        return;
    }

    [_pinField resignFirstResponder];
    [_confirmPinField resignFirstResponder];
    self.session = newSession;

    NSString *msg = [NSString stringWithFormat:FBPL(@"kosher.admin.recoveryGeneratedMessage"),
                     FBPBidiIsolateLTR(recoveryCode ?: @"")];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:FBPL(@"kosher.admin.recoveryGeneratedTitle")
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.ok")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [self refreshAuthState];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)unlockTapped {
    NSError *err = nil;
    FBPKosherAdminSession *sess =
        [FBPKosherPolicyStore.shared authenticateWithPIN:(_pinField.text ?: @"") error:&err];
    if (!sess) {
        NSTimeInterval lockout = FBPKosherPolicyStore.shared.remainingLockoutSeconds;
        if (lockout > 0) {
            _lockStatusLabel.text = [NSString stringWithFormat:FBPL(@"kosher.admin.lockedOutSeconds"), (long)ceil(lockout)];
        } else {
            _lockStatusLabel.text = FBPL(@"kosher.admin.pinWrong");
        }
        return;
    }
    [_pinField resignFirstResponder];
    self.session = sess;
    [self refreshAuthState];
}

- (void)recoveryTapped {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:FBPL(@"kosher.admin.recoverTitle")
                                            message:FBPL(@"kosher.admin.recoverMessage")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = FBPL(@"kosher.admin.recoverCodePlaceholder");
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = FBPL(@"kosher.admin.newPinPlaceholder");
        tf.secureTextEntry = YES;
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.confirm")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSString *code = alert.textFields[0].text ?: @"";
        NSString *newPin = alert.textFields[1].text ?: @"";
        NSString *nextCode = nil;
        NSError *err = nil;
        if ([FBPKosherPolicyStore.shared resetAdminPINWithRecoveryCode:code
                                                                newPIN:newPin
                                                    newRecoveryCodeOut:&nextCode
                                                                 error:&err]) {
            self.lockStatusLabel.text = @"";
            NSString *msg = [NSString stringWithFormat:FBPL(@"kosher.admin.recoveryGeneratedMessage"),
                             FBPBidiIsolateLTR(nextCode ?: @"")];
            UIAlertController *done =
                [UIAlertController alertControllerWithTitle:FBPL(@"kosher.admin.pinChangedTitle")
                                                    message:msg
                                             preferredStyle:UIAlertControllerStyleAlert];
            [done addAction:[UIAlertAction actionWithTitle:FBPL(@"common.ok")
                                                     style:UIAlertActionStyleDefault
                                                   handler:nil]];
            [self presentViewController:done animated:YES completion:nil];
        } else {
            self.lockStatusLabel.text = err.localizedDescription ?: FBPL(@"kosher.admin.recoverFailed");
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Unlocked Admin Table

- (void)buildAdminTable {
    _searchBar = [[UISearchBar alloc] init];
    _searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    _searchBar.delegate = self;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.placeholder = FBPL(@"kosher.admin.searchSourcesPlaceholder");
    FBPApplySemanticDirection(_searchBar);
    [self.view addSubview:_searchBar];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = FBPKosherSurfaceColor();
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 56.0;
    FBPApplySemanticDirection(_tableView);
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [_tableView.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)refreshAuthState {
    BOOL unlocked = [FBPKosherPolicyStore.shared validateAdminSession:self.session error:nil];
    _lockContainer.hidden = unlocked;
    _searchBar.hidden = !unlocked;
    _tableView.hidden = !unlocked;
    if (unlocked) {
        [self.view bringSubviewToFront:_tableView];
        [self.view bringSubviewToFront:_searchBar];
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:FBPL(@"kosher.admin.lockNow")
                                             style:UIBarButtonItemStylePlain
                                            target:self
                                            action:@selector(lockNowTapped)];
        [_tableView reloadData];
    } else {
        self.navigationItem.rightBarButtonItem = nil;
        [self.view bringSubviewToFront:_lockContainer];
        [self rebuildLockGateContent];
    }
}

- (void)lockNowTapped {
    [FBPKosherPolicyStore.shared lockAdminSession];
    self.session = nil;
    [self refreshAuthState];
}

- (BOOL)ensureUnlockedOrRefresh {
    if ([FBPKosherPolicyStore.shared validateAdminSession:self.session error:nil]) {
        return YES;
    }
    self.session = nil;
    [self refreshAuthState];
    return NO;
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.filterQuery = searchText;
    [_tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (NSArray<FBPKosherApprovedSource *> *)filteredSourcesForKind:(FBPKosherSourceKind)kind {
    NSArray<FBPKosherApprovedSource *> *all = [FBPKosherPolicyStore.shared approvedSourcesOfKind:kind];
    NSString *q = [self.filterQuery stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    if (q.length == 0) return all;
    NSMutableArray<FBPKosherApprovedSource *> *out = [NSMutableArray array];
    for (FBPKosherApprovedSource *src in all) {
        if ([src.displayName.lowercaseString containsString:q] ||
            [src.identifier.lowercaseString containsString:q]) {
            [out addObject:src];
        }
    }
    return out;
}

#pragma mark - Table Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 10;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ((FBPAdminSection)section) {
        case FBPAdminSectionMode: return FBPL(@"kosher.admin.sec.mode");
        case FBPAdminSectionGroups: return FBPL(@"kosher.admin.sec.groups");
        case FBPAdminSectionPages: return FBPL(@"kosher.admin.sec.pages");
        case FBPAdminSectionProfiles: return FBPL(@"kosher.admin.sec.profiles");
        case FBPAdminSectionDomains: return FBPL(@"kosher.admin.sec.links");
        case FBPAdminSectionMarketplace: return FBPL(@"kosher.admin.sec.marketplace");
        case FBPAdminSectionNotifications: return FBPL(@"kosher.admin.sec.notifications");
        case FBPAdminSectionAccessibility: return FBPL(@"kosher.admin.sec.accessibility");
        case FBPAdminSectionDiagnostics: return FBPL(@"kosher.admin.sec.diagnostics");
        case FBPAdminSectionSecurity: return FBPL(@"kosher.admin.sec.security");
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == FBPAdminSectionMode) return FBPL(@"kosher.security.deviceControlNotice");
    if (section == FBPAdminSectionSecurity) return FBPL(@"kosher.disclaimer.notReligiousCert");
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ((FBPAdminSection)section) {
        case FBPAdminSectionMode: return 2;
        case FBPAdminSectionGroups: return 1 + (NSInteger)[self filteredSourcesForKind:FBPKosherSourceKindGroup].count;
        case FBPAdminSectionPages: return 1 + (NSInteger)[self filteredSourcesForKind:FBPKosherSourceKindPage].count;
        case FBPAdminSectionProfiles: return 1 + (NSInteger)[self filteredSourcesForKind:FBPKosherSourceKindProfile].count;
        case FBPAdminSectionDomains: return 1 + (NSInteger)[self filteredSourcesForKind:FBPKosherSourceKindTrustedDomain].count;
        case FBPAdminSectionMarketplace: return 2;
        case FBPAdminSectionNotifications: return 1;
        case FBPAdminSectionAccessibility: return 4;
        case FBPAdminSectionDiagnostics: return 2;
        case FBPAdminSectionSecurity: return 4;
    }
    return 0;
}

- (UISwitch *)switchWithTag:(NSInteger)tag on:(BOOL)on action:(SEL)action {
    UISwitch *sw = [[UISwitch alloc] init];
    sw.tag = tag;
    sw.on = on;
    sw.onTintColor = FBPKosherAccentColor();
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    return sw;
}

- (UITableViewCell *)sourceCellForSource:(FBPKosherApprovedSource *)src {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                    reuseIdentifier:nil];
    cell.backgroundColor = FBPKosherCardColor();
    FBPApplySemanticDirection(cell);
    cell.textLabel.text = src.displayName;
    cell.textLabel.font = FBPScaledFont(16, UIFontWeightSemibold, UIFontTextStyleHeadline);
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.detailTextLabel.text = src.allowedPathPrefix.length
        ? [NSString stringWithFormat:@"%@%@", FBPBidiIsolateLTR(src.identifier), FBPBidiIsolateLTR(src.allowedPathPrefix)]
        : FBPBidiIsolateLTR(src.identifier);
    cell.detailTextLabel.font = FBPScaledFont(13, UIFontWeightRegular, UIFontTextStyleSubheadline);
    cell.detailTextLabel.textColor = FBPKosherSecondaryTextColor();
    cell.imageView.image = [UIImage fbp_symbolNamed:(src.isFavorite ? @"star.fill" : @"checkmark.circle.fill")
                                               size:18];
    cell.imageView.tintColor = src.isFavorite ? UIColor.systemYellowColor : UIColor.systemGreenColor;
    cell.accessoryType = UITableViewCellAccessoryDetailButton;
    return cell;
}

- (UITableViewCell *)addRowCellWithTitle:(NSString *)title {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                    reuseIdentifier:nil];
    cell.backgroundColor = FBPKosherCardColor();
    FBPApplySemanticDirection(cell);
    cell.textLabel.text = title;
    cell.textLabel.font = FBPScaledFont(16, UIFontWeightSemibold, UIFontTextStyleBody);
    cell.textLabel.textColor = FBPKosherAccentColor();
    cell.imageView.image = [UIImage fbp_symbolNamed:@"plus.circle.fill" size:20];
    cell.imageView.tintColor = FBPKosherAccentColor();
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    FBPAdminSection sec = (FBPAdminSection)indexPath.section;

    if (sec == FBPAdminSectionGroups || sec == FBPAdminSectionPages ||
        sec == FBPAdminSectionProfiles || sec == FBPAdminSectionDomains) {
        FBPKosherSourceKind kind = (sec == FBPAdminSectionGroups) ? FBPKosherSourceKindGroup
            : (sec == FBPAdminSectionPages ? FBPKosherSourceKindPage
               : (sec == FBPAdminSectionProfiles ? FBPKosherSourceKindProfile : FBPKosherSourceKindTrustedDomain));
        if (indexPath.row == 0) {
            NSString *addKey = (kind == FBPKosherSourceKindGroup) ? @"kosher.admin.addGroup"
                : (kind == FBPKosherSourceKindPage ? @"kosher.admin.addPage"
                   : (kind == FBPKosherSourceKindProfile ? @"kosher.admin.addProfile" : @"kosher.admin.addDomain"));
            return [self addRowCellWithTitle:FBPL(addKey)];
        }
        NSArray<FBPKosherApprovedSource *> *list = [self filteredSourcesForKind:kind];
        return [self sourceCellForSource:list[indexPath.row - 1]];
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                    reuseIdentifier:nil];
    cell.backgroundColor = FBPKosherCardColor();
    FBPApplySemanticDirection(cell);
    cell.textLabel.font = FBPScaledFont(16, UIFontWeightSemibold, UIFontTextStyleBody);
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.font = FBPScaledFont(13, UIFontWeightRegular, UIFontTextStyleFootnote);
    cell.detailTextLabel.textColor = FBPKosherSecondaryTextColor();
    cell.detailTextLabel.numberOfLines = 0;

    switch (sec) {
        case FBPAdminSectionMode:
            if (indexPath.row == 0) {
                cell.textLabel.text = FBPL(@"kosher.admin.strictModeTitle");
                cell.detailTextLabel.text = FBPL(@"kosher.admin.strictModeDesc");
                cell.accessoryView = [self switchWithTag:100
                                                      on:FBPKosherPolicyStore.shared.strictModeEnabled
                                                  action:@selector(strictModeSwitchChanged:)];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else {
                cell.textLabel.text = FBPL(@"kosher.admin.textOnlyEnforced");
                cell.detailTextLabel.text = FBPKosherCompatibilityMonitor.shared.criticalEnforcementHealthy
                    ? FBPL(@"kosher.admin.enforcementHealthy")
                    : FBPL(@"kosher.admin.enforcementDegraded");
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            }
            break;

        case FBPAdminSectionMarketplace:
            if (indexPath.row == 0) {
                BOOL verified = FBPKosherCompatibilityMonitor.shared.marketplaceEnforcementVerified;
                cell.textLabel.text = FBPL(@"kosher.admin.marketplaceCapability");
                cell.detailTextLabel.text = verified
                    ? FBPL(@"kosher.admin.marketplaceVerified")
                    : FBPL(@"kosher.admin.marketplaceUnverified");
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else {
                cell.textLabel.text = FBPL(@"kosher.admin.marketplaceAllow");
                cell.detailTextLabel.text = FBPL(@"kosher.admin.marketplaceAllowDesc");
                cell.accessoryView = [self switchWithTag:101
                                                      on:FBPKosherPolicyStore.shared.marketplaceAdminEnabled
                                                  action:@selector(marketplaceSwitchChanged:)];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            }
            break;

        case FBPAdminSectionNotifications:
            cell.textLabel.text = FBPL(@"kosher.admin.safeNotifications");
            cell.detailTextLabel.text = FBPL(@"kosher.admin.safeNotificationsDesc");
            cell.accessoryView = [self switchWithTag:102
                                                  on:FBPEnabled(FBPKeyKosherSafeNotificationsOnly)
                                              action:@selector(prefSwitchChanged:)];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;

        case FBPAdminSectionAccessibility:
            if (indexPath.row == 0) {
                cell.textLabel.text = FBPL(@"kosher.a11y.highContrast");
                cell.accessoryView = [self switchWithTag:200
                                                      on:FBPEnabled(FBPKeyKosherHighContrast)
                                                  action:@selector(prefSwitchChanged:)];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else if (indexPath.row == 1) {
                cell.textLabel.text = FBPL(@"kosher.a11y.largeText");
                cell.accessoryView = [self switchWithTag:201
                                                      on:FBPEnabled(FBPKeyKosherLargeText)
                                                  action:@selector(prefSwitchChanged:)];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else if (indexPath.row == 2) {
                cell.textLabel.text = FBPL(@"kosher.a11y.reducedMotion");
                cell.accessoryView = [self switchWithTag:202
                                                      on:FBPEnabled(FBPKeyKosherReducedMotion)
                                                  action:@selector(prefSwitchChanged:)];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else {
                cell.textLabel.text = FBPL(@"kosher.admin.localTextFilter");
                cell.detailTextLabel.text = FBPL(@"kosher.admin.localTextFilterDesc");
                cell.accessoryView = [self switchWithTag:203
                                                      on:FBPEnabled(FBPKeyKosherLocalTextModeration)
                                                  action:@selector(prefSwitchChanged:)];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            }
            break;

        case FBPAdminSectionDiagnostics:
            if (indexPath.row == 0) {
                cell.textLabel.text = FBPL(@"kosher.admin.viewCompatReport");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu / %lu",
                                             (unsigned long)FBPKosherDiagnostics.shared.allowCount,
                                             (unsigned long)FBPKosherDiagnostics.shared.blockCount];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else {
                cell.textLabel.text = FBPL(@"kosher.admin.exportDiagnostics");
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            break;

        case FBPAdminSectionSecurity:
            if (indexPath.row == 0) cell.textLabel.text = FBPL(@"kosher.admin.exportPolicy");
            else if (indexPath.row == 1) cell.textLabel.text = FBPL(@"kosher.admin.importPolicy");
            else if (indexPath.row == 2) cell.textLabel.text = FBPL(@"kosher.admin.changePin");
            else {
                cell.textLabel.text = FBPL(@"kosher.admin.lockNow");
                cell.textLabel.textColor = UIColor.systemRedColor;
            }
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;

        default:
            break;
    }
    return cell;
}

#pragma mark - Actions & Mutations

- (void)strictModeSwitchChanged:(UISwitch *)sender {
    if (![self ensureUnlockedOrRefresh]) return;
    NSError *err = nil;
    if (![FBPKosherPolicyStore.shared setStrictModeEnabled:sender.isOn session:self.session error:&err]) {
        [sender setOn:FBPKosherPolicyStore.shared.strictModeEnabled animated:YES];
        [FBPToastManager.shared showMessage:(err.localizedDescription ?: FBPL(@"kosher.admin.actionFailed"))
                                    success:NO];
        return;
    }
    [self.tableView reloadData];
}

- (void)marketplaceSwitchChanged:(UISwitch *)sender {
    if (![self ensureUnlockedOrRefresh]) return;
    BOOL verified = FBPKosherCompatibilityMonitor.shared.marketplaceEnforcementVerified;
    NSError *err = nil;
    if (![FBPKosherPolicyStore.shared setMarketplaceAdminEnabled:sender.isOn
                                                         session:self.session
                                           capabilityVerifiedNow:verified
                                                           error:&err]) {
        [sender setOn:NO animated:YES];
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:FBPL(@"kosher.admin.sec.marketplace")
                                                message:FBPL(@"kosher.marketplace.blockedMessage")
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.ok")
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)prefSwitchChanged:(UISwitch *)sender {
    if (![self ensureUnlockedOrRefresh]) return;
    NSString *key = nil;
    if (sender.tag == 102) key = FBPKeyKosherSafeNotificationsOnly;
    else if (sender.tag == 200) key = FBPKeyKosherHighContrast;
    else if (sender.tag == 201) key = FBPKeyKosherLargeText;
    else if (sender.tag == 202) key = FBPKeyKosherReducedMotion;
    else if (sender.tag == 203) key = FBPKeyKosherLocalTextModeration;
    if (!key) return;
    [FBPPrefs.shared setBool:sender.isOn forKey:key];
    [FBPPrefs.shared commit];
    if (sender.tag == 203) {
        FBPKosherModerationEngine.shared.policy.textModerationEnabled = sender.isOn;
    }
    if (sender.tag == 200 || sender.tag == 201) {
        [self.tableView reloadData];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (![self ensureUnlockedOrRefresh]) return;

    FBPAdminSection sec = (FBPAdminSection)indexPath.section;
    if (sec == FBPAdminSectionGroups || sec == FBPAdminSectionPages ||
        sec == FBPAdminSectionProfiles || sec == FBPAdminSectionDomains) {
        FBPKosherSourceKind kind = (sec == FBPAdminSectionGroups) ? FBPKosherSourceKindGroup
            : (sec == FBPAdminSectionPages ? FBPKosherSourceKindPage
               : (sec == FBPAdminSectionProfiles ? FBPKosherSourceKindProfile : FBPKosherSourceKindTrustedDomain));
        if (indexPath.row == 0) {
            [self promptAddSourceOfKind:kind];
        } else {
            FBPKosherApprovedSource *src = [self filteredSourcesForKind:kind][indexPath.row - 1];
            [self promptEditSource:src];
        }
        return;
    }

    if (sec == FBPAdminSectionDiagnostics) {
        if (indexPath.row == 0) {
            NSString *report = FBPKosherCompatibilityMonitor.shared.formattedHebrewDiagnosticsReport;
            UIAlertController *alert =
                [UIAlertController alertControllerWithTitle:FBPL(@"kosher.admin.viewCompatReport")
                                                    message:report
                                             preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.ok")
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        } else {
            NSString *summary = [FBPKosherDiagnostics.shared exportSanitizedSummary];
            UIActivityViewController *share =
                [[UIActivityViewController alloc] initWithActivityItems:@[summary]
                                                  applicationActivities:nil];
            share.popoverPresentationController.sourceView = self.view;
            [self presentViewController:share animated:YES completion:nil];
        }
        return;
    }

    if (sec == FBPAdminSectionSecurity) {
        if (indexPath.row == 0) [self exportPolicyTapped];
        else if (indexPath.row == 1) [self importPolicyTapped];
        else if (indexPath.row == 2) [self changePINTapped];
        else [self lockNowTapped];
    }
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
    [self tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (void)promptAddSourceOfKind:(FBPKosherSourceKind)kind {
    NSString *title = (kind == FBPKosherSourceKindGroup) ? FBPL(@"kosher.admin.addGroup")
        : (kind == FBPKosherSourceKindPage ? FBPL(@"kosher.admin.addPage")
           : (kind == FBPKosherSourceKindProfile ? FBPL(@"kosher.admin.addProfile") : FBPL(@"kosher.admin.addDomain")));
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:FBPL(@"kosher.admin.addSourceHint")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = (kind == FBPKosherSourceKindTrustedDomain)
            ? @"example.org"
            : FBPL(@"kosher.admin.idOrUrlPlaceholder");
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = FBPL(@"kosher.admin.friendlyNamePlaceholder");
    }];
    if (kind == FBPKosherSourceKindTrustedDomain) {
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = FBPL(@"kosher.admin.pathPrefixOptionalPlaceholder");
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        }];
    }
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.confirm")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        if (![self ensureUnlockedOrRefresh]) return;
        NSString *rawID = alert.textFields[0].text ?: @"";
        NSString *name = alert.textFields[1].text ?: @"";
        NSString *prefix = (kind == FBPKosherSourceKindTrustedDomain && alert.textFields.count > 2)
            ? alert.textFields[2].text : nil;
        FBPKosherApprovedSource *src =
            [[FBPKosherApprovedSource alloc] initWithIdentifier:rawID
                                                           kind:kind
                                                    displayName:name
                                                       favorite:NO
                                              allowedPathPrefix:prefix
                                                          notes:nil
                                                        addedAt:nil];
        NSError *err = nil;
        if ([FBPKosherPolicyStore.shared addApprovedSource:src session:self.session error:&err]) {
            [self.tableView reloadData];
            [FBPToastManager.shared showMessage:FBPL(@"kosher.admin.sourceAdded") success:YES];
        } else {
            [FBPToastManager.shared showMessage:(err.localizedDescription ?: FBPL(@"kosher.admin.actionFailed"))
                                        success:NO];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptEditSource:(FBPKosherApprovedSource *)src {
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:src.displayName
                                            message:FBPBidiIsolateLTR(src.identifier)
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:(src.isFavorite ? FBPL(@"kosher.admin.unfavorite")
                                                                    : FBPL(@"kosher.admin.favorite"))
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        if (![self ensureUnlockedOrRefresh]) return;
        FBPKosherApprovedSource *updated =
            [[FBPKosherApprovedSource alloc] initWithIdentifier:src.identifier
                                                           kind:src.kind
                                                    displayName:src.displayName
                                                       favorite:!src.isFavorite
                                              allowedPathPrefix:src.allowedPathPrefix
                                                          notes:src.notes
                                                        addedAt:src.addedAt];
        [FBPKosherPolicyStore.shared updateApprovedSource:updated session:self.session error:nil];
        [self.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:FBPL(@"kosher.admin.renameSource")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [self promptRenameSource:src];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:FBPL(@"kosher.admin.removeSource")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        if (![self ensureUnlockedOrRefresh]) return;
        [FBPKosherPolicyStore.shared removeApprovedSourceWithIdentifier:src.identifier
                                                                   kind:src.kind
                                                                session:self.session
                                                                  error:nil];
        [self.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:FBPL(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)promptRenameSource:(FBPKosherApprovedSource *)src {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:FBPL(@"kosher.admin.renameSource")
                                            message:FBPBidiIsolateLTR(src.identifier)
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = src.displayName;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.confirm")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        if (![self ensureUnlockedOrRefresh]) return;
        NSString *newName = alert.textFields[0].text ?: src.identifier;
        FBPKosherApprovedSource *updated =
            [[FBPKosherApprovedSource alloc] initWithIdentifier:src.identifier
                                                           kind:src.kind
                                                    displayName:newName
                                                       favorite:src.isFavorite
                                              allowedPathPrefix:src.allowedPathPrefix
                                                          notes:src.notes
                                                        addedAt:src.addedAt];
        [FBPKosherPolicyStore.shared updateApprovedSource:updated session:self.session error:nil];
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exportPolicyTapped {
    NSError *err = nil;
    NSData *data = [FBPKosherPolicyStore.shared exportPolicyJSONWithSession:self.session error:&err];
    if (!data) {
        [FBPToastManager.shared showMessage:(err.localizedDescription ?: FBPL(@"kosher.admin.actionFailed"))
                                    success:NO];
        return;
    }
    NSString *jsonStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    UIActivityViewController *share =
        [[UIActivityViewController alloc] initWithActivityItems:@[jsonStr ?: @""]
                                          applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)importPolicyTapped {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:FBPL(@"kosher.admin.importPolicy")
                                            message:FBPL(@"kosher.admin.importPolicyHint")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"{\"schemaVersion\":1,...}";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.confirm")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        if (![self ensureUnlockedOrRefresh]) return;
        NSString *raw = alert.textFields[0].text ?: @"";
        NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
        NSError *err = nil;
        if ([FBPKosherPolicyStore.shared importPolicyJSONData:data session:self.session error:&err]) {
            [self.tableView reloadData];
            [FBPToastManager.shared showMessage:FBPL(@"kosher.admin.importSuccess") success:YES];
        } else {
            [FBPToastManager.shared showMessage:(err.localizedDescription ?: FBPL(@"kosher.admin.importFailed"))
                                        success:NO];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)changePINTapped {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:FBPL(@"kosher.admin.changePin")
                                            message:FBPL(@"kosher.admin.pinInvalidFormat")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = FBPL(@"kosher.admin.currentPinPlaceholder");
        tf.secureTextEntry = YES;
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = FBPL(@"kosher.admin.newPinPlaceholder");
        tf.secureTextEntry = YES;
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.confirm")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        if (![self ensureUnlockedOrRefresh]) return;
        NSError *err = nil;
        if ([FBPKosherPolicyStore.shared changeAdminPINFrom:(alert.textFields[0].text ?: @"")
                                                      toPIN:(alert.textFields[1].text ?: @"")
                                                    session:self.session
                                                      error:&err]) {
            [FBPToastManager.shared showMessage:FBPL(@"kosher.admin.pinChangedTitle") success:YES];
        } else {
            [FBPToastManager.shared showMessage:(err.localizedDescription ?: FBPL(@"kosher.admin.actionFailed"))
                                        success:NO];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
