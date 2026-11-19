// Policy-aware notification interception, attachment stripping, and safe UI.

#import "FBPKosherNotificationGuard.h"
#import "FBPKosherPolicyEngine.h"
#import "FBPKosherCompatibilityMonitor.h"
#import "FBPKosherNavigationGuard.h"
#import "FBPKosherDiagnostics.h"
#import "FBPResources.h"

#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

@interface FBPKosherNotificationRecord ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy, readwrite) NSString *body;
@property (nonatomic, assign, readwrite) BOOL allowed;
@property (nonatomic, copy, readwrite) NSString *reasonCode;
@property (nonatomic, copy, readwrite, nullable) NSURL *destinationURL;
@property (nonatomic, copy, readwrite) NSDate *receivedAt;
@end

@implementation FBPKosherNotificationRecord
@end

static NSURL *FBPExtractNotificationURL(NSDictionary *userInfo) {
    if (![userInfo isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[@"url", @"uri", @"href", @"target_url", @"d"]) {
        id val = userInfo[key];
        if ([val isKindOfClass:NSString.class] && [(NSString *)val length] > 0) {
            NSURL *u = [NSURL URLWithString:val];
            if (u) return u;
        }
    }
    return nil;
}

@implementation FBPKosherNotificationGuard {
    NSLock *_lock;
    NSMutableArray<FBPKosherNotificationRecord *> *_records;
}

+ (FBPKosherNotificationGuard *)shared {
    static FBPKosherNotificationGuard *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [[NSLock alloc] init];
        _records = [NSMutableArray array];
    }
    return self;
}

- (NSArray<FBPKosherNotificationRecord *> *)recentRecords {
    [_lock lock];
    NSArray *copy = [_records copy];
    [_lock unlock];
    return copy;
}

- (void)recordNotification:(FBPKosherNotificationRecord *)record {
    [_lock lock];
    [_records insertObject:record atIndex:0];
    if (_records.count > 100) [_records removeLastObject];
    [_lock unlock];
}

- (FBPKosherPolicyResult *)evaluateAndSanitizeNotificationWithID:(NSString *)identifier
                                                           title:(NSString *)title
                                                            body:(NSString *)body
                                                        userInfo:(NSDictionary *)userInfo
                                                   hasAttachment:(BOOL)hasAttachment
                                                    safeTitleOut:(NSString **)safeTitleOut
                                                     safeBodyOut:(NSString **)safeBodyOut {
    FBPKosherPolicyResult *res =
        [FBPKosherPolicyEngine.shared evaluateNotificationWithTitle:title
                                                               body:body
                                                           userInfo:userInfo
                                                      hasAttachment:hasAttachment];

    NSString *outTitle = title ?: @"";
    NSString *outBody = body ?: @"";

    if (res.decision == FBPKosherDecisionBlock) {
        outTitle = @"";
        outBody = @"";
    } else if (res.decision == FBPKosherDecisionUnknown) {
        // Generic safe fallback so unverified notification previews are never leaked.
        outTitle = FBPL(@"kosher.notif.genericTitle");
        outBody = FBPL(@"kosher.notif.genericBody");
    }

    if (safeTitleOut) *safeTitleOut = outTitle;
    if (safeBodyOut) *safeBodyOut = outBody;

    FBPKosherNotificationRecord *rec = [[FBPKosherNotificationRecord alloc] init];
    rec.identifier = identifier ?: NSUUID.UUID.UUIDString;
    rec.title = outTitle.length ? outTitle : FBPL(@"kosher.notif.blockedEntry");
    rec.body = outBody.length ? outBody : (res.localizedReason ?: @"");
    rec.allowed = res.effectiveAllowed;
    rec.reasonCode = res.reasonCode ?: @"";
    rec.destinationURL = FBPExtractNotificationURL(userInfo);
    rec.receivedAt = [NSDate date];
    [self recordNotification:rec];

    return res;
}

