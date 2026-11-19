// Persistent allowlist store, PBKDF2-HMAC-SHA256 PIN auth, rate limiting, and recovery.

#import "FBPKosherPolicyStore.h"
#import "FBPKosherDiagnostics.h"
#import "FBPKosherCompatibilityMonitor.h"
#import "FBPPrefs.h"

#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <math.h>

NSErrorDomain const FBPKosherPolicyStoreErrorDomain = @"com.shajon.fbplus.kosher.store";

static NSString *const kKeychainService = @"com.shajon.fbplus.kosher.admin";
static NSString *const kAccountPINRecord = @"admin_pin_v1";
static NSString *const kAccountRecoveryRecord = @"admin_recovery_v1";
static NSString *const kAccountAttemptRecord = @"admin_attempts_v1";
static NSString *const kAccountStrictOverride = @"strict_mode_override_v1";

static const uint32_t kPBKDF2Iterations = 120000;
static const size_t kSaltLength = 32;
static const size_t kHashLength = 32;
static const NSTimeInterval kAdminSessionTTL = 300.0; // 5 minutes
static const NSUInteger kPolicySchemaVersion = 1;
static const NSUInteger kMaxImportBytes = 512 * 1024;
static const NSUInteger kMaxAllowedSources = 2000;

#pragma mark - Constant-time & Crypto Helpers

static BOOL FBPConstantTimeEqualData(NSData *a, NSData *b) {
    if (!a || !b || a.length != b.length || a.length == 0) return NO;
    const uint8_t *pa = (const uint8_t *)a.bytes;
    const uint8_t *pb = (const uint8_t *)b.bytes;
    uint8_t diff = 0;
    for (size_t i = 0; i < a.length; i++) {
        diff |= (pa[i] ^ pb[i]);
    }
    return diff == 0;
}

static NSData *FBPRandomBytes(size_t length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    if (SecRandomCopyBytes(kSecRandomDefault, length, data.mutableBytes) != errSecSuccess) {
        return nil;
    }
    return [data copy];
}

static NSData *FBPDerivePBKDF2(NSString *secret, NSData *salt, uint32_t iterations) {
    if (secret.length == 0 || salt.length == 0 || iterations < 10000) return nil;
    NSData *secretData = [secret dataUsingEncoding:NSUTF8StringEncoding];
    if (!secretData) return nil;

    NSMutableData *derived = [NSMutableData dataWithLength:kHashLength];
    int rc = CCKeyDerivationPBKDF(kCCPBKDF2,
                                  (const char *)secretData.bytes,
                                  secretData.length,
                                  (const uint8_t *)salt.bytes,
                                  salt.length,
                                  kCCPRFHmacAlgSHA256,
                                  iterations,
                                  (uint8_t *)derived.mutableBytes,
                                  derived.length);
    if (rc != kCCSuccess) return nil;
    return [derived copy];
}

static NSString *FBPGenerateRecoveryCode(void) {
    static const char kAlphabet[] = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"; // Crockford Base32 (32 chars)
    NSData *entropy = FBPRandomBytes(16);
    if (entropy.length != 16) return nil;
    const uint8_t *bytes = (const uint8_t *)entropy.bytes;
    NSMutableString *raw = [NSMutableString stringWithCapacity:19];
    for (NSUInteger i = 0; i < 16; i++) {
        if (i > 0 && (i % 4) == 0) [raw appendString:@"-"];
        [raw appendFormat:@"%c", kAlphabet[bytes[i] & 0x1F]];
    }
    return [raw copy];
}

static NSString *FBPNormalizeRecoveryInput(NSString *input) {
    if (![input isKindOfClass:NSString.class]) return @"";
    NSString *upper = input.uppercaseString;
    NSMutableString *clean = [NSMutableString stringWithCapacity:upper.length];
    for (NSUInteger i = 0; i < upper.length; i++) {
        unichar c = [upper characterAtIndex:i];
        if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z')) {
            [clean appendFormat:@"%C", c];
        }
    }
    return [clean copy];
}

