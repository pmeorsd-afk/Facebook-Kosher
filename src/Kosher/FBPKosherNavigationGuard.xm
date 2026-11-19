// Centralized navigation guard, entertainment blocking, and persistent Kosher return pill.

#import "FBPKosherNavigationGuard.h"
#import "FBPHeaders.h"
#import "FBPKosherPolicyEngine.h"
#import "FBPKosherPolicyStore.h"
#import "FBPKosherCompatibilityMonitor.h"
#import "FBPKosherDiagnostics.h"
#import "FBPKosherHomeController.h"
#import "FBPKosherSearchGuard.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import "FBPSheet.h"
#import "FBPToast.h"

#import <objc/runtime.h>
#import <objc/message.h>

static _Thread_local BOOL gFBPNavigationGuardReentry = NO;
static NSURL *gTempAuthorizedURL = nil;
static NSDate *gTempAuthorizedExpiresAt = nil;
static FBPKosherApprovedSource *gActiveApprovedSource = nil;
static NSDate *gActiveApprovedExpiresAt = nil;

#pragma mark - Persistent Return-to-Kosher Pill Window

@interface FBPKosherReturnPillWindow : UIWindow
+ (instancetype)shared;
- (void)setPillVisible:(BOOL)visible;
@end

@implementation FBPKosherReturnPillWindow {
    UIButton *_pillButton;
}

+ (instancetype)shared {
    static FBPKosherReturnPillWindow *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) {
                activeScene = (UIWindowScene *)scene;
                if (scene.activationState == UISceneActivationStateForegroundActive) break;
            }
        }
        shared = activeScene
            ? [[self alloc] initWithWindowScene:activeScene]
            : [[self alloc] initWithFrame:UIScreen.mainScreen.bounds];
    });
    return shared;
}

- (instancetype)initWithWindowScene:(UIWindowScene *)windowScene {
    if ((self = [super initWithWindowScene:windowScene])) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    self.backgroundColor = UIColor.clearColor;
    self.windowLevel = UIWindowLevelStatusBar + 50;
    self.rootViewController = [[UIViewController alloc] init];
    self.rootViewController.view.backgroundColor = UIColor.clearColor;
    FBPApplySemanticDirection(self.rootViewController.view);

    _pillButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _pillButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_pillButton setTitle:FBPL(@"kosher.nav.returnApproved") forState:UIControlStateNormal];
    [_pillButton setImage:[UIImage fbp_symbolNamed:@"shield.lefthalf.filled" size:15]
                 forState:UIControlStateNormal];
    _pillButton.titleLabel.font = FBPScaledFont(13, UIFontWeightBold, UIFontTextStyleFootnote);
    _pillButton.backgroundColor = [UIColor colorWithRed:0.08 green:0.12 blue:0.18 alpha:0.95];
    _pillButton.tintColor = FBPKosherAccentColor();
    [_pillButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _pillButton.layer.cornerRadius = 18;
    _pillButton.layer.borderWidth = 1.0;
    _pillButton.layer.borderColor = FBPKosherAccentColor().CGColor;
    _pillButton.contentEdgeInsets = UIEdgeInsetsMake(7, 14, 7, 14);
    _pillButton.accessibilityLabel = FBPL(@"kosher.nav.returnApproved");
    [_pillButton addTarget:self action:@selector(returnTapped) forControlEvents:UIControlEventTouchUpInside];

    [self.rootViewController.view addSubview:_pillButton];
    [NSLayoutConstraint activateConstraints:@[
        [_pillButton.bottomAnchor constraintEqualToAnchor:self.rootViewController.view.safeAreaLayoutGuide.bottomAnchor constant:-58],
        [_pillButton.centerXAnchor constraintEqualToAnchor:self.rootViewController.view.centerXAnchor],
        [_pillButton.heightAnchor constraintGreaterThanOrEqualToConstant:36],
    ]];
    self.hidden = YES;
}

- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)_canBecomeKeyWindow { return NO; }
- (BOOL)shouldAffectStatusBarAppearance { return NO; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}

