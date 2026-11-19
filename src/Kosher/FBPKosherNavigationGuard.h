// Centralized navigation guard, entertainment route blocker, and safe approved-source routing.

#import "FBPlus.h"
#import "FBPKosherTypes.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

extern void FBPInitKosherNavigationGuard(void);

#ifdef __cplusplus
}
#endif

@interface FBPKosherNavigationGuard : NSObject

/// Authorizes an approved destination URL for the active navigation transition.
+ (void)authorizeDestinationURLTemporarily:(NSURL *)url;

/// Evaluates and opens an approved group/page/profile safely, hiding the Kosher
/// Home overlay temporarily and showing a persistent Hebrew "Return to Facebook Kosher" pill.
+ (BOOL)openApprovedSource:(FBPKosherApprovedSource *)source
        fromViewController:(nullable UIViewController *)host;

/// Centralized entry point for deep links, universal links, notification taps,
/// and internal links. Fails closed to FBPKosherBlockedViewController when denied.
+ (BOOL)handleIncomingURL:(nullable NSURL *)url
       fromViewController:(nullable UIViewController *)host;

+ (void)presentBlockedScreenForResult:(FBPKosherPolicyResult *)result
                   fromViewController:(nullable UIViewController *)host;

+ (BOOL)isAuthenticationFlowActive;
+ (void)setReturnPillVisible:(BOOL)visible;

@end

NS_ASSUME_NONNULL_END