static BOOL FBPIsValidPINFormat(NSString *pin) {
    if (![pin isKindOfClass:NSString.class]) return NO;
    if (pin.length < 6 || pin.length > 16) return NO;
    for (NSUInteger i = 0; i < pin.length; i++) {
        unichar c = [pin characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    return YES;
}

static NSTimeInterval FBPLockoutDurationForAttempts(NSUInteger attempts) {
    if (attempts < 5) return 0;
    if (attempts == 5) return 60;
    if (attempts == 6) return 300;
    if (attempts == 7) return 900;
    return 3600;
}

#pragma mark - Admin Session

@interface FBPKosherAdminSession ()
@property (nonatomic, copy, readwrite) NSString *token;
@property (nonatomic, copy, readwrite) NSDate *expiresAt;
@property (nonatomic, assign) BOOL revoked;
@end

@implementation FBPKosherAdminSession

- (instancetype)initWithToken:(NSString *)token expiresAt:(NSDate *)expiresAt {
    if ((self = [super init])) {
        _token = [token copy];
        _expiresAt = [expiresAt copy];
        _revoked = NO;
    }
    return self;
}

- (BOOL)isValid {
    if (self.revoked || self.token.length == 0) return NO;
    return [self.expiresAt timeIntervalSinceNow] > 0;
}

- (void)invalidate {
    self.revoked = YES;
}

@end

#pragma mark - Keychain Credential Backing

@interface FBPKosherKeychainCredentialBacking : NSObject <FBPKosherCredentialBacking>
@end

@implementation FBPKosherKeychainCredentialBacking

- (NSDictionary *)baseQueryForAccount:(NSString *)account {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: account,
    };
}

- (nullable NSData *)readSecretDataForAccount:(NSString *)account error:(NSError **)error {
    NSMutableDictionary *query = [[self baseQueryForAccount:account] mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound) {
        return nil;
    }
    if (status != errSecSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:FBPKosherPolicyStoreErrorDomain
                                         code:FBPKosherPolicyStoreErrorKeychainFailure
                                     userInfo:@{@"osstatus": @(status)}];
        }
        return nil;
    }
    NSData *data = (__bridge_transfer NSData *)result;
    return [data isKindOfClass:NSData.class] ? data : nil;
}

- (BOOL)writeSecretData:(NSData *)data forAccount:(NSString *)account error:(NSError **)error {
    if (!data) return NO;
    NSDictionary *query = [self baseQueryForAccount:account];
    NSDictionary *update = @{(__bridge id)kSecValueData: data};

    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *attrs = [query mutableCopy];
        attrs[(__bridge id)kSecValueData] = data;
        attrs[(__bridge id)kSecAttrAccessible] =
            (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)attrs, NULL);
    }
    if (status != errSecSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:FBPKosherPolicyStoreErrorDomain
                                         code:FBPKosherPolicyStoreErrorKeychainFailure
                                     userInfo:@{@"osstatus": @(status)}];
        }
        return NO;
    }
    return YES;
}

- (BOOL)deleteSecretForAccount:(NSString *)account error:(NSError **)error {
    NSDictionary *query = [self baseQueryForAccount:account];
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    if (status == errSecSuccess || status == errSecItemNotFound) {
        return YES;
    }
    if (error) {
        *error = [NSError errorWithDomain:FBPKosherPolicyStoreErrorDomain
                                     code:FBPKosherPolicyStoreErrorKeychainFailure
                                 userInfo:@{@"osstatus": @(status)}];
    }
    return NO;
}

@end

#pragma mark - Store Implementation

@implementation FBPKosherPolicyStore {
    NSRecursiveLock *_lock;
    NSURL *_storageDir;
    NSURL *_policyFileURL;
    id<FBPKosherCredentialBacking> _backing;
    BOOL _mirrorToShared;

    NSMutableArray<FBPKosherApprovedSource *> *_sources;
    BOOL _strictModeEnabled;
    BOOL _marketplaceAdminEnabled;
    FBPKosherAdminSession *_activeSession;
    id _bgObserver;
}

+ (FBPKosherPolicyStore *)shared {
    static FBPKosherPolicyStore *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURL *appSupport = [NSFileManager.defaultManager
            URLsForDirectory:NSApplicationSupportDirectory
                   inDomains:NSUserDomainMask].firstObject;
        NSURL *dir = [appSupport URLByAppendingPathComponent:@"FacebookKosher" isDirectory:YES];
        shared = [[self alloc] initWithStorageDirectory:dir
                                      credentialBacking:[[FBPKosherKeychainCredentialBacking alloc] init]
                                         mirrorToShared:YES];
    });
    return shared;
}

- (instancetype)initWithStorageDirectory:(NSURL *)directory
                       credentialBacking:(id<FBPKosherCredentialBacking>)backing
                          mirrorToShared:(BOOL)mirrorToShared {
    if ((self = [super init])) {
        _lock = [[NSRecursiveLock alloc] init];
        _storageDir = directory;
        _policyFileURL = [directory URLByAppendingPathComponent:@"policy.json"];
        _backing = backing;
        _mirrorToShared = mirrorToShared;
        _sources = [NSMutableArray array];
        _strictModeEnabled = YES;
        _marketplaceAdminEnabled = NO;

        [self ensureStorageDirectory];
        [self loadPolicyFromDisk];
        [self enforceStrictDefaultsAndMigrationIntegrity];

        __weak typeof(self) weakSelf = self;
        _bgObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *note) {
            [weakSelf lockAdminSession];
        }];

        [FBPKosherCompatibilityMonitor.shared markPolicyStoreInitialized:YES];
    }
    return self;
}

- (void)dealloc {
    if (_bgObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:_bgObserver];
    }
}

