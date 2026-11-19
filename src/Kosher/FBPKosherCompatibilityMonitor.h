// Runtime compatibility monitoring and safe-fallback verification for Facebook Kosher.

#import "FBPlus.h"
#import "FBPKosherTypes.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FBPKosherVersionSupport) {
    FBPKosherVersionSupportUnknown = 0,
    FBPKosherVersionSupportPartial = 1,
    FBPKosherVersionSupportVerifiedHooks = 2,
};

@interface FBPKosherHookStatusRecord : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, assign, readonly) FBPKosherHookSeverity severity;
@property (nonatomic, assign, readonly) FBPKosherHookStatus status;
@property (nonatomic, copy, readonly, nullable) NSString *detail;
@property (nonatomic, copy, readonly) NSDate *updatedAt;
@end

/// Tracks installed enforcement hooks, host Facebook version compatibility,
/// and determines whether strict enforcement is healthy enough to show permitted content.
@interface FBPKosherCompatibilityMonitor : NSObject

@property (class, readonly) FBPKosherCompatibilityMonitor *shared;

@property (nonatomic, copy, readonly) NSString *facebookVersion;
@property (nonatomic, copy, readonly) NSString *facebookBuildNumber;
@property (nonatomic, copy, readonly) NSString *tweakVersion;
@property (nonatomic, assign, readonly) FBPKosherVersionSupport versionSupport;
@property (nonatomic, assign, readonly) BOOL policyStoreInitialized;
@property (nonatomic, assign, readonly) BOOL criticalEnforcementHealthy;
@property (nonatomic, assign, readonly) BOOL marketplaceEnforcementVerified;
@property (nonatomic, copy, readonly) NSArray<FBPKosherHookStatusRecord *> *hookRecords;

+ (NSArray<NSString *> *)criticalHookIdentifiers;

- (instancetype)initWithFacebookVersion:(NSString *)fbVersion
                            buildNumber:(NSString *)buildNumber
                           tweakVersion:(NSString *)tweakVersion NS_DESIGNATED_INITIALIZER;

- (void)reportHook:(NSString *)identifier
          severity:(FBPKosherHookSeverity)severity
            status:(FBPKosherHookStatus)status
            detail:(nullable NSString *)detail;

- (void)markPolicyStoreInitialized:(BOOL)initialized;
- (void)markMarketplaceCapabilityVerified:(BOOL)verified reason:(nullable NSString *)reason;
- (void)evaluateStartupHealth;

/// Exact required Hebrew restricted-state message when critical enforcement fails.
- (NSString *)restrictedStateMessage;
- (NSDictionary<NSString *, id> *)compatibilityReportDictionary;
- (NSString *)formattedHebrewDiagnosticsReport;

@end

NS_ASSUME_NONNULL_END
