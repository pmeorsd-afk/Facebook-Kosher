// Centralized fail-closed policy evaluation implementation.

#import "FBPKosherPolicyEngine.h"
#import "FBPKosherModeration.h"
#import "FBPPrefs.h"

BOOL FBPKosherStrictModeActive(void) {
    return [FBPKosherPolicyEngine.shared isStrictModeActive];
}

static BOOL FBPHostMatchesSuffix(NSString *host, NSString *suffix) {
    if (!host.length || !suffix.length) return NO;
    return [host isEqualToString:suffix] || [host hasSuffix:[@"." stringByAppendingString:suffix]];
}

static BOOL FBPIsFacebookFamilyHost(NSString *host) {
    if (!host.length) return NO;
    NSString *h = host.lowercaseString;
    NSArray<NSString *> *suffixes = @[
        @"facebook.com", @"fb.com", @"fb.watch", @"fbwat.ch",
        @"fb.me", @"fb.gg", @"messenger.com", @"m.me",
        @"fbcdn.net", @"fbsbx.com", @"facebook.net", @"meta.com"
    ];
    for (NSString *s in suffixes) {
        if (FBPHostMatchesSuffix(h, s)) return YES;
    }
    return NO;
}

static NSString *FBPQueryParam(NSURL *url, NSArray<NSString *> *names) {
    NSURLComponents *comps = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in comps.queryItems) {
        for (NSString *name in names) {
            if ([item.name caseInsensitiveCompare:name] == NSOrderedSame && item.value.length) {
                return item.value;
            }
        }
    }
    return nil;
}

static BOOL FBPURLHasSuspiciousStructure(NSURL *url) {
    NSString *abs = url.absoluteString ?: @"";
    if (abs.length == 0 || abs.length > 4096) return YES;
    // Block user@host spoofing (e.g., https://www.facebook.com@evil.com/groups/1).
    if (url.user.length > 0 || url.password.length > 0) return YES;
    // Reject path traversal or control characters before/after decoding.
    NSString *decoded = abs.stringByRemovingPercentEncoding ?: abs;
    if ([abs containsString:@".."] || [decoded containsString:@".."]) return YES;
    if ([abs rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return YES;
    return NO;
}

static BOOL FBPPathHasMediaExtension(NSString *path) {
    if (path.length == 0) return NO;
    NSString *ext = path.pathExtension.lowercaseString;
    if (ext.length == 0) return NO;
    static NSSet<NSString *> *mediaExts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mediaExts = [NSSet setWithArray:@[
            @"jpg", @"jpeg", @"png", @"gif", @"webp", @"heic", @"heif", @"avif", @"bmp",
            @"mp4", @"m4v", @"mov", @"m3u8", @"mpd", @"webm", @"ts", @"flv", @"avi"
        ]];
    });
    return [mediaExts containsObject:ext];
}

static NSArray<NSString *> *FBPCleanPathSegments(NSURL *url) {
    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    for (NSString *part in url.path.pathComponents) {
        if (part.length && ![part isEqualToString:@"/"]) {
            [segments addObject:part];
        }
    }
    return [segments copy];
}

@implementation FBPKosherPolicyEngine

+ (FBPKosherPolicyEngine *)shared {
    static FBPKosherPolicyEngine *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] initWithStore:FBPKosherPolicyStore.shared
                        compatibilityMonitor:FBPKosherCompatibilityMonitor.shared
                                 diagnostics:FBPKosherDiagnostics.shared];
    });
    return shared;
}

- (instancetype)initWithStore:(FBPKosherPolicyStore *)store
         compatibilityMonitor:(FBPKosherCompatibilityMonitor *)monitor
                  diagnostics:(FBPKosherDiagnostics *)diagnostics {
    if ((self = [super init])) {
        _store = store;
        _compatibilityMonitor = monitor;
        _diagnostics = diagnostics;
    }
    return self;
}

- (BOOL)isStrictModeActive {
    return self.store.strictModeEnabled;
}

- (FBPKosherPolicyResult *)recordAndReturn:(FBPKosherPolicyResult *)result {
    [self.diagnostics recordPolicyResult:result];
    return result;
}

- (nullable NSURL *)normalizedURLFromURL:(nullable NSURL *)rawURL {
    if (![rawURL isKindOfClass:NSURL.class]) return nil;
    NSURL *current = rawURL;

    for (NSInteger depth = 0; depth < 3; depth++) {
        if (FBPURLHasSuspiciousStructure(current)) return nil;
        NSString *scheme = current.scheme.lowercaseString ?: @"";
        NSString *host = current.host.lowercaseString ?: @"";

        if ([scheme isEqualToString:@"fb"]) {
            if ([host isEqualToString:@"fbplusbridge"] ||
                [host isEqualToString:@"faceweb"] ||
                [host isEqualToString:@"facewebmodal"] ||
                [host isEqualToString:@"web"]) {
                NSString *inner = FBPQueryParam(current, @[@"url", @"href"]);
                NSURL *next = inner.length ? [NSURL URLWithString:inner] : nil;
                if (!next) return nil;
                current = next;
                continue;
            }
            return current;
        }

        if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
            if (FBPHostMatchesSuffix(host, @"facebook.com")) {
                NSString *path = current.path.lowercaseString ?: @"";
                if ([path isEqualToString:@"/l.php"] || [path hasPrefix:@"/l/"]) {
                    NSString *inner = FBPQueryParam(current, @[@"u", @"url"]);
                    NSURL *next = inner.length ? [NSURL URLWithString:inner] : nil;
                    if (!next) return nil;
                    current = next;
                    continue;
                }
            }
            return current;
        }

        return current;
    }
    // Too many nested redirects -> reject fail-closed.
    return nil;
}