- (BOOL)shouldAllowPushObject:(id)pushObject {
    if (!FBPKosherStrictModeActive()) return YES;
    if (!pushObject) return NO;

    NSString *title = nil;
    NSString *body = nil;
    NSDictionary *userInfo = nil;
    @try {
        id t = [pushObject valueForKey:@"title"];
        if ([t isKindOfClass:NSString.class]) title = t;
    } @catch (__unused NSException *e) {}
    @try {
        id b = [pushObject valueForKey:@"body"] ?: [pushObject valueForKey:@"message"];
        if ([b isKindOfClass:NSString.class]) body = b;
    } @catch (__unused NSException *e) {}
    @try {
        id info = [pushObject valueForKey:@"userInfo"] ?: [pushObject valueForKey:@"payload"];
        if ([info isKindOfClass:NSDictionary.class]) userInfo = info;
    } @catch (__unused NSException *e) {}

    FBPKosherPolicyResult *res =
        [self evaluateAndSanitizeNotificationWithID:nil
                                              title:title
                                               body:body
                                           userInfo:userInfo
                                      hasAttachment:NO
                                       safeTitleOut:nil
                                        safeBodyOut:nil];
    return (res.decision != FBPKosherDecisionBlock);
}

@end

BOOL FBPKosherShouldAllowPushEvaluate(id pushObject) {
    return [FBPKosherNotificationGuard.shared shouldAllowPushObject:pushObject];
}

#pragma mark - UNUserNotificationCenter Hook

%group FBPKosherUNCenter

%hook UNUserNotificationCenter

- (void)addNotificationRequest:(UNNotificationRequest *)request
         withCompletionHandler:(void (^)(NSError *error))completionHandler {
    if (!FBPKosherStrictModeActive() || !request) {
        %orig;
        return;
    }

    UNNotificationContent *content = request.content;
    NSString *safeTitle = nil;
    NSString *safeBody = nil;
    FBPKosherPolicyResult *res =
        [FBPKosherNotificationGuard.shared
            evaluateAndSanitizeNotificationWithID:request.identifier
                                            title:content.title
                                             body:content.body
                                         userInfo:content.userInfo
                                    hasAttachment:(content.attachments.count > 0)
                                     safeTitleOut:&safeTitle
                                      safeBodyOut:&safeBody];

    if (res.decision == FBPKosherDecisionBlock) {
        [FBPKosherDiagnostics.shared recordSecurityEvent:@"notification_suppressed"
                                                  detail:res.reasonCode];
        if (completionHandler) completionHandler(nil);
        return;
    }

    // Always strip attachments (photos/video previews/GIFs) in Strict Mode.
    UNMutableNotificationContent *sanitized = [content mutableCopy];
    sanitized.attachments = @[];
    if (res.decision == FBPKosherDecisionUnknown) {
        sanitized.title = safeTitle ?: FBPL(@"kosher.notif.genericTitle");
        sanitized.subtitle = @"";
        sanitized.body = safeBody ?: FBPL(@"kosher.notif.genericBody");
    }

    UNNotificationRequest *cleanRequest =
        [UNNotificationRequest requestWithIdentifier:request.identifier
                                             content:sanitized
                                             trigger:request.trigger];
    %orig(cleanRequest, completionHandler);
}

%end

%end // FBPKosherUNCenter

void FBPInitKosherNotificationGuard(void) {
    Class centerCls = objc_getClass("UNUserNotificationCenter");
    if (centerCls && [centerCls instancesRespondToSelector:@selector(addNotificationRequest:withCompletionHandler:)]) {
        FBP_ONCE(gKosherUNCenter) { %init(FBPKosherUNCenter); }
        [FBPKosherCompatibilityMonitor.shared reportHook:@"NotificationGuard.UNUserNotificationCenter"
                                                 severity:FBPKosherHookSeveritySurface
                                                   status:FBPKosherHookStatusInstalled
                                                   detail:@"UNUserNotificationCenter filter active"];
    } else {
        [FBPKosherCompatibilityMonitor.shared reportHook:@"NotificationGuard.UNUserNotificationCenter"
                                                 severity:FBPKosherHookSeveritySurface
                                                   status:FBPKosherHookStatusMissing
                                                   detail:@"UNUserNotificationCenter missing"];
    }
}

