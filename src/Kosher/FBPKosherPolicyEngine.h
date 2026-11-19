// Centralized policy decision engine for Facebook Kosher.

#import "FBPlus.h"
#import "FBPKosherTypes.h"
#import "FBPKosherPolicyStore.h"
#import "FBPKosherCompatibilityMonitor.h"
#import "FBPKosherDiagnostics.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Fast C-linkage helper for Logos .xm hooks to query whether Strict Mode is enforced.
extern BOOL FBPKosherStrictModeActive(void);

#ifdef __cplusplus
}
#endif

/// Central policy evaluator. Every content, media, search, navigation, URL,
/// Marketplace, and notification decision passes through this single engine.
@interface FBPKosherPolicyEngine : NSObject

@property (class, readonly) FBPKosherPolicyEngine *shared;

@property (nonatomic, strong, readonly) FBPKosherPolicyStore *store;
@property (nonatomic, strong, readonly) FBPKosherCompatibilityMonitor *compatibilityMonitor;
@property (nonatomic, strong, readonly) FBPKosherDiagnostics *diagnostics;

- (instancetype)initWithStore:(FBPKosherPolicyStore *)store
         compatibilityMonitor:(FBPKosherCompatibilityMonitor *)monitor
                  diagnostics:(FBPKosherDiagnostics *)diagnostics NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (BOOL)isStrictModeActive;

/// Normalizes incoming URLs (unwrapping fbplusbridge, faceweb, LinkShim) and
/// rejects malformed or spoofed inputs safely.
- (nullable NSURL *)normalizedURLFromURL:(nullable NSURL *)rawURL;

- (FBPKosherPolicyResult *)evaluateContext:(FBPKosherPolicyContext *)context;
- (FBPKosherPolicyResult *)evaluateURL:(nullable NSURL *)url;
- (FBPKosherPolicyResult *)evaluateMediaURL:(nullable NSURL *)url;

- (FBPKosherPolicyResult *)evaluateViewControllerClassName:(NSString *)className
                                                     title:(nullable NSString *)title
                                                       url:(nullable NSURL *)url
                                                  sourceID:(nullable NSString *)sourceID;

- (FBPKosherPolicyResult *)evaluateModelWithClassName:(NSString *)className
                                             category:(nullable NSString *)category
                                             sourceID:(nullable NSString *)sourceID
                                           sourceKind:(FBPKosherSourceKind)sourceKind
                                  hasExplicitSourceID:(BOOL)hasExplicitSourceID
                                          isSponsored:(BOOL)isSponsored
                                              isMedia:(BOOL)isMedia
                               isSharedFromUnapproved:(BOOL)isSharedFromUnapproved
                                          textualBody:(nullable NSString *)textualBody;

- (FBPKosherPolicyResult *)evaluateNotificationWithTitle:(nullable NSString *)title
                                                    body:(nullable NSString *)body
                                                userInfo:(nullable NSDictionary *)userInfo
                                           hasAttachment:(BOOL)hasAttachment;

@end

NS_ASSUME_NONNULL_END
