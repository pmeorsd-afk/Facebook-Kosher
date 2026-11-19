// Privacy-scrubbed diagnostics and policy-decision audit trail for Facebook Kosher.

#import "FBPlus.h"
#import "FBPKosherTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface FBPKosherDiagnosticEvent : NSObject
@property (nonatomic, copy, readonly) NSDate *timestamp;
@property (nonatomic, assign, readonly) FBPKosherDecision decision;
@property (nonatomic, assign, readonly) BOOL effectiveAllowed;
@property (nonatomic, assign, readonly) FBPKosherDestinationType destination;
@property (nonatomic, assign, readonly) FBPKosherContentType contentType;
@property (nonatomic, copy, readonly) NSString *reasonCode;
@property (nonatomic, copy, readonly, nullable) NSString *surfaceDetail;
@end

/// Records sanitized Kosher enforcement events without ever storing Facebook
/// credentials, cookies, tokens, PINs, or private user content.
@interface FBPKosherDiagnostics : NSObject

@property (class, readonly) FBPKosherDiagnostics *shared;

@property (nonatomic, assign, readonly) NSUInteger allowCount;
@property (nonatomic, assign, readonly) NSUInteger blockCount;
@property (nonatomic, assign, readonly) NSUInteger unknownCount;
@property (nonatomic, copy, readonly) NSArray<FBPKosherDiagnosticEvent *> *recentEvents;

- (void)recordPolicyResult:(FBPKosherPolicyResult *)result;
- (void)recordSecurityEvent:(NSString *)code detail:(nullable NSString *)detail;
- (NSString *)scrubSensitiveText:(nullable NSString *)raw;
- (NSString *)exportSanitizedSummary;
- (void)clearEvents;

@end

NS_ASSUME_NONNULL_END