- (void)ensureStorageDirectory {
    if (!_storageDir) return;
    [NSFileManager.defaultManager createDirectoryAtURL:_storageDir
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
}

- (NSError *)errorWithCode:(FBPKosherPolicyStoreErrorCode)code message:(NSString *)message {
    return [NSError errorWithDomain:FBPKosherPolicyStoreErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Policy store error"}];
}

- (void)enforceStrictDefaultsAndMigrationIntegrity {
    [_lock lock];
    // Strict mode can only be disabled if an admin PIN is configured, the policy file
    // explicitly records strictMode=NO, AND the Keychain holds an authorized disable record.
    // Migrated Facebook-Plus prefs or missing files always default/snap back to Strict Mode.
    BOOL allowDisable = NO;
    if (!_strictModeEnabled && [self hasConfiguredAdminPIN]) {
        NSData *overrideData = [_backing readSecretDataForAccount:kAccountStrictOverride error:nil];
        if (overrideData.length > 0) {
            NSString *val = [[NSString alloc] initWithData:overrideData encoding:NSUTF8StringEncoding];
            if ([val isEqualToString:@"ADMIN_AUTHORIZED_DISABLE"]) {
                allowDisable = YES;
            }
        }
    }
    if (!allowDisable) {
        _strictModeEnabled = YES;
    }

    if (_strictModeEnabled) {
        [FBPPrefs.shared applyAdminStrictMode:YES];
    }
    [FBPPrefs.shared applyAdminMarketplaceEnabled:_marketplaceAdminEnabled];
    [_lock unlock];
}

- (BOOL)strictModeEnabled {
    [_lock lock];
    BOOL v = _strictModeEnabled;
    [_lock unlock];
    return v;
}

- (BOOL)marketplaceAdminEnabled {
    [_lock lock];
    BOOL v = _marketplaceAdminEnabled;
    [_lock unlock];
    return v;
}

#pragma mark - Persistence

- (void)loadPolicyFromDisk {
    [_lock lock];
    [_sources removeAllObjects];
    _strictModeEnabled = YES;
    _marketplaceAdminEnabled = NO;

    NSData *data = _policyFileURL ? [NSData dataWithContentsOfURL:_policyFileURL] : nil;
    if (data.length > 0 && data.length <= kMaxImportBytes) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([json isKindOfClass:NSDictionary.class]) {
            NSDictionary *dict = (NSDictionary *)json;
            id strictVal = dict[@"strictModeEnabled"];
            if ([strictVal isKindOfClass:NSNumber.class]) {
                _strictModeEnabled = [strictVal boolValue];
            }
            id marketVal = dict[@"marketplaceAdminEnabled"];
            if ([marketVal isKindOfClass:NSNumber.class]) {
                _marketplaceAdminEnabled = [marketVal boolValue];
            }
            id rawSources = dict[@"approvedSources"];
            if ([rawSources isKindOfClass:NSArray.class]) {
                for (id entry in (NSArray *)rawSources) {
                    if (_sources.count >= kMaxAllowedSources) break;
                    FBPKosherApprovedSource *src = [FBPKosherApprovedSource fromJSONDictionary:entry];
                    if (src && [self indexForIdentifier:src.identifier kind:src.kind] == NSNotFound) {
                        [_sources addObject:src];
                    }
                }
            }
        }
    }
    [_lock unlock];
    [self writeNSEPolicyMirror];
}

- (NSData *)serializedPolicyDataLocked {
    NSMutableArray<NSDictionary *> *encoded = [NSMutableArray arrayWithCapacity:_sources.count];
    for (FBPKosherApprovedSource *src in _sources) {
        [encoded addObject:[src toJSONDictionary]];
    }
    NSDictionary *payload = @{
        @"schemaVersion": @(kPolicySchemaVersion),
        @"strictModeEnabled": @(_strictModeEnabled),
        @"marketplaceAdminEnabled": @(_marketplaceAdminEnabled),
        @"approvedSources": encoded,
    };
    return [NSJSONSerialization dataWithJSONObject:payload
                                           options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                             error:nil];
}

- (BOOL)savePolicyToDiskLocked {
    [self ensureStorageDirectory];
    NSData *data = [self serializedPolicyDataLocked];
    if (!data || !_policyFileURL) return NO;
    NSError *err = nil;
    BOOL ok = [data writeToURL:_policyFileURL
                       options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication
                         error:&err];
    if (ok) {
        [self writeNSEPolicyMirror];
        [NSNotificationCenter.defaultCenter postNotificationName:FBPKosherPolicyDidChangeNotification
                                                          object:self];
    }
    return ok;
}

/// Writes a minimal, PIN-free snapshot (strict flag + approved group/page IDs)
/// to the App-Group container so FBPNotifyBridge in the NSE can enforce policy
/// without pulling in UIKit or Keychain admin state.
- (void)writeNSEPolicyMirror {
    if (!_mirrorToShared) return;
    [_lock lock];
    NSMutableArray<NSString *> *groupIDs = [NSMutableArray array];
    NSMutableArray<NSString *> *pageIDs = [NSMutableArray array];
    for (FBPKosherApprovedSource *src in _sources) {
        if (src.kind == FBPKosherSourceKindGroup) [groupIDs addObject:src.identifier];
        else if (src.kind == FBPKosherSourceKindPage) [pageIDs addObject:src.identifier];
    }
    NSDictionary *mirror = @{
        @"strictMode": @(_strictModeEnabled),
        @"safeNotificationsOnly": @([FBPPrefs.shared boolForKey:FBPKeyKosherSafeNotificationsOnly]),
        @"approvedGroupIDs": groupIDs,
        @"approvedPageIDs": pageIDs,
    };
    [_lock unlock];

    NSData *json = [NSJSONSerialization dataWithJSONObject:mirror options:0 error:nil];
    if (!json) return;

    // Write to Caches/Library App Support and redirected App Group if available.
    NSString *appGroupID = @"group.com.facebook.Facebook";
    NSURL *groupURL = [NSFileManager.defaultManager
        containerURLForSecurityApplicationGroupIdentifier:appGroupID];
    if (groupURL) {
        NSURL *mirrorURL = [groupURL URLByAppendingPathComponent:@"fbp_kosher_nse_policy.json"];
        [json writeToURL:mirrorURL atomically:YES];
    }
}

#pragma mark - Credential Records

- (nullable NSDictionary *)readJSONRecordForAccount:(NSString *)account {
    NSData *data = [_backing readSecretDataForAccount:account error:nil];
    if (!data.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

- (BOOL)writeJSONRecord:(NSDictionary *)dict forAccount:(NSString *)account error:(NSError **)error {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:error];
    if (!data) return NO;
    return [_backing writeSecretData:data forAccount:account error:error];
}

- (BOOL)storeDerivedSecret:(NSString *)secret forAccount:(NSString *)account error:(NSError **)error {
    NSData *salt = FBPRandomBytes(kSaltLength);
    if (!salt) {
        if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorKeychainFailure
                                        message:@"Random salt generation failed"];
        return NO;
    }
    NSData *hash = FBPDerivePBKDF2(secret, salt, kPBKDF2Iterations);
    if (!hash) {
        if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorKeychainFailure
                                        message:@"PBKDF2 key derivation failed"];
        return NO;
    }
    NSDictionary *record = @{
        @"v": @1,
        @"alg": @"PBKDF2-HMAC-SHA256",
        @"iter": @(kPBKDF2Iterations),
        @"salt": [salt base64EncodedStringWithOptions:0],
        @"hash": [hash base64EncodedStringWithOptions:0],
    };
    return [self writeJSONRecord:record forAccount:account error:error];
}

