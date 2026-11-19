// Application-wide text-only media blocking hooks.
// Prevents remote images, avatars, GIFs, stickers, videos, autoplay, and
// embedded web media from loading or rendering in Strict Mode while keeping
// local tweak icons, SF Symbols, UIKit chrome, and auth/GraphQL APIs functional.

#import "FBPKosherMediaGuard.h"
#import "FBPHeaders.h"
#import "FBPKosherPolicyEngine.h"
#import "FBPKosherCompatibilityMonitor.h"
#import "FBPKosherDiagnostics.h"
#import "FBPResources.h"

#import <AVFoundation/AVFoundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const void *kFBPWKScriptInstalledKey = &kFBPWKScriptInstalledKey;

#pragma mark - Helpers

static BOOL FBPViewIsInsideTweakOrSystemChrome(UIView *view) {
    UIView *cur = view;
    for (int depth = 0; cur && depth < 12; depth++, cur = cur.superview) {
        NSString *cls = NSStringFromClass([cur class]);
        if ([cls hasPrefix:@"FBP"] ||
            [cls hasPrefix:@"_UI"] ||
            [cls hasPrefix:@"UIKeyboard"] ||
            [cls isEqualToString:@"UINavigationBar"] ||
            [cls isEqualToString:@"UITabBar"] ||
            [cls isEqualToString:@"UISwitch"] ||
            [cls isEqualToString:@"UISearchBar"] ||
            [cls isEqualToString:@"UIAlertController"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL FBPImageViewIsPermittedChrome(UIImageView *iv, UIImage *image) {
    if (!image) return YES;
    if (@available(iOS 13.0, *)) {
        if (image.isSymbolImage) return YES;
    }
    if (image.renderingMode == UIImageRenderingModeAlwaysTemplate) return YES;
    if (FBPViewIsInsideTweakOrSystemChrome(iv)) return YES;

    // Small UI button/cell chrome icons (<= 28pt) rendered inside UIKit controls.
    if ([iv.superview isKindOfClass:UIControl.class]) {
        CGSize sz = image.size;
        if (sz.width > 0 && sz.height > 0 && sz.width <= 28.0 && sz.height <= 28.0) {
            return YES;
        }
    }
    return NO;
}

static NSURLRequest *FBPCancelledPlaceholderRequest(void) {
    return [NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]];
}

static NSError *FBPBlockedMediaError(void) {
    return [NSError errorWithDomain:NSURLErrorDomain
                               code:NSURLErrorCancelled
                           userInfo:@{NSLocalizedDescriptionKey: @"Blocked by Facebook Kosher strict text-only policy"}];
}

static BOOL FBPShouldInjectTextOnlyWebScript(NSURL *url) {
    if (!url) return YES;
    FBPKosherPolicyResult *res = [FBPKosherPolicyEngine.shared evaluateURL:url];
    // Never strip login / OAuth / 2FA DOM elements so authentication keeps working.
    if (res.context.destinationType == FBPKosherDestinationAuth) return NO;
    return YES;
}

static void FBPEnsureTextOnlyUserScriptOnWebView(WKWebView *webView) {
    if (!webView || [objc_getAssociatedObject(webView, kFBPWKScriptInstalledKey) boolValue]) return;
    objc_setAssociatedObject(webView, kFBPWKScriptInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *js =
        @"(function(){"
        @"var s=document.createElement('style');"
        @"s.id='fbp-kosher-text-only';"
        @"s.textContent='img,video,audio,picture,source,canvas,object,embed,iframe[src*=\"youtube\"],iframe[src*=\"vimeo\"],iframe[src*=\"video\"]{display:none!important;visibility:hidden!important;width:0!important;height:0!important;opacity:0!important;} *{background-image:none!important;}';"
        @"(document.head||document.documentElement).appendChild(s);"
        @"var strip=function(){document.querySelectorAll('img,video,audio,picture,source').forEach(function(e){e.removeAttribute('src');e.removeAttribute('srcset');e.remove();});};"
        @"if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',strip);}else{strip();}"
        @"})();";

    WKUserScript *script = [[WKUserScript alloc] initWithSource:js
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:NO];
    [webView.configuration.userContentController addUserScript:script];
}

#pragma mark - Critical Hook 1: UIImageView

%group FBPKosherMediaImageView

%hook UIImageView

- (void)setImage:(UIImage *)image {
    if (!FBPKosherStrictModeActive() || FBPImageViewIsPermittedChrome(self, image)) {
        %orig;
        return;
    }

    // Block remote/photographic/GIF/avatar images before rendering.
    %orig(nil);
    self.animationImages = nil;
    self.highlightedImage = nil;

    // Disable tap-to-zoom / preview interaction on blocked media containers outside buttons.
    if (![self.superview isKindOfClass:UIControl.class]) {
        self.userInteractionEnabled = NO;
    }

    // Show a safe local SF Symbol placeholder on larger content image boxes.
    CGSize boundsSize = self.bounds.size;
    if (boundsSize.width >= 56.0 && boundsSize.height >= 56.0) {
        if (@available(iOS 13.0, *)) {
            UIImage *placeholder = [UIImage fbp_symbolNamed:@"text.justify.right" size:22.0];
            if (placeholder) {
                self.tintColor = UIColor.tertiaryLabelColor;
                self.contentMode = UIViewContentModeCenter;
                %orig(placeholder);
            }
        }
    }
}

- (void)setHighlightedImage:(UIImage *)highlightedImage {
    if (!FBPKosherStrictModeActive() || FBPImageViewIsPermittedChrome(self, highlightedImage)) {
        %orig;
        return;
    }
    %orig(nil);
}

- (void)setAnimationImages:(NSArray<UIImage *> *)animationImages {
    if (FBPKosherStrictModeActive() && animationImages.count > 0 && !FBPViewIsInsideTweakOrSystemChrome(self)) {
        %orig(nil);
        return;
    }
    %orig;
}

%end

%end // FBPKosherMediaImageView

#pragma mark - Critical Hook 2: NSURLSession

%group FBPKosherMediaURLSession

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    if (FBPKosherStrictModeActive() && request.URL &&
        ![FBPKosherPolicyEngine.shared evaluateMediaURL:request.URL].effectiveAllowed) {
        NSURLSessionDataTask *dummy = %orig(FBPCancelledPlaceholderRequest());
        [dummy cancel];
        return dummy;
    }
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url {
    if (FBPKosherStrictModeActive() && url &&
        ![FBPKosherPolicyEngine.shared evaluateMediaURL:url].effectiveAllowed) {
        NSURLSessionDataTask *dummy = %orig([NSURL URLWithString:@"about:blank"]);
        [dummy cancel];
        return dummy;
    }
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    if (FBPKosherStrictModeActive() && request.URL &&
        ![FBPKosherPolicyEngine.shared evaluateMediaURL:request.URL].effectiveAllowed) {
        NSURLSessionDataTask *dummy = %orig(FBPCancelledPlaceholderRequest(),
                                            ^(__unused NSData *d, __unused NSURLResponse *r, __unused NSError *e) {});
        [dummy cancel];
        if (completionHandler) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                completionHandler(nil, nil, FBPBlockedMediaError());
            });
        }
        return dummy;
    }
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    if (FBPKosherStrictModeActive() && url &&
        ![FBPKosherPolicyEngine.shared evaluateMediaURL:url].effectiveAllowed) {
        NSURLSessionDataTask *dummy = %orig([NSURL URLWithString:@"about:blank"],
                                            ^(__unused NSData *d, __unused NSURLResponse *r, __unused NSError *e) {});
        [dummy cancel];
        if (completionHandler) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                completionHandler(nil, nil, FBPBlockedMediaError());
            });
        }
        return dummy;
    }
    return %orig;
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request {
    if (FBPKosherStrictModeActive() && request.URL &&
        ![FBPKosherPolicyEngine.shared evaluateMediaURL:request.URL].effectiveAllowed) {
        NSURLSessionDownloadTask *dummy = %orig(FBPCancelledPlaceholderRequest());
        [dummy cancel];
        return dummy;
    }
    return %orig;
}

- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url {
    if (FBPKosherStrictModeActive() && url &&
        ![FBPKosherPolicyEngine.shared evaluateMediaURL:url].effectiveAllowed) {
        NSURLSessionDownloadTask *dummy = %orig([NSURL URLWithString:@"about:blank"]);
        [dummy cancel];
        return dummy;
    }
    return %orig;
}

%end

%end // FBPKosherMediaURLSession

#pragma mark - Critical Hook 3: AVPlayer & AVPlayerLayer

%group FBPKosherMediaAVPlayer

%hook AVPlayer

- (void)play {
    if (FBPKosherStrictModeActive()) {
        [self pause];
        return;
    }
    %orig;
}

- (void)playImmediatelyAtRate:(float)rate {
    if (FBPKosherStrictModeActive()) {
        [self pause];
        return;
    }
    %orig;
}

- (void)setRate:(float)rate {
    if (FBPKosherStrictModeActive() && rate != 0.0f) {
        %orig(0.0f);
        return;
    }
    %orig;
}

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    if (FBPKosherStrictModeActive() && item != nil) {
        %orig(nil);
        return;
    }
    %orig;
}

%end

%hook AVPlayerLayer

- (void)setPlayer:(AVPlayer *)player {
    if (FBPKosherStrictModeActive() && player != nil) {
        %orig(nil);
        return;
    }
    %orig;
}

