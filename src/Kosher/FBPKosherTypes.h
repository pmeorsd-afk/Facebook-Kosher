// Typed policy models, enums, and decision structures for Facebook Kosher.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FBPKosherDecision) {
    FBPKosherDecisionAllow = 0,
    FBPKosherDecisionBlock = 1,
    FBPKosherDecisionUnknown = 2,
};

typedef NS_ENUM(NSInteger, FBPKosherDestinationType) {
    FBPKosherDestinationUnknown = 0,
    FBPKosherDestinationHomeFeed,
    FBPKosherDestinationGroup,
    FBPKosherDestinationPage,
    FBPKosherDestinationProfile,
    FBPKosherDestinationReels,
    FBPKosherDestinationStories,
    FBPKosherDestinationWatch,
    FBPKosherDestinationLive,
    FBPKosherDestinationMarketplace,
    FBPKosherDestinationSearch,
    FBPKosherDestinationPhotoViewer,
    FBPKosherDestinationVideoViewer,
    FBPKosherDestinationNotifications,
    FBPKosherDestinationMessaging,
    FBPKosherDestinationExternalLink,
    FBPKosherDestinationAuth,
    FBPKosherDestinationSettings,
    FBPKosherDestinationAdmin,
    FBPKosherDestinationKosherHome,
};

typedef NS_ENUM(NSInteger, FBPKosherContentType) {
    FBPKosherContentUnknown = 0,
    FBPKosherContentText,
    FBPKosherContentImage,
    FBPKosherContentVideo,
    FBPKosherContentGIF,
    FBPKosherContentSticker,
    FBPKosherContentAudio,
    FBPKosherContentCarousel,
    FBPKosherContentLinkPreview,
    FBPKosherContentSponsored,
    FBPKosherContentRecommendation,
    FBPKosherContentSurvey,
    FBPKosherContentNavigation,
};

typedef NS_ENUM(NSInteger, FBPKosherSourceKind) {
    FBPKosherSourceKindGroup = 0,
    FBPKosherSourceKindPage = 1,
    FBPKosherSourceKindProfile = 2,
    FBPKosherSourceKindTrustedDomain = 3,
};

typedef NS_ENUM(NSInteger, FBPKosherHookSeverity) {
    FBPKosherHookSeverityCritical = 0,
    FBPKosherHookSeveritySurface = 1,
    FBPKosherHookSeverityCosmetic = 2,
};

typedef NS_ENUM(NSInteger, FBPKosherHookStatus) {
    FBPKosherHookStatusPending = 0,
    FBPKosherHookStatusInstalled = 1,
    FBPKosherHookStatusMissing = 2,
    FBPKosherHookStatusFailed = 3,
};

#ifdef __cplusplus
extern "C" {
#endif

extern NSString *FBPKosherDecisionName(FBPKosherDecision decision);
extern NSString *FBPKosherDestinationName(FBPKosherDestinationType destination);
extern NSString *FBPKosherContentTypeName(FBPKosherContentType contentType);
extern NSString *FBPKosherSourceKindName(FBPKosherSourceKind kind);

#ifdef __cplusplus
}
#endif

/// Validated, administrator-approved source entry (Group, Page, Profile, or Trusted Domain).
@interface FBPKosherApprovedSource : NSObject <NSCopying>

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, assign, readonly) FBPKosherSourceKind kind;
@property (nonatomic, copy, readonly) NSString *displayName;
@property (nonatomic, assign, readonly, getter=isFavorite) BOOL favorite;
@property (nonatomic, copy, readonly, nullable) NSString *allowedPathPrefix;
@property (nonatomic, copy, readonly, nullable) NSString *notes;
@property (nonatomic, copy, readonly) NSDate *addedAt;

- (instancetype)initWithIdentifier:(NSString *)identifier
                              kind:(FBPKosherSourceKind)kind
                       displayName:(NSString *)displayName
                          favorite:(BOOL)favorite
                 allowedPathPrefix:(nullable NSString *)allowedPathPrefix
                             notes:(nullable NSString *)notes
                           addedAt:(nullable NSDate *)addedAt NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

+ (nullable NSString *)normalizedIdentifier:(NSString *)rawIdentifier
                                    forKind:(FBPKosherSourceKind)kind;

- (NSDictionary<NSString *, id> *)toJSONDictionary;
+ (nullable instancetype)fromJSONDictionary:(NSDictionary<NSString *, id> *)dict;

@end

/// Typed policy evaluation input context.
@interface FBPKosherPolicyContext : NSObject

@property (nonatomic, assign) FBPKosherDestinationType destinationType;
@property (nonatomic, assign) FBPKosherContentType contentType;
@property (nonatomic, copy, nullable) NSString *sourceIdentifier;
@property (nonatomic, assign) FBPKosherSourceKind sourceKind;
@property (nonatomic, assign) BOOL hasExplicitSourceKind;
@property (nonatomic, copy, nullable) NSURL *rawURL;
@property (nonatomic, copy, nullable) NSString *viewControllerClassName;
@property (nonatomic, copy, nullable) NSString *modelClassName;
@property (nonatomic, copy, nullable) NSString *surfaceDescription;
@property (nonatomic, assign) BOOL isSharedFromUnapprovedSource;
@property (nonatomic, assign) BOOL strictModeActive;
@property (nonatomic, assign) BOOL compatibilityHealthy;

+ (instancetype)contextWithDestination:(FBPKosherDestinationType)destination
                           contentType:(FBPKosherContentType)contentType;

@end

/// Immutable result produced by FBPKosherPolicyEngine.
/// Invariant: when strictModeActive is YES, UNKNOWN always resolves to effectiveAllowed = NO.
@interface FBPKosherPolicyResult : NSObject

@property (nonatomic, assign, readonly) FBPKosherDecision decision;
@property (nonatomic, assign, readonly) BOOL effectiveAllowed;
@property (nonatomic, copy, readonly) NSString *reasonCode;
@property (nonatomic, copy, readonly) NSString *localizedReason;
@property (nonatomic, strong, readonly) FBPKosherPolicyContext *context;
@property (nonatomic, copy, readonly) NSDate *evaluatedAt;

- (instancetype)initWithDecision:(FBPKosherDecision)decision
                      reasonCode:(NSString *)reasonCode
                 localizedReason:(NSString *)localizedReason
                         context:(FBPKosherPolicyContext *)context NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
