// Automated Foundation/Objective-C unit tests for Facebook Kosher policy enforcement.
// Covers all 21 required policy cases, strict defaults, PIN cryptography & lockout,
// compatibility monitoring, Marketplace fail-closed guard, and AI moderation invariants.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import "FBPKosherTypes.h"
#import "FBPKosherDiagnostics.h"
#import "FBPKosherCompatibilityMonitor.h"
#import "FBPKosherPolicyStore.h"
#import "FBPKosherPolicyEngine.h"
#import "FBPKosherContentFilter.h"
#import "FBPKosherMarketplaceGuard.h"
#import "FBPKosherModeration.h"

#pragma mark - In-Memory Test Credential Backing

@interface FBPKosherMemoryCredentialBacking : NSObject <FBPKosherCredentialBacking>
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *secrets;
@end

@implementation FBPKosherMemoryCredentialBacking

- (instancetype)init {
    if ((self = [super init])) {
        _secrets = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSData *)readSecretDataForAccount:(NSString *)account error:(NSError **)error {
    return _secrets[account];
}

- (BOOL)writeSecretData:(NSData *)data forAccount:(NSString *)account error:(NSError **)error {
    if (!account.length || !data) {
        if (error) {
            *error = [NSError errorWithDomain:FBPKosherPolicyStoreErrorDomain
                                         code:FBPKosherPolicyStoreErrorKeychainFailure
                                     userInfo:nil];
        }
        return NO;
    }
    _secrets[account] = [data copy];
    return YES;
}

- (BOOL)deleteSecretForAccount:(NSString *)account error:(NSError **)error {
    [_secrets removeObjectForKey:account];
    return YES;
}

@end

#pragma mark - Mock Facebook Feed Models for Model-Filter Tests

@interface FBPTestTargetGroup : NSObject
@property (nonatomic, copy) NSString *graphQLID;
@end
@implementation FBPTestTargetGroup
@end

@interface FBPTestActor : NSObject
@property (nonatomic, copy) NSString *graphQLID;
@end
@implementation FBPTestActor
@end

@interface FBPTestMessage : NSObject
@property (nonatomic, copy) NSString *text;
@end
@implementation FBPTestMessage
@end

@interface FBMemFeedStory : NSObject
@property (nonatomic, strong, nullable) FBPTestTargetGroup *targetGroup;
@property (nonatomic, strong, nullable) FBPTestActor *actor;
@property (nonatomic, strong, nullable) FBMemFeedStory *attachedStory;
@property (nonatomic, strong, nullable) FBPTestMessage *message;
@property (nonatomic, copy, nullable) NSString *category;
@property (nonatomic, strong, nullable) id sponsoredData;
@end
@implementation FBMemFeedStory
@end

@interface FBMemReelsFeedUnit : NSObject
@property (nonatomic, copy, nullable) NSString *category;
@end
@implementation FBMemReelsFeedUnit
@end

@interface FBPAllowAllMockImageModerator : NSObject <FBPKosherImageModerator>
@end
@implementation FBPAllowAllMockImageModerator
- (NSString *)providerName { return @"MockAllowAllImage"; }
- (BOOL)isModelAvailable { return YES; }
- (FBPKosherModerationResult *)classifyImage:(UIImage *)image metadata:(NSDictionary *)metadata {
    return [FBPKosherModerationResult resultWithVerdict:FBPKosherModerationVerdictAllow
                                               category:FBPKosherModerationCategoryNone
                                           providerName:self.providerName
                                            implemented:YES
                                            explanation:@"Mock says allow"];
}
@end

#pragma mark - Test Harness Helpers

static NSUInteger gPassed = 0;
static NSUInteger gFailed = 0;

#define TEST_ASSERT(cond, fmt, ...)                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            NSString *msg__ = [NSString stringWithFormat:@"" fmt, ##__VA_ARGS__];                \
            fprintf(stderr, "  ASSERTION FAILED (%s:%d): %s\n", __FILE__, __LINE__,              \
                    msg__.UTF8String);                                                           \
            return NO;                                                                           \
        }                                                                                        \
    } while (0)

typedef BOOL (*FBPTestFn)(void);

static void RunTest(const char *name, FBPTestFn fn) {
    @autoreleasepool {
        BOOL ok = fn();
        if (ok) {
            gPassed++;
            fprintf(stdout, "[PASS] %s\n", name);
        } else {
            gFailed++;
            fprintf(stderr, "[FAIL] %s\n", name);
        }
    }
}

static FBPKosherCompatibilityMonitor *CreateHealthyMonitor(NSString *version) {
    FBPKosherCompatibilityMonitor *mon =
        [[FBPKosherCompatibilityMonitor alloc] initWithFacebookVersion:version
                                                           buildNumber:@"586000000"
                                                          tweakVersion:@"1.0.8-kosher"];
    [mon markPolicyStoreInitialized:YES];
    for (NSString *criticalID in FBPKosherCompatibilityMonitor.criticalHookIdentifiers) {
        [mon reportHook:criticalID
               severity:FBPKosherHookSeverityCritical
                 status:FBPKosherHookStatusInstalled
                 detail:@"Installed in unit test"];
    }
    [mon evaluateStartupHealth];
    return mon;
}