- (void)setPillVisible:(BOOL)visible {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.hidden = !visible;
    });
}

- (void)returnTapped {
    gActiveApprovedSource = nil;
    gActiveApprovedExpiresAt = nil;
    [self setPillVisible:NO];
    [FBPKosherHomeController presentAsRootOverlayIfNeeded];
}

@end

#pragma mark - Helpers

static NSURL *FBPExtractURLFromController(UIViewController *vc) {
    if (!vc) return nil;
    for (NSString *name in @[@"initialNavigationURL", @"currentRequestURL", @"requestURL", @"targetURL", @"url", @"URL"]) {
        SEL sel = NSSelectorFromString(name);
        if (![vc respondsToSelector:sel]) continue;
        NSMethodSignature *sig = [vc methodSignatureForSelector:sel];
        const char *ret = sig.methodReturnType;
        if (!ret || ret[0] != _C_ID) continue;
        @try {
            id obj = ((id (*)(id, SEL))objc_msgSend)(vc, sel);
            if ([obj isKindOfClass:NSURL.class]) return (NSURL *)obj;
            if ([obj isKindOfClass:NSString.class]) return [NSURL URLWithString:(NSString *)obj];
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static NSString *FBPExtractSourceIDFromController(UIViewController *vc) {
    if (!vc) return nil;
    for (NSString *name in @[@"groupID", @"pageID", @"profileID", @"targetID", @"fbid"]) {
        SEL sel = NSSelectorFromString(name);
        if (![vc respondsToSelector:sel]) continue;
        NSMethodSignature *sig = [vc methodSignatureForSelector:sel];
        const char *ret = sig.methodReturnType;
        if (!ret || ret[0] != _C_ID) continue;
        @try {
            id obj = ((id (*)(id, SEL))objc_msgSend)(vc, sel);
            if ([obj isKindOfClass:NSString.class] && [(NSString *)obj length]) return obj;
            if ([obj isKindOfClass:NSNumber.class]) return [(NSNumber *)obj stringValue];
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static BOOL FBPControllerIsTweakOrSystemSafe(UIViewController *vc) {
    if (!vc) return YES;
    NSString *cls = NSStringFromClass([vc class]) ?: @"";
    if ([cls hasPrefix:@"FBPKosher"] ||
        [cls hasPrefix:@"FBPSettings"] ||
        [cls isEqualToString:@"FBPLanguageController"] ||
        [cls isEqualToString:@"FBPFontController"] ||
        [cls isEqualToString:@"FBPAppIconController"] ||
        [cls isEqualToString:@"FBPWelcomeController"]) {
        return YES;
    }
    if ([vc isKindOfClass:UIAlertController.class] ||
        [vc isKindOfClass:UIActivityViewController.class] ||
        [cls hasPrefix:@"_UI"] ||
        [cls hasPrefix:@"UIInputWindow"] ||
        [cls hasPrefix:@"UIEditing"] ||
        [cls hasPrefix:@"UIDocument"] ||
        [cls hasPrefix:@"UISystem"]) {
        return YES;
    }
    if ([vc isKindOfClass:UINavigationController.class]) {
        UIViewController *top = ((UINavigationController *)vc).topViewController;
        if (top && FBPControllerIsTweakOrSystemSafe(top)) return YES;
    }
    return NO;
}

static BOOL FBPControllerIsAuthFlow(UIViewController *vc) {
    if (!vc) return NO;
    NSString *low = NSStringFromClass([vc class]).lowercaseString;
    return [low containsString:@"login"] ||
           [low containsString:@"auth"] ||
           [low containsString:@"twofactor"] ||
           [low containsString:@"checkpoint"] ||
           [low containsString:@"caa"] ||
           [low containsString:@"registration"] ||
           [low containsString:@"accountswitcher"];
}

static BOOL FBPControllerIsSearchSurface(UIViewController *vc) {
    if (!vc) return NO;
    NSString *cls = NSStringFromClass([vc class]);
    if ([cls isEqualToString:@"FBPKosherSearchController"]) return NO;
    NSString *low = cls.lowercaseString;
    return [low containsString:@"fbsearch"] || [low containsString:@"graphsearch"] || [low hasPrefix:@"searchview"];
}

static BOOL FBPTempApprovedSessionMatchesController(UIViewController *vc) {
    if (!gActiveApprovedSource || !gActiveApprovedExpiresAt) return NO;
    if ([gActiveApprovedExpiresAt timeIntervalSinceNow] <= 0) {
        gActiveApprovedSource = nil;
        gActiveApprovedExpiresAt = nil;
        return NO;
    }
    NSString *low = NSStringFromClass([vc class]).lowercaseString;
    // Never allow entertainment/feed/photo/marketplace controllers even during an approved visit.
    if ([low containsString:@"shorts"] || [low containsString:@"reels"] ||
        [low containsString:@"snacks"] || [low containsString:@"stories"] ||
        [low containsString:@"watch"] || [low containsString:@"videohome"] ||
        [low containsString:@"facecast"] || [low containsString:@"photoview"] ||
        [low containsString:@"mediagallery"] || [low containsString:@"marketplace"] ||
        [low containsString:@"newsfeed"] || [low containsString:@"homefeed"]) {
        return NO;
    }
    if ([low containsString:@"group"] || [low containsString:@"page"] ||
        [low containsString:@"permalink"] || [low containsString:@"comment"] ||
        [low containsString:@"componenthosting"] || [low containsString:@"webview"]) {
        return YES;
    }
    return NO;
}

static BOOL FBPIsProhibitedTabLabel(NSString *label) {
    if (!label.length) return NO;
    NSString *low = label.lowercaseString;
    for (NSString *token in @[@"reel", @"reels", @"watch", @"video", @"friends",
                               @"dating", @"gaming", @"feeds", @"רילס", @"סרטונים",
                               @"חברים", @"גיימינג"]) {
        if ([low containsString:token]) return YES;
    }
    if (!FBPKosherPolicyStore.shared.marketplaceAdminEnabled ||
        !FBPKosherCompatibilityMonitor.shared.marketplaceEnforcementVerified) {
        if ([low containsString:@"marketplace"] || [low containsString:@"מרקטפלייס"]) return YES;
    }
    return NO;
}

static void FBPTrimProhibitedTabsInView(UIView *root) {
    if (!root || !FBPKosherStrictModeActive()) return;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSInteger visited = 0;
    while (queue.count && visited < 150) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (FBPIsProhibitedTabLabel(v.accessibilityIdentifier) ||
            FBPIsProhibitedTabLabel(v.accessibilityLabel)) {
            v.hidden = YES;
            v.userInteractionEnabled = NO;
            continue;
        }
        [queue addObjectsFromArray:v.subviews];
    }
}

static FBPKosherPolicyResult *FBPEvaluateViewControllerForNavigation(UIViewController *vc) {
    NSString *cls = NSStringFromClass([vc class]) ?: @"";
    NSURL *url = FBPExtractURLFromController(vc);
    NSString *sourceID = FBPExtractSourceIDFromController(vc);

    if (url && gTempAuthorizedURL && gTempAuthorizedExpiresAt &&
        [gTempAuthorizedExpiresAt timeIntervalSinceNow] > 0 &&
        [url.absoluteString isEqualToString:gTempAuthorizedURL.absoluteString]) {
        return [FBPKosherPolicyEngine.shared evaluateURL:url];
    }

    if (FBPTempApprovedSessionMatchesController(vc) && !url && !sourceID) {
        FBPKosherPolicyContext *ctx = [FBPKosherPolicyContext contextWithDestination:
            (gActiveApprovedSource.kind == FBPKosherSourceKindGroup
             ? FBPKosherDestinationGroup : FBPKosherDestinationPage)
                                                                         contentType:FBPKosherContentText];
        ctx.sourceIdentifier = gActiveApprovedSource.identifier;
        ctx.sourceKind = gActiveApprovedSource.kind;
        ctx.viewControllerClassName = cls;
        return [FBPKosherPolicyEngine.shared evaluateContext:ctx];
    }

    return [FBPKosherPolicyEngine.shared evaluateViewControllerClassName:cls
                                                                   title:vc.title
                                                                     url:url
                                                                sourceID:sourceID];
}

#pragma mark - Public Guard API

@implementation FBPKosherNavigationGuard

+ (void)authorizeDestinationURLTemporarily:(NSURL *)url {
    gTempAuthorizedURL = [url copy];
    gTempAuthorizedExpiresAt = [NSDate dateWithTimeIntervalSinceNow:10.0];
}

+ (void)setReturnPillVisible:(BOOL)visible {
    [FBPKosherReturnPillWindow.shared setPillVisible:visible];
}

+ (BOOL)isAuthenticationFlowActive {
    UIViewController *node = [FBPToastWindow appKeyWindow].rootViewController;
    NSMutableArray<UIViewController *> *queue = node ? [NSMutableArray arrayWithObject:node] : [NSMutableArray array];
    NSInteger visited = 0;
    while (queue.count && visited < 80) {
        UIViewController *cur = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (FBPControllerIsAuthFlow(cur)) return YES;
        if (cur.presentedViewController) [queue addObject:cur.presentedViewController];
        [queue addObjectsFromArray:cur.childViewControllers];
    }
    return NO;
}

+ (void)presentBlockedScreenForResult:(FBPKosherPolicyResult *)result
                   fromViewController:(UIViewController *)host {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFBPNavigationGuardReentry) return;
        UIViewController *target = host ?: [FBPSheetPresenter topViewController];
        while (target.presentedViewController) target = target.presentedViewController;
        if (!target || [target isKindOfClass:FBPKosherBlockedViewController.class]) return;

        gFBPNavigationGuardReentry = YES;
        FBPKosherBlockedViewController *blocked = [FBPKosherBlockedViewController controllerWithResult:result];
        [target presentViewController:blocked animated:!FBPEnabled(FBPKeyKosherReducedMotion) completion:^{
            gFBPNavigationGuardReentry = NO;
        }];
    });
}

+ (BOOL)handleIncomingURL:(NSURL *)url fromViewController:(UIViewController *)host {
    if (!FBPKosherStrictModeActive()) return YES;

    FBPKosherPolicyResult *res = [FBPKosherPolicyEngine.shared evaluateURL:url];
    if (!res.effectiveAllowed) {
        [self presentBlockedScreenForResult:res fromViewController:host];
        return NO;
    }

    NSURL *canonical = [FBPKosherPolicyEngine.shared normalizedURLFromURL:url] ?: url;
    [self authorizeDestinationURLTemporarily:canonical];

    id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
    SEL ulSel = NSSelectorFromString(@"application:continueUserActivity:restorationHandler:");
    if (delegate && [delegate respondsToSelector:ulSel]) {
        NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
        activity.webpageURL = canonical;
        void (^restoration)(NSArray *) = ^(__unused NSArray *objs) {};
        BOOL (*sendUL)(id, SEL, UIApplication *, NSUserActivity *, void (^)(NSArray *)) =
            (BOOL (*)(id, SEL, UIApplication *, NSUserActivity *, void (^)(NSArray *)))objc_msgSend;
        return sendUL(delegate, ulSel, UIApplication.sharedApplication, activity, restoration);
    }
    return YES;
}

+ (BOOL)openApprovedSource:(FBPKosherApprovedSource *)source
        fromViewController:(UIViewController *)host {
    if (!source) return NO;

    NSString *urlString = nil;
    if (source.kind == FBPKosherSourceKindGroup) {
        urlString = [NSString stringWithFormat:@"https://www.facebook.com/groups/%@", source.identifier];
    } else if (source.kind == FBPKosherSourceKindPage) {
        urlString = [NSString stringWithFormat:@"https://www.facebook.com/%@", source.identifier];
    } else if (source.kind == FBPKosherSourceKindProfile) {
        urlString = [NSString stringWithFormat:@"https://www.facebook.com/profile.php?id=%@", source.identifier];
    } else {
        urlString = [NSString stringWithFormat:@"https://%@%@", source.identifier, source.allowedPathPrefix ?: @""];
    }

    NSURL *destURL = [NSURL URLWithString:urlString];
    FBPKosherPolicyResult *res = [FBPKosherPolicyEngine.shared evaluateURL:destURL];
    if (!res.effectiveAllowed) {
        [self presentBlockedScreenForResult:res fromViewController:host];
        return NO;
    }

    gActiveApprovedSource = source;
    gActiveApprovedExpiresAt = [NSDate dateWithTimeIntervalSinceNow:120.0];
    [self authorizeDestinationURLTemporarily:destURL];
    [self setReturnPillVisible:YES];

    [FBPKosherHomeController dismissActiveHomeForApprovedNavigationWithCompletion:^{
        [self handleIncomingURL:destURL fromViewController:[FBPSheetPresenter topViewController]];
    }];
    return YES;
}

@end

#pragma mark - UIViewController & UINavigationController Hooks

%group FBPKosherNavigationVC

%hook UIViewController

- (void)presentViewController:(UIViewController *)viewControllerToPresent
                       animated:(BOOL)flag
                     completion:(void (^)(void))completion {
    if (!FBPKosherStrictModeActive() || gFBPNavigationGuardReentry ||
        FBPControllerIsTweakOrSystemSafe(viewControllerToPresent)) {
        %orig;
        return;
    }

    if (FBPControllerIsSearchSurface(viewControllerToPresent)) {
        [FBPKosherSearchController presentFromViewController:self];
        if (completion) completion();
        return;
    }

    FBPKosherPolicyResult *res = FBPEvaluateViewControllerForNavigation(viewControllerToPresent);
    if (!res.effectiveAllowed) {
        [FBPKosherNavigationGuard presentBlockedScreenForResult:res fromViewController:self];
        if (completion) completion();
        return;
    }
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!FBPKosherStrictModeActive() || gFBPNavigationGuardReentry) return;
    if (FBPControllerIsTweakOrSystemSafe(self) || FBPControllerIsAuthFlow(self)) return;

    if (!FBPKosherCompatibilityMonitor.shared.criticalEnforcementHealthy) {
        if (![FBPKosherNavigationGuard isAuthenticationFlowActive]) {
            [FBPKosherRestrictedViewController presentFromViewController:self];
        }
        return;
    }

    NSString *low = NSStringFromClass([self class]).lowercaseString;
    if ([low containsString:@"newsfeed"] || [low containsString:@"homefeed"]) {
        gActiveApprovedSource = nil;
        [FBPKosherNavigationGuard setReturnPillVisible:NO];
        [FBPKosherHomeController presentAsRootOverlayIfNeeded];
        return;
    }

    if (FBPControllerIsSearchSurface(self)) {
        [FBPKosherSearchController presentFromViewController:self];
        return;
    }

    FBPKosherPolicyResult *res = FBPEvaluateViewControllerForNavigation(self);
    if (!res.effectiveAllowed &&
        (res.context.destinationType == FBPKosherDestinationReels ||
         res.context.destinationType == FBPKosherDestinationStories ||
         res.context.destinationType == FBPKosherDestinationWatch ||
         res.context.destinationType == FBPKosherDestinationLive ||
         res.context.destinationType == FBPKosherDestinationPhotoViewer ||
         res.context.destinationType == FBPKosherDestinationVideoViewer ||
         res.context.destinationType == FBPKosherDestinationMarketplace)) {
        [FBPKosherNavigationGuard presentBlockedScreenForResult:res fromViewController:self];
    }
}

%end

%end // FBPKosherNavigationVC

%group FBPKosherNavigationNav

%hook UINavigationController

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (!FBPKosherStrictModeActive() || gFBPNavigationGuardReentry ||
        FBPControllerIsTweakOrSystemSafe(viewController)) {
        %orig;
        return;
    }

    if (FBPControllerIsSearchSurface(viewController)) {
        [FBPKosherSearchController presentFromViewController:self];
        return;
    }

    FBPKosherPolicyResult *res = FBPEvaluateViewControllerForNavigation(viewController);
    if (!res.effectiveAllowed) {
        [FBPKosherNavigationGuard presentBlockedScreenForResult:res fromViewController:self];
        return;
    }
    %orig;
}

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers animated:(BOOL)animated {
    if (!FBPKosherStrictModeActive() || gFBPNavigationGuardReentry) {
        %orig;
        return;
    }
    NSMutableArray<UIViewController *> *filtered = [NSMutableArray arrayWithCapacity:viewControllers.count];
    for (UIViewController *vc in viewControllers) {
        if (FBPControllerIsTweakOrSystemSafe(vc) || FBPEvaluateViewControllerForNavigation(vc).effectiveAllowed) {
            [filtered addObject:vc];
        }
    }
    if (filtered.count == 0) {
        %orig;
        [FBPKosherHomeController presentAsRootOverlayIfNeeded];
        return;
    }
    %orig(filtered, animated);
}