#pragma mark - Notifications List UI

@interface FBPKosherNotificationsController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy) NSArray<FBPKosherNotificationRecord *> *records;
@end

@implementation FBPKosherNotificationsController

+ (void)presentFromViewController:(UIViewController *)host {
    if (!host) return;
    while (host.presentedViewController) host = host.presentedViewController;
    FBPKosherNotificationsController *vc = [[FBPKosherNotificationsController alloc] init];
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

    self.title = FBPL(@"kosher.home.notifications");
    if (self.navigationController.viewControllers.count == 1) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:FBPL(@"kosher.nav.back")
                                             style:UIBarButtonItemStylePlain
                                            target:self
                                            action:@selector(closeTapped)];
    }

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = FBPKosherSurfaceColor();
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 72.0;
    FBPApplySemanticDirection(_tableView);
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.records = FBPKosherNotificationGuard.shared.recentRecords;
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:!FBPEnabled(FBPKeyKosherReducedMotion) completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return MAX(1, (NSInteger)self.records.count);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? FBPL(@"kosher.notif.osGuideHeader") : FBPL(@"kosher.notif.recentHeader");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                    reuseIdentifier:nil];
    cell.backgroundColor = FBPKosherCardColor();
    FBPApplySemanticDirection(cell);

    if (indexPath.section == 0) {
        cell.textLabel.text = FBPL(@"kosher.notif.osGuideTitle");
        cell.textLabel.font = FBPScaledFont(15, UIFontWeightSemibold, UIFontTextStyleHeadline);
        cell.textLabel.textColor = UIColor.labelColor;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.text = FBPL(@"kosher.notif.osGuideBody");
        cell.detailTextLabel.font = FBPScaledFont(13, UIFontWeightRegular, UIFontTextStyleFootnote);
        cell.detailTextLabel.textColor = FBPKosherSecondaryTextColor();
        cell.detailTextLabel.numberOfLines = 0;
        cell.imageView.image = [UIImage fbp_symbolNamed:@"bell.badge.fill" size:20];
        cell.imageView.tintColor = FBPKosherAccentColor();
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (self.records.count == 0) {
        cell.textLabel.text = FBPL(@"kosher.notif.empty");
        cell.textLabel.textColor = FBPKosherSecondaryTextColor();
        cell.textLabel.font = FBPScaledFont(15, UIFontWeightRegular, UIFontTextStyleBody);
        cell.textLabel.numberOfLines = 0;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    FBPKosherNotificationRecord *rec = self.records[indexPath.row];
    cell.textLabel.text = rec.title;
    cell.textLabel.font = FBPScaledFont(16, UIFontWeightSemibold, UIFontTextStyleHeadline);
    cell.textLabel.textColor = rec.allowed ? UIColor.labelColor : UIColor.systemOrangeColor;
    cell.textLabel.numberOfLines = 0;

    cell.detailTextLabel.text = rec.body;
    cell.detailTextLabel.font = FBPScaledFont(13, UIFontWeightRegular, UIFontTextStyleSubheadline);
    cell.detailTextLabel.textColor = FBPKosherSecondaryTextColor();
    cell.detailTextLabel.numberOfLines = 0;
    cell.imageView.image = [UIImage fbp_symbolNamed:(rec.allowed ? @"checkmark.shield.fill" : @"hand.raised.fill")
                                               size:18];
    cell.imageView.tintColor = rec.allowed ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
    cell.accessoryType = (rec.allowed && rec.destinationURL)
        ? UITableViewCellAccessoryDisclosureIndicator
        : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || self.records.count == 0) return;

    FBPKosherNotificationRecord *rec = self.records[indexPath.row];
    if (rec.destinationURL) {
        [FBPKosherNavigationGuard handleIncomingURL:rec.destinationURL fromViewController:self];
    }
}

@end