static NSURL *CreateTempStorageDir(NSString *suffix) {
    NSString *path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"fbp_kosher_test_%@_%@",
                                        suffix, NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:path
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

static FBPKosherPolicyStore *CreateConfiguredStore(NSURL *dir,
                                                   FBPKosherMemoryCredentialBacking *backing,
                                                   FBPKosherAdminSession * _Nullable *sessionOut) {
    FBPKosherPolicyStore *store = [[FBPKosherPolicyStore alloc] initWithStorageDirectory:dir
                                                                       credentialBacking:backing
                                                                          mirrorToShared:NO];
    NSString *recovery = nil;
    NSError *err = nil;
    BOOL ok = [store configureInitialAdminPIN:@"246810"
                              recoveryCodeOut:&recovery
                                   sessionOut:sessionOut
                                        error:&err];
    if (!ok || !recovery.length) return nil;
    return store;
}

#pragma mark - 21 Required Policy Test Cases (Section 18)

// 1. Unknown content source is blocked
static BOOL test_01_unknown_content_source_is_blocked(void) {
    NSURL *dir = CreateTempStorageDir(@"t01");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherCompatibilityMonitor *mon = CreateHealthyMonitor(@"586.0.0");
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, NULL);
    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:mon
                                         diagnostics:[[FBPKosherDiagnostics alloc] init]];

    FBPKosherPolicyContext *ctx = [FBPKosherPolicyContext contextWithDestination:FBPKosherDestinationUnknown
                                                                     contentType:FBPKosherContentUnknown];
    FBPKosherPolicyResult *res = [engine evaluateContext:ctx];
    TEST_ASSERT(res.decision == FBPKosherDecisionUnknown || res.decision == FBPKosherDecisionBlock,
                "Expected BLOCK/UNKNOWN decision");
    TEST_ASSERT(res.effectiveAllowed == NO, "UNKNOWN must resolve to blocked in Strict Mode");

    FBPKosherPolicyResult *modelRes =
        [engine evaluateModelWithClassName:@"FBMemFeedStory"
                                  category:nil
                                  sourceID:nil
                                sourceKind:FBPKosherSourceKindGroup
                       hasExplicitSourceID:NO
                               isSponsored:NO
                                   isMedia:NO
                    isSharedFromUnapproved:NO
                               textualBody:@"Text without verified source"];
    TEST_ASSERT(modelRes.effectiveAllowed == NO, "Model without explicit sourceID must be blocked");
    return YES;
}

// 2. Unapproved group is blocked
static BOOL test_02_unapproved_group_is_blocked(void) {
    NSURL *dir = CreateTempStorageDir(@"t02");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherCompatibilityMonitor *mon = CreateHealthyMonitor(@"586.0.0");
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, NULL);
    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:mon
                                         diagnostics:[[FBPKosherDiagnostics alloc] init]];

    FBPKosherPolicyResult *res =
        [engine evaluateURL:[NSURL URLWithString:@"https://www.facebook.com/groups/999888777/"]];
    TEST_ASSERT(res.effectiveAllowed == NO, "Unapproved group URL must be blocked");
    return YES;
}

// 3. Approved group text is allowed
static BOOL test_03_approved_group_text_is_allowed(void) {
    NSURL *dir = CreateTempStorageDir(@"t03");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherCompatibilityMonitor *mon = CreateHealthyMonitor(@"586.0.0");
    FBPKosherAdminSession *session = nil;
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, &session);
    TEST_ASSERT(store != nil && session != nil, "Admin session must be established");

    FBPKosherApprovedSource *grp =
        [[FBPKosherApprovedSource alloc] initWithIdentifier:@"1234567890"
                                                       kind:FBPKosherSourceKindGroup
                                                displayName:@"קבוצת לימוד תורה"
                                                   favorite:YES
                                          allowedPathPrefix:nil
                                                      notes:nil
                                                    addedAt:nil];
    NSError *err = nil;
    TEST_ASSERT([store addApprovedSource:grp session:session error:&err], "Failed adding approved group: %@", err);

    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:mon
                                         diagnostics:[[FBPKosherDiagnostics alloc] init]];

    FBPKosherPolicyResult *urlRes =
        [engine evaluateURL:[NSURL URLWithString:@"https://m.facebook.com/groups/1234567890/permalink/42"]];
    TEST_ASSERT(urlRes.effectiveAllowed == YES, "Approved group URL should be allowed");

    FBPKosherPolicyResult *modelRes =
        [engine evaluateModelWithClassName:@"FBMemFeedStory"
                                  category:@"ORGANIC"
                                  sourceID:@"1234567890"
                                sourceKind:FBPKosherSourceKindGroup
                       hasExplicitSourceID:YES
                               isSponsored:NO
                                   isMedia:NO
                    isSharedFromUnapproved:NO
                               textualBody:@"שיעור דף יומי בשעה 20:00"];
    TEST_ASSERT(modelRes.effectiveAllowed == YES, "Approved group textual post must be allowed");
    return YES;
}

// 4. Approved group image is blocked
static BOOL test_04_approved_group_image_is_blocked(void) {
    NSURL *dir = CreateTempStorageDir(@"t04");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherCompatibilityMonitor *mon = CreateHealthyMonitor(@"586.0.0");
    FBPKosherAdminSession *session = nil;
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, &session);
    FBPKosherApprovedSource *grp =
        [[FBPKosherApprovedSource alloc] initWithIdentifier:@"1234567890"
                                                       kind:FBPKosherSourceKindGroup
                                                displayName:@"קבוצה מאושרת"
                                                   favorite:NO
                                          allowedPathPrefix:nil
                                                      notes:nil
                                                    addedAt:nil];
    [store addApprovedSource:grp session:session error:nil];
    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:mon
                                         diagnostics:[[FBPKosherDiagnostics alloc] init]];

    FBPKosherPolicyResult *modelRes =
        [engine evaluateModelWithClassName:@"FBMemFeedStory"
                                  category:@"ORGANIC"
                                  sourceID:@"1234567890"
                                sourceKind:FBPKosherSourceKindGroup
                       hasExplicitSourceID:YES
                               isSponsored:NO
                                   isMedia:YES
                    isSharedFromUnapproved:NO
                               textualBody:nil];
    TEST_ASSERT(modelRes.effectiveAllowed == NO, "Media in approved group must be blocked");

    FBPKosherPolicyResult *mediaRes =
        [engine evaluateMediaURL:[NSURL URLWithString:@"https://scontent.xx.fbcdn.net/v/t39.30808-6/photo.jpg"]];
    TEST_ASSERT(mediaRes.effectiveAllowed == NO, "Image CDN URL must be blocked");

    FBPKosherPolicyResult *viewerRes =
        [engine evaluateURL:[NSURL URLWithString:@"https://www.facebook.com/photo/?fbid=55555"]];
    TEST_ASSERT(viewerRes.effectiveAllowed == NO, "Photo viewer URL must be blocked");
    return YES;
}

