// Runtime compatibility monitoring and fail-closed startup verification.

#import "FBPKosherCompatibilityMonitor.h"
#import "FBPKosherDiagnostics.h"
#import "FBPResources.h"

#ifndef FBP_VERSION
#define FBP_VERSION @"1.0.8-kosher"
#endif

@interface FBPKosherHookStatusRecord ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, assign, readwrite) FBPKosherHookSeverity severity;
@property (nonatomic, assign, readwrite) FBPKosherHookStatus status;
@property (nonatomic, copy, readwrite, nullable) NSString *detail;
@property (nonatomic, copy, readwrite) NSDate *updatedAt;
@end

@implementation FBPKosherHookStatusRecord
@end

@implementation FBPKosherCompatibilityMonitor {
    NSLock *_lock;
    NSMutableDictionary<NSString *, FBPKosherHookStatusRecord *> *_records;
    BOOL _policyStoreInitialized;
    BOOL _marketplaceCapabilityVerified;
    NSString *_marketplaceReason;
}

+ (FBPKosherCompatibilityMonitor *)shared {
    static FBPKosherCompatibilityMonitor *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *fbVer =
            [NSBundle.mainBundle objectForInfoDictionaryKey:@"FBAppVersion"]
            ?: [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
            ?: @"unknown";
        NSString *build =
            [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]
            ?: @"unknown";
        shared = [[self alloc] initWithFacebookVersion:fbVer
                                           buildNumber:build
                                          tweakVersion:FBP_VERSION];
    });
    return shared;
}

+ (NSArray<NSString *> *)criticalHookIdentifiers {
    return @[
        @"MediaGuard.UIImageView",
        @"MediaGuard.NSURLSession",
        @"MediaGuard.AVPlayer",
        @"NavigationGuard.UIViewController",
        @"NavigationGuard.UINavigationController",
        @"LinkBridge.AppDelegate",
        @"FeedFilter.FBMemModelObject",
    ];
}

+ (FBPKosherVersionSupport)supportLevelForFacebookVersion:(NSString *)version {
    if (version.length == 0 || [version isEqualToString:@"unknown"]) {
        return FBPKosherVersionSupportUnknown;
    }
    NSArray<NSString *> *verifiedPrefixes = @[@"570.", @"574.", @"578.", @"585.", @"586."];
    for (NSString *prefix in verifiedPrefixes) {
        if ([version hasPrefix:prefix]) return FBPKosherVersionSupportVerifiedHooks;
    }
    // Build 587 introduced C++ ComponentKit Reels surveys and Hermes Marketplace modules.
    if ([version hasPrefix:@"587."]) {
        return FBPKosherVersionSupportPartial;
    }
    return FBPKosherVersionSupportUnknown;
}

- (instancetype)initWithFacebookVersion:(NSString *)fbVersion
                            buildNumber:(NSString *)buildNumber
                           tweakVersion:(NSString *)tweakVersion {
    if ((self = [super init])) {
        _lock = [[NSLock alloc] init];
        _records = [NSMutableDictionary dictionary];
        _facebookVersion = [fbVersion copy];
        _facebookBuildNumber = [buildNumber copy];
        _tweakVersion = [tweakVersion copy];
        _versionSupport = [self.class supportLevelForFacebookVersion:fbVersion];
        _marketplaceCapabilityVerified = NO;
        _marketplaceReason = @"Marketplace strict text-only Hermes/Relay surface is unverified and blocked by default.";

        for (NSString *criticalID in [self.class criticalHookIdentifiers]) {
            FBPKosherHookStatusRecord *rec = [[FBPKosherHookStatusRecord alloc] init];
            rec.identifier = criticalID;
            rec.severity = FBPKosherHookSeverityCritical;
            rec.status = FBPKosherHookStatusPending;
            rec.detail = @"Awaiting initialization";
            rec.updatedAt = [NSDate date];
            _records[criticalID] = rec;
        }
    }
    return self;
}

- (void)reportHook:(NSString *)identifier
          severity:(FBPKosherHookSeverity)severity
            status:(FBPKosherHookStatus)status
            detail:(NSString *)detail {
    if (identifier.length == 0) return;

    FBPKosherHookStatusRecord *rec = [[FBPKosherHookStatusRecord alloc] init];
    rec.identifier = identifier;
    rec.severity = severity;
    rec.status = status;
    rec.detail = detail;
    rec.updatedAt = [NSDate date];

    [_lock lock];
    _records[identifier] = rec;
    [_lock unlock];

    if (status == FBPKosherHookStatusMissing || status == FBPKosherHookStatusFailed) {
        [FBPKosherDiagnostics.shared recordSecurityEvent:@"hook_unavailable"
                                                  detail:[NSString stringWithFormat:@"%@:%@", identifier, detail ?: @""]];
    }
}

- (void)markPolicyStoreInitialized:(BOOL)initialized {
    [_lock lock];
    _policyStoreInitialized = initialized;
    [_lock unlock];
}

- (void)markMarketplaceCapabilityVerified:(BOOL)verified reason:(NSString *)reason {
    [_lock lock];
    _marketplaceCapabilityVerified = verified;
    if (reason.length) _marketplaceReason = [reason copy];
    [_lock unlock];
}

- (BOOL)policyStoreInitialized {
    [_lock lock];
    BOOL v = _policyStoreInitialized;
    [_lock unlock];
    return v;
}

