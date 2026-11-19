// Privacy-first optional AI moderation infrastructure (never overrides Strict Mode).

#import "FBPlus.h"
#import "FBPKosherTypes.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FBPKosherModerationVerdict) {
    FBPKosherModerationVerdictAllow = 0,
    FBPKosherModerationVerdictFlag = 1,
    FBPKosherModerationVerdictBlock = 2,
    FBPKosherModerationVerdictNotImplemented = 3,
};

typedef NS_ENUM(NSInteger, FBPKosherModerationCategory) {
    FBPKosherModerationCategoryNone = 0,
    FBPKosherModerationCategoryImmodestOrExplicit,
    FBPKosherModerationCategoryProfanityOrHarassment,
    FBPKosherModerationCategoryPromotionOrSpam,
    FBPKosherModerationCategoryUnverifiedMedia,
    FBPKosherModerationCategoryUnsupported,
};

@interface FBPKosherModerationResult : NSObject
@property (nonatomic, assign, readonly) FBPKosherModerationVerdict verdict;
@property (nonatomic, assign, readonly) FBPKosherModerationCategory category;
@property (nonatomic, copy, readonly) NSString *providerName;
@property (nonatomic, assign, readonly) BOOL isImplementedProvider;
@property (nonatomic, copy, readonly, nullable) NSString *explanation;

+ (instancetype)resultWithVerdict:(FBPKosherModerationVerdict)verdict
                         category:(FBPKosherModerationCategory)category
                     providerName:(NSString *)providerName
                      implemented:(BOOL)implemented
                      explanation:(nullable NSString *)explanation;
@end

@interface FBPKosherModerationPolicy : NSObject
@property (nonatomic, assign) BOOL textModerationEnabled;
@property (nonatomic, assign) BOOL imageModerationEnabled;
/// Privacy default: NO. Private Facebook content must never be uploaded to third-party AI clouds.
@property (nonatomic, assign) BOOL allowThirdPartyCloudUpload;
@property (nonatomic, copy) NSArray<NSString *> *blockedKeywords;
+ (instancetype)strictDefaultPolicy;
@end

@protocol FBPKosherTextModerator <NSObject>
@property (nonatomic, copy, readonly) NSString *providerName;
@property (nonatomic, assign, readonly) BOOL isModelAvailable;
- (FBPKosherModerationResult *)classifyText:(NSString *)text;
@end

@protocol FBPKosherImageModerator <NSObject>
@property (nonatomic, copy, readonly) NSString *providerName;
@property (nonatomic, assign, readonly) BOOL isModelAvailable;
- (FBPKosherModerationResult *)classifyImage:(nullable UIImage *)image metadata:(nullable NSDictionary *)metadata;
@end

/// Deterministic local keyword filter (zero network, privacy-preserving).
@interface FBPKosherLocalKeywordTextModerator : NSObject <FBPKosherTextModerator>
- (instancetype)initWithBlockedKeywords:(NSArray<NSString *> *)keywords;
@end

/// Honest stub ML text classifier explicitly marked NOT IMPLEMENTED.
@interface FBPKosherStubMLTextModerator : NSObject <FBPKosherTextModerator>
@end

/// Honest stub ML image classifier explicitly marked NOT IMPLEMENTED.
@interface FBPKosherStubMLImageModerator : NSObject <FBPKosherImageModerator>
@end

/// Coordinates optional moderation while guaranteeing Strict Mode ALWAYS blocks media
/// regardless of any classifier output.
@interface FBPKosherModerationEngine : NSObject

@property (class, readonly) FBPKosherModerationEngine *shared;
@property (nonatomic, strong) FBPKosherModerationPolicy *policy;
@property (nonatomic, strong) id<FBPKosherTextModerator> textModerator;
@property (nonatomic, strong) id<FBPKosherImageModerator> imageModerator;

- (FBPKosherDecision)evaluateText:(nullable NSString *)text
                       strictMode:(BOOL)strictMode
                        resultOut:(FBPKosherModerationResult * _Nullable * _Nullable)resultOut;

/// Strict Mode invariant: ALWAYS returns FBPKosherDecisionBlock for media when strictMode is YES,
/// even if an image moderator returns FBPKosherModerationVerdictAllow.
- (FBPKosherDecision)evaluateMedia:(nullable UIImage *)image
                          metadata:(nullable NSDictionary *)metadata
                        strictMode:(BOOL)strictMode
                         resultOut:(FBPKosherModerationResult * _Nullable * _Nullable)resultOut;

@end

NS_ASSUME_NONNULL_END