#pragma mark - Context Core Evaluation

- (FBPKosherPolicyResult *)evaluateContext:(FBPKosherPolicyContext *)context {
    BOOL strict = self.isStrictModeActive;
    context.strictModeActive = strict;
    context.compatibilityHealthy = self.compatibilityMonitor.criticalEnforcementHealthy;

    if (!strict) {
        return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
            initWithDecision:FBPKosherDecisionAllow
                  reasonCode:@"strict_mode_disabled_by_admin"
             localizedReason:@"המערכת פועלת במצב מנוהל פתוח."
                     context:context]];
    }

    // 1. Critical compatibility gate: never expose Facebook content if enforcement hooks failed.
    if (!context.compatibilityHealthy) {
        BOOL safeShell = (context.destinationType == FBPKosherDestinationAuth ||
                          context.destinationType == FBPKosherDestinationSettings ||
                          context.destinationType == FBPKosherDestinationAdmin ||
                          context.destinationType == FBPKosherDestinationKosherHome);
        if (!safeShell) {
            return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                initWithDecision:FBPKosherDecisionBlock
                      reasonCode:@"compatibility_unhealthy"
                 localizedReason:[self.compatibilityMonitor restrictedStateMessage]
                         context:context]];
        }
    }

    // 2. Always permit essential authentication & internal safe Kosher UI.
    if (context.destinationType == FBPKosherDestinationAuth) {
        return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
            initWithDecision:FBPKosherDecisionAllow
                  reasonCode:@"auth_essential"
             localizedReason:@"מסך התחברות ואימות חיוני."
                     context:context]];
    }
    if (context.destinationType == FBPKosherDestinationKosherHome ||
        context.destinationType == FBPKosherDestinationSettings ||
        context.destinationType == FBPKosherDestinationAdmin) {
        return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
            initWithDecision:FBPKosherDecisionAllow
                  reasonCode:@"kosher_shell"
             localizedReason:@"ממשק פייסבוק כשר."
                     context:context]];
    }

    // 3. Always block media & entertainment content types in strict mode.
    switch (context.contentType) {
        case FBPKosherContentImage:
        case FBPKosherContentVideo:
        case FBPKosherContentGIF:
        case FBPKosherContentSticker:
        case FBPKosherContentCarousel:
        case FBPKosherContentLinkPreview:
            return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                initWithDecision:FBPKosherDecisionBlock
                      reasonCode:@"media_blocked_strict"
                 localizedReason:@"תמונות, סרטונים ומדיה חסומים במצב טקסט בלבד."
                         context:context]];
        case FBPKosherContentSponsored:
        case FBPKosherContentRecommendation:
        case FBPKosherContentSurvey:
            return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                initWithDecision:FBPKosherDecisionBlock
                      reasonCode:@"clutter_or_ads_blocked"
                 localizedReason:@"מודעות, המלצות וסקרים חסומים במצב המחמיר."
                         context:context]];
        default:
            break;
    }

    // 4. Shared post from unapproved/unknown source stays blocked even inside an approved group.
    if (context.isSharedFromUnapprovedSource) {
        return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
            initWithDecision:FBPKosherDecisionBlock
                  reasonCode:@"shared_unapproved_source"
             localizedReason:@"פוסט משותף ממקור שאינו מאושר נחסם."
                     context:context]];
    }

    // 5. Destination rules.
    switch (context.destinationType) {
        case FBPKosherDestinationReels:
        case FBPKosherDestinationStories:
        case FBPKosherDestinationWatch:
        case FBPKosherDestinationLive:
        case FBPKosherDestinationPhotoViewer:
        case FBPKosherDestinationVideoViewer:
        case FBPKosherDestinationHomeFeed:
            return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                initWithDecision:FBPKosherDecisionBlock
                      reasonCode:@"prohibited_entertainment_surface"
                 localizedReason:@"שטח זה (פיד כללי / רילס / סטוריז / וידאו) חסום במצב המחמיר."
                         context:context]];

        case FBPKosherDestinationSearch:
            return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                initWithDecision:FBPKosherDecisionBlock
                      reasonCode:@"unrestricted_search_blocked"
                 localizedReason:@"חיפוש כללי חסום. ניתן לחפש רק במקורות מאושרים."
                         context:context]];

        case FBPKosherDestinationMarketplace:
            if (self.store.marketplaceAdminEnabled &&
                self.compatibilityMonitor.marketplaceEnforcementVerified) {
                return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                    initWithDecision:FBPKosherDecisionAllow
                          reasonCode:@"marketplace_verified_text_only"
                     localizedReason:@"מרקטפלייס מאושר במצב טקסט בלבד."
                             context:context]];
            }
            return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                initWithDecision:FBPKosherDecisionBlock
                      reasonCode:@"marketplace_blocked"
                 localizedReason:@"מרקטפלייס אינו זמין במצב הסינון המחמיר."
                         context:context]];

        case FBPKosherDestinationGroup:
            if (context.sourceIdentifier.length && [self.store isGroupApproved:context.sourceIdentifier]) {
                return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                    initWithDecision:FBPKosherDecisionAllow
                          reasonCode:@"approved_group"
                     localizedReason:@"קבוצה מאושרת (טקסט בלבד)."
                             context:context]];
            }
            return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                initWithDecision:FBPKosherDecisionBlock
                      reasonCode:@"unapproved_group"
                 localizedReason:@"קבוצה זו אינה ברשימת הקבוצות המאושרות."
                         context:context]];

        case FBPKosherDestinationPage:
            if (context.sourceIdentifier.length && [self.store isPageApproved:context.sourceIdentifier]) {
                return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                    initWithDecision:FBPKosherDecisionAllow
                          reasonCode:@"approved_page"
                     localizedReason:@"עמוד מאושר (טקסט בלבד)."
                             context:context]];
            }
            return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                initWithDecision:FBPKosherDecisionBlock
                      reasonCode:@"unapproved_page"
                 localizedReason:@"עמוד זה אינו ברשימת העמודים המאושרים."
                         context:context]];

        case FBPKosherDestinationProfile:
            if (context.sourceIdentifier.length && [self.store isProfileApproved:context.sourceIdentifier]) {
                return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                    initWithDecision:FBPKosherDecisionAllow
                          reasonCode:@"approved_profile"
                     localizedReason:@"פרופיל מאושר (טקסט בלבד)."
                             context:context]];
            }
            return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                initWithDecision:FBPKosherDecisionBlock
                      reasonCode:@"unapproved_profile"
                 localizedReason:@"פרופילים שאינם מאושרים חסומים במצב המחמיר."
                         context:context]];

        case FBPKosherDestinationExternalLink: {
            NSString *host = context.rawURL.host;
            NSString *path = context.rawURL.path;
            if (host.length && [self.store isExternalDomainTrusted:host path:path]) {
                return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                    initWithDecision:FBPKosherDecisionAllow
                          reasonCode:@"trusted_external_domain"
                     localizedReason:@"קישור חיצוני מאושר."
                             context:context]];
            }
            return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                initWithDecision:FBPKosherDecisionBlock
                      reasonCode:@"untrusted_external_link"
                 localizedReason:@"קישור חיצוני זה אינו ברשימת הדומיינים המאושרים."
                         context:context]];
        }

        case FBPKosherDestinationNotifications:
        case FBPKosherDestinationMessaging:
            return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                initWithDecision:FBPKosherDecisionAllow
                      reasonCode:@"permitted_communication_surface"
                 localizedReason:@"תקשורת מותרת בכפוף לחסימת מדיה וקישורים."
                         context:context]];

        case FBPKosherDestinationUnknown:
        default:
            // UNKNOWN must always fail closed in strict mode.
            return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                initWithDecision:FBPKosherDecisionUnknown
                      reasonCode:@"unknown_destination_blocked"
                 localizedReason:@"יעד לא מזוהה נחסם אוטומטית במצב המחמיר."
                         context:context]];
    }
}