- (BOOL)verifySecret:(NSString *)secret againstAccount:(NSString *)account {
    NSDictionary *record = [self readJSONRecordForAccount:account];
    if (!record) return NO;
    NSString *saltB64 = [record[@"salt"] isKindOfClass:NSString.class] ? record[@"salt"] : nil;
    NSString *hashB64 = [record[@"hash"] isKindOfClass:NSString.class] ? record[@"hash"] : nil;
    NSNumber *iterNum = [record[@"iter"] isKindOfClass:NSNumber.class] ? record[@"iter"] : nil;
    if (!saltB64 || !hashB64 || !iterNum) return NO;

    NSData *salt = [[NSData alloc] initWithBase64EncodedString:saltB64 options:0];
    NSData *expected = [[NSData alloc] initWithBase64EncodedString:hashB64 options:0];
    uint32_t iterations = iterNum.unsignedIntValue;
    if (!salt.length || !expected.length || iterations < 10000) return NO;

    NSData *candidate = FBPDerivePBKDF2(secret, salt, iterations);
    return FBPConstantTimeEqualData(candidate, expected);
}

#pragma mark - Rate Limiting

- (void)readAttemptStateCount:(NSUInteger *)countOut lockoutUntil:(NSTimeInterval *)untilOut {
    NSDictionary *record = [self readJSONRecordForAccount:kAccountAttemptRecord];
    NSUInteger count = [record[@"failures"] isKindOfClass:NSNumber.class] ? [record[@"failures"] unsignedIntegerValue] : 0;
    NSTimeInterval until = [record[@"lockoutUntil"] isKindOfClass:NSNumber.class] ? [record[@"lockoutUntil"] doubleValue] : 0;
    if (countOut) *countOut = count;
    if (untilOut) *untilOut = until;
}

- (void)recordFailedAttempt {
    NSUInteger count = 0;
    NSTimeInterval until = 0;
    [self readAttemptStateCount:&count lockoutUntil:&until];
    count += 1;
    NSTimeInterval duration = FBPLockoutDurationForAttempts(count);
    NSTimeInterval newUntil = duration > 0 ? ([NSDate.date timeIntervalSince1970] + duration) : 0;
    [self writeJSONRecord:@{@"failures": @(count), @"lockoutUntil": @(newUntil)}
               forAccount:kAccountAttemptRecord
                    error:nil];
}

- (void)resetFailedAttempts {
    [_backing deleteSecretForAccount:kAccountAttemptRecord error:nil];
}

- (NSUInteger)failedPINAttempts {
    [_lock lock];
    NSUInteger count = 0;
    [self readAttemptStateCount:&count lockoutUntil:nil];
    [_lock unlock];
    return count;
}

