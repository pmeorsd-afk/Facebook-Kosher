// Privacy-first optional moderation engine implementation.

#import "FBPKosherModeration.h"

@interface FBPKosherModerationResult ()
@property (nonatomic, assign, readwrite) FBPKosherModerationVerdict verdict;
@property (nonatomic, assign, readwrite) FBPKosherModerationCategory category;
@property (nonatomic, copy, readwrite) NSString *providerName;
@property (nonatomic, assign, readwrite) BOOL isImplementedProvider;
@property (nonatomic, copy, readwrite, nullable) NSString *explanation;
@end

@implementation FBPKosherModerationResult

+ (instancetype)resultWithVerdict:(FBPKosherModerationVerdict)verdict
                         category:(FBPKosherModerationCategory)category
                     providerName:(NSString *)providerName
                      implemented:(BOOL)implemented
                      explanation:(NSString *)explanation {
    FBPKosherModerationResult *res = [[FBPKosherModerationResult alloc] init];
    res.verdict = verdict;
    res.category = category;
    res.providerName = [providerName copy];
    res.isImplementedProvider = implemented;
    res.explanation = [explanation copy];
    return res;
}

@end

@implementation FBPKosherModerationPolicy

+ (instancetype)strictDefaultPolicy {
    FBPKosherModerationPolicy *p = [[FBPKosherModerationPolicy alloc] init];
    p.textModerationEnabled = NO;
    p.imageModerationEnabled = NO;
    p.allowThirdPartyCloudUpload = NO;
    p.blockedKeywords = @[];
    return p;
}

@end

@implementation FBPKosherLocalKeywordTextModerator {
    NSArray<NSString *> *_keywords;
}

- (instancetype)initWithBlockedKeywords:(NSArray<NSString *> *)keywords {
    if ((self = [super init])) {
        _keywords = [keywords copy] ?: @[];
    }
    return self;
}

- (NSString *)providerName {
    return @"FBPKosherLocalKeywordTextModerator";
}

- (BOOL)isModelAvailable {
    return YES;
}

- (FBPKosherModerationResult *)classifyText:(NSString *)text {
    if (text.length == 0 || _keywords.count == 0) {
        return [FBPKosherModerationResult resultWithVerdict:FBPKosherModerationVerdictAllow
                                                   category:FBPKosherModerationCategoryNone
                                               providerName:self.providerName
                                                implemented:YES
                                                explanation:@"No local keyword hit"];
    }
    NSString *lower = text.lowercaseString;
    for (NSString *kw in _keywords) {
        NSString *clean = [kw stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
        if (clean.length > 0 && [lower containsString:clean]) {
            return [FBPKosherModerationResult resultWithVerdict:FBPKosherModerationVerdictBlock
                                                       category:FBPKosherModerationCategoryProfanityOrHarassment
                                                   providerName:self.providerName
                                                    implemented:YES
                                                    explanation:@"Matched local blocked keyword"];
        }
    }
    return [FBPKosherModerationResult resultWithVerdict:FBPKosherModerationVerdictAllow
                                               category:FBPKosherModerationCategoryNone
                                           providerName:self.providerName
                                            implemented:YES
                                            explanation:@"No local keyword hit"];
}

@end

@implementation FBPKosherStubMLTextModerator

- (NSString *)providerName {
    return @"FBPKosherStubMLTextModerator (NOT IMPLEMENTED)";
}

- (BOOL)isModelAvailable {
    return NO;
}

- (FBPKosherModerationResult *)classifyText:(__unused NSString *)text {
    return [FBPKosherModerationResult resultWithVerdict:FBPKosherModerationVerdictNotImplemented
                                               category:FBPKosherModerationCategoryUnsupported
                                           providerName:self.providerName
                                            implemented:NO
                                            explanation:@"On-device ML text classifier is NOT IMPLEMENTED."];
}

@end

@implementation FBPKosherStubMLImageModerator

- (NSString *)providerName {
    return @"FBPKosherStubMLImageModerator (NOT IMPLEMENTED)";
}

- (BOOL)isModelAvailable {
    return NO;
}

- (FBPKosherModerationResult *)classifyImage:(__unused UIImage *)image
                                    metadata:(__unused NSDictionary *)metadata {
    return [FBPKosherModerationResult resultWithVerdict:FBPKosherModerationVerdictNotImplemented
                                               category:FBPKosherModerationCategoryUnverifiedMedia
                                           providerName:self.providerName
                                            implemented:NO
                                            explanation:@"On-device ML image classifier is NOT IMPLEMENTED; Strict Mode always blocks all media."];
}

@end

@implementation FBPKosherModerationEngine

+ (FBPKosherModerationEngine *)shared {
    static FBPKosherModerationEngine *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _policy = [FBPKosherModerationPolicy strictDefaultPolicy];
        _textModerator = [[FBPKosherLocalKeywordTextModerator alloc] initWithBlockedKeywords:@[]];
        _imageModerator = [[FBPKosherStubMLImageModerator alloc] init];
    }
    return self;
}

