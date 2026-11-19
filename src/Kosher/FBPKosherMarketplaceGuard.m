// Strict text-only Marketplace guard implementation.

#import "FBPKosherMarketplaceGuard.h"
#import "FBPKosherPolicyEngine.h"
#import "FBPKosherCompatibilityMonitor.h"
#import "FBPKosherPolicyStore.h"
#import "FBPKosherDiagnostics.h"

NSString *FBPKosherMarketplaceBlockedMessage(void) {
    return @"מרקטפלייס אינו זמין במצב הסינון המחמיר.";
}

BOOL FBPKosherMarketplaceShouldBlockRequest(NSString *friendlyName) {
    return [FBPKosherMarketplaceGuard shouldBlockQueryNamed:friendlyName];
}

NSData *FBPKosherMarketplaceSanitizeResponseData(NSData *data, NSString *friendlyName) {
    return [FBPKosherMarketplaceGuard sanitizeResponseData:data queryName:friendlyName];
}

@implementation FBPKosherMarketplaceGuard

+ (BOOL)isMarketplacePermitted {
    if (!FBPKosherStrictModeActive()) return YES;
    return FBPKosherPolicyStore.shared.marketplaceAdminEnabled &&
           FBPKosherCompatibilityMonitor.shared.marketplaceEnforcementVerified;
}

+ (BOOL)isProhibitedMarketplaceQueryName:(NSString *)name {
    if (name.length == 0) return NO;
    NSString *low = name.lowercaseString;
    if ([low containsString:@"ads"] ||
        [low containsString:@"sponsored"] ||
        [low containsString:@"boosted"] ||
        [low containsString:@"gysj"] ||
        [low containsString:@"suggested"] ||
        [low containsString:@"recommendation"] ||
        [low containsString:@"similar"] ||
        [low containsString:@"related"] ||
        [low containsString:@"video"] ||
        [low containsString:@"reels"] ||
        [low containsString:@"story"] ||
        [low containsString:@"stories"] ||
        [low containsString:@"pymk"]) {
        return YES;
    }
    return NO;
}

+ (BOOL)shouldBlockQueryNamed:(NSString *)friendlyName {
    if (!FBPKosherStrictModeActive()) return NO;
    if (friendlyName.length == 0) return NO;

    BOOL isMarketplaceQuery = [friendlyName hasPrefix:@"Marketplace"] ||
                              [friendlyName.lowercaseString containsString:@"marketplace"];
    if (!isMarketplaceQuery) return NO;

    // Fail-closed whenever Marketplace strict text-only capability is unverified or admin-disabled.
    if (![self isMarketplacePermitted]) {
        [FBPKosherDiagnostics.shared recordSecurityEvent:@"marketplace_query_blocked"
                                                  detail:friendlyName];
        return YES;
    }

    if ([self isProhibitedMarketplaceQueryName:friendlyName]) {
        [FBPKosherDiagnostics.shared recordSecurityEvent:@"marketplace_prohibited_surface_blocked"
                                                  detail:friendlyName];
        return YES;
    }

    return NO;
}

+ (NSSet<NSString *> *)mediaFieldKeys {
    static NSSet<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSSet setWithArray:@[
            @"image", @"images", @"photo", @"photos",
            @"primary_listing_photo", @"listing_photos",
            @"thumbnail", @"thumbnails", @"avatar", @"profile_picture",
            @"cover_photo", @"seller_photo", @"video", @"videos",
            @"media", @"story_attachment_media", @"large_image",
            @"small_image", @"preview_image", @"playable_url",
            @"dash_manifest", @"animated_image", @"sticker"
        ]];
    });
    return keys;
}

+ (BOOL)isBlockedNodeDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:NSDictionary.class]) return NO;

    id typenameVal = dict[@"__typename"];
    if ([typenameVal isKindOfClass:NSString.class]) {
        NSString *low = [(NSString *)typenameVal lowercaseString];
        if ([low containsString:@"adstory"] ||
            [low containsString:@"adsstory"] ||
            [low containsString:@"sponsored"] ||
            [low containsString:@"gysj"] ||
            [low containsString:@"suggested"] ||
            [low containsString:@"recommendation"] ||
            [low containsString:@"video"] ||
            [low containsString:@"reel"] ||
            [low containsString:@"story"] ||
            [low containsString:@"pymk"]) {
            return YES;
        }
    }

    for (NSString *marker in @[@"sponsored_data", @"sponsoredData", @"boosted_listing",
                               @"boostedListingAdsData", @"ad_id", @"ad_client_token"]) {
        id v = dict[marker];
        if (v && v != (id)NSNull.null) {
            if ([v isKindOfClass:NSString.class] && [(NSString *)v length] == 0) continue;
            return YES;
        }
    }
    for (NSString *boolKey in @[@"is_sponsored", @"isSponsored"]) {
        id v = dict[boolKey];
        if ([v isKindOfClass:NSNumber.class] && [v boolValue]) return YES;
    }
    return NO;
}