%end

%end // FBPKosherNavigationNav

#pragma mark - Tab Bar Cosmetic Hide (Defense-in-Depth)

%group FBPKosherTabTrim
%hook FBTabBarContainerView
- (void)layoutSubviews {
    %orig;
    FBPTrimProhibitedTabsInView((UIView *)self);
}
%end
%end

%group FBPKosherLiquidTabTrim
%hook FBFloatingTabBar
- (void)layoutSubviews {
    %orig;
    FBPTrimProhibitedTabsInView((UIView *)self);
}
%end
%hook FBNativeTabBar
- (void)layoutSubviews {
    %orig;
    FBPTrimProhibitedTabsInView((UIView *)self);
}
%end
%end

void FBPInitKosherNavigationGuard(void) {
    FBPKosherCompatibilityMonitor *monitor = FBPKosherCompatibilityMonitor.shared;

    Class vcCls = objc_getClass("UIViewController");
    if (vcCls && [vcCls instancesRespondToSelector:@selector(presentViewController:animated:completion:)]) {
        FBP_ONCE(gKosherNavVC) { %init(FBPKosherNavigationVC); }
        [monitor reportHook:@"NavigationGuard.UIViewController"
                   severity:FBPKosherHookSeverityCritical
                     status:FBPKosherHookStatusInstalled
                     detail:@"UIViewController modal & viewDidAppear gate active"];
    } else {
        [monitor reportHook:@"NavigationGuard.UIViewController"
                   severity:FBPKosherHookSeverityCritical
                     status:FBPKosherHookStatusMissing
                     detail:@"UIViewController missing"];
    }

    Class navCls = objc_getClass("UINavigationController");
    if (navCls && [navCls instancesRespondToSelector:@selector(pushViewController:animated:)]) {
        FBP_ONCE(gKosherNavPush) { %init(FBPKosherNavigationNav); }
        [monitor reportHook:@"NavigationGuard.UINavigationController"
                   severity:FBPKosherHookSeverityCritical
                     status:FBPKosherHookStatusInstalled
                     detail:@"UINavigationController push gate active"];
    } else {
        [monitor reportHook:@"NavigationGuard.UINavigationController"
                   severity:FBPKosherHookSeverityCritical
                     status:FBPKosherHookStatusMissing
                     detail:@"UINavigationController missing"];
    }

    if (objc_getClass("FBTabBarContainerView")) {
        FBP_ONCE(gKosherTabTrim) { %init(FBPKosherTabTrim); }
        [monitor reportHook:@"Chrome.TabBarTrim"
                   severity:FBPKosherHookSeverityCosmetic
                     status:FBPKosherHookStatusInstalled
                     detail:@"FBTabBarContainerView prohibited tabs trimmed"];
    }
    if (objc_getClass("FBFloatingTabBar") || objc_getClass("FBNativeTabBar")) {
        FBP_ONCE(gKosherLiquidTabTrim) { %init(FBPKosherLiquidTabTrim); }
    }
}