// 5. Approved group video is blocked
static BOOL test_05_approved_group_video_is_blocked(void) {
    NSURL *dir = CreateTempStorageDir(@"t05");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherCompatibilityMonitor *mon = CreateHealthyMonitor(@"586.0.0");
    FBPKosherAdminSession *session = nil;
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, &session);
    FBPKosherApprovedSource *grp =
        [[FBPKosherApprovedSource alloc] initWithIdentifier:@"1234567890"
                                                       kind:FBPKosherSourceKindGroup
                                                displayName:@"קבוצה מאושרת"
                                                   favorite:NO
                                          allowedPathPrefix:nil
                                                      notes:nil
                                                    addedAt:nil];
    [store addApprovedSource:grp session:session error:nil];
    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:mon
                                         diagnostics:[[FBPKosherDiagnostics alloc] init]];

    FBPKosherPolicyResult *videoRes =
        [engine evaluateMediaURL:[NSURL URLWithString:@"https://video.xx.fbcdn.net/v/t42.1790-2/clip.mp4"]];
    TEST_ASSERT(videoRes.effectiveAllowed == NO, "Video CDN URL must be blocked");

    FBPKosherPolicyResult *watchRes =
        [engine evaluateURL:[NSURL URLWithString:@"https://www.facebook.com/watch/?v=12345678"]];
    TEST_ASSERT(watchRes.effectiveAllowed == NO, "Video watch URL must be blocked");

    FBPKosherPolicyResult *ctxRes = nil;
    FBPKosherPolicyContext *ctx = [FBPKosherPolicyContext contextWithDestination:FBPKosherDestinationGroup
                                                                     contentType:FBPKosherContentVideo];
    ctx.sourceIdentifier = @"1234567890";
    ctx.sourceKind = FBPKosherSourceKindGroup;
    ctx.hasExplicitSourceKind = YES;
    ctxRes = [engine evaluateContext:ctx];
    TEST_ASSERT(ctxRes.effectiveAllowed == NO, "Approved group video context must be blocked");
    return YES;
}

// 6. Shared post from unapproved source is blocked
static BOOL test_06_shared_post_from_unapproved_source_is_blocked(void) {
    NSURL *dir = CreateTempStorageDir(@"t06");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherCompatibilityMonitor *mon = CreateHealthyMonitor(@"586.0.0");
    FBPKosherAdminSession *session = nil;
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, &session);
    FBPKosherApprovedSource *grp =
        [[FBPKosherApprovedSource alloc] initWithIdentifier:@"1234567890"
                                                       kind:FBPKosherSourceKindGroup
                                                displayName:@"קבוצה מאושרת"
                                                   favorite:NO
                                          allowedPathPrefix:nil
                                                      notes:nil
                                                    addedAt:nil];
    [store addApprovedSource:grp session:session error:nil];
    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:mon
                                         diagnostics:[[FBPKosherDiagnostics alloc] init]];

    FBPKosherPolicyResult *sharedRes =
        [engine evaluateModelWithClassName:@"FBMemFeedStory"
                                  category:@"ORGANIC"
                                  sourceID:@"1234567890"
                                sourceKind:FBPKosherSourceKindGroup
                       hasExplicitSourceID:YES
                               isSponsored:NO
                                   isMedia:NO
                    isSharedFromUnapproved:YES
                               textualBody:@"פוסט משותף ממקור חיצוני"];
    TEST_ASSERT(sharedRes.effectiveAllowed == NO,
                "Post in approved group sharing an unapproved post must be blocked");
    return YES;
}

// 7. Unknown profile is blocked
static BOOL test_07_unknown_profile_is_blocked(void) {
    NSURL *dir = CreateTempStorageDir(@"t07");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherCompatibilityMonitor *mon = CreateHealthyMonitor(@"586.0.0");
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, NULL);
    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:mon
                                         diagnostics:[[FBPKosherDiagnostics alloc] init]];

    FBPKosherPolicyResult *urlRes =
        [engine evaluateURL:[NSURL URLWithString:@"https://www.facebook.com/profile.php?id=1000999888"]];
    TEST_ASSERT(urlRes.effectiveAllowed == NO, "Unapproved numeric profile must be blocked");

    FBPKosherPolicyResult *slugRes =
        [engine evaluateURL:[NSURL URLWithString:@"https://www.facebook.com/random.celebrity"]];
    TEST_ASSERT(slugRes.effectiveAllowed == NO, "Unapproved slug profile/page must be blocked");
    return YES;
}

// 8. Direct Reel URL is blocked
static BOOL test_08_direct_reel_url_is_blocked(void) {
    NSURL *dir = CreateTempStorageDir(@"t08");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherCompatibilityMonitor *mon = CreateHealthyMonitor(@"586.0.0");
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, NULL);
    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:mon
                                         diagnostics:[[FBPKosherDiagnostics alloc] init]];

    NSArray<NSString *> *urls = @[
        @"https://www.facebook.com/reel/987654321",
        @"https://m.facebook.com/reels/987654321",
        @"fb://reels/987654321",
    ];
    for (NSString *raw in urls) {
        FBPKosherPolicyResult *res = [engine evaluateURL:[NSURL URLWithString:raw]];
        TEST_ASSERT(res.effectiveAllowed == NO, "Direct Reel URL must be blocked: %@", raw);
        TEST_ASSERT(res.context.destinationType == FBPKosherDestinationReels,
                    "Expected Reels destination classification for %@", raw);
    }

    FBMemReelsFeedUnit *reelModel = [[FBMemReelsFeedUnit alloc] init];
    reelModel.category = @"FB_SHORTS";
    TEST_ASSERT([FBPKosherContentFilter shouldFilterModel:reelModel] == YES,
                "FBMemReelsFeedUnit must be filtered in Strict Mode");
    return YES;
}

