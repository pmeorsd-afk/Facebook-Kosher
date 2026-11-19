// Model-level content filtering implementation.

#import "FBPKosherContentFilter.h"
#import "FBPKosherPolicyEngine.h"

#import <objc/message.h>
#import <objc/runtime.h>

static id FBPSafeKVCValue(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *FBPSafeStringField(id obj, NSArray<NSString *> *keys) {
    for (NSString *k in keys) {
        id val = nil;
        SEL sel = NSSelectorFromString(k);
        if ([obj respondsToSelector:sel]) {
            NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
            const char *ret = sig.methodReturnType;
            if (ret && ret[0] == _C_ID) {
                @try {
                    val = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
                } @catch (__unused NSException *e) {}
            }
        }
        if (!val) val = FBPSafeKVCValue(obj, k);
        if ([val isKindOfClass:NSString.class] && [(NSString *)val length] > 0) {
            return val;
        }
        if ([val isKindOfClass:NSNumber.class]) {
            return [(NSNumber *)val stringValue];
        }
    }
    return nil;
}

static void FBPExtractSourceFromStory(id storyModel,
                                      NSString * _Nullable *sourceIDOut,
                                      FBPKosherSourceKind *kindOut,
                                      BOOL *hasExplicitOut) {
    NSString *sourceID = nil;
    FBPKosherSourceKind kind = FBPKosherSourceKindGroup;
    BOOL hasExplicit = NO;

    id targetGroup = FBPSafeKVCValue(storyModel, @"targetGroup")
                  ?: FBPSafeKVCValue(storyModel, @"to")
                  ?: FBPSafeKVCValue(storyModel, @"group");
    if (targetGroup) {
        NSString *gid = FBPSafeStringField(targetGroup, @[@"graphQLID", @"fbid", @"id"]);
        NSString *typeName = NSStringFromClass([targetGroup class]).lowercaseString;
        if (gid.length) {
            sourceID = gid;
            hasExplicit = YES;
            if ([typeName containsString:@"page"]) kind = FBPKosherSourceKindPage;
            else if ([typeName containsString:@"user"] || [typeName containsString:@"person"]) {
                kind = FBPKosherSourceKindProfile;
            } else {
                kind = FBPKosherSourceKindGroup;
            }
        }
    }

    if (!hasExplicit) {
        id actors = FBPSafeKVCValue(storyModel, @"actors");
        id actor = ([actors isKindOfClass:NSArray.class] && [(NSArray *)actors count] > 0)
            ? [(NSArray *)actors firstObject]
            : FBPSafeKVCValue(storyModel, @"actor");
        if (actor) {
            NSString *aid = FBPSafeStringField(actor, @[@"graphQLID", @"fbid", @"id"]);
            NSString *typeName = NSStringFromClass([actor class]).lowercaseString;
            if (aid.length) {
                sourceID = aid;
                hasExplicit = YES;
                if ([typeName containsString:@"page"]) kind = FBPKosherSourceKindPage;
                else if ([typeName containsString:@"group"]) kind = FBPKosherSourceKindGroup;
                else kind = FBPKosherSourceKindProfile;
            }
        }
    }

    if (sourceIDOut) *sourceIDOut = sourceID;
    if (kindOut) *kindOut = kind;
    if (hasExplicitOut) *hasExplicitOut = hasExplicit;
}

BOOL FBPKosherShouldFilterModel(id model) {
    return [FBPKosherContentFilter shouldFilterModel:model];
}

@implementation FBPKosherContentFilter

+ (BOOL)shouldFilterModel:(id)model {
    if (!model || !FBPKosherStrictModeActive()) return NO;

    NSString *className = NSStringFromClass([model class]) ?: @"";
    NSString *low = className.lowercaseString;

    // Never drop core auth/session/UI metadata or leaf action objects whose
    // parent container assumes non-nil references.
    if ([low containsString:@"session"] ||
        [low containsString:@"auth"] ||
        [low containsString:@"login"] ||
        [low containsString:@"pagination"] ||
        [low containsString:@"pageinfo"] ||
        [low containsString:@"actionlink"]) {
        return NO;
    }

    // Immediate blocks for Reels, Stories, Watch, Live, Ads, Surveys, Recommendations.
    if ([low containsString:@"shorts"] ||
        [low containsString:@"reels"] ||
        [low containsString:@"singlebucketinlineviewer"] ||
        [low containsString:@"stories"] ||
        [low containsString:@"storybucket"] ||
        [low containsString:@"groupsyoushouldjoin"] ||
        [low containsString:@"pagesyoumaylike"] ||
        [low containsString:@"positionalfeedsurvey"] ||
        [low containsString:@"surveyfeedunit"] ||
        [low containsString:@"quickpromotion"] ||
        [low containsString:@"pymk"] ||
        [low containsString:@"facecast"] ||
        [low containsString:@"livevideo"] ||
        [low containsString:@"videohome"] ||
        [low containsString:@"watchfeed"]) {
        return YES;
    }

    NSString *category = FBPSafeStringField(model, @[@"category", @"feedUnitCategory", @"feed_unit_category"]);
    BOOL isSponsored = ([category isEqualToString:@"SPONSORED"] ||
                        FBPSafeKVCValue(model, @"sponsoredData") != nil);
    if (isSponsored) return YES;

    if ([category isEqualToString:@"FB_SHORTS"] ||
        [category isEqualToString:@"MULTI_FB_STORIES_TRAY"] ||
        [category isEqualToString:@"ENGAGEMENT"] ||
        [category isEqualToString:@"ENGAGEMENT_QP"] ||
        [category isEqualToString:@"PYMK"] ||
        [category isEqualToString:@"PYMK_FEED"] ||
        [category isEqualToString:@"PYMK_STORY"]) {
        return YES;
    }

    // Check Threads / promotional in-feed cards.
    NSString *unitType = FBPSafeStringField(model, @[@"feedUnitType", @"feed_unit_type", @"unitType", @"inlineUnitType"]);
    if ([unitType hasPrefix:@"THREADS_"]) return YES;

    // Evaluate story / feed unit objects against source allowlist & shared-post rules.
    BOOL isFeedStory = [low isEqualToString:@"fbmemfeedstory"] ||
                       [low hasSuffix:@"feedunit"] ||
                       [low containsString:@"storyfeedunit"];
    if (!isFeedStory) {
        return NO;
    }

    NSString *sourceID = nil;
    FBPKosherSourceKind sourceKind = FBPKosherSourceKindGroup;
    BOOL hasExplicitSource = NO;
    FBPExtractSourceFromStory(model, &sourceID, &sourceKind, &hasExplicitSource);

    // Check embedded shared posts (attachedStory / attached_story):
    // approving a group MUST NOT automatically allow shared posts from unapproved sources.
    BOOL sharedFromUnapproved = NO;
    id attached = FBPSafeKVCValue(model, @"attachedStory")
               ?: FBPSafeKVCValue(model, @"attached_story");
    if (attached) {
        NSString *sharedID = nil;
        FBPKosherSourceKind sharedKind = FBPKosherSourceKindGroup;
        BOOL hasShared = NO;
        FBPExtractSourceFromStory(attached, &sharedID, &sharedKind, &hasShared);
        if (!hasShared || !sharedID.length) {
            sharedFromUnapproved = YES;
        } else {
            FBPKosherPolicyStore *store = FBPKosherPolicyStore.shared;
            if (sharedKind == FBPKosherSourceKindGroup && ![store isGroupApproved:sharedID]) {
                sharedFromUnapproved = YES;
            } else if (sharedKind == FBPKosherSourceKindPage && ![store isPageApproved:sharedID]) {
                sharedFromUnapproved = YES;
            } else if (sharedKind == FBPKosherSourceKindProfile && ![store isProfileApproved:sharedID]) {
                sharedFromUnapproved = YES;
            }
        }
    }

    NSString *bodyText = nil;
    id messageObj = FBPSafeKVCValue(model, @"message");
    if (messageObj) {
        bodyText = FBPSafeStringField(messageObj, @[@"text"]);
    }

    FBPKosherPolicyResult *res =
        [FBPKosherPolicyEngine.shared evaluateModelWithClassName:className
                                                        category:category
                                                        sourceID:sourceID
                                                      sourceKind:sourceKind
                                             hasExplicitSourceID:hasExplicitSource
                                                     isSponsored:isSponsored
                                                         isMedia:NO
                                          isSharedFromUnapproved:sharedFromUnapproved
                                                     textualBody:bodyText];
    return !res.effectiveAllowed;
}

@end
