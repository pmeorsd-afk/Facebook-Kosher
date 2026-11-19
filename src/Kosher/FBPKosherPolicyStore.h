// Administrator-controlled persistent policy allowlist and Keychain-backed PIN auth.

#import "FBPlus.h"
#import "FBPKosherTypes.h"

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const FBPKosherPolicyStoreErrorDomain;

typedef NS_ENUM(NSInteger, FBPKosherPolicyStoreErrorCode) {
    FBPKosherPolicyStoreErrorUnauthorized = 1,
    FBPKosherPolicyStoreErrorSessionExpired = 2,
    FBPKosherPolicyStoreErrorPINNotConfigured = 3,
    FBPKosherPolicyStoreErrorPINAlreadyConfigured = 4,
    FBPKosherPolicyStoreErrorInvalidPINFormat = 5,
    FBPKosherPolicyStoreErrorIncorrectPIN = 6,
    FBPKosherPolicyStoreErrorLockedOut = 7,
    FBPKosherPolicyStoreErrorInvalidIdentifier = 8,
    FBPKosherPolicyStoreErrorInvalidPolicyImport = 9,
    FBPKosherPolicyStoreErrorKeychainFailure = 10,
    FBPKosherPolicyStoreErrorMarketplaceUnverified = 11,
    FBPKosherPolicyStoreErrorInvalidRecoveryCode = 12,
};

/// Ephemeral in-memory administrator session token obtained after PIN verification.
@interface FBPKosherAdminSession : NSObject
@property (nonatomic, copy, readonly) NSString *token;
@property (nonatomic, copy, readonly) NSDate *expiresAt;
@property (nonatomic, assign, readonly, getter=isValid) BOOL valid;
- (void)invalidate;
@end

/// Key-value storage abstraction for derived credential blobs (Keychain in production).
@protocol FBPKosherCredentialBacking <NSObject>
- (nullable NSData *)readSecretDataForAccount:(NSString *)account error:(NSError **)error;
- (BOOL)writeSecretData:(NSData *)data forAccount:(NSString *)account error:(NSError **)error;
- (BOOL)deleteSecretForAccount:(NSString *)account error:(NSError **)error;
@end

/// Thread-safe persistent store for allowlisted groups, pages, profiles, trusted domains,
/// strict-mode flags, and PBKDF2-HMAC-SHA256 administrator PIN authentication.
@interface FBPKosherPolicyStore : NSObject

@property (class, readonly) FBPKosherPolicyStore *shared;

@property (nonatomic, assign, readonly) BOOL strictModeEnabled;
@property (nonatomic, assign, readonly) BOOL marketplaceAdminEnabled;
@property (nonatomic, assign, readonly) BOOL hasConfiguredAdminPIN;
@property (nonatomic, assign, readonly) NSUInteger failedPINAttempts;
@property (nonatomic, assign, readonly) NSTimeInterval remainingLockoutSeconds;
@property (nonatomic, strong, readonly, nullable) FBPKosherAdminSession *activeAdminSession;

/// Designated initializer (production +shared uses App Support + Keychain).
- (instancetype)initWithStorageDirectory:(NSURL *)directory
                       credentialBacking:(id<FBPKosherCredentialBacking>)backing
                          mirrorToShared:(BOOL)mirrorToShared NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

#pragma mark - Administrator PIN & Session Security

/// Initial administrator PIN setup (minimum 6 numeric digits). Generates and returns
/// a one-time 16-character Crockford Base32 recovery code via recoveryCodeOut.
- (BOOL)configureInitialAdminPIN:(NSString *)pin
                 recoveryCodeOut:(NSString * _Nullable * _Nonnull)recoveryCodeOut
                      sessionOut:(FBPKosherAdminSession * _Nullable * _Nullable)sessionOut
                           error:(NSError **)error;

/// Authenticates with existing PIN, enforcing progressive rate limiting.
- (nullable FBPKosherAdminSession *)authenticateWithPIN:(NSString *)pin error:(NSError **)error;

/// Changes PIN using an active authenticated admin session.
- (BOOL)changeAdminPINFrom:(NSString *)currentPIN
                     toPIN:(NSString *)newPIN
                   session:(FBPKosherAdminSession *)session
                     error:(NSError **)error;

/// Explicit recovery flow: resets PIN using the one-time recovery code while
/// preserving Strict Mode ON and rotating the recovery code.
- (BOOL)resetAdminPINWithRecoveryCode:(NSString *)recoveryCode
                               newPIN:(NSString *)newPIN
                  newRecoveryCodeOut:(NSString * _Nullable * _Nonnull)newRecoveryCodeOut
                               error:(NSError **)error;

/// Locks the current admin session immediately.
- (void)lockAdminSession;

/// Validates an admin session token (non-expired and matching active session).
- (BOOL)validateAdminSession:(nullable FBPKosherAdminSession *)session error:(NSError **)error;

#pragma mark - Policy Toggles (Admin Session Required)

- (BOOL)setStrictModeEnabled:(BOOL)enabled
                     session:(FBPKosherAdminSession *)session
                       error:(NSError **)error;

- (BOOL)setMarketplaceAdminEnabled:(BOOL)enabled
                           session:(FBPKosherAdminSession *)session
             capabilityVerifiedNow:(BOOL)capabilityVerifiedNow
                             error:(NSError **)error;

#pragma mark - Approved Sources (Read-only public, Write requires Admin Session)

- (NSArray<FBPKosherApprovedSource *> *)allApprovedSources;
- (NSArray<FBPKosherApprovedSource *> *)approvedSourcesOfKind:(FBPKosherSourceKind)kind;
- (NSArray<FBPKosherApprovedSource *> *)favoriteSources;
- (NSArray<FBPKosherApprovedSource *> *)searchApprovedSourcesWithQuery:(nullable NSString *)query;

- (nullable FBPKosherApprovedSource *)approvedSourceWithIdentifier:(NSString *)identifier
                                                              kind:(FBPKosherSourceKind)kind;
- (BOOL)isGroupApproved:(NSString *)groupIdentifier;
- (BOOL)isPageApproved:(NSString *)pageIdentifier;
- (BOOL)isProfileApproved:(NSString *)profileIdentifier;
- (BOOL)isExternalDomainTrusted:(NSString *)host path:(nullable NSString *)path;

- (BOOL)addApprovedSource:(FBPKosherApprovedSource *)source
                  session:(FBPKosherAdminSession *)session
                    error:(NSError **)error;

- (BOOL)updateApprovedSource:(FBPKosherApprovedSource *)source
                     session:(FBPKosherAdminSession *)session
                       error:(NSError **)error;

- (BOOL)removeApprovedSourceWithIdentifier:(NSString *)identifier
                                      kind:(FBPKosherSourceKind)kind
                                   session:(FBPKosherAdminSession *)session
                                     error:(NSError **)error;

#pragma mark - Validated JSON Export / Import (No Credentials Included)

- (nullable NSData *)exportPolicyJSONWithSession:(FBPKosherAdminSession *)session
                                           error:(NSError **)error;

- (BOOL)importPolicyJSONData:(NSData *)jsonData
                     session:(FBPKosherAdminSession *)session
                       error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