- (BOOL)criticalEnforcementHealthy {
    [_lock lock];
    BOOL storeReady = _policyStoreInitialized;
    NSDictionary<NSString *, FBPKosherHookStatusRecord *> *snapshot = [_records copy];
    [_lock unlock];

    if (!storeReady) return NO;

    for (NSString *criticalID in [self.class criticalHookIdentifiers]) {
        FBPKosherHookStatusRecord *rec = snapshot[criticalID];
        if (!rec || rec.status != FBPKosherHookStatusInstalled) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)marketplaceEnforcementVerified {
    [_lock lock];
    BOOL verified = _marketplaceCapabilityVerified;
    FBPKosherHookStatusRecord *rnHook = _records[@"Marketplace.RCTNetworking"];
    [_lock unlock];

    if (!self.criticalEnforcementHealthy) return NO;
    if (!verified) return NO;
    if (!rnHook || rnHook.status != FBPKosherHookStatusInstalled) return NO;
    return YES;
}

- (NSArray<FBPKosherHookStatusRecord *> *)hookRecords {
    [_lock lock];
    NSArray<NSString *> *keys = [_records.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<FBPKosherHookStatusRecord *> *list = [NSMutableArray arrayWithCapacity:keys.count];
    for (NSString *k in keys) {
        [list addObject:_records[k]];
    }
    [_lock unlock];
    return [list copy];
}

- (void)evaluateStartupHealth {
    BOOL healthy = self.criticalEnforcementHealthy;
    [FBPKosherDiagnostics.shared recordSecurityEvent:(healthy ? @"startup_compat_ok" : @"startup_compat_failed")
                                              detail:[NSString stringWithFormat:@"fb=%@ support=%ld",
                                                      self.facebookVersion, (long)self.versionSupport]];
    [NSNotificationCenter.defaultCenter postNotificationName:FBPKosherPolicyDidChangeNotification
                                                      object:self];
}

- (NSString *)restrictedStateMessage {
    return @"לא ניתן להפעיל את הסינון בצורה בטוחה בגרסה זו של פייסבוק.";
}

- (NSDictionary<NSString *, id> *)compatibilityReportDictionary {
    NSMutableDictionary<NSString *, id> *hooksDict = [NSMutableDictionary dictionary];
    for (FBPKosherHookStatusRecord *rec in self.hookRecords) {
        NSString *statusStr = @"pending";
        if (rec.status == FBPKosherHookStatusInstalled) statusStr = @"installed";
        else if (rec.status == FBPKosherHookStatusMissing) statusStr = @"missing";
        else if (rec.status == FBPKosherHookStatusFailed) statusStr = @"failed";

        NSString *sevStr = @"cosmetic";
        if (rec.severity == FBPKosherHookSeverityCritical) sevStr = @"critical";
        else if (rec.severity == FBPKosherHookSeveritySurface) sevStr = @"surface";

        hooksDict[rec.identifier] = @{
            @"severity": sevStr,
            @"status": statusStr,
            @"detail": rec.detail ?: @"",
        };
    }

    return @{
        @"facebookVersion": self.facebookVersion ?: @"unknown",
        @"facebookBuild": self.facebookBuildNumber ?: @"unknown",
        @"tweakVersion": self.tweakVersion ?: @"unknown",
        @"versionSupport": @(self.versionSupport),
        @"policyStoreInitialized": @(self.policyStoreInitialized),
        @"criticalEnforcementHealthy": @(self.criticalEnforcementHealthy),
        @"marketplaceEnforcementVerified": @(self.marketplaceEnforcementVerified),
        @"marketplaceReason": _marketplaceReason ?: @"",
        @"hooks": hooksDict,
    };
}

- (NSString *)formattedHebrewDiagnosticsReport {
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"גרסת פייסבוק: %@\n", FBPBidiIsolateLTR(self.facebookVersion ?: @"—")];
    [report appendFormat:@"Build: %@\n", FBPBidiIsolateLTR(self.facebookBuildNumber ?: @"—")];
    [report appendFormat:@"גרסת תוסף: %@\n", FBPBidiIsolateLTR(self.tweakVersion ?: @"—")];

    NSString *supportText = @"לא מזוהה (מצב חסימה מחמיר)";
    if (self.versionSupport == FBPKosherVersionSupportVerifiedHooks) {
        supportText = @"תואם לממשקי ה-ObjC המוכרים (הרצה במכשיר נדרשת לאימות סופי)";
    } else if (self.versionSupport == FBPKosherVersionSupportPartial) {
        supportText = @"תאימות חלקית (רכיבי Reels C++ / Marketplace Hermes חסומים)";
    }
    [report appendFormat:@"סטטוס תאימות גרסה: %@\n", supportText];
    [report appendFormat:@"אכיפה קריטית פעילה: %@\n", self.criticalEnforcementHealthy ? @"כן" : @"לא (מצב חסום)"];
    [report appendFormat:@"אכיפת מרקטפלייס מאומתת: %@\n\n", self.marketplaceEnforcementVerified ? @"כן" : @"לא (חסום כברירת מחדל)"];

    [report appendString:@"פירוט רכיבי האכיפה:\n"];
    for (FBPKosherHookStatusRecord *rec in self.hookRecords) {
        NSString *badge = @"• ממתין";
        if (rec.status == FBPKosherHookStatusInstalled) badge = @"✓ פעיל";
        else if (rec.status == FBPKosherHookStatusMissing) badge = @"✕ חסר";
        else if (rec.status == FBPKosherHookStatusFailed) badge = @"✕ נכשל";
        [report appendFormat:@"  %@ — %@ (%@)\n",
         badge, FBPBidiIsolateLTR(rec.identifier), rec.detail ?: @""];
    }
    return [report copy];
}

@end
