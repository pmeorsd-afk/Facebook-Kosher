// Strict text-only Marketplace guard and fail-closed blocker for Facebook Kosher.

#import "FBPlus.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Returns YES if a Marketplace GraphQL/Relay query must be failed completely
/// (either Marketplace is disabled/unverified or the query is an ad/recommendation/GYSJ query).
extern BOOL FBPKosherMarketplaceShouldBlockRequest(NSString *_Nullable friendlyName);

/// Recursively strips all media URLs, photos, videos, avatars, sponsored/ad nodes,
/// recommendations, and untrusted external URLs from a Marketplace GraphQL response.
extern NSData *FBPKosherMarketplaceSanitizeResponseData(NSData *data,
                                                        NSString *_Nullable friendlyName);

/// Exact Hebrew message shown whenever Marketplace is blocked under Strict Mode.
extern NSString *FBPKosherMarketplaceBlockedMessage(void);

#ifdef __cplusplus
}
#endif

@interface FBPKosherMarketplaceGuard : NSObject
+ (BOOL)isMarketplacePermitted;
+ (BOOL)shouldBlockQueryNamed:(nullable NSString *)friendlyName;
+ (nullable id)sanitizedJSONObject:(id)obj removedCount:(NSUInteger *_Nullable)removedCount;
+ (NSData *)sanitizeResponseData:(NSData *)data queryName:(nullable NSString *)friendlyName;
@end

NS_ASSUME_NONNULL_END
