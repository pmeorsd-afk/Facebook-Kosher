// Hebrew Kosher Home screen, Blocked Destination screen, and Restricted-State fallback screen.

#import "FBPlus.h"
#import "FBPKosherTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// Primary Hebrew home interface ("פייסבוק כשר") replacing the unrestricted Facebook feed.
@interface FBPKosherHomeController : UIViewController

@property (class, readonly) BOOL isCurrentlyPresented;

+ (void)presentAsRootOverlayIfNeeded;
+ (void)presentFromViewController:(nullable UIViewController *)host;
+ (void)dismissActiveHomeForApprovedNavigationWithCompletion:(nullable dispatch_block_t)completion;

@end

/// Full-screen Hebrew blocked-content explanation screen with safe Back / Home controls.
@interface FBPKosherBlockedViewController : UIViewController
+ (instancetype)controllerWithResult:(FBPKosherPolicyResult *)result;
@end

/// Safe Hebrew restricted-state screen shown when critical enforcement fails or
/// compatibility cannot be verified — never falls back to unrestricted Facebook.
@interface FBPKosherRestrictedViewController : UIViewController
+ (void)presentFromViewController:(nullable UIViewController *)host;
@end

NS_ASSUME_NONNULL_END