// 9. Direct Story URL is blocked
static BOOL test_09_direct_story_url_is_blocked(void) {
    NSURL *dir = CreateTempStorageDir(@"t09");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherCompatibilityMonitor *mon = CreateHealthyMonitor(@"586.0.0");
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, NULL);
    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:mon
                                         diagnostics:[[FBPKosherDiagnostics alloc] init]];

    NSArray<NSString *> *urls = @[
        @"https://www.facebook.com/stories/123456789/UzpfSVNDOg==",
        @"fb://stories/123456789",
    ];
    for (NSString *raw in urls) {
        FBPKosherPolicyResult *res = [engine evaluateURL:[NSURL URLWithString:raw]];
        TEST_ASSERT(res.effectiveAllowed == NO, "Direct Story URL must be blocked: %@", raw);
        TEST_ASSERT(res.context.destinationType == FBPKosherDestinationStories,
                    "Expected Stories destination classification for %@", raw);
    }
    return YES;
}

// 10. Video opened through notification is blocked
static BOOL test_10_video_opened_through_notification_is_blocked(void) {
    NSURL *dir = CreateTempStorageDir(@"t10");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherCompatibilityMonitor *mon = CreateHealthyMonitor(@"586.0.0");
    FBPKosherAdminSession *session = nil;
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, &session);
    FBPKosherApprovedSource *grp =
        [[FBPKosherApprovedSource alloc] initWithIdentifier:@"1234567890"
                                                       kind:FBPKosherSourceKindGroup
                                                displayName:@"קבוצה מאושרת"
                                                   favorite:NO
                                          allowedPathPrefix:nil
                                                      notes:nil
                                                    addedAt:nil];
    [store addApprovedSource:grp session:session error:nil];
    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:mon
                                         diagnostics:[[FBPKosherDiagnostics alloc] init]];

    FBPKosherPolicyResult *videoNotif =
        [engine evaluateNotificationWithTitle:@"סרטון חדש מומלץ"
                                         body:@"צפה ברילס החדש"
                                     userInfo:@{@"href": @"https://www.facebook.com/watch/?v=777777"}
                                hasAttachment:YES];
    TEST_ASSERT(videoNotif.effectiveAllowed == NO, "Video notification must be blocked");

    // Notification pointing to approved group but with an attachment must also be rejected
    FBPKosherPolicyResult *attachNotif =
        [engine evaluateNotificationWithTitle:@"פוסט בקבוצה"
                                         body:@"עדכון חדש"
                                     userInfo:@{@"href": @"https://www.facebook.com/groups/1234567890/permalink/1"}
                                hasAttachment:YES];
    TEST_ASSERT(attachNotif.effectiveAllowed == NO, "Notification with media attachment must fail media check");

    // Text-only notification for approved group must be allowed
    FBPKosherPolicyResult *okNotif =
        [engine evaluateNotificationWithTitle:@"הודעה בקבוצה"
                                         body:@"תגובה חדשה לדיון"
                                     userInfo:@{@"href": @"https://www.facebook.com/groups/1234567890/permalink/1"}
                                hasAttachment:NO];
    TEST_ASSERT(okNotif.effectiveAllowed == YES, "Text notification for approved group should be allowed");
    return YES;
}

// 11. Unsafe redirect is blocked
static BOOL test_11_unsafe_redirect_is_blocked(void) {
    NSURL *dir = CreateTempStorageDir(@"t11");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherCompatibilityMonitor *mon = CreateHealthyMonitor(@"586.0.0");
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, NULL);
    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:mon
                                         diagnostics:[[FBPKosherDiagnostics alloc] init]];

    NSArray<NSString *> *traps = @[
        @"https://l.facebook.com/l.php?u=https%3A%2F%2Funapproved.example.com%2Fvideo",
        @"fb://facewebmodal/f?href=https%3A%2F%2Fwww.facebook.com%2Freel%2F999",
        @"fb://fbplusbridge?url=https%3A%2F%2Fwww.facebook.com%2Fwatch%2F%3Fv%3D123",
        @"https://approved.example.org@evil.example.com/groups/1234567890",
        @"https://www.facebook.com/groups/1234567890/../../reel/555",
    ];
    for (NSString *raw in traps) {
        FBPKosherPolicyResult *res = [engine evaluateURL:[NSURL URLWithString:raw]];
        TEST_ASSERT(res.effectiveAllowed == NO, "Unsafe redirect / spoofed URL must be blocked: %@", raw);
    }
    return YES;
}

// 12. Untrusted external URL is blocked (while trusted domain + allowed path prefix is permitted)
static BOOL test_12_untrusted_external_url_is_blocked(void) {
    NSURL *dir = CreateTempStorageDir(@"t12");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherCompatibilityMonitor *mon = CreateHealthyMonitor(@"586.0.0");
    FBPKosherAdminSession *session = nil;
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, &session);
    FBPKosherApprovedSource *domain =
        [[FBPKosherApprovedSource alloc] initWithIdentifier:@"docs.gov.il"
                                                       kind:FBPKosherSourceKindTrustedDomain
                                                displayName:@"אתר ממשלתי מאושר"
                                                   favorite:NO
                                          allowedPathPrefix:@"/he/articles/"
                                                      notes:nil
                                                    addedAt:nil];
    TEST_ASSERT([store addApprovedSource:domain session:session error:nil], "Should add trusted domain");

    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:mon
                                         diagnostics:[[FBPKosherDiagnostics alloc] init]];

    FBPKosherPolicyResult *untrusted =
        [engine evaluateURL:[NSURL URLWithString:@"https://news-entertainment.example.com/feed"]];
    TEST_ASSERT(untrusted.effectiveAllowed == NO, "Untrusted external domain must be blocked");

    FBPKosherPolicyResult *wrongPath =
        [engine evaluateURL:[NSURL URLWithString:@"https://docs.gov.il/videos/watch"]];
    TEST_ASSERT(wrongPath.effectiveAllowed == NO,
                "Trusted host with disallowed path prefix must be blocked");

    FBPKosherPolicyResult *allowedExternal =
        [engine evaluateURL:[NSURL URLWithString:@"https://docs.gov.il/he/articles/tax-form"]];
    TEST_ASSERT(allowedExternal.effectiveAllowed == YES,
                "Trusted domain with matching path prefix should be allowed");
    return YES;
}

