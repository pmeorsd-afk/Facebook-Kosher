# Facebook Kosher — Technical Architecture (`docs/KOSHER-ARCHITECTURE.md`)

## 1. Core Design Principles

1. **Centralized Fail-Closed Policy Engine (`ALLOW` / `BLOCK` / `UNKNOWN`):**
   Every content model, media request, view controller transition, search request, URL/deep link, Marketplace GraphQL operation, and notification flows through `FBPKosherPolicyEngine`. In Strict Mode, `UNKNOWN` **always** evaluates to `effectiveAllowed = NO`.
2. **Defense-in-Depth Boundaries:**
   Hiding a tab-bar item is never sufficient by itself. Enforcement spans:
   - **Startup & Compatibility Gate** (`FBPEntry.xm`, `FBPKosherCompatibilityMonitor`, `FBPChromeHooks.xm`)
   - **Content Model Boundary** (`FBPFeedHooks.xm` → `FBPKosherContentFilter`)
   - **Media Transport & Rendering Boundary** (`FBPKosherMediaGuard.xm`)
   - **Navigation & URL Routing Boundary** (`FBPLinkBridge.xm`, `FBPLinkHooks.xm`, `FBPKosherNavigationGuard.xm`, Safari Extension)
   - **Marketplace Relay/Networking Boundary** (`FBPAdsHooks.xm` → `FBPKosherMarketplaceGuard`)
   - **Push & In-App Notification Boundary** (`FBPNotifClientSync.xm`, `FBPKosherNotificationGuard.xm`, `FBPNotifyBridge.mm`)
3. **Upstream Compatibility & Stability:**
   No `MSHookFunction` C++ symbol detours are used in `src/Kosher/` (preventing known crashes across sideloaded builds noted in upstream `TODO.md`). All hooks use Objective-C Logos hooks or guarded dynamic runtime swizzles that report installation status to `FBPKosherCompatibilityMonitor`.

---

## 2. Module Map (`src/Kosher/`)