- (NSTimeInterval)remainingLockoutSeconds {
    [_lock lock];
    NSTimeInterval until = 0;
    [self readAttemptStateCount:nil lockoutUntil:&until];
    [_lock unlock];
    NSTimeInterval diff = until - [NSDate.date timeIntervalSince1970];
    return diff > 0 ? diff : 0;
}

#pragma mark - PIN & Session API

- (BOOL)hasConfiguredAdminPIN {
    [_lock lock];
    BOOL configured = ([self readJSONRecordForAccount:kAccountPINRecord] != nil);
    [_lock unlock];
    return configured;
}

- (nullable FBPKosherAdminSession *)activeAdminSession {
    [_lock lock];
    FBPKosherAdminSession *session = (_activeSession && _activeSession.isValid) ? _activeSession : nil;
    [_lock unlock];
    return session;
}

- (FBPKosherAdminSession *)issueNewAdminSessionLocked {
    [_activeSession invalidate];
    _activeSession = [[FBPKosherAdminSession alloc]
        initWithToken:NSUUID.UUID.UUIDString
            expiresAt:[NSDate dateWithTimeIntervalSinceNow:kAdminSessionTTL]];
    return _activeSession;
}

- (BOOL)configureInitialAdminPIN:(NSString *)pin
                 recoveryCodeOut:(NSString * _Nullable * _Nonnull)recoveryCodeOut
                      sessionOut:(FBPKosherAdminSession * _Nullable * _Nullable)sessionOut
                           error:(NSError **)error {
    [_lock lock];
    @try {
        if ([self hasConfiguredAdminPIN]) {
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorPINAlreadyConfigured
                                            message:@"Administrator PIN is already configured"];
            return NO;
        }
        if (!FBPIsValidPINFormat(pin)) {
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorInvalidPINFormat
                                            message:@"PIN must be 6-16 numeric digits"];
            return NO;
        }
        NSString *recovery = FBPGenerateRecoveryCode();
        if (!recovery) {
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorKeychainFailure
                                            message:@"Could not generate recovery code"];
            return NO;
        }
        NSString *normalizedRecovery = FBPNormalizeRecoveryInput(recovery);
        if (![self storeDerivedSecret:pin forAccount:kAccountPINRecord error:error]) {
            return NO;
        }
        if (![self storeDerivedSecret:normalizedRecovery forAccount:kAccountRecoveryRecord error:error]) {
            [_backing deleteSecretForAccount:kAccountPINRecord error:nil];
            return NO;
        }
        [self resetFailedAttempts];
        FBPKosherAdminSession *session = [self issueNewAdminSessionLocked];
        if (recoveryCodeOut) *recoveryCodeOut = recovery;
        if (sessionOut) *sessionOut = session;
        [FBPKosherDiagnostics.shared recordSecurityEvent:@"admin_pin_configured" detail:@"initial_setup"];
        return YES;
    } @finally {
        [_lock unlock];
    }
}

- (nullable FBPKosherAdminSession *)authenticateWithPIN:(NSString *)pin error:(NSError **)error {
    [_lock lock];
    @try {
        if (![self hasConfiguredAdminPIN]) {
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorPINNotConfigured
                                            message:@"Administrator PIN has not been set"];
            return nil;
        }
        NSTimeInterval remaining = [self remainingLockoutSeconds];
        if (remaining > 0) {
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorLockedOut
                                            message:[NSString stringWithFormat:@"Locked out for %.0f seconds", ceil(remaining)]];
            [FBPKosherDiagnostics.shared recordSecurityEvent:@"admin_pin_lockout_hit" detail:@"rate_limited"];
            return nil;
        }
        if (!FBPIsValidPINFormat(pin) || ![self verifySecret:pin againstAccount:kAccountPINRecord]) {
            [self recordFailedAttempt];
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorIncorrectPIN
                                            message:@"Incorrect administrator PIN"];
            [FBPKosherDiagnostics.shared recordSecurityEvent:@"admin_pin_failed" detail:@"invalid_pin"];
            return nil;
        }
        [self resetFailedAttempts];
        FBPKosherAdminSession *session = [self issueNewAdminSessionLocked];
        [FBPKosherDiagnostics.shared recordSecurityEvent:@"admin_pin_unlocked" detail:@"session_started"];
        return session;
    } @finally {
        [_lock unlock];
    }
}

- (BOOL)changeAdminPINFrom:(NSString *)currentPIN
                     toPIN:(NSString *)newPIN
                   session:(FBPKosherAdminSession *)session
                     error:(NSError **)error {
    [_lock lock];
    @try {
        if (![self validateAdminSession:session error:error]) return NO;
        if (![self verifySecret:currentPIN againstAccount:kAccountPINRecord]) {
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorIncorrectPIN
                                            message:@"Current PIN is incorrect"];
            return NO;
        }
        if (!FBPIsValidPINFormat(newPIN)) {
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorInvalidPINFormat
                                            message:@"PIN must be 6-16 numeric digits"];
            return NO;
        }
        if (![self storeDerivedSecret:newPIN forAccount:kAccountPINRecord error:error]) return NO;
        [FBPKosherDiagnostics.shared recordSecurityEvent:@"admin_pin_changed" detail:@"rotated"];
        return YES;
    } @finally {
        [_lock unlock];
    }
}

