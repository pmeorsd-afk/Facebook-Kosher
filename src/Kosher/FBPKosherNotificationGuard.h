// Policy-aware notification filtering, safe fallback, and Hebrew notifications UI.

#import "FBPlus.h"
#import "FBPKosherTypes.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

extern void FBPInitKosherNotificationGuard(void);
extern BOOL FBPKosherShouldAllowPushEvaluate(id pushObject);

#ifdef __cplusplus
}
#endif

@interface FBPKosherNotificationRecord : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString *body;
@property (nonatomic, assign, readonly) BOOL allowed;
@property (nonatomic, copy, readonly) NSString *reasonCode;
@property (nonatomic, copy, readonly, nullable) NSURL *destinationURL;
@property (nonatomic, copy, readonly) NSDate *receivedAt;
@end

@interface FBPKosherNotificationGuard : NSObject

@property (class, readonly) FBPKosherNotificationGuard *shared;
@property (nonatomic, copy, readonly) NSArray<FBPKosherNotificationRecord *> *recentRecords;

- (FBPKosherPolicyResult *)evaluateAndSanitizeNotificationWithID:(nullable NSString *)identifier
                                                           title:(nullable NSString *)title
                                                            body:(nullable NSString *)body
                                                        userInfo:(nullable NSDictionary *)userInfo
                                                   hasAttachment:(BOOL)hasAttachment
                                                    safeTitleOut:(NSString * _Nullable * _Nullable)safeTitleOut
                                                     safeBodyOut:(NSString * _Nullable * _Nullable)safeBodyOut;

- (BOOL)shouldAllowPushObject:(nullable id)pushObject;

@end

/// Hebrew notifications screen showing approved/sanitized notifications and
/// iOS push-preview limitations & OS hardening instructions.
@interface FBPKosherNotificationsController : UIViewController
+ (void)presentFromViewController:(nullable UIViewController *)host;
@end

NS_ASSUME_NONNULL_END
