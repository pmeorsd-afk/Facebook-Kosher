# Facebook Kosher — Security, Threat Model & Limitations (`docs/KOSHER-SECURITY.md`)

## 1. Threat Model & Honest Trust Boundary

> **Critical Disclosure:**  
> Application-level filtering inside a modified or injected iOS binary **is NOT tamper-proof** against a user who controls the device, jailbreak environment, sideloading tools, App binary, or installed tweaks.  
> Users or institutions requiring hardware/OS-enforced restrictions MUST combine app-level filtering with **Apple Supervised Mode (MDM)**, Apple Configurator restrictions, Screen Time passcodes controlled by an administrator, and network/DNS-level filtering.

Within its intended threat model (an iOS device operated by a user who respects the PIN/tweak configuration without removing the tweak or jailbreaking around it):
- **Strict Mode (`FBPKeyKosherStrictMode`)** defaults to `YES` and cannot be disabled through ordinary `FBPPrefs` writes or UI settings toggles.
- **Migration hardening (`FBPPrefs.m`):** Upgrading over an existing `Facebook-Plus` installation runs `enforceKosherMigrationIfNeeded`, forcing `Strict Mode = YES`, disabling Reels/Story downloaders, anonymous stories, MetaPlus trials, and Safari forwarding bypasses (`LinksInSafari = NO`), and defaulting language to Hebrew (`he`).
- **No Release Backdoors:** There is no hidden bypass gesture, secret diagnostics toggle, or debug skip mode compiled into release or tweak builds.

---

## 2. Administrator PIN & Keychain Security

Implemented in [`src/Kosher/FBPKosherPolicyStore.m`](../src/Kosher/FBPKosherPolicyStore.m):

- **Storage:** Credentials are stored via `FBPKosherKeychainCredentialBacking` (`SecItemAdd` / `SecItemCopyMatching` / `SecItemUpdate`) with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Plaintext PINs are **never** written to `NSUserDefaults`, files, or diagnostic logs.
- **Key Derivation:** PBKDF2-HMAC-SHA256 (`CCKeyDerivationPBKDF`, `kCCPRFHmacAlgSHA256`, **120,000 iterations**) with a unique cryptographically random **32-byte salt** (`SecRandomCopyBytes`) per secret.
- **Verification:** Constant-time comparison (`FBPConstantTimeEqualData`).
- **Rate Limiting:** Progressive persistent attempt counter in Keychain (`failedPINAttempts`):
  - After 3 failed attempts: 30s lockout
  - Escalating exponentially up to 15 minutes (`900s`) on continued failures.
- **Recovery Policy:** On initial PIN setup, a one-time 16-character Crockford Base32 recovery code (`XXXX-XXXX-XXXX-XXXX`) is generated, PBKDF2-hashed in Keychain, and shown once. Using recovery rotates the recovery code and **always preserves Strict Mode ON** (it never silently unlocks unrestricted mode).
- **Session Hygiene:** Admin authentication creates a random in-memory `FBPKosherAdminSession` token with a 5-minute TTL that automatically invalidates on `UIApplicationDidEnterBackgroundNotification` or manual "Lock Admin Now".
- **Policy Export/Import:** JSON export/import validates schema, version, and identifiers (`[0-9]{1,32}` for IDs, valid hostnames/prefixes for trusted domains, max 512 KB) and **never exports credentials, salts, or hashes**.

---

## 3. URL & Navigation Spoofing Defenses

Implemented in [`src/Kosher/FBPKosherPolicyEngine.m`](../src/Kosher/FBPKosherPolicyEngine.m) and [`FBPLinkBridge.xm`](../src/Features/Links/FBPLinkBridge.xm):