- (BOOL)resetAdminPINWithRecoveryCode:(NSString *)recoveryCode
                               newPIN:(NSString *)newPIN
                  newRecoveryCodeOut:(NSString * _Nullable * _Nonnull)newRecoveryCodeOut
                               error:(NSError **)error {
    [_lock lock];
    @try {
        if (![self hasConfiguredAdminPIN]) {
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorPINNotConfigured
                                            message:@"No PIN configured"];
            return NO;
        }
        NSTimeInterval remaining = [self remainingLockoutSeconds];
        if (remaining > 0) {
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorLockedOut
                                            message:@"Locked out"];
            return NO;
        }
        NSString *normalized = FBPNormalizeRecoveryInput(recoveryCode);
        if (normalized.length < 8 || ![self verifySecret:normalized againstAccount:kAccountRecoveryRecord]) {
            [self recordFailedAttempt];
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorInvalidRecoveryCode
                                            message:@"Invalid recovery code"];
            [FBPKosherDiagnostics.shared recordSecurityEvent:@"admin_recovery_failed" detail:@"invalid_code"];
            return NO;
        }
        if (!FBPIsValidPINFormat(newPIN)) {
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorInvalidPINFormat
                                            message:@"PIN must be 6-16 numeric digits"];
            return NO;
        }
        NSString *nextRecovery = FBPGenerateRecoveryCode();
        if (!nextRecovery) return NO;
        if (![self storeDerivedSecret:newPIN forAccount:kAccountPINRecord error:error]) return NO;
        if (![self storeDerivedSecret:FBPNormalizeRecoveryInput(nextRecovery)
                           forAccount:kAccountRecoveryRecord
                                error:error]) return NO;
        [self resetFailedAttempts];
        // Recovery ALWAYS keeps Strict Mode active.
        _strictModeEnabled = YES;
        [_backing deleteSecretForAccount:kAccountStrictOverride error:nil];
        [FBPPrefs.shared applyAdminStrictMode:YES];
        [self savePolicyToDiskLocked];

        if (newRecoveryCodeOut) *newRecoveryCodeOut = nextRecovery;
        [FBPKosherDiagnostics.shared recordSecurityEvent:@"admin_pin_recovered" detail:@"strict_preserved"];
        return YES;
    } @finally {
        [_lock unlock];
    }
}

- (void)lockAdminSession {
    [_lock lock];
    [_activeSession invalidate];
    _activeSession = nil;
    [_lock unlock];
}

- (BOOL)validateAdminSession:(FBPKosherAdminSession *)session error:(NSError **)error {
    [_lock lock];
    @try {
        if (!session || !_activeSession || session != _activeSession ||
            ![session.token isEqualToString:_activeSession.token]) {
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorUnauthorized
                                            message:@"Administrator authentication required"];
            return NO;
        }
        if (!session.isValid) {
            [_activeSession invalidate];
            _activeSession = nil;
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorSessionExpired
                                            message:@"Administrator session expired"];
            return NO;
        }
        return YES;
    } @finally {
        [_lock unlock];
    }
}

#pragma mark - Admin Policy Toggles

- (BOOL)setStrictModeEnabled:(BOOL)enabled
                     session:(FBPKosherAdminSession *)session
                       error:(NSError **)error {
    [_lock lock];
    @try {
        if (![self validateAdminSession:session error:error]) return NO;
        if (!enabled) {
            NSData *token = [@"ADMIN_AUTHORIZED_DISABLE" dataUsingEncoding:NSUTF8StringEncoding];
            if (![_backing writeSecretData:token forAccount:kAccountStrictOverride error:error]) {
                return NO;
            }
        } else {
            [_backing deleteSecretForAccount:kAccountStrictOverride error:nil];
        }
        _strictModeEnabled = enabled;
        [FBPPrefs.shared applyAdminStrictMode:enabled];
        [self savePolicyToDiskLocked];
        [FBPKosherDiagnostics.shared recordSecurityEvent:@"strict_mode_changed"
                                                  detail:enabled ? @"enabled" : @"disabled_by_admin"];
        return YES;
    } @finally {
        [_lock unlock];
    }
}

- (BOOL)setMarketplaceAdminEnabled:(BOOL)enabled
                           session:(FBPKosherAdminSession *)session
             capabilityVerifiedNow:(BOOL)capabilityVerifiedNow
                             error:(NSError **)error {
    [_lock lock];
    @try {
        if (![self validateAdminSession:session error:error]) return NO;
        if (enabled && !capabilityVerifiedNow) {
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorMarketplaceUnverified
                                            message:@"Marketplace text-only enforcement is not verified on this Facebook version"];
            return NO;
        }
        _marketplaceAdminEnabled = enabled;
        [FBPPrefs.shared applyAdminMarketplaceEnabled:enabled];
        [self savePolicyToDiskLocked];
        [FBPKosherDiagnostics.shared recordSecurityEvent:@"marketplace_admin_changed"
                                                  detail:enabled ? @"enabled" : @"disabled"];
        return YES;
    } @finally {
        [_lock unlock];
    }
}