| Module | Responsibilities |
|---|---|
| `FBPKosherTypes.{h,m}` | Strongly typed enums (`FBPKosherDecision`, `FBPKosherDestinationType`, `FBPKosherContentType`, `FBPKosherSourceKind`, `FBPKosherHookSeverity`, `FBPKosherHookStatus`), validated `FBPKosherApprovedSource`, `FBPKosherPolicyContext`, and immutable `FBPKosherPolicyResult`. |
| `FBPKosherPolicyStore.{h,m}` | Persistent allowlist JSON storage under Application Support, mirror export (`fbp_kosher_nse_policy.json`) to shared/App Group location for `FBPNotifyBridge`, Keychain-backed PBKDF2-HMAC-SHA256 admin PIN verification (`FBPKosherCredentialBacking` / `FBPKosherKeychainCredentialBacking`), progressive lockout, Crockford Base32 recovery code flow, ephemeral `FBPKosherAdminSession` (5-min TTL, auto-invalidated on app background), and validated credential-free policy JSON import/export. |
| `FBPKosherPolicyEngine.{h,m}` | Central evaluator (`evaluateContext:`, `evaluateURL:`, `evaluateMediaURL:`, `evaluateViewControllerClassName:title:url:sourceID:`, `evaluateModelWithClassName:...`, `evaluateNotificationWithTitle:...`). Normalizes LinkShim (`/l.php`, `/l/`), FaceWeb (`fb://facewebmodal`), and bridge URLs (`fb://fbplusbridge`), rejects `user@host` spoofing and `..` path traversal, verifies approved IDs vs trusted domain prefixes, and enforces compatibility-monitor health gates. |
| `FBPKosherCompatibilityMonitor.{h,m}` | Tracks host app version/build (`FBAppVersion`, `CFBundleShortVersionString`, `CFBundleVersion`) against known verified version prefixes (`570.*`–`586.*`), `587.*` partial, or `Unknown`. Monitors all 7 critical hook identifiers plus surface hooks and exposes `criticalEnforcementHealthy`, `marketplaceEnforcementVerified`, and `restrictedStateMessage`. |
| `FBPKosherDiagnostics.{h,m}` | Privacy-scrubbing bounded ring buffer logging policy denials and security events while stripping query parameters, `access_token`, `c_user`, `xs`, `cookie`, and secrets. |
| `FBPKosherContentFilter.{h,m}` | Inspects `FBMemModelObject` / Pando feed units (`FBMemFeedStory`, feed units, surveys, Reels, Stories, PYMK, GYSJ, sponsored units) while preserving core auth/session/pagination objects. Enforces that approving a group does not permit embedded shared posts (`attachedStory`) from unapproved sources. |
| `FBPKosherMediaGuard.{h,xm}` | Text-only enforcement across `UIImageView`, `NSURLSession`, `AVPlayer`/`AVPlayerLayer`, `WKWebView` (CSS + MutationObserver JS injection), and dynamic host classes (`FBWebImageView`, `RCTImageView`, `FNFAVPlayer`, `FBVideoPlaybackController`), plus startup `FBPKosherPurgeMediaCaches()` clearing `NSURLCache`, temporary media, and image cache directories. Preserves API/GraphQL/auth traffic and tweak UI assets (`FBP*`, `kosher*` SF symbols). |
| `FBPKosherNavigationGuard.{h,xm}` | Enforces destination policy on `UIViewController` presentations, `UINavigationController` pushes, and `UITabBarController` tab trimming; installs floating Hebrew "חזרה לפייסבוק כשר" pill (`FBPKosherReturnPillWindow`) on permitted detail views; presents `FBPKosherBlockedViewController` or `FBPKosherRestrictedViewController` on denial/failure. |
| `FBPKosherSearchGuard.{h,m}` | Replaces global Facebook search in Strict Mode with `FBPKosherSearchController`, searching solely the local `FBPKosherPolicyStore` allowlist. |
| `FBPKosherMarketplaceGuard.{h,m}` | Keeps Marketplace denied by default with `"מרקטפלייס אינו זמין במצב הסינון המחמיר."` and provides defensive GraphQL/Relay query blocking (recommendations/GYSJ/ads) plus recursive JSON stripping of photos, videos, avatars, sponsored nodes, and untrusted URLs for future verified builds. |
| `FBPKosherNotificationGuard.{h,xm}` | Filters `UNUserNotificationCenter` notification content, strips media attachments, replaces unverified previews with generic Hebrew copy, exposes `FBPKosherShouldAllowPushEvaluate` for `FBPNotifClientSync.xm`, and provides `FBPKosherNotificationsController` (audit view + OS Lock Screen setup guidance). |
| `FBPKosherHomeController.{h,m}` | Clean RTL Hebrew root navigation hub (`פייסבוק כשר`) with segmented access to Groups, Pages, and Favorites, zero avatars/remote thumbnails, empty-state setup prompt, plus `FBPKosherBlockedViewController` and `FBPKosherRestrictedViewController`. |
| `FBPKosherAdminController.{h,m}` | PIN-gated RTL Hebrew administration console covering filtering mode, groups, pages, optional profiles, trusted external links, Marketplace capability gate, notifications, accessibility + local keyword moderation, diagnostics/compatibility, and PIN/recovery/JSON backup controls. |
| `FBPKosherModeration.{h,m}` | Optional privacy-first moderation interfaces (`FBPKosherTextModerator`, `FBPKosherImageModerator`), deterministic local keyword filter (`FBPKosherLocalKeywordTextModerator`), honest `NOT IMPLEMENTED` ML stubs (`FBPKosherStubMLTextModerator`, `FBPKosherStubMLImageModerator`), and invariant guaranteeing AI moderation never overrides Strict Mode media blocking. |

---

## 3. Startup & Integration Flow

1. **`src/Core/FBPEntry.xm` (`%ctor`)** initializes in order:
   - `FBPPrefs.shared` (registers Hebrew & Strict Mode defaults + `enforceKosherMigrationIfNeeded`)
   - `FBPKosherPolicyStore.shared` → marks `policyStoreInitialized` on `FBPKosherCompatibilityMonitor.shared`
   - `FBPKosherPurgeMediaCaches()` + `[NSURLCache.sharedURLCache removeAllCachedResponses]` (in Strict Mode)
   - Installs upstream feed/ad/link/chrome/notif hooks + `FBPInitKosherMediaGuard()`, `FBPInitKosherNavigationGuard()`, `FBPInitKosherNotificationGuard()`
   - Conflicting downloaders (`FBPInitReelsDownloader()`) are gated off while Strict Mode is active.
2. **`src/Features/AppChrome/FBPChromeHooks.xm`** on `applicationDidBecomeActive:` runs `evaluateStartupHealth`, trims forbidden tabs, and either presents `FBPKosherRestrictedViewController` (if critical hooks failed) or presents `FBPKosherHomeController` (unless login/auth/admin UI is active).
3. **Links & Safari Extension (`FBPLinkBridge.xm`, `FBPLinkHooks.xm`, `OpenInFacebookSafariExtension/`)**:
   Prohibited paths in Safari route through `fb://fbplusbridge?url=...`, `FBPLinkBridge` checks every incoming scheme/Universal Link/Shortcut against `FBPKosherPolicyEngine`, and `FBWebViewController` blocks unapproved URLs instead of forwarding them to Safari.