%end

%end // FBPKosherMediaAVPlayer

#pragma mark - Surface Hook 4: WKWebView

%group FBPKosherMediaWKWebView

%hook WKWebView

- (WKNavigation *)loadRequest:(NSURLRequest *)request {
    if (FBPKosherStrictModeActive() && request.URL) {
        NSURL *url = request.URL;
        NSString *scheme = url.scheme.lowercaseString ?: @"";
        if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
            FBPKosherPolicyResult *res = [FBPKosherPolicyEngine.shared evaluateURL:url];
            if (!res.effectiveAllowed) {
                [self stopLoading];
                NSString *html =
                    @"<html dir='rtl' lang='he'><body style='background:#000;color:#fff;font-family:-apple-system;padding:24px;text-align:center;'>"
                    @"<h2>תוכן חסום</h2><p>קישור זה אינו מאושר במצב הסינון המחמיר של פייסבוק כשר.</p>"
                    @"</body></html>";
                return [self loadHTMLString:html baseURL:nil];
            }
            if (FBPShouldInjectTextOnlyWebScript(url)) {
                FBPEnsureTextOnlyUserScriptOnWebView(self);
            }
        }
    }
    return %orig;
}

- (WKNavigation *)loadHTMLString:(NSString *)string baseURL:(NSURL *)baseURL {
    if (FBPKosherStrictModeActive() && baseURL && FBPShouldInjectTextOnlyWebScript(baseURL)) {
        FBPEnsureTextOnlyUserScriptOnWebView(self);
    }
    return %orig;
}

%end

%end // FBPKosherMediaWKWebView

#pragma mark - Dynamic Facebook / React Native Media Hooks

%group FBPKosherFBWebImageView
%hook FBWebImageView
- (void)setImageURL:(NSURL *)url {
    if (FBPKosherStrictModeActive() && url) {
        %orig(nil);
        return;
    }
    %orig;
}
%end
%end

%group FBPKosherRCTImageView
%hook RCTImageView
- (void)setImageSources:(NSArray *)sources {
    if (FBPKosherStrictModeActive() && sources.count > 0) {
        %orig(@[]);
        return;
    }
    %orig;
}
%end
%end

%group FBPKosherFNFAVPlayer
%hook FNFAVPlayer
- (void)play {
    if (FBPKosherStrictModeActive()) return;
    %orig;
}
- (void)setRate:(float)rate {
    if (FBPKosherStrictModeActive() && rate != 0.0f) {
        %orig(0.0f);
        return;
    }
    %orig;
}
%end
%end

%group FBPKosherVideoPlaybackController
%hook FBVideoPlaybackController
- (void)play {
    if (FBPKosherStrictModeActive()) return;
    %orig;
}
- (void)prepareToPlay {
    if (FBPKosherStrictModeActive()) return;
    %orig;
}
%end
%end

#pragma mark - Launch Media Cache Purge

void FBPKosherPurgeMediaCaches(void) {
    if (!FBPKosherStrictModeActive()) return;
    [NSURLCache.sharedURLCache removeAllCachedResponses];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *cacheDir = NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        if (!cacheDir.length) return;

        NSFileManager *fm = NSFileManager.defaultManager;
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:cacheDir error:nil];
        for (NSString *item in items) {
            NSString *low = item.lowercaseString;
            if ([low containsString:@"image"] ||
                [low containsString:@"photo"] ||
                [low containsString:@"video"] ||
                [low containsString:@"media"] ||
                [low containsString:@"cache"] ||
                [low containsString:@"snacks"] ||
                [low containsString:@"shorts"] ||
                [low containsString:@"fscacheddata"] ||
                [low containsString:@"pincache"] ||
                [low containsString:@"sdimage"]) {
                [fm removeItemAtPath:[cacheDir stringByAppendingPathComponent:item] error:nil];
            }
        }
    });
}

#pragma mark - Init

