// Typed policy models and strict identifier validation for Facebook Kosher.

#import "FBPKosherTypes.h"

NSString *FBPKosherDecisionName(FBPKosherDecision decision) {
    switch (decision) {
        case FBPKosherDecisionAllow: return @"ALLOW";
        case FBPKosherDecisionBlock: return @"BLOCK";
        case FBPKosherDecisionUnknown: return @"UNKNOWN";
    }
    return @"UNKNOWN";
}

NSString *FBPKosherDestinationName(FBPKosherDestinationType destination) {
    switch (destination) {
        case FBPKosherDestinationUnknown: return @"unknown";
        case FBPKosherDestinationHomeFeed: return @"home_feed";
        case FBPKosherDestinationGroup: return @"group";
        case FBPKosherDestinationPage: return @"page";
        case FBPKosherDestinationProfile: return @"profile";
        case FBPKosherDestinationReels: return @"reels";
        case FBPKosherDestinationStories: return @"stories";
        case FBPKosherDestinationWatch: return @"watch";
        case FBPKosherDestinationLive: return @"live";
        case FBPKosherDestinationMarketplace: return @"marketplace";
        case FBPKosherDestinationSearch: return @"search";
        case FBPKosherDestinationPhotoViewer: return @"photo_viewer";
        case FBPKosherDestinationVideoViewer: return @"video_viewer";
        case FBPKosherDestinationNotifications: return @"notifications";
        case FBPKosherDestinationMessaging: return @"messaging";
        case FBPKosherDestinationExternalLink: return @"external_link";
        case FBPKosherDestinationAuth: return @"auth";
        case FBPKosherDestinationSettings: return @"settings";
        case FBPKosherDestinationAdmin: return @"admin";
        case FBPKosherDestinationKosherHome: return @"kosher_home";
    }
    return @"unknown";
}

NSString *FBPKosherContentTypeName(FBPKosherContentType contentType) {
    switch (contentType) {
        case FBPKosherContentUnknown: return @"unknown";
        case FBPKosherContentText: return @"text";
        case FBPKosherContentImage: return @"image";
        case FBPKosherContentVideo: return @"video";
        case FBPKosherContentGIF: return @"gif";
        case FBPKosherContentSticker: return @"sticker";
        case FBPKosherContentAudio: return @"audio";
        case FBPKosherContentCarousel: return @"carousel";
        case FBPKosherContentLinkPreview: return @"link_preview";
        case FBPKosherContentSponsored: return @"sponsored";
        case FBPKosherContentRecommendation: return @"recommendation";
        case FBPKosherContentSurvey: return @"survey";
        case FBPKosherContentNavigation: return @"navigation";
    }
    return @"unknown";
}

NSString *FBPKosherSourceKindName(FBPKosherSourceKind kind) {
    switch (kind) {
        case FBPKosherSourceKindGroup: return @"group";
        case FBPKosherSourceKindPage: return @"page";
        case FBPKosherSourceKindProfile: return @"profile";
        case FBPKosherSourceKindTrustedDomain: return @"trusted_domain";
    }
    return @"group";
}

static BOOL FBPKosherStringMatchesRegex(NSString *str, NSString *pattern) {
    if (str.length == 0) return NO;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                          options:0
                                                                            error:nil];
    if (!re) return NO;
    return [re firstMatchInString:str options:0 range:NSMakeRange(0, str.length)] != nil;
}

static BOOL FBPKosherIsReservedFacebookPath(NSString *slug) {
    static NSSet<NSString *> *reserved;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        reserved = [NSSet setWithArray:@[
            @"reel", @"reels", @"watch", @"stories", @"story", @"live", @"gaming",
            @"marketplace", @"dating", @"friends", @"groups", @"pages", @"search",
            @"photo", @"photos", @"video", @"videos", @"share", @"sharer", @"l.php",
            @"login", @"checkpoint", @"recover", @"home", @"feed", @"notifications",
            @"messages", @"settings", @"privacy", @"help", @"about", @"ads",
        ]];
    });
    return [reserved containsObject:slug.lowercaseString];
}

@implementation FBPKosherApprovedSource

