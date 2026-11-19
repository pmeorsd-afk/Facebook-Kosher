// Preference store implementation. Registers default values at launch and posts
// a change notification on commit.

#import "FBPPrefs.h"

static NSString *const kSuiteName = @"com.shajon.fbplus";
static NSString *const kKosherMigratedKey = @"kosherMigratedV1";

@implementation FBPPrefs {
    NSUserDefaults *_defaults;
}

+ (FBPPrefs *)shared {
    static FBPPrefs *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
        [_defaults registerDefaults:[self.class defaultValues]];
        [self enforceKosherMigrationIfNeeded];
    }
    return self;
}

/// Ensures upgraded/migrated Facebook-Plus preferences cannot silently turn off
/// strict mode or re-enable conflicting download/entertainment features.
- (void)enforceKosherMigrationIfNeeded {
    if (![_defaults boolForKey:kKosherMigratedKey]) {
        [_defaults setBool:YES forKey:FBPKeyKosherStrictMode];
        [_defaults setBool:NO forKey:FBPKeyKosherMarketplaceEnabled];
        [_defaults setBool:YES forKey:FBPKeyKosherSafeNotificationsOnly];
        [_defaults setBool:NO forKey:FBPKeyReelsDownloaderEnabled];
        [_defaults setBool:NO forKey:FBPKeyStoryDownloaderEnabled];
        [_defaults setBool:NO forKey:FBPKeyDownloadQualityPicker];
        [_defaults setBool:NO forKey:FBPKeyAnonymousStories];
        [_defaults setBool:NO forKey:FBPKeyMetaPlus];
        [_defaults setBool:NO forKey:FBPKeyLinksInSafari];
        if (![_defaults objectForKey:FBPKeyLanguage]) {
            [_defaults setObject:@"he" forKey:FBPKeyLanguage];
        }
        [_defaults setBool:YES forKey:kKosherMigratedKey];
        [_defaults synchronize];
    }
}

+ (NSDictionary<NSString *, id> *)defaultValues {
    // Facebook Kosher ships in Strict Mode with Hebrew UI by default.
    // Conflicting entertainment, download, incognito, and entitlement bypass
    // toggles default to NO and remain disabled while strict mode is active.
    return @{
        FBPKeyNoAds            : @YES,
        FBPKeyNoRecs           : @YES,
        FBPKeyNoPYMK           : @YES,
        FBPKeyNoReels          : @YES,
        FBPKeyNoStories        : @YES,
        FBPKeyNoStoryPYMK      : @YES,
        FBPKeyNoThreads        : @YES,
        FBPKeyNoGroupSuggestions : @YES,
        FBPKeyNoSuggestedPages : @YES,
        FBPKeyNoSurveys        : @YES,
        FBPKeyNoCommentProductBanner : @YES,
        FBPKeyNoReelsRecommended : @YES,
        FBPKeyConfirmComment   : @NO,
        FBPKeyConfirmFriend    : @NO,
        FBPKeyConfirmShare     : @NO,
        FBPKeyConfirmFollow    : @NO,
        FBPKeyConfirmPost      : @NO,
        FBPKeyReelsDownloaderEnabled : @NO,
        FBPKeyStoryDownloaderEnabled : @NO,
        FBPKeyDownloadQualityPicker : @NO,
        FBPKeyReelsHideOverlay : @YES,
        FBPKeyAnonymousStories : @NO,
        FBPKeyNoAutoNext       : @YES,
        FBPKeyFeedLike         : @YES,
        FBPKeyOLED             : @NO,
        FBPKeyOLEDDividers     : @YES,
        FBPKeyDisableHDR       : @NO,
        FBPKeyMetaPlus         : @NO,
        FBPKeyMetaPlusMode     : @"direct",
        FBPKeyLinksInSafari    : @NO,
        FBPKeyLogsKeep         : @YES,
        FBPKeyKeychainRebind   : @YES,
        FBPKeyNotifClientSync  : @YES,
        FBPKeyNotifyUpdates    : @YES,
        FBPKeyAutoClearCache   : @YES,
        FBPKeyLanguage         : @"he",
        FBPKeyIntroduced       : @NO,
        FBPKeyKosherStrictMode           : @YES,
        FBPKeyKosherMarketplaceEnabled   : @NO,
        FBPKeyKosherHighContrast         : @NO,
        FBPKeyKosherLargeText            : @NO,
        FBPKeyKosherReducedMotion        : @NO,
        FBPKeyKosherSafeNotificationsOnly : @YES,
        FBPKeyKosherLocalTextModeration  : @NO,
    };
}

- (BOOL)boolForKey:(NSString *)key {
    if ([key isEqualToString:FBPKeyKosherStrictMode]) {
        id stored = [_defaults objectForKey:key];
        return stored ? [stored boolValue] : YES;
    }
    return [_defaults boolForKey:key];
}

- (void)setBool:(BOOL)value forKey:(NSString *)key {
    // Protected policy keys cannot be relaxed through generic settings writes.
    if ([key isEqualToString:FBPKeyKosherStrictMode] ||
        [key isEqualToString:FBPKeyKosherMarketplaceEnabled]) {
        return;
    }
    [_defaults setBool:value forKey:key];
}

- (void)applyAdminStrictMode:(BOOL)strictMode {
    [_defaults setBool:strictMode forKey:FBPKeyKosherStrictMode];
    [_defaults setBool:YES forKey:kKosherMigratedKey];
    [self commit];
}

- (void)applyAdminMarketplaceEnabled:(BOOL)enabled {
    [_defaults setBool:enabled forKey:FBPKeyKosherMarketplaceEnabled];
    [self commit];
}

- (NSString *)stringForKey:(NSString *)key {
    id value = [_defaults objectForKey:key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

- (void)setString:(NSString *)value forKey:(NSString *)key {
    if (value) {
        [_defaults setObject:value forKey:key];
    } else {
        [_defaults removeObjectForKey:key];
    }
}

- (void)commit {
    [_defaults synchronize];
    [NSNotificationCenter.defaultCenter
        postNotificationName:FBPSettingsDidChangeNotification
                      object:nil];
}

- (void)resetToDefaults {
    BOOL introduced = [self boolForKey:FBPKeyIntroduced];
    BOOL strictMode = [self boolForKey:FBPKeyKosherStrictMode];
    BOOL marketplace = [self boolForKey:FBPKeyKosherMarketplaceEnabled];
    NSString *language = [self stringForKey:FBPKeyLanguage] ?: @"he";
    [_defaults removePersistentDomainForName:kSuiteName];
    [_defaults registerDefaults:[self.class defaultValues]];
    [_defaults setBool:introduced forKey:FBPKeyIntroduced];
    [_defaults setBool:strictMode forKey:FBPKeyKosherStrictMode];
    [_defaults setBool:marketplace forKey:FBPKeyKosherMarketplaceEnabled];
    [_defaults setObject:language forKey:FBPKeyLanguage];
    [_defaults setBool:YES forKey:kKosherMigratedKey];
    [self commit];
}

@end