// 13. Unknown search result is blocked
static BOOL test_13_unknown_search_result_is_blocked(void) {
    NSURL *dir = CreateTempStorageDir(@"t13");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherCompatibilityMonitor *mon = CreateHealthyMonitor(@"586.0.0");
    FBPKosherAdminSession *session = nil;
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, &session);
    FBPKosherApprovedSource *grp =
        [[FBPKosherApprovedSource alloc] initWithIdentifier:@"111222333"
                                                       kind:FBPKosherSourceKindGroup
                                                displayName:@"גמ\"ח השבת אבידה"
                                                   favorite:YES
                                          allowedPathPrefix:nil
                                                      notes:nil
                                                    addedAt:nil];
    [store addApprovedSource:grp session:session error:nil];

    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:mon
                                         diagnostics:[[FBPKosherDiagnostics alloc] init]];

    FBPKosherPolicyResult *globalSearch =
        [engine evaluateURL:[NSURL URLWithString:@"https://www.facebook.com/search/top?q=movies"]];
    TEST_ASSERT(globalSearch.effectiveAllowed == NO, "Global search URL must be blocked");

    NSArray<FBPKosherApprovedSource *> *localMatch = [store searchApprovedSourcesWithQuery:@"אבידה"];
    TEST_ASSERT(localMatch.count == 1 && [localMatch.firstObject.identifier isEqualToString:@"111222333"],
                "Local search must match only approved source");

    NSArray<FBPKosherApprovedSource *> *noMatch = [store searchApprovedSourcesWithQuery:@"movies"];
    TEST_ASSERT(noMatch.count == 0, "Unapproved terms must return zero results in local search");
    return YES;
}

// 14. Marketplace remains blocked when capability is unverified
static BOOL test_14_marketplace_remains_blocked_when_unverified(void) {
    NSURL *dir = CreateTempStorageDir(@"t14");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherCompatibilityMonitor *mon = CreateHealthyMonitor(@"586.0.0");
    FBPKosherAdminSession *session = nil;
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, &session);

    NSError *err = nil;
    BOOL enabledUnverified = [store setMarketplaceAdminEnabled:YES
                                                       session:session
                                         capabilityVerifiedNow:NO
                                                         error:&err];
    TEST_ASSERT(enabledUnverified == NO && err.code == FBPKosherPolicyStoreErrorMarketplaceUnverified,
                "Enabling Marketplace without verified capability must fail");
    TEST_ASSERT(store.marketplaceAdminEnabled == NO, "Marketplace must stay disabled by default");

    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:mon
                                         diagnostics:[[FBPKosherDiagnostics alloc] init]];
    FBPKosherPolicyResult *mktRes =
        [engine evaluateURL:[NSURL URLWithString:@"https://www.facebook.com/marketplace/item/12345"]];
    TEST_ASSERT(mktRes.effectiveAllowed == NO, "Marketplace URL must be blocked");

    NSString *blockedMsg = FBPKosherMarketplaceBlockedMessage();
    TEST_ASSERT([blockedMsg isEqualToString:@"מרקטפלייס אינו זמין במצב הסינון המחמיר."],
                "Unexpected Marketplace blocked message: %@", blockedMsg);

    // Also test JSON sanitizer strips media/ads/recommendations while preserving text fields
    NSDictionary *samplePayload = @{
        @"data": @{
            @"listing": @{
                @"marketplace_listing_title": @"שולחן לימוד עץ מלא",
                @"formatted_amount": @{@"text": @"₪450"},
                @"listing_photos": @[@{@"image": @{@"uri": @"https://scontent.xx.fbcdn.net/p.jpg"}}],
                @"seller": @{@"name": @"אברהם", @"profile_picture": @{@"uri": @"https://scontent.xx.fbcdn.net/a.jpg"}},
                @"sponsored_data": @{@"ad_id": @"999"},
                @"related_listings": @[@{@"id": @"rel1"}],
            }
        }
    };
    NSUInteger removed = 0;
    NSDictionary *clean = [FBPKosherMarketplaceGuard sanitizedJSONObject:samplePayload removedCount:&removed];
    TEST_ASSERT(removed >= 4, "Expected sanitizer to strip photos, profile_picture, sponsored_data, related_listings");
    NSDictionary *listing = clean[@"data"][@"listing"];
    TEST_ASSERT([listing[@"marketplace_listing_title"] isEqualToString:@"שולחן לימוד עץ מלא"],
                "Text title must remain intact");
    TEST_ASSERT([listing[@"formatted_amount"][@"text"] isEqualToString:@"₪450"],
                "Price text must remain intact");
    TEST_ASSERT(listing[@"listing_photos"] == nil && listing[@"sponsored_data"] == nil &&
                listing[@"related_listings"] == nil && listing[@"seller"][@"profile_picture"] == nil,
                "Prohibited Marketplace keys must be stripped");
    TEST_ASSERT([FBPKosherMarketplaceGuard shouldBlockQueryNamed:@"MarketplaceGYSJQuery"] == YES,
                "GYSJ recommendation query must always be blocked");
    return YES;
}