- (instancetype)initWithIdentifier:(NSString *)identifier
                              kind:(FBPKosherSourceKind)kind
                       displayName:(NSString *)displayName
                          favorite:(BOOL)favorite
                 allowedPathPrefix:(NSString *)allowedPathPrefix
                             notes:(NSString *)notes
                           addedAt:(NSDate *)addedAt {
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _kind = kind;
        _displayName = displayName.length ? [displayName copy] : [identifier copy];
        _favorite = favorite;
        _allowedPathPrefix = allowedPathPrefix.length ? [allowedPathPrefix copy] : nil;
        _notes = notes.length ? [notes copy] : nil;
        _addedAt = addedAt ? [addedAt copy] : [NSDate date];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return [[FBPKosherApprovedSource allocWithZone:zone]
        initWithIdentifier:self.identifier
                      kind:self.kind
               displayName:self.displayName
                  favorite:self.favorite
         allowedPathPrefix:self.allowedPathPrefix
                     notes:self.notes
                   addedAt:self.addedAt];
}

+ (nullable NSString *)normalizedIdentifier:(NSString *)rawIdentifier
                                    forKind:(FBPKosherSourceKind)kind {
    if (![rawIdentifier isKindOfClass:NSString.class]) return nil;
    NSString *trimmed = [rawIdentifier stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0 || trimmed.length > 255) return nil;

    // Reject path traversal, fragments, control chars, whitespace, or wildcards.
    if ([trimmed containsString:@".."] ||
        [trimmed containsString:@"*"] ||
        [trimmed containsString:@"@"] ||
        [trimmed rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) {
        return nil;
    }

    if (kind == FBPKosherSourceKindTrustedDomain) {
        NSString *candidate = trimmed.lowercaseString;
        if ([candidate hasPrefix:@"https://"] || [candidate hasPrefix:@"http://"]) {
            NSURL *url = [NSURL URLWithString:candidate];
            if (!url || !url.host.length) return nil;
            candidate = url.host.lowercaseString;
        }
        if ([candidate hasSuffix:@"."]) {
            candidate = [candidate substringToIndex:candidate.length - 1];
        }
        // Reject raw IPv4 addresses and malformed domains.
        if (FBPKosherStringMatchesRegex(candidate, @"^\\d+\\.\\d+\\.\\d+\\.\\d+$")) return nil;
        if (!FBPKosherStringMatchesRegex(candidate, @"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,24}$")) {
            return nil;
        }
        return candidate;
    }

    // Allow administrators to paste a Facebook group/page/profile URL directly.
    NSString *extracted = trimmed;
    if ([trimmed.lowercaseString hasPrefix:@"https://"] ||
        [trimmed.lowercaseString hasPrefix:@"http://"]) {
        NSURL *url = [NSURL URLWithString:trimmed];
        if (!url || !url.host.length) return nil;
        NSString *host = url.host.lowercaseString;
        if (![host isEqualToString:@"facebook.com"] && ![host hasSuffix:@".facebook.com"]) {
            return nil;
        }
        NSArray<NSString *> *parts = [url.path pathComponents];
        NSMutableArray<NSString *> *clean = [NSMutableArray array];
        for (NSString *part in parts) {
            if (part.length && ![part isEqualToString:@"/"]) [clean addObject:part];
        }
        if (kind == FBPKosherSourceKindGroup) {
            if (clean.count >= 2 && [clean[0].lowercaseString isEqualToString:@"groups"]) {
                extracted = clean[1];
            } else {
                return nil;
            }
        } else {
            NSURLComponents *comps = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
            NSString *idParam = nil;
            for (NSURLQueryItem *item in comps.queryItems) {
                if ([item.name isEqualToString:@"id"] && item.value.length) {
                    idParam = item.value;
                    break;
                }
            }
            if (idParam) {
                extracted = idParam;
            } else if (clean.count >= 1) {
                extracted = clean[0];
            } else {
                return nil;
            }
        }
    }

    extracted = extracted.lowercaseString;
    if (FBPKosherIsReservedFacebookPath(extracted)) return nil;

    if (kind == FBPKosherSourceKindGroup) {
        // Group IDs are numeric or valid Facebook group slugs (never arbitrary paths).
        if (FBPKosherStringMatchesRegex(extracted, @"^[0-9]{5,30}$") ||
            FBPKosherStringMatchesRegex(extracted, @"^[a-z0-9][a-z0-9._-]{2,80}$")) {
            return extracted;
        }
        return nil;
    }

    if (FBPKosherStringMatchesRegex(extracted, @"^[0-9]{4,30}$") ||
        FBPKosherStringMatchesRegex(extracted, @"^[a-z0-9][a-z0-9._-]{1,80}$")) {
        return extracted;
    }
    return nil;
}

- (NSDictionary<NSString *, id> *)toJSONDictionary {
    NSMutableDictionary<NSString *, id> *dict = [NSMutableDictionary dictionary];
    dict[@"identifier"] = self.identifier;
    dict[@"kind"] = @(self.kind);
    dict[@"displayName"] = self.displayName;
    dict[@"favorite"] = @(self.favorite);
    dict[@"addedAtTimestamp"] = @([self.addedAt timeIntervalSince1970]);
    if (self.allowedPathPrefix.length) dict[@"allowedPathPrefix"] = self.allowedPathPrefix;
    if (self.notes.length) dict[@"notes"] = self.notes;
    return [dict copy];
}

+ (nullable instancetype)fromJSONDictionary:(NSDictionary<NSString *, id> *)dict {
    if (![dict isKindOfClass:NSDictionary.class]) return nil;
    id rawKind = dict[@"kind"];
    id rawID = dict[@"identifier"];
    id rawName = dict[@"displayName"];
    if (![rawKind isKindOfClass:NSNumber.class] || ![rawID isKindOfClass:NSString.class]) {
        return nil;
    }
    NSInteger kindVal = [rawKind integerValue];
    if (kindVal < FBPKosherSourceKindGroup || kindVal > FBPKosherSourceKindTrustedDomain) {
        return nil;
    }
    FBPKosherSourceKind kind = (FBPKosherSourceKind)kindVal;
    NSString *normalized = [self normalizedIdentifier:rawID forKind:kind];
    if (!normalized) return nil;

    NSString *displayName = [rawName isKindOfClass:NSString.class] ? rawName : normalized;
    BOOL favorite = [dict[@"favorite"] isKindOfClass:NSNumber.class] ? [dict[@"favorite"] boolValue] : NO;
    NSString *prefix = [dict[@"allowedPathPrefix"] isKindOfClass:NSString.class] ? dict[@"allowedPathPrefix"] : nil;
    if (prefix.length) {
        if (![prefix hasPrefix:@"/"] || [prefix containsString:@".."] ||
            [prefix rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) {
            return nil;
        }
    }
    NSString *notes = [dict[@"notes"] isKindOfClass:NSString.class] ? dict[@"notes"] : nil;
    NSDate *addedAt = [NSDate date];
    if ([dict[@"addedAtTimestamp"] isKindOfClass:NSNumber.class]) {
        addedAt = [NSDate dateWithTimeIntervalSince1970:[dict[@"addedAtTimestamp"] doubleValue]];
    }

    return [[FBPKosherApprovedSource alloc] initWithIdentifier:normalized
                                                          kind:kind
                                                   displayName:displayName
                                                      favorite:favorite
                                             allowedPathPrefix:prefix
                                                         notes:notes
                                                       addedAt:addedAt];
}

@end

@implementation FBPKosherPolicyContext

+ (instancetype)contextWithDestination:(FBPKosherDestinationType)destination
                           contentType:(FBPKosherContentType)contentType {
    FBPKosherPolicyContext *ctx = [[FBPKosherPolicyContext alloc] init];
    ctx.destinationType = destination;
    ctx.contentType = contentType;
    ctx.strictModeActive = YES;
    ctx.compatibilityHealthy = YES;
    return ctx;
}

@end

@implementation FBPKosherPolicyResult

- (instancetype)initWithDecision:(FBPKosherDecision)decision
                      reasonCode:(NSString *)reasonCode
                 localizedReason:(NSString *)localizedReason
                         context:(FBPKosherPolicyContext *)context {
    if ((self = [super init])) {
        _decision = decision;
        // Core fail-closed invariant: UNKNOWN always behaves as BLOCK in strict mode.
        if (context.strictModeActive) {
            _effectiveAllowed = (decision == FBPKosherDecisionAllow);
        } else {
            _effectiveAllowed = (decision != FBPKosherDecisionBlock);
        }
        _reasonCode = [reasonCode copy];
        _localizedReason = [localizedReason copy];
        _context = context;
        _evaluatedAt = [NSDate date];
    }
    return self;
}

@end