#pragma mark - URL Evaluation

- (FBPKosherPolicyResult *)evaluateURL:(nullable NSURL *)rawURL {
    FBPKosherPolicyContext *ctx = [FBPKosherPolicyContext contextWithDestination:FBPKosherDestinationUnknown
                                                                    contentType:FBPKosherContentNavigation];
    ctx.rawURL = rawURL;

    if (!rawURL) {
        return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
            initWithDecision:FBPKosherDecisionUnknown
                  reasonCode:@"nil_url"
             localizedReason:@"כתובת ריקה נחסמה במצב המחמיר."
                     context:ctx]];
    }

    NSURL *url = [self normalizedURLFromURL:rawURL];
    if (!url) {
        return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
            initWithDecision:FBPKosherDecisionBlock
                  reasonCode:@"malformed_or_suspicious_url"
             localizedReason:@"קישור לא תקין או חשוד נחסם."
                     context:ctx]];
    }
    ctx.rawURL = url;

    NSString *scheme = url.scheme.lowercaseString ?: @"";
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path.lowercaseString ?: @"";
    NSArray<NSString *> *segments = FBPCleanPathSegments(url);
    NSString *first = segments.firstObject.lowercaseString ?: @"";

    if ([scheme isEqualToString:@"about"]) {
        ctx.destinationType = FBPKosherDestinationKosherHome;
        return [self evaluateContext:ctx];
    }

    if ([scheme isEqualToString:@"fb"]) {
        if ([host isEqualToString:@"login"] || [host isEqualToString:@"auth"] || [host isEqualToString:@"checkpoint"]) {
            ctx.destinationType = FBPKosherDestinationAuth;
        } else if ([host isEqualToString:@"reel"] || [host isEqualToString:@"reels"] || [host isEqualToString:@"shorts"]) {
            ctx.destinationType = FBPKosherDestinationReels;
        } else if ([host isEqualToString:@"story"] || [host isEqualToString:@"stories"] || [host isEqualToString:@"snacks"]) {
            ctx.destinationType = FBPKosherDestinationStories;
        } else if ([host isEqualToString:@"watch"] || [host isEqualToString:@"video"] || [host isEqualToString:@"videos"]) {
            ctx.destinationType = FBPKosherDestinationWatch;
        } else if ([host isEqualToString:@"live"]) {
            ctx.destinationType = FBPKosherDestinationLive;
        } else if ([host isEqualToString:@"photo"] || [host isEqualToString:@"photos"] || [host isEqualToString:@"albums"]) {
            ctx.destinationType = FBPKosherDestinationPhotoViewer;
        } else if ([host isEqualToString:@"marketplace"]) {
            ctx.destinationType = FBPKosherDestinationMarketplace;
        } else if ([host isEqualToString:@"search"]) {
            ctx.destinationType = FBPKosherDestinationSearch;
        } else if ([host isEqualToString:@"feed"] || [host isEqualToString:@"newsfeed"] || [host isEqualToString:@"home"] ||
                   [host isEqualToString:@"friends"] || [host isEqualToString:@"gaming"] || [host isEqualToString:@"dating"]) {
            ctx.destinationType = FBPKosherDestinationHomeFeed;
        } else if ([host isEqualToString:@"notifications"]) {
            ctx.destinationType = FBPKosherDestinationNotifications;
        } else if ([host isEqualToString:@"messaging"] || [host isEqualToString:@"messages"]) {
            ctx.destinationType = FBPKosherDestinationMessaging;
        } else if ([host isEqualToString:@"group"] || [host isEqualToString:@"groups"]) {
            ctx.destinationType = FBPKosherDestinationGroup;
            ctx.sourceKind = FBPKosherSourceKindGroup;
            ctx.sourceIdentifier = FBPQueryParam(url, @[@"id", @"group_id"]) ?: (first.length ? first : nil);
        } else if ([host isEqualToString:@"page"] || [host isEqualToString:@"pages"]) {
            ctx.destinationType = FBPKosherDestinationPage;
            ctx.sourceKind = FBPKosherSourceKindPage;
            ctx.sourceIdentifier = FBPQueryParam(url, @[@"id", @"page_id"]) ?: (first.length ? first : nil);
        } else if ([host isEqualToString:@"profile"]) {
            ctx.destinationType = FBPKosherDestinationProfile;
            ctx.sourceKind = FBPKosherSourceKindProfile;
            ctx.sourceIdentifier = FBPQueryParam(url, @[@"id"]) ?: (first.length ? first : nil);
        } else {
            ctx.destinationType = FBPKosherDestinationUnknown;
        }
        return [self evaluateContext:ctx];
    }

    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        ctx.destinationType = FBPKosherDestinationExternalLink;
        return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
            initWithDecision:FBPKosherDecisionBlock
                  reasonCode:@"disallowed_scheme"
             localizedReason:@"סכימת קישור זו אסורה במצב המחמיר."
                     context:ctx]];
    }

    if (!FBPIsFacebookFamilyHost(host)) {
        ctx.destinationType = FBPKosherDestinationExternalLink;
        return [self evaluateContext:ctx];
    }

    // Short video domains.
    if (FBPHostMatchesSuffix(host, @"fb.watch") || FBPHostMatchesSuffix(host, @"fbwat.ch")) {
        ctx.destinationType = FBPKosherDestinationWatch;
        return [self evaluateContext:ctx];
    }
    if (FBPHostMatchesSuffix(host, @"fb.gg")) {
        ctx.destinationType = FBPKosherDestinationLive;
        return [self evaluateContext:ctx];
    }

    // Direct CDN media URLs opened as destinations.
    if (FBPHostMatchesSuffix(host, @"fbcdn.net") ||
        [host hasPrefix:@"scontent"] ||
        [host hasPrefix:@"video"] ||
        FBPPathHasMediaExtension(path)) {
        ctx.destinationType = FBPKosherDestinationPhotoViewer;
        ctx.contentType = FBPKosherContentImage;
        return [self evaluateContext:ctx];
    }

    // Essential authentication & OAuth flows on Facebook.
    if ([first isEqualToString:@"login"] || [first isEqualToString:@"login.php"] ||
        [first isEqualToString:@"checkpoint"] || [first isEqualToString:@"two_factor"] ||
        [first isEqualToString:@"recover"] || [first isEqualToString:@"cookie"] ||
        [path hasPrefix:@"/dialog/oauth"] ||
        ([path hasPrefix:@"/v"] && [path containsString:@"/dialog/oauth"]) ||
        FBPHostMatchesSuffix(host, @"meta.com")) {
        ctx.destinationType = FBPKosherDestinationAuth;
        return [self evaluateContext:ctx];
    }

    // Entertainment / blocked Facebook web paths.
    if ([first isEqualToString:@"reel"] || [first isEqualToString:@"reels"] || [path containsString:@"/reel/"]) {
        ctx.destinationType = FBPKosherDestinationReels;
        return [self evaluateContext:ctx];
    }
    if ([first isEqualToString:@"stories"] || [first isEqualToString:@"story.php"]) {
        ctx.destinationType = FBPKosherDestinationStories;
        return [self evaluateContext:ctx];
    }
    if ([first isEqualToString:@"watch"] || [first isEqualToString:@"video"] ||
        [first isEqualToString:@"videos"] || [path containsString:@"/videos/"]) {
        ctx.destinationType = FBPKosherDestinationWatch;
        return [self evaluateContext:ctx];
    }
    if ([first isEqualToString:@"live"]) {
        ctx.destinationType = FBPKosherDestinationLive;
        return [self evaluateContext:ctx];
    }
    if ([first isEqualToString:@"photo"] || [first isEqualToString:@"photo.php"] ||
        [first isEqualToString:@"photos"] || [path containsString:@"/photos/"]) {
        ctx.destinationType = FBPKosherDestinationPhotoViewer;
        return [self evaluateContext:ctx];
    }
    if ([first isEqualToString:@"marketplace"]) {
        ctx.destinationType = FBPKosherDestinationMarketplace;
        return [self evaluateContext:ctx];
    }
    if ([first isEqualToString:@"search"]) {
        ctx.destinationType = FBPKosherDestinationSearch;
        return [self evaluateContext:ctx];
    }
    if (segments.count == 0 || [first isEqualToString:@"home.php"] || [first isEqualToString:@"feed"] ||
        [first isEqualToString:@"friends"] || [first isEqualToString:@"gaming"] || [first isEqualToString:@"dating"]) {
        ctx.destinationType = FBPKosherDestinationHomeFeed;
        return [self evaluateContext:ctx];
    }
    if ([first isEqualToString:@"notifications"]) {
        ctx.destinationType = FBPKosherDestinationNotifications;
        return [self evaluateContext:ctx];
    }
    if ([first isEqualToString:@"messages"]) {
        ctx.destinationType = FBPKosherDestinationMessaging;
        return [self evaluateContext:ctx];
    }

    // Group routes: /groups/<id>
    if ([first isEqualToString:@"groups"]) {
        ctx.destinationType = FBPKosherDestinationGroup;
        ctx.sourceKind = FBPKosherSourceKindGroup;
        ctx.sourceIdentifier = segments.count >= 2 ? segments[1] : nil;
        return [self evaluateContext:ctx];
    }

    // Explicit profile.php?id=...
    if ([first isEqualToString:@"profile.php"]) {
        ctx.destinationType = FBPKosherDestinationProfile;
        ctx.sourceKind = FBPKosherSourceKindProfile;
        ctx.sourceIdentifier = FBPQueryParam(url, @[@"id"]);
        return [self evaluateContext:ctx];
    }

    // Explicit /pages/<name>/<id> or /pg/<slug>
    if ([first isEqualToString:@"pages"] || [first isEqualToString:@"pg"]) {
        ctx.destinationType = FBPKosherDestinationPage;
        ctx.sourceKind = FBPKosherSourceKindPage;
        ctx.sourceIdentifier = segments.count >= 3 ? segments[2] : (segments.count >= 2 ? segments[1] : nil);
        return [self evaluateContext:ctx];
    }

    // Single-segment page or profile vanity slug (e.g. /MyApprovedPage)
    if (first.length > 0) {
        if ([self.store isPageApproved:first]) {
            ctx.destinationType = FBPKosherDestinationPage;
            ctx.sourceKind = FBPKosherSourceKindPage;
            ctx.sourceIdentifier = first;
            return [self evaluateContext:ctx];
        }
        if ([self.store isProfileApproved:first]) {
            ctx.destinationType = FBPKosherDestinationProfile;
            ctx.sourceKind = FBPKosherSourceKindProfile;
            ctx.sourceIdentifier = first;
            return [self evaluateContext:ctx];
        }
        ctx.destinationType = FBPKosherDestinationPage;
        ctx.sourceKind = FBPKosherSourceKindPage;
        ctx.sourceIdentifier = first;
        return [self evaluateContext:ctx];
    }

    ctx.destinationType = FBPKosherDestinationUnknown;
    return [self evaluateContext:ctx];
}