#pragma mark - Allowlist Lookups & Mutations

- (NSUInteger)indexForIdentifier:(NSString *)identifier kind:(FBPKosherSourceKind)kind {
    NSString *low = identifier.lowercaseString;
    for (NSUInteger i = 0; i < _sources.count; i++) {
        FBPKosherApprovedSource *s = _sources[i];
        if (s.kind == kind && [s.identifier.lowercaseString isEqualToString:low]) {
            return i;
        }
    }
    return NSNotFound;
}

- (NSArray<FBPKosherApprovedSource *> *)allApprovedSources {
    [_lock lock];
    NSArray *copy = [_sources copy];
    [_lock unlock];
    return copy;
}

- (NSArray<FBPKosherApprovedSource *> *)approvedSourcesOfKind:(FBPKosherSourceKind)kind {
    [_lock lock];
    NSMutableArray<FBPKosherApprovedSource *> *out = [NSMutableArray array];
    for (FBPKosherApprovedSource *src in _sources) {
        if (src.kind == kind) [out addObject:src];
    }
    [_lock unlock];
    return [out copy];
}

- (NSArray<FBPKosherApprovedSource *> *)favoriteSources {
    [_lock lock];
    NSMutableArray<FBPKosherApprovedSource *> *out = [NSMutableArray array];
    for (FBPKosherApprovedSource *src in _sources) {
        if (src.isFavorite) [out addObject:src];
    }
    [_lock unlock];
    return [out copy];
}

- (NSArray<FBPKosherApprovedSource *> *)searchApprovedSourcesWithQuery:(NSString *)query {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    [_lock lock];
    if (trimmed.length == 0) {
        NSArray *all = [_sources copy];
        [_lock unlock];
        return all;
    }
    NSMutableArray<FBPKosherApprovedSource *> *matches = [NSMutableArray array];
    for (FBPKosherApprovedSource *src in _sources) {
        if ([src.displayName.lowercaseString containsString:trimmed] ||
            [src.identifier.lowercaseString containsString:trimmed] ||
            (src.notes && [src.notes.lowercaseString containsString:trimmed])) {
            [matches addObject:src];
        }
    }
    [_lock unlock];
    return [matches copy];
}

- (nullable FBPKosherApprovedSource *)approvedSourceWithIdentifier:(NSString *)identifier
                                                              kind:(FBPKosherSourceKind)kind {
    NSString *norm = [FBPKosherApprovedSource normalizedIdentifier:identifier forKind:kind];
    if (!norm) return nil;
    [_lock lock];
    NSUInteger idx = [self indexForIdentifier:norm kind:kind];
    FBPKosherApprovedSource *found = (idx != NSNotFound) ? _sources[idx] : nil;
    [_lock unlock];
    return found;
}

- (BOOL)isGroupApproved:(NSString *)groupIdentifier {
    return [self approvedSourceWithIdentifier:groupIdentifier kind:FBPKosherSourceKindGroup] != nil;
}

- (BOOL)isPageApproved:(NSString *)pageIdentifier {
    return [self approvedSourceWithIdentifier:pageIdentifier kind:FBPKosherSourceKindPage] != nil;
}

- (BOOL)isProfileApproved:(NSString *)profileIdentifier {
    return [self approvedSourceWithIdentifier:profileIdentifier kind:FBPKosherSourceKindProfile] != nil;
}

- (BOOL)isExternalDomainTrusted:(NSString *)host path:(NSString *)path {
    NSString *normHost = [FBPKosherApprovedSource normalizedIdentifier:host
                                                               forKind:FBPKosherSourceKindTrustedDomain];
    if (!normHost) return NO;
    NSString *cleanPath = path ?: @"/";

    [_lock lock];
    BOOL trusted = NO;
    for (FBPKosherApprovedSource *src in _sources) {
        if (src.kind != FBPKosherSourceKindTrustedDomain) continue;
        BOOL hostMatches = [normHost isEqualToString:src.identifier] ||
                           [normHost hasSuffix:[@"." stringByAppendingString:src.identifier]];
        if (!hostMatches) continue;
        if (src.allowedPathPrefix.length > 0) {
            if ([cleanPath hasPrefix:src.allowedPathPrefix]) {
                trusted = YES;
                break;
            }
        } else {
            trusted = YES;
            break;
        }
    }
    [_lock unlock];
    return trusted;
}