+ (BOOL)sanitizeInPlace:(id)obj removedCount:(NSUInteger *)removedCount {
    if ([obj isKindOfClass:NSMutableArray.class]) {
        NSMutableArray *arr = (NSMutableArray *)obj;
        for (NSInteger i = (NSInteger)arr.count - 1; i >= 0; i--) {
            id item = arr[i];
            if ([item isKindOfClass:NSDictionary.class] && [self isBlockedNodeDictionary:item]) {
                [arr removeObjectAtIndex:i];
                if (removedCount) (*removedCount)++;
                continue;
            }
            if ([item isKindOfClass:NSDictionary.class]) {
                id node = item[@"node"];
                if ([node isKindOfClass:NSDictionary.class] && [self isBlockedNodeDictionary:node]) {
                    [arr removeObjectAtIndex:i];
                    if (removedCount) (*removedCount)++;
                    continue;
                }
            }
            [self sanitizeInPlace:item removedCount:removedCount];
        }
        return YES;
    }

    if ([obj isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary *dict = (NSMutableDictionary *)obj;
        NSSet<NSString *> *mediaKeys = [self mediaFieldKeys];
        NSArray<NSString *> *allKeys = [dict.allKeys copy];
        for (NSString *k in allKeys) {
            if (![k isKindOfClass:NSString.class]) continue;
            NSString *low = k.lowercaseString;
            if ([mediaKeys containsObject:low] ||
                [low hasSuffix:@"_photo"] ||
                [low hasSuffix:@"_photos"] ||
                [low hasSuffix:@"_image"] ||
                [low hasSuffix:@"_images"] ||
                [low hasSuffix:@"_video"] ||
                [low hasSuffix:@"_videos"] ||
                [low hasSuffix:@"_thumbnail"]) {
                [dict removeObjectForKey:k];
                if (removedCount) (*removedCount)++;
                continue;
            }
            id val = dict[k];
            if ([val isKindOfClass:NSString.class] &&
                ([low isEqualToString:@"uri"] || [low isEqualToString:@"url"] || [low isEqualToString:@"external_url"])) {
                NSURL *u = [NSURL URLWithString:val];
                if (u && ![FBPKosherPolicyEngine.shared evaluateMediaURL:u].effectiveAllowed) {
                    [dict removeObjectForKey:k];
                    if (removedCount) (*removedCount)++;
                    continue;
                }
                if (u && [low isEqualToString:@"external_url"] &&
                    ![FBPKosherPolicyEngine.shared evaluateURL:u].effectiveAllowed) {
                    [dict removeObjectForKey:k];
                    if (removedCount) (*removedCount)++;
                    continue;
                }
            }
            [self sanitizeInPlace:val removedCount:removedCount];
        }
        return YES;
    }

    return NO;
}

+ (nullable id)sanitizedJSONObject:(id)obj removedCount:(NSUInteger *)removedCount {
    if (!obj) return nil;
    NSUInteger count = 0;
    id mutableCopy = nil;
    if ([obj isKindOfClass:NSMutableDictionary.class] || [obj isKindOfClass:NSMutableArray.class]) {
        mutableCopy = obj;
    } else if ([NSJSONSerialization isValidJSONObject:obj]) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
        if (d) {
            mutableCopy = [NSJSONSerialization JSONObjectWithData:d
                                                          options:NSJSONReadingMutableContainers
                                                            error:nil];
        }
    }
    if (!mutableCopy) return nil;
    [self sanitizeInPlace:mutableCopy removedCount:&count];
    if (removedCount) *removedCount = count;
    return mutableCopy;
}

+ (NSData *)sanitizeResponseData:(NSData *)data queryName:(NSString *)friendlyName {
    if (!FBPKosherStrictModeActive() || data.length == 0) return data;

    if (![self isMarketplacePermitted]) {
        // Fail-closed: strip entire payload if an unverified Marketplace response slipped through.
        return [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    }

    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return [@"{}" dataUsingEncoding:NSUTF8StringEncoding];

    NSString *sep = [body containsString:@"\r\n"] ? @"\r\n" : @"\n";
    NSArray<NSString *> *parts = [body componentsSeparatedByString:sep];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:parts.count];
    NSUInteger totalRemoved = 0;

    for (NSString *part in parts) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length == 0) {
            [out addObject:part];
            continue;
        }
        id json = [NSJSONSerialization
            JSONObjectWithData:[trimmed dataUsingEncoding:NSUTF8StringEncoding]
                       options:NSJSONReadingMutableContainers
                         error:nil];
        if (!json) {
            // Non-JSON Marketplace payloads cannot be safely verified in strict mode -> fail closed.
            [FBPKosherDiagnostics.shared recordSecurityEvent:@"marketplace_non_json_blocked"
                                                      detail:friendlyName];
            return [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
        }
        NSUInteger partRemoved = 0;
        [self sanitizeInPlace:json removedCount:&partRemoved];
        totalRemoved += partRemoved;
        NSData *re = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
        if (!re) return [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
        [out addObject:[[NSString alloc] initWithData:re encoding:NSUTF8StringEncoding]];
    }

    if (totalRemoved > 0) {
        [FBPKosherDiagnostics.shared recordSecurityEvent:@"marketplace_response_sanitized"
                                                  detail:[NSString stringWithFormat:@"%@:%lu",
                                                          friendlyName ?: @"query",
                                                          (unsigned long)totalRemoved]];
    }
    return [[out componentsJoinedByString:sep] dataUsingEncoding:NSUTF8StringEncoding] ?: data;
}

@end