#pragma mark - Media URL Evaluation

- (FBPKosherPolicyResult *)evaluateMediaURL:(nullable NSURL *)url {
    FBPKosherPolicyContext *ctx = [FBPKosherPolicyContext contextWithDestination:FBPKosherDestinationUnknown
                                                                    contentType:FBPKosherContentNavigation];
    ctx.rawURL = url;
    ctx.strictModeActive = self.isStrictModeActive;
    ctx.compatibilityHealthy = self.compatibilityMonitor.criticalEnforcementHealthy;

    if (!ctx.strictModeActive) {
        return [[FBPKosherPolicyResult alloc] initWithDecision:FBPKosherDecisionAllow
                                                    reasonCode:@"strict_off"
                                               localizedReason:@""
                                                       context:ctx];
    }

    if (!url) {
        ctx.contentType = FBPKosherContentUnknown;
        return [[FBPKosherPolicyResult alloc] initWithDecision:FBPKosherDecisionUnknown
                                                    reasonCode:@"nil_media_url"
                                               localizedReason:@"כתובת מדיה לא תקינה"
                                                       context:ctx];
    }

    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        return [[FBPKosherPolicyResult alloc] initWithDecision:FBPKosherDecisionAllow
                                                    reasonCode:@"local_non_http"
                                               localizedReason:@""
                                                       context:ctx];
    }

    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path.lowercaseString ?: @"";

    // Never block critical GraphQL, REST API, MQTT, or Authentication traffic needed for login/app startup.
    if ([host isEqualToString:@"graph.facebook.com"] ||
        [host isEqualToString:@"b-graph.facebook.com"] ||
        [host isEqualToString:@"api.facebook.com"] ||
        [host isEqualToString:@"b-api.facebook.com"] ||
        [host isEqualToString:@"edge-mqtt.facebook.com"] ||
        [host isEqualToString:@"mqtt-mini.facebook.com"] ||
        [host isEqualToString:@"graph.meta.com"] ||
        [host isEqualToString:@"auth.meta.com"]) {
        if (!FBPPathHasMediaExtension(path)) {
            return [[FBPKosherPolicyResult alloc] initWithDecision:FBPKosherDecisionAllow
                                                        reasonCode:@"essential_api_endpoint"
                                                   localizedReason:@""
                                                           context:ctx];
        }
    }

    // Block image/video/GIF/sticker CDNs and media URLs immediately.
    BOOL isMediaCDN = [host hasPrefix:@"scontent"] ||
                      [host hasPrefix:@"video"] ||
                      [host hasPrefix:@"external"] ||
                      [host containsString:@"scontent."] ||
                      [host containsString:@".scontent"] ||
                      FBPHostMatchesSuffix(host, @"lookaside.fbsbx.com") ||
                      FBPHostMatchesSuffix(host, @"giphy.com") ||
                      FBPHostMatchesSuffix(host, @"tenor.com") ||
                      [path containsString:@"safe_image.php"];

    if (isMediaCDN || FBPPathHasMediaExtension(path)) {
        ctx.contentType = FBPKosherContentImage;
        return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
            initWithDecision:FBPKosherDecisionBlock
                  reasonCode:@"media_network_blocked"
             localizedReason:@"הורדת תמונות וסרטונים נחסמה במצב טקסט בלבד."
                     context:ctx]];
    }

    if (FBPHostMatchesSuffix(host, @"fbcdn.net")) {
        // Allow JS/CSS/font/JSON bundles on static CDN; block image/video payloads.
        NSString *ext = path.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"js"] || [ext isEqualToString:@"css"] ||
            [ext isEqualToString:@"json"] || [ext isEqualToString:@"woff"] ||
            [ext isEqualToString:@"woff2"] || [ext isEqualToString:@"ttf"] ||
            [ext isEqualToString:@"otf"] || [path containsString:@"rsrc.php"]) {
            if (!FBPPathHasMediaExtension(path)) {
                return [[FBPKosherPolicyResult alloc] initWithDecision:FBPKosherDecisionAllow
                                                            reasonCode:@"static_non_media_asset"
                                                       localizedReason:@""
                                                               context:ctx];
            }
        }
        ctx.contentType = FBPKosherContentImage;
        return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
            initWithDecision:FBPKosherDecisionBlock
                  reasonCode:@"fbcdn_media_blocked"
             localizedReason:@"נכס מדיה משרתי Facebook CDN נחסם."
                     context:ctx]];
    }

    return [[FBPKosherPolicyResult alloc] initWithDecision:FBPKosherDecisionAllow
                                                reasonCode:@"non_media_request"
                                           localizedReason:@""
                                                   context:ctx];
}