- (BOOL)addApprovedSource:(FBPKosherApprovedSource *)source
                  session:(FBPKosherAdminSession *)session
                    error:(NSError **)error {
    [_lock lock];
    @try {
        if (![self validateAdminSession:session error:error]) return NO;
        NSString *norm = [FBPKosherApprovedSource normalizedIdentifier:source.identifier forKind:source.kind];
        if (!norm) {
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorInvalidIdentifier
                                            message:@"Invalid group/page/domain identifier"];
            return NO;
        }
        FBPKosherApprovedSource *validated =
            [[FBPKosherApprovedSource alloc] initWithIdentifier:norm
                                                           kind:source.kind
                                                    displayName:source.displayName
                                                       favorite:source.isFavorite
                                              allowedPathPrefix:source.allowedPathPrefix
                                                          notes:source.notes
                                                        addedAt:source.addedAt];
        NSUInteger existing = [self indexForIdentifier:norm kind:source.kind];
        if (existing != NSNotFound) {
            _sources[existing] = validated;
        } else {
            if (_sources.count >= kMaxAllowedSources) {
                if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorInvalidPolicyImport
                                                message:@"Allowlist limit reached"];
                return NO;
            }
            [_sources addObject:validated];
        }
        [self savePolicyToDiskLocked];
        return YES;
    } @finally {
        [_lock unlock];
    }
}

- (BOOL)updateApprovedSource:(FBPKosherApprovedSource *)source
                     session:(FBPKosherAdminSession *)session
                       error:(NSError **)error {
    return [self addApprovedSource:source session:session error:error];
}

- (BOOL)removeApprovedSourceWithIdentifier:(NSString *)identifier
                                      kind:(FBPKosherSourceKind)kind
                                   session:(FBPKosherAdminSession *)session
                                     error:(NSError **)error {
    [_lock lock];
    @try {
        if (![self validateAdminSession:session error:error]) return NO;
        NSString *norm = [FBPKosherApprovedSource normalizedIdentifier:identifier forKind:kind]
            ?: identifier.lowercaseString;
        NSUInteger idx = [self indexForIdentifier:norm kind:kind];
        if (idx == NSNotFound) return YES;
        [_sources removeObjectAtIndex:idx];
        [self savePolicyToDiskLocked];
        return YES;
    } @finally {
        [_lock unlock];
    }
}

#pragma mark - Import / Export

- (nullable NSData *)exportPolicyJSONWithSession:(FBPKosherAdminSession *)session
                                           error:(NSError **)error {
    [_lock lock];
    @try {
        if (![self validateAdminSession:session error:error]) return nil;
        return [self serializedPolicyDataLocked];
    } @finally {
        [_lock unlock];
    }
}

- (BOOL)importPolicyJSONData:(NSData *)jsonData
                     session:(FBPKosherAdminSession *)session
                       error:(NSError **)error {
    [_lock lock];
    @try {
        if (![self validateAdminSession:session error:error]) return NO;
        if (![jsonData isKindOfClass:NSData.class] || jsonData.length == 0 || jsonData.length > kMaxImportBytes) {
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorInvalidPolicyImport
                                            message:@"Invalid policy payload size"];
            return NO;
        }
        id parsed = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:error];
        if (![parsed isKindOfClass:NSDictionary.class]) {
            if (error && !*error) {
                *error = [self errorWithCode:FBPKosherPolicyStoreErrorInvalidPolicyImport
                                     message:@"Policy must be a JSON object"];
            }
            return NO;
        }
        NSDictionary *dict = (NSDictionary *)parsed;
        NSNumber *schema = [dict[@"schemaVersion"] isKindOfClass:NSNumber.class] ? dict[@"schemaVersion"] : nil;
        if (!schema || schema.unsignedIntegerValue != kPolicySchemaVersion) {
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorInvalidPolicyImport
                                            message:@"Unsupported policy schemaVersion"];
            return NO;
        }
        id rawSources = dict[@"approvedSources"];
        if (![rawSources isKindOfClass:NSArray.class]) {
            if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorInvalidPolicyImport
                                            message:@"Missing approvedSources array"];
            return NO;
        }

        NSMutableArray<FBPKosherApprovedSource *> *validatedSources = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (id item in (NSArray *)rawSources) {
            if (validatedSources.count >= kMaxAllowedSources) {
                if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorInvalidPolicyImport
                                                message:@"Too many sources in imported policy"];
                return NO;
            }
            FBPKosherApprovedSource *src = [FBPKosherApprovedSource fromJSONDictionary:item];
            if (!src) {
                if (error) *error = [self errorWithCode:FBPKosherPolicyStoreErrorInvalidPolicyImport
                                                message:@"Malformed entry in approvedSources"];
                return NO;
            }
            NSString *dedupKey = [NSString stringWithFormat:@"%ld:%@", (long)src.kind, src.identifier];
            if (![seen containsObject:dedupKey]) {
                [seen addObject:dedupKey];
                [validatedSources addObject:src];
            }
        }

        // Imported policy NEVER silently weakens strict mode or unlocks unverified Marketplace.
        _sources = validatedSources;
        [self savePolicyToDiskLocked];
        [FBPKosherDiagnostics.shared recordSecurityEvent:@"policy_imported"
                                                  detail:[NSString stringWithFormat:@"count=%lu", (unsigned long)_sources.count]];
        return YES;
    } @finally {
        [_lock unlock];
    }
}

@end