// 15. Administrator PIN is required for policy modifications (+ lockout + recovery + JSON import/export)
static BOOL test_15_administrator_pin_required_for_modifications(void) {
    NSURL *dir = CreateTempStorageDir(@"t15");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherPolicyStore *store = [[FBPKosherPolicyStore alloc] initWithStorageDirectory:dir
                                                                       credentialBacking:backing
                                                                          mirrorToShared:NO];

    NSString *recoveryCode = nil;
    FBPKosherAdminSession *session = nil;
    NSError *err = nil;

    // Short/non-numeric PIN rejected
    TEST_ASSERT([store configureInitialAdminPIN:@"123" recoveryCodeOut:&recoveryCode sessionOut:&session error:&err] == NO,
                "Short PIN must be rejected");
    // Valid 6-digit PIN accepted
    TEST_ASSERT([store configureInitialAdminPIN:@"654321" recoveryCodeOut:&recoveryCode sessionOut:&session error:&err] == YES,
                "Valid PIN setup must succeed");
    TEST_ASSERT(recoveryCode.length >= 16, "Recovery code must be generated");

    // Lock session -> modifications without session must fail
    [store lockAdminSession];
    FBPKosherApprovedSource *grp =
        [[FBPKosherApprovedSource alloc] initWithIdentifier:@"555666"
                                                       kind:FBPKosherSourceKindGroup
                                                displayName:@"Test"
                                                   favorite:NO
                                          allowedPathPrefix:nil
                                                      notes:nil
                                                    addedAt:nil];
    TEST_ASSERT([store addApprovedSource:grp session:session error:&err] == NO,
                "Locked/invalidated session must not modify allowlist");
    TEST_ASSERT([store setStrictModeEnabled:NO session:session error:&err] == NO,
                "Locked session must not disable Strict Mode");

    // Failed attempts trigger lockout (3 wrong attempts -> lockout)
    for (int i = 0; i < 3; i++) {
        FBPKosherAdminSession *bad = [store authenticateWithPIN:@"000000" error:&err];
        TEST_ASSERT(bad == nil, "Wrong PIN must fail");
    }
    TEST_ASSERT(store.remainingLockoutSeconds > 0, "Expected progressive lockout after failed attempts");
    FBPKosherAdminSession *evenRightDuringLock = [store authenticateWithPIN:@"654321" error:&err];
    TEST_ASSERT(evenRightDuringLock == nil && err.code == FBPKosherPolicyStoreErrorLockedOut,
                "Lockout must reject attempts until cooldown expires");

    // Recovery code resets PIN while preserving Strict Mode ON
    NSString *newRecovery = nil;
    TEST_ASSERT([store resetAdminPINWithRecoveryCode:recoveryCode
                                              newPIN:@"778899"
                                  newRecoveryCodeOut:&newRecovery
                                               error:&err] == YES,
                "Valid recovery code must reset PIN: %@", err);
    TEST_ASSERT(![newRecovery isEqualToString:recoveryCode], "Recovery code must rotate on use");
    TEST_ASSERT(store.strictModeEnabled == YES, "Recovery must preserve Strict Mode ON");

    FBPKosherAdminSession *reauth = [store authenticateWithPIN:@"778899" error:&err];
    TEST_ASSERT(reauth != nil && [store addApprovedSource:grp session:reauth error:&err] == YES,
                "New PIN must authenticate and allow source addition");

    // Export JSON contains sources but zero PIN/salt/hash material
    NSData *exported = [store exportPolicyJSONWithSession:reauth error:&err];
    TEST_ASSERT(exported != nil, "Policy export must succeed");
    NSString *exportStr = [[NSString alloc] initWithData:exported encoding:NSUTF8StringEncoding];
    TEST_ASSERT([exportStr containsString:@"555666"] &&
                ![exportStr containsString:@"778899"] &&
                ![exportStr containsString:newRecovery],
                "Exported policy JSON must exclude credentials");
    return YES;
}

// 16. New installations default to strict mode
static BOOL test_16_new_installations_default_to_strict_mode(void) {
    NSURL *dir = CreateTempStorageDir(@"t16");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherPolicyStore *store = [[FBPKosherPolicyStore alloc] initWithStorageDirectory:dir
                                                                       credentialBacking:backing
                                                                          mirrorToShared:NO];
    TEST_ASSERT(store.strictModeEnabled == YES, "Fresh store must default to strictModeEnabled == YES");
    TEST_ASSERT(store.marketplaceAdminEnabled == NO, "Fresh store must default marketplaceAdminEnabled == NO");
    TEST_ASSERT(store.allApprovedSources.count == 0, "Fresh allowlist must be empty (fail closed)");
    return YES;
}

// 17. Migrated preferences cannot silently disable strict mode
static BOOL test_17_migrated_preferences_cannot_disable_strict_mode(void) {
    NSUserDefaults *legacy = [[NSUserDefaults alloc] initWithSuiteName:@"com.shajon.fbplus"];
    [legacy removePersistentDomainForName:@"com.shajon.fbplus"];
    [legacy setBool:NO forKey:FBPKeyKosherStrictMode];
    [legacy setBool:YES forKey:FBPKeyReelsDownloaderEnabled];
    [legacy setBool:YES forKey:FBPKeyStoryDownloaderEnabled];
    [legacy setBool:YES forKey:FBPKeyLinksInSafari];
    [legacy setBool:YES forKey:FBPKeyAnonymousStories];
    [legacy setBool:YES forKey:FBPKeyMetaPlus];
    [legacy removeObjectForKey:@"kosherMigratedV1"];
    [legacy synchronize];

    // Instantiating FBPPrefs executes default registration + enforceKosherMigrationIfNeeded
    FBPPrefs *prefs = [[FBPPrefs alloc] init];
    TEST_ASSERT([prefs boolForKey:FBPKeyKosherStrictMode] == YES,
                "Migration must enforce Strict Mode ON");
    TEST_ASSERT([prefs boolForKey:FBPKeyReelsDownloaderEnabled] == NO,
                "Migration must disable Reels downloader");
    TEST_ASSERT([prefs boolForKey:FBPKeyStoryDownloaderEnabled] == NO,
                "Migration must disable Story downloader");
    TEST_ASSERT([prefs boolForKey:FBPKeyLinksInSafari] == NO,
                "Migration must disable Safari bypass forwarding");

    // Ordinary settings write cannot weaken protected Kosher keys
    [prefs setBool:NO forKey:FBPKeyKosherStrictMode];
    [prefs setBool:YES forKey:FBPKeyKosherMarketplaceEnabled];
    TEST_ASSERT([prefs boolForKey:FBPKeyKosherStrictMode] == YES,
                "setBool:NO must not turn off Strict Mode");
    TEST_ASSERT([prefs boolForKey:FBPKeyKosherMarketplaceEnabled] == NO,
                "setBool:YES must not enable Marketplace without admin auth");
    return YES;
}