#pragma mark - ViewController Evaluation

- (FBPKosherPolicyResult *)evaluateViewControllerClassName:(NSString *)className
                                                     title:(NSString *)title
                                                       url:(NSURL *)url
                                                  sourceID:(NSString *)sourceID {
    FBPKosherPolicyContext *ctx = [FBPKosherPolicyContext contextWithDestination:FBPKosherDestinationUnknown
                                                                    contentType:FBPKosherContentNavigation];
    ctx.viewControllerClassName = className;
    ctx.surfaceDescription = title;
    ctx.rawURL = url;
    ctx.sourceIdentifier = sourceID;

    NSString *cls = className ?: @"";
    NSString *low = cls.lowercaseString;

    // Our own Kosher & safe Settings controllers are always permitted.
    if ([cls hasPrefix:@"FBPKosher"] ||
        [cls isEqualToString:@"FBPSettingsMenuController"] ||
        [cls isEqualToString:@"FBPSettingsDetailController"] ||
        [cls isEqualToString:@"FBPSettingsController"] ||
        [cls isEqualToString:@"FBPLanguageController"] ||
        [cls isEqualToString:@"FBPFontController"] ||
        [cls isEqualToString:@"FBPAppIconController"] ||
        [cls isEqualToString:@"FBPWelcomeController"]) {
        ctx.destinationType = FBPKosherDestinationKosherHome;
        return [self evaluateContext:ctx];
    }

    // System UIKit/Safari/Share controllers (except AVPlayerViewController).
    if ([cls isEqualToString:@"AVPlayerViewController"] || [low containsString:@"avplayer"]) {
        ctx.destinationType = FBPKosherDestinationVideoViewer;
        ctx.contentType = FBPKosherContentVideo;
        return [self evaluateContext:ctx];
    }
    if ([cls hasPrefix:@"UI"] || [cls hasPrefix:@"_UI"] || [cls hasPrefix:@"SFSafari"] ||
        [cls hasPrefix:@"UIDocument"] || [cls hasPrefix:@"CNContact"]) {
        ctx.destinationType = FBPKosherDestinationSettings;
        return [self evaluateContext:ctx];
    }

    // Essential authentication / login / 2FA / checkpoint screens.
    if ([low containsString:@"login"] || [low containsString:@"auth"] ||
        [low containsString:@"twofactor"] || [low containsString:@"checkpoint"] ||
        [low containsString:@"caa"] || [low containsString:@"registration"] ||
        [low containsString:@"password"] || [low containsString:@"accountswitcher"]) {
        ctx.destinationType = FBPKosherDestinationAuth;
        return [self evaluateContext:ctx];
    }

    // Blocked entertainment & media viewers.
    if ([low containsString:@"shorts"] || [low containsString:@"reels"] || [low containsString:@"fbclips"]) {
        ctx.destinationType = FBPKosherDestinationReels;
        return [self evaluateContext:ctx];
    }
    if ([low containsString:@"snacks"] || [low containsString:@"storyviewer"] || [low containsString:@"stories"]) {
        ctx.destinationType = FBPKosherDestinationStories;
        return [self evaluateContext:ctx];
    }
    if ([low containsString:@"videohome"] || [low containsString:@"fbwatch"] ||
        [low containsString:@"unifiedplayer"] || [low containsString:@"videoplayer"]) {
        ctx.destinationType = FBPKosherDestinationWatch;
        return [self evaluateContext:ctx];
    }
    if ([low containsString:@"facecast"] || [low containsString:@"livevideo"]) {
        ctx.destinationType = FBPKosherDestinationLive;
        return [self evaluateContext:ctx];
    }
    if ([low containsString:@"photoview"] || [low containsString:@"mediagallery"] ||
        [low containsString:@"lightbox"] || [low containsString:@"imageviewer"]) {
        ctx.destinationType = FBPKosherDestinationPhotoViewer;
        ctx.contentType = FBPKosherContentImage;
        return [self evaluateContext:ctx];
    }
    if ([low containsString:@"marketplace"]) {
        ctx.destinationType = FBPKosherDestinationMarketplace;
        return [self evaluateContext:ctx];
    }
    if ([low containsString:@"search"]) {
        ctx.destinationType = FBPKosherDestinationSearch;
        return [self evaluateContext:ctx];
    }
    if ([low containsString:@"newsfeed"] || [low containsString:@"homefeed"]) {
        ctx.destinationType = FBPKosherDestinationHomeFeed;
        return [self evaluateContext:ctx];
    }

    if (url) {
        return [self evaluateURL:url];
    }

    if ([low containsString:@"group"]) {
        ctx.destinationType = FBPKosherDestinationGroup;
        ctx.sourceKind = FBPKosherSourceKindGroup;
        return [self evaluateContext:ctx];
    }
    if ([low containsString:@"page"]) {
        ctx.destinationType = FBPKosherDestinationPage;
        ctx.sourceKind = FBPKosherSourceKindPage;
        return [self evaluateContext:ctx];
    }
    if ([low containsString:@"profile"] || [low containsString:@"timeline"]) {
        ctx.destinationType = FBPKosherDestinationProfile;
        ctx.sourceKind = FBPKosherSourceKindProfile;
        return [self evaluateContext:ctx];
    }

    // Unknown view controllers without verified context: fail-closed if they look like feed/content.
    if ([low containsString:@"comment"] || [low containsString:@"permalink"] ||
        [low containsString:@"composer"] || [low containsString:@"notification"] ||
        [low containsString:@"message"] || [low containsString:@"thread"]) {
        ctx.destinationType = FBPKosherDestinationNotifications;
        return [self evaluateContext:ctx];
    }

    ctx.destinationType = FBPKosherDestinationUnknown;
    return [self evaluateContext:ctx];
}

