// Restricted policy-aware search controller (searches approved sources only).

#import "FBPlus.h"

NS_ASSUME_NONNULL_BEGIN

@interface FBPKosherSearchController : UIViewController
+ (void)presentFromViewController:(nullable UIViewController *)host;
@end

NS_ASSUME_NONNULL_END