// 18. Missing critical hook produces a safe blocked state
static BOOL test_18_missing_critical_hook_produces_safe_blocked_state(void) {
    NSURL *dir = CreateTempStorageDir(@"t18");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherAdminSession *session = nil;
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, &session);
    FBPKosherApprovedSource *grp =
        [[FBPKosherApprovedSource alloc] initWithIdentifier:@"1234567890"
                                                       kind:FBPKosherSourceKindGroup
                                                displayName:@"קבוצה מאושרת"
                                                   favorite:NO
                                          allowedPathPrefix:nil
                                                      notes:nil
                                                    addedAt:nil];
    [store addApprovedSource:grp session:session error:nil];

    FBPKosherCompatibilityMonitor *brokenMonitor =
        [[FBPKosherCompatibilityMonitor alloc] initWithFacebookVersion:@"586.0.0"
                                                           buildNumber:@"586000000"
                                                          tweakVersion:@"1.0.8-kosher"];
    [brokenMonitor markPolicyStoreInitialized:YES];
    for (NSString *criticalID in FBPKosherCompatibilityMonitor.criticalHookIdentifiers) {
        FBPKosherHookStatus st = [criticalID isEqualToString:@"MediaGuard.UIImageView"]
            ? FBPKosherHookStatusMissing
            : FBPKosherHookStatusInstalled;
        [brokenMonitor reportHook:criticalID
                         severity:FBPKosherHookSeverityCritical
                           status:st
                           detail:@"Simulated hook failure"];
    }
    [brokenMonitor evaluateStartupHealth];

    TEST_ASSERT(brokenMonitor.criticalEnforcementHealthy == NO,
                "Missing critical hook must mark enforcement unhealthy");
    TEST_ASSERT([brokenMonitor.restrictedStateMessage
                    isEqualToString:@"לא ניתן להפעיל את הסינון בצורה בטוחה בגרסה זו של פייסבוק."],
                "Unexpected restricted-state Hebrew message: %@", brokenMonitor.restrictedStateMessage);

    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:brokenMonitor
                                         diagnostics:[[FBPKosherDiagnostics alloc] init]];
    FBPKosherPolicyResult *res =
        [engine evaluateURL:[NSURL URLWithString:@"https://www.facebook.com/groups/1234567890"]];
    TEST_ASSERT(res.effectiveAllowed == NO,
                "Even approved groups must fail closed when a critical hook is missing");
    return YES;
}

// 19. Unknown Facebook version cannot silently bypass filtering
static BOOL test_19_unknown_facebook_version_cannot_bypass_filtering(void) {
    NSURL *dir = CreateTempStorageDir(@"t19");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, NULL);

    FBPKosherCompatibilityMonitor *unknownMon =
        [[FBPKosherCompatibilityMonitor alloc] initWithFacebookVersion:@"999.0.0"
                                                           buildNumber:@"999999"
                                                          tweakVersion:@"1.0.8-kosher"];
    [unknownMon markPolicyStoreInitialized:YES];
    for (NSString *criticalID in FBPKosherCompatibilityMonitor.criticalHookIdentifiers) {
        [unknownMon reportHook:criticalID
                      severity:FBPKosherHookSeverityCritical
                        status:FBPKosherHookStatusInstalled
                        detail:@"Runtime attached"];
    }
    [unknownMon evaluateStartupHealth];

    TEST_ASSERT(unknownMon.versionSupport == FBPKosherVersionSupportUnknown,
                "Unrecognized version must be classified Unknown");
    TEST_ASSERT(unknownMon.marketplaceEnforcementVerified == NO,
                "Unknown version must never verify Marketplace capability");

    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:unknownMon
                                         diagnostics:[[FBPKosherDiagnostics alloc] init]];
    TEST_ASSERT([engine evaluateURL:[NSURL URLWithString:@"https://www.facebook.com/reel/111"]].effectiveAllowed == NO,
                "Reels must remain blocked on unknown Facebook version");
    TEST_ASSERT([engine evaluateURL:[NSURL URLWithString:@"https://www.facebook.com/groups/999"]].effectiveAllowed == NO,
                "Unapproved groups must remain blocked on unknown Facebook version");
    return YES;
}

// 20. RTL and localization validation
static BOOL test_20_rtl_and_localization_validation(void) {
    FBPPrefs *prefs = FBPPrefs.shared;
    NSString *lang = [prefs stringForKey:FBPKeyLanguage];
    TEST_ASSERT([lang isEqualToString:@"he"], "Default tweak language must be Hebrew (he), got: %@", lang);
    TEST_ASSERT(FBPIsRTLLanguage() == YES, "FBPIsRTLLanguage() must return YES for default 'he'");

    NSString *isolated = FBPBidiIsolateLTR(@"ID 12345");
    TEST_ASSERT([isolated containsString:@"\u2066"] && [isolated containsString:@"\u2069"],
                "FBPBidiIsolateLTR must wrap string with U+2066..U+2069 isolates");
    return YES;
}