#pragma mark - Model Evaluation

- (FBPKosherPolicyResult *)evaluateModelWithClassName:(NSString *)className
                                             category:(NSString *)category
                                             sourceID:(NSString *)sourceID
                                           sourceKind:(FBPKosherSourceKind)sourceKind
                                  hasExplicitSourceID:(BOOL)hasExplicitSourceID
                                          isSponsored:(BOOL)isSponsored
                                              isMedia:(BOOL)isMedia
                               isSharedFromUnapproved:(BOOL)isSharedFromUnapproved
                                          textualBody:(NSString *)textualBody {
    FBPKosherPolicyContext *ctx = [FBPKosherPolicyContext contextWithDestination:FBPKosherDestinationUnknown
                                                                    contentType:FBPKosherContentText];
    ctx.modelClassName = className;
    ctx.sourceIdentifier = sourceID;
    ctx.sourceKind = sourceKind;
    ctx.hasExplicitSourceKind = hasExplicitSourceID;
    ctx.isSharedFromUnapprovedSource = isSharedFromUnapproved;

    if (isSponsored || [category isEqualToString:@"SPONSORED"]) {
        ctx.contentType = FBPKosherContentSponsored;
        return [self evaluateContext:ctx];
    }
    if (isMedia) {
        ctx.contentType = FBPKosherContentImage;
        return [self evaluateContext:ctx];
    }

    NSString *low = (className ?: @"").lowercaseString;
    if ([category isEqualToString:@"FB_SHORTS"] || [low containsString:@"shorts"] || [low containsString:@"reels"]) {
        ctx.destinationType = FBPKosherDestinationReels;
        return [self evaluateContext:ctx];
    }
    if ([category isEqualToString:@"MULTI_FB_STORIES_TRAY"] ||
        [category isEqualToString:@"PYMK_STORY"] ||
        [low containsString:@"singlebucketinlineviewer"] ||
        [low containsString:@"storybucket"]) {
        ctx.destinationType = FBPKosherDestinationStories;
        return [self evaluateContext:ctx];
    }
    if ([category isEqualToString:@"ENGAGEMENT"] ||
        [category isEqualToString:@"ENGAGEMENT_QP"] ||
        [category isEqualToString:@"PYMK"] ||
        [category isEqualToString:@"PYMK_FEED"] ||
        [low containsString:@"groupsyoushouldjoin"] ||
        [low containsString:@"pagesyoumaylike"]) {
        ctx.contentType = FBPKosherContentRecommendation;
        return [self evaluateContext:ctx];
    }
    if ([low containsString:@"positionalfeedsurvey"] || [low containsString:@"surveyfeedunit"]) {
        ctx.contentType = FBPKosherContentSurvey;
        return [self evaluateContext:ctx];
    }
    if ([low containsString:@"livevideo"] || [low containsString:@"facecast"]) {
        ctx.destinationType = FBPKosherDestinationLive;
        return [self evaluateContext:ctx];
    }

    if (isSharedFromUnapproved) {
        return [self evaluateContext:ctx];
    }

    if (hasExplicitSourceID) {
        if (sourceKind == FBPKosherSourceKindGroup) ctx.destinationType = FBPKosherDestinationGroup;
        else if (sourceKind == FBPKosherSourceKindPage) ctx.destinationType = FBPKosherDestinationPage;
        else if (sourceKind == FBPKosherSourceKindProfile) ctx.destinationType = FBPKosherDestinationProfile;
        else ctx.destinationType = FBPKosherDestinationUnknown;

        FBPKosherPolicyResult *sourceRes = [self evaluateContext:ctx];
        if (!sourceRes.effectiveAllowed) return sourceRes;

        // Optional local deterministic text moderation.
        if (textualBody.length && [FBPPrefs.shared boolForKey:FBPKeyKosherLocalTextModeration]) {
            FBPKosherModerationResult *modRes = nil;
            FBPKosherDecision modDecision =
                [FBPKosherModerationEngine.shared evaluateText:textualBody
                                                    strictMode:self.isStrictModeActive
                                                     resultOut:&modRes];
            if (modDecision != FBPKosherDecisionAllow) {
                return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                    initWithDecision:FBPKosherDecisionBlock
                          reasonCode:@"local_text_moderation_blocked"
                     localizedReason:@"הפוסט הוסתר לפי סינון מילות המפתח המקומי."
                             context:ctx]];
            }
        }
        return sourceRes;
    }

    // General feed story with no verified approved source -> blocked in strict mode.
    ctx.destinationType = FBPKosherDestinationHomeFeed;
    return [self evaluateContext:ctx];
}