- (FBPKosherDecision)evaluateText:(NSString *)text
                       strictMode:(BOOL)strictMode
                        resultOut:(FBPKosherModerationResult **)resultOut {
    (void)strictMode;
    if (!self.policy.textModerationEnabled || text.length == 0) {
        if (resultOut) {
            *resultOut = [FBPKosherModerationResult resultWithVerdict:FBPKosherModerationVerdictAllow
                                                             category:FBPKosherModerationCategoryNone
                                                         providerName:self.textModerator.providerName
                                                          implemented:self.textModerator.isModelAvailable
                                                          explanation:@"Text moderation disabled or empty text"];
        }
        return FBPKosherDecisionAllow;
    }

    FBPKosherModerationResult *res = [self.textModerator classifyText:text];
    if (resultOut) *resultOut = res;

    if (res.verdict == FBPKosherModerationVerdictBlock ||
        res.verdict == FBPKosherModerationVerdictFlag) {
        return FBPKosherDecisionBlock;
    }
    // If an unimplemented ML stub was plugged in, fail deterministicly without overriding policy.
    if (res.verdict == FBPKosherModerationVerdictNotImplemented) {
        return FBPKosherDecisionUnknown;
    }
    return FBPKosherDecisionAllow;
}

- (FBPKosherDecision)evaluateMedia:(UIImage *)image
                          metadata:(NSDictionary *)metadata
                        strictMode:(BOOL)strictMode
                         resultOut:(FBPKosherModerationResult **)resultOut {
    // Non-negotiable Strict Mode invariant: AI moderation MUST NEVER permit media in Strict Mode.
    if (strictMode) {
        if (resultOut) {
            *resultOut = [FBPKosherModerationResult resultWithVerdict:FBPKosherModerationVerdictBlock
                                                             category:FBPKosherModerationCategoryUnverifiedMedia
                                                         providerName:@"StrictModeDeterministicOverride"
                                                          implemented:YES
                                                          explanation:@"Strict Mode blocks all media unconditionally regardless of AI inference."];
        }
        return FBPKosherDecisionBlock;
    }

    if (!self.policy.imageModerationEnabled) {
        if (resultOut) {
            *resultOut = [FBPKosherModerationResult resultWithVerdict:FBPKosherModerationVerdictAllow
                                                             category:FBPKosherModerationCategoryNone
                                                         providerName:self.imageModerator.providerName
                                                          implemented:self.imageModerator.isModelAvailable
                                                          explanation:@"Image moderation disabled outside Strict Mode"];
        }
        return FBPKosherDecisionAllow;
    }

    FBPKosherModerationResult *res = [self.imageModerator classifyImage:image metadata:metadata];
    if (resultOut) *resultOut = res;
    if (res.verdict == FBPKosherModerationVerdictBlock || res.verdict == FBPKosherModerationVerdictFlag) {
        return FBPKosherDecisionBlock;
    }
    if (res.verdict == FBPKosherModerationVerdictNotImplemented) {
        return FBPKosherDecisionBlock;
    }
    return FBPKosherDecisionAllow;
}

@end
