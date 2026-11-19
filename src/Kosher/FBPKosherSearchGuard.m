// Restricted policy-aware search implementation.
// Searches only the administrator-approved allowlist so unrestricted global
// Facebook search results, people suggestions, photos, and videos are never exposed.

#import "FBPKosherSearchGuard.h"
#import "FBPKosherPolicyEngine.h"
#import "FBPKosherPolicyStore.h"
#import "FBPKosherNavigationGuard.h"
#import "FBPResources.h"

static NSString *const kSearchCellID = @"fbp.kosher.search.cell";

@interface FBPKosherSearchController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *noticeLabel;
@property (nonatomic, copy) NSArray<FBPKosherApprovedSource *> *results;
@end

@implementation FBPKosherSearchController

+ (void)presentFromViewController:(UIViewController *)host {
    if (!host) return;
    while (host.presentedViewController) host = host.presentedViewController;

    FBPKosherSearchController *vc = [[FBPKosherSearchController alloc] init];
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

    self.title = FBPL(@"kosher.search.title");

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:FBPL(@"kosher.nav.back")
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(closeTapped)];

    _noticeLabel = [[UILabel alloc] init];
    _noticeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _noticeLabel.text = FBPL(@"kosher.search.restrictedNotice");
    _noticeLabel.font = FBPScaledFont(13, UIFontWeightRegular, UIFontTextStyleFootnote);
    _noticeLabel.textColor = FBPKosherSecondaryTextColor();
    _noticeLabel.numberOfLines = 0;
    _noticeLabel.textAlignment = FBPIsRTLLanguage() ? NSTextAlignmentRight : NSTextAlignmentLeft;
    [self.view addSubview:_noticeLabel];

    _searchBar = [[UISearchBar alloc] init];
    _searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    _searchBar.delegate = self;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.placeholder = FBPL(@"kosher.search.placeholder");
    _searchBar.accessibilityLabel = FBPL(@"kosher.search.placeholder");
    FBPApplySemanticDirection(_searchBar);
    [self.view addSubview:_searchBar];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = FBPKosherSurfaceColor();
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 64.0;
    FBPApplySemanticDirection(_tableView);
    [_tableView registerClass:UITableViewCell.class forCellReuseIdentifier:kSearchCellID];
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4],
        [_searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [_noticeLabel.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor constant:4],
        [_noticeLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_noticeLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [_tableView.topAnchor constraintEqualToAnchor:_noticeLabel.bottomAnchor constant:8],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self reloadResultsForQuery:nil];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:!FBPEnabled(FBPKeyKosherReducedMotion) completion:nil];
}

- (void)reloadResultsForQuery:(NSString *)query {
    // Only return verified local allowlist sources (excluding trusted domains if needed, or keeping all).
    NSArray<FBPKosherApprovedSource *> *found = [FBPKosherPolicyStore.shared searchApprovedSourcesWithQuery:query];
    NSMutableArray<FBPKosherApprovedSource *> *filtered = [NSMutableArray array];
    for (FBPKosherApprovedSource *src in found) {
        if (src.kind != FBPKosherSourceKindTrustedDomain) {
            [filtered addObject:src];
        }
    }
    self.results = [filtered copy];
    [self.tableView reloadData];
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self reloadResultsForQuery:searchText];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [self reloadResultsForQuery:searchBar.text];
}

#pragma mark - UITableViewDataSource / Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX(1, (NSInteger)self.results.count);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                    reuseIdentifier:nil];
    cell.backgroundColor = FBPKosherCardColor();
    FBPApplySemanticDirection(cell);

    if (self.results.count == 0) {
        cell.textLabel.text = FBPL(@"kosher.search.empty");
        cell.textLabel.textColor = FBPKosherSecondaryTextColor();
        cell.textLabel.font = FBPScaledFont(15, UIFontWeightRegular, UIFontTextStyleBody);
        cell.textLabel.numberOfLines = 0;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    FBPKosherApprovedSource *src = self.results[indexPath.row];
    NSString *kindLabel = (src.kind == FBPKosherSourceKindGroup)
        ? FBPL(@"kosher.sourceKind.group")
        : (src.kind == FBPKosherSourceKindPage ? FBPL(@"kosher.sourceKind.page")
                                               : FBPL(@"kosher.sourceKind.profile"));

    cell.textLabel.text = src.displayName;
    cell.textLabel.font = FBPScaledFont(17, UIFontWeightSemibold, UIFontTextStyleHeadline);
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
                                 kindLabel, FBPBidiIsolateLTR(src.identifier)];
    cell.detailTextLabel.font = FBPScaledFont(13, UIFontWeightRegular, UIFontTextStyleSubheadline);
    cell.detailTextLabel.textColor = FBPKosherSecondaryTextColor();

    NSString *iconName = (src.kind == FBPKosherSourceKindGroup) ? @"person.3.fill"
        : (src.kind == FBPKosherSourceKindPage ? @"doc.text.fill" : @"person.fill");
    cell.imageView.image = [UIImage fbp_symbolNamed:iconName size:20];
    cell.imageView.tintColor = src.isFavorite ? UIColor.systemYellowColor : FBPKosherAccentColor();
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.isAccessibilityElement = YES;
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", src.displayName, kindLabel];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.results.count == 0) return;

    FBPKosherApprovedSource *src = self.results[indexPath.row];
    UIViewController *presenter = self.presentingViewController;
    [self dismissViewControllerAnimated:NO completion:^{
        [FBPKosherNavigationGuard openApprovedSource:src fromViewController:presenter];
    }];
}

@end
