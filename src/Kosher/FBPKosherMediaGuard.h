// Application-wide text-only media blocking guard for Facebook Kosher.

#import "FBPlus.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Installs UIImageView, NSURLSession, AVPlayer, WKWebView, and dynamic Facebook/RN
/// media-blocking hooks, reporting each hook's status to FBPKosherCompatibilityMonitor.
extern void FBPInitKosherMediaGuard(void);

/// Purges previously cached images/videos on launch so stale prohibited media
/// cannot flash or load offline in Strict Mode.
extern void FBPKosherPurgeMediaCaches(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