#pragma mark - Notification Evaluation

- (FBPKosherPolicyResult *)evaluateNotificationWithTitle:(NSString *)title
                                                    body:(NSString *)body
                                                userInfo:(NSDictionary *)userInfo
                                           hasAttachment:(BOOL)hasAttachment {
    FBPKosherPolicyContext *ctx = [FBPKosherPolicyContext contextWithDestination:FBPKosherDestinationNotifications
                                                                    contentType:FBPKosherContentText];
    NSString *combined = [[NSString stringWithFormat:@"%@ %@", title ?: @"", body ?: @""] lowercaseString];

    // Check explicit blocked keywords/surface hints in notification text or metadata.
    NSString *rawType = @"";
    id nt = userInfo[@"nt"] ?: userInfo[@"notification_type"] ?: userInfo[@"t"];
    if ([nt isKindOfClass:NSString.class]) rawType = [(NSString *)nt lowercaseString];
    if ([userInfo[@"pim"] isKindOfClass:NSDictionary.class]) {
        id pimNT = userInfo[@"pim"][@"nt"];
        if ([pimNT isKindOfClass:NSString.class]) {
            rawType = [rawType stringByAppendingFormat:@" %@", [(NSString *)pimNT lowercaseString]];
        }
    }

    if ([rawType containsString:@"reel"] || [combined containsString:@"reel"] || [combined containsString:@"רילס"] ||
        [rawType containsString:@"story"] || [combined containsString:@"story"] || [combined containsString:@"סטורי"] ||
        [rawType containsString:@"video"] || [rawType containsString:@"watch"] || [rawType containsString:@"live"] ||
        [rawType containsString:@"pymk"] || [rawType containsString:@"friend_suggestion"] ||
        [rawType containsString:@"group_suggestion"] || [rawType containsString:@"gysj"] ||
        [combined containsString:@"people you may know"] || [combined containsString:@"suggested for you"] ||
        [combined containsString:@"אולי תכיר"] || [combined containsString:@"מומלץ עבורך"]) {
        ctx.contentType = FBPKosherContentRecommendation;
        return [self evaluateContext:ctx];
    }

    // Check destination URL inside notification payload if provided.
    NSString *urlString = nil;
    for (NSString *k in @[@"url", @"uri", @"href", @"target_url", @"d"]) {
        id v = userInfo[k];
        if ([v isKindOfClass:NSString.class] && [(NSString *)v length] > 0) {
            urlString = v;
            break;
        }
    }
    if (urlString) {
        NSURL *destURL = [NSURL URLWithString:urlString];
        FBPKosherPolicyResult *urlResult = [self evaluateURL:destURL];
        if (!urlResult.effectiveAllowed) {
            return urlResult;
        }
    }

    if (hasAttachment) {
        // Attachments must be stripped, never allowed through.
        ctx.contentType = FBPKosherContentImage;
        return [self evaluateContext:ctx];
    }

    // If strict safe notifications only is enabled and payload source cannot be confirmed,
    // signal Unknown so caller falls back to safe generic text.
    if ([FBPPrefs.shared boolForKey:FBPKeyKosherSafeNotificationsOnly]) {
        id groupID = userInfo[@"group_id"] ?: userInfo[@"groupId"];
        id pageID = userInfo[@"page_id"] ?: userInfo[@"pageId"];
        if ([groupID isKindOfClass:NSString.class] || [groupID isKindOfClass:NSNumber.class]) {
            NSString *gid = [NSString stringWithFormat:@"%@", groupID];
            ctx.destinationType = FBPKosherDestinationGroup;
            ctx.sourceIdentifier = gid;
            return [self evaluateContext:ctx];
        }
        if ([pageID isKindOfClass:NSString.class] || [pageID isKindOfClass:NSNumber.class]) {
            NSString *pid = [NSString stringWithFormat:@"%@", pageID];
            ctx.destinationType = FBPKosherDestinationPage;
            ctx.sourceIdentifier = pid;
            return [self evaluateContext:ctx];
        }
        if (!urlString) {
            return [self recordAndReturn:[[FBPKosherPolicyResult alloc]
                initWithDecision:FBPKosherDecisionUnknown
                      reasonCode:@"notification_unverified_preview"
                 localizedReason:@"תוכן ההתראה הוסתר במצב המחמיר (לא ניתן לאמת מקור מאושר)."
                         context:ctx]];
        }
    }

    return [self evaluateContext:ctx];
}

@end