void FBPInitKosherMediaGuard(void) {
    FBPKosherCompatibilityMonitor *monitor = FBPKosherCompatibilityMonitor.shared;

    Class imageViewCls = objc_getClass("UIImageView");
    if (imageViewCls && [imageViewCls instancesRespondToSelector:@selector(setImage:)]) {
        FBP_ONCE(gKosherImgGuard) { %init(FBPKosherMediaImageView); }
        [monitor reportHook:@"MediaGuard.UIImageView"
                   severity:FBPKosherHookSeverityCritical
                     status:FBPKosherHookStatusInstalled
                     detail:@"UIImageView text-only filter active"];
    } else {
        [monitor reportHook:@"MediaGuard.UIImageView"
                   severity:FBPKosherHookSeverityCritical
                     status:FBPKosherHookStatusMissing
                     detail:@"UIImageView class/selector missing"];
    }

    Class sessionCls = objc_getClass("NSURLSession");
    if (sessionCls && [sessionCls instancesRespondToSelector:@selector(dataTaskWithRequest:completionHandler:)]) {
        FBP_ONCE(gKosherSessionGuard) { %init(FBPKosherMediaURLSession); }
        [monitor reportHook:@"MediaGuard.NSURLSession"
                   severity:FBPKosherHookSeverityCritical
                     status:FBPKosherHookStatusInstalled
                     detail:@"NSURLSession media CDN filter active"];
    } else {
        [monitor reportHook:@"MediaGuard.NSURLSession"
                   severity:FBPKosherHookSeverityCritical
                     status:FBPKosherHookStatusMissing
                     detail:@"NSURLSession selector missing"];
    }

    Class avPlayerCls = objc_getClass("AVPlayer");
    if (avPlayerCls && [avPlayerCls instancesRespondToSelector:@selector(play)]) {
        FBP_ONCE(gKosherAVGuard) { %init(FBPKosherMediaAVPlayer); }
        [monitor reportHook:@"MediaGuard.AVPlayer"
                   severity:FBPKosherHookSeverityCritical
                     status:FBPKosherHookStatusInstalled
                     detail:@"AVPlayer/AVPlayerLayer video block active"];
    } else {
        [monitor reportHook:@"MediaGuard.AVPlayer"
                   severity:FBPKosherHookSeverityCritical
                     status:FBPKosherHookStatusMissing
                     detail:@"AVPlayer missing"];
    }

    Class wkCls = objc_getClass("WKWebView");
    if (wkCls && [wkCls instancesRespondToSelector:@selector(loadRequest:)]) {
        FBP_ONCE(gKosherWKGuard) { %init(FBPKosherMediaWKWebView); }
        [monitor reportHook:@"MediaGuard.WKWebView"
                   severity:FBPKosherHookSeveritySurface
                     status:FBPKosherHookStatusInstalled
                     detail:@"WKWebView script & URL filter active"];
    }

    Class fbWebImg = objc_getClass("FBWebImageView");
    if (fbWebImg && [fbWebImg instancesRespondToSelector:@selector(setImageURL:)]) {
        FBP_ONCE(gKosherFBWebImg) { %init(FBPKosherFBWebImageView); }
        [monitor reportHook:@"MediaGuard.FBWebImageView"
                   severity:FBPKosherHookSeveritySurface
                     status:FBPKosherHookStatusInstalled
                     detail:@"FBWebImageView installed"];
    }

    Class rctImg = objc_getClass("RCTImageView");
    if (rctImg && [rctImg instancesRespondToSelector:@selector(setImageSources:)]) {
        FBP_ONCE(gKosherRCTImg) { %init(FBPKosherRCTImageView); }
        [monitor reportHook:@"MediaGuard.RCTImageView"
                   severity:FBPKosherHookSeveritySurface
                     status:FBPKosherHookStatusInstalled
                     detail:@"RCTImageView installed"];
    }

    Class fnfPlayer = objc_getClass("FNFAVPlayer");
    if (fnfPlayer && [fnfPlayer instancesRespondToSelector:@selector(play)]) {
        FBP_ONCE(gKosherFNFPlayer) { %init(FBPKosherFNFAVPlayer); }
        [monitor reportHook:@"MediaGuard.FNFAVPlayer"
                   severity:FBPKosherHookSeveritySurface
                     status:FBPKosherHookStatusInstalled
                     detail:@"FNFAVPlayer installed"];
    }

    Class fbVideoCtrl = objc_getClass("FBVideoPlaybackController");
    if (fbVideoCtrl && [fbVideoCtrl instancesRespondToSelector:@selector(play)]) {
        FBP_ONCE(gKosherFBVideoCtrl) { %init(FBPKosherVideoPlaybackController); }
        [monitor reportHook:@"MediaGuard.FBVideoPlaybackController"
                   severity:FBPKosherHookSeveritySurface
                     status:FBPKosherHookStatusInstalled
                     detail:@"FBVideoPlaybackController installed"];
    }
}