// 21. Previously cached prohibited content & AI moderation / diagnostic privacy invariants
static BOOL test_21_cached_media_blocked_and_moderation_privacy(void) {
    NSURL *dir = CreateTempStorageDir(@"t21");
    FBPKosherMemoryCredentialBacking *backing = [[FBPKosherMemoryCredentialBacking alloc] init];
    FBPKosherCompatibilityMonitor *mon = CreateHealthyMonitor(@"586.0.0");
    FBPKosherPolicyStore *store = CreateConfiguredStore(dir, backing, NULL);
    FBPKosherDiagnostics *diag = [[FBPKosherDiagnostics alloc] init];
    FBPKosherPolicyEngine *engine =
        [[FBPKosherPolicyEngine alloc] initWithStore:store
                                compatibilityMonitor:mon
                                         diagnostics:diag];

    // Even local cache/file or CDN URLs for media cannot pass policy evaluation
    FBPKosherPolicyResult *imgCacheURL =
        [engine evaluateMediaURL:[NSURL URLWithString:@"https://scontent.ftlv1-1.fna.fbcdn.net/v/cached.webp"]];
    TEST_ASSERT(imgCacheURL.effectiveAllowed == NO, "Cached/CDN image URL must remain denied");

    // Auth/API endpoints must remain allowed so login/text fetches work
    FBPKosherPolicyResult *authEndpoint =
        [engine evaluateMediaURL:[NSURL URLWithString:@"https://b-graph.facebook.com/graphql"]];
    TEST_ASSERT(authEndpoint.effectiveAllowed == YES, "Core GraphQL API endpoint must not break");

    // Moderation engine: ML stubs explicitly report NOT IMPLEMENTED, and Strict Mode overrides Allow verdict
    FBPKosherModerationEngine *mod = [[FBPKosherModerationEngine alloc] init];
    TEST_ASSERT(mod.textModerator.isModelAvailable == NO, "Stub text ML moderator must not claim availability");
    TEST_ASSERT(mod.imageModerator.isModelAvailable == NO, "Stub image ML moderator must not claim availability");

    FBPKosherModerationResult *stubTextRes = nil;
    [mod evaluateText:@"טקסט בדיקה" strictMode:YES resultOut:&stubTextRes];
    TEST_ASSERT(stubTextRes.verdict == FBPKosherModerationVerdictNotImplemented &&
                stubTextRes.isImplementedProvider == NO,
                "Stub text moderator must explicitly return NOT IMPLEMENTED");

    mod.imageModerator = [[FBPAllowAllMockImageModerator alloc] init];
    FBPKosherModerationResult *imgRes = nil;
    FBPKosherDecision strictImgDecision = [mod evaluateMedia:nil metadata:nil strictMode:YES resultOut:&imgRes];
    TEST_ASSERT(strictImgDecision == FBPKosherDecisionBlock,
                "Strict Mode MUST override any AI image classifier Allow verdict");

    // Diagnostics scrubbing must redact tokens/cookies/query params
    NSString *scrubbed = [diag scrubSensitiveText:@"https://facebook.com/groups/123?access_token=SECRET123&c_user=999"];
    TEST_ASSERT(![scrubbed containsString:@"SECRET123"] && ![scrubbed containsString:@"c_user=999"],
                "Diagnostics must scrub tokens and cookies: %@", scrubbed);
    return YES;
}

int main(void) {
    @autoreleasepool {
        fprintf(stdout, "=== Facebook Kosher Objective-C Policy Unit Tests ===\n");
        RunTest("01. Unknown content source is blocked", test_01_unknown_content_source_is_blocked);
        RunTest("02. Unapproved group is blocked", test_02_unapproved_group_is_blocked);
        RunTest("03. Approved group text is allowed", test_03_approved_group_text_is_allowed);
        RunTest("04. Approved group image is blocked", test_04_approved_group_image_is_blocked);
        RunTest("05. Approved group video is blocked", test_05_approved_group_video_is_blocked);
        RunTest("06. Shared post from unapproved source is blocked", test_06_shared_post_from_unapproved_source_is_blocked);
        RunTest("07. Unknown profile is blocked", test_07_unknown_profile_is_blocked);
        RunTest("08. Direct Reel URL is blocked", test_08_direct_reel_url_is_blocked);
        RunTest("09. Direct Story URL is blocked", test_09_direct_story_url_is_blocked);
        RunTest("10. Video opened through notification is blocked", test_10_video_opened_through_notification_is_blocked);
        RunTest("11. Unsafe redirect is blocked", test_11_unsafe_redirect_is_blocked);
        RunTest("12. Untrusted external URL is blocked", test_12_untrusted_external_url_is_blocked);
        RunTest("13. Unknown search result is blocked", test_13_unknown_search_result_is_blocked);
        RunTest("14. Marketplace remains blocked when capability is unverified", test_14_marketplace_remains_blocked_when_unverified);
        RunTest("15. Administrator PIN is required for policy modifications", test_15_administrator_pin_required_for_modifications);
        RunTest("16. New installations default to strict mode", test_16_new_installations_default_to_strict_mode);
        RunTest("17. Migrated preferences cannot silently disable strict mode", test_17_migrated_preferences_cannot_disable_strict_mode);
        RunTest("18. Missing critical hook produces safe blocked state", test_18_missing_critical_hook_produces_safe_blocked_state);
        RunTest("19. Unknown Facebook version cannot silently bypass filtering", test_19_unknown_facebook_version_cannot_bypass_filtering);
        RunTest("20. RTL and localization validation", test_20_rtl_and_localization_validation);
        RunTest("21. Cached media & moderation/diagnostics privacy invariants", test_21_cached_media_blocked_and_moderation_privacy);

        fprintf(stdout, "\nSummary: %lu passed, %lu failed\n",
                (unsigned long)gPassed, (unsigned long)gFailed);
        return (gFailed == 0) ? 0 : 1;
    }
}