- **Bounded Recursive Unwrapping:** LinkShim (`facebook.com/l.php?u=...`, `/l/...`), FaceWeb (`fb://facewebmodal/f?href=...`), and `fb://fbplusbridge?url=...` are unwrapped up to depth 3 before policy evaluation. Exceeding depth 3 fails closed.
- **Userinfo & Traversal Rejection:** URLs containing `user:password@host` authority spoofing (e.g., `https://approved.example@evil.com`), literal or percent-encoded `..` traversal, control characters, or lengths > 4096 bytes are rejected.
- **Path-Scoped Domain Allowlisting:** Approving `facebook.com` groups (`123456`) never approves sibling paths (`/reel/`, `/stories/`, `/watch/`, `/marketplace/`). Trusted external domains require matching an exact normalized host (or subdomain) AND optional `allowedPathPrefix` (segment-boundary checked).
- **No Safari Fallback Leak:** `FBPLinkHooks.xm` no longer forwards denied links out to Safari when Strict Mode is active; it blocks in-app with the Hebrew blocked screen.

---

## 4. iOS Push Notification Limitations (`FBPNotifyBridge`)

In iOS, remote APNs notifications are rendered by the OS before the main Facebook app launches, and can only be transformed pre-delivery by a signed **Notification Service Extension (NSE)** bundled inside the app (`FBPNotifyBridge`):

1. **Signing & Entitlements Limitation:** If the host app or `FBPNotifyBridge` NSE is stripped during sideloading without preserving matching App Group entitlements or push extension signatures, the NSE may not execute on incoming remote pushes.
2. **Silent / Non-Mutable Push Limitation:** Push payloads without `mutable-content: 1` bypass `UNNotificationServiceExtension` completely and are displayed verbatim by iOS SpringBoard.
3. **Mitigations Implemented:**
   - [`FBPNotifyBridge/src/FBPNotifyBridge.mm`](../FBPNotifyBridge/src/FBPNotifyBridge.mm) installs `FBPKosherBridgeNotificationService` unconditionally (not only in debug), reads the sanitized allowlist mirror (`fbp_kosher_nse_policy.json`), strips image/video attachments, and rewrites prohibited or unverified push previews to generic Hebrew text (`"פייסבוק כשר"` / `"התקבלה התראה חדשה — פתח את פייסבוק כשר לבדיקת עדכונים מאושרים."`).
   - [`FBPKosherNotificationsController`](../src/Kosher/FBPKosherNotificationGuard.xm) documents these exact limits and instructs users/admins to set:  
     **הגדרות iOS ← עדכונים ← פייסבוק ← הצג תצוגה מקדימה: אף פעם (`Never`)**.
4. **Separate Messenger App:** Facebook Messenger (`com.facebook.Messenger`) is a separate iOS application binary and is **out of scope** unless independently modified and tested.

---

## 5. Privacy & Diagnostics

- [`FBPKosherDiagnostics.m`](../src/Kosher/FBPKosherDiagnostics.m) scrubs URL query strings, fragments, `access_token`, `c_user`, `xs`, `fr`, `cookie`, and bearer tokens before recording up to 250 local events in memory.
- [`FBPKosherModeration.m`](../src/Kosher/FBPKosherModeration.m) defaults `allowThirdPartyCloudUpload = NO`, performs keyword matching locally if enabled, explicitly marks ML classifiers `NOT IMPLEMENTED`, and guarantees Strict Mode **always** returns `FBPKosherDecisionBlock` for media regardless of any classifier verdict.

---

## 6. Known Residual Bypass & Failure Surfaces

1. **Hermes / React Native Direct Skia/Metal Canvas Rendering:** Native `UIImageView`, `AVPlayer`, `RCTImageView`, `FBWebImageView`, `FNFAVPlayer`, and `WKWebView` are guarded, but custom GPU/Metal/C++ surface textures rendered without `UIImageView`/`AVPlayerLayer` or network media URLs bypassing `NSURLSession` (e.g., custom C++ Tigon HTTP stacks) could potentially render media unless blocked at the parent screen (`FBPKosherNavigationGuard`) or tested live on each Facebook build.
2. **Relay/GraphQL Pando C++ Models (`FB587+`):** Some newer ComponentKit surfaces bypass `FBMemModelObject` `-init`. `FBPKosherNavigationGuard` mitigates this by blocking unapproved tabs/controllers and Marketplace by default, rather than trusting partial model hooks.
3. **Not Compiled/Run on Real iOS Binary Yet:** Zero-flash media blocking, Hermes Marketplace GraphQL payloads, and APNs NSE execution require live iOS verification (`UNVERIFIED` locally on Windows).
