# Facebook Kosher — Compatibility & Build Matrix (`docs/KOSHER-COMPATIBILITY.md`)

## 1. Host Facebook Version Matrix (`FBPKosherCompatibilityMonitor`)

Evaluated at startup in [`src/Kosher/FBPKosherCompatibilityMonitor.m`](../src/Kosher/FBPKosherCompatibilityMonitor.m):

| Facebook Version Prefix | Classification (`FBPKosherVersionSupport`) | Upstream Hook Basis | Facebook Kosher Strict Behavior | Runtime Device Status |
|---|---|---|---|---|
| `570.*` | `VerifiedHooks` (upstream hook signatures) | Verified in upstream `scripts/audit.py` / `TODO.md` baseline | Text-only & Navigation guards active; Marketplace remains blocked | **UNVERIFIED on device** (static hook alignment only) |
| `574.*` | `VerifiedHooks` | Verified in upstream `Facebook-Plus` | Same as above | **UNVERIFIED on device** |
| `578.*` | `VerifiedHooks` | Verified in upstream `Facebook-Plus` | Same as above | **UNVERIFIED on device** |
| `585.*` | `VerifiedHooks` | Verified in upstream `Facebook-Plus` | Same as above | **UNVERIFIED on device** |
| `586.*` | `VerifiedHooks` | Verified in upstream `TODO.md` | Same as above | **UNVERIFIED on device** |
| `587.*` | `Partial` | Upstream `TODO.md` notes C++ ComponentKit Reels surveys & Hermes Marketplace changes | Navigation/URL fail-closed guards enforced; Marketplace blocked | **UNVERIFIED on device** |
| Any unknown version | `Unknown` | Unaudited binary | Strict Mode remains active; unverified destinations fail closed; Marketplace blocked | Requires `scripts/audit.py` + device test |

> **Critical Invariant:** Compilation success does **not** constitute runtime compatibility. Unknown Facebook versions never silently bypass Strict Mode filtering.

---

## 2. Critical vs. Surface vs. Cosmetic Hooks

`FBPKosherCompatibilityMonitor` tracks 7 critical enforcement hooks (`+criticalHookIdentifiers`):
1. `MediaGuard.UIImageView`
2. `MediaGuard.NSURLSession`
3. `MediaGuard.AVPlayer`
4. `NavigationGuard.UIViewController`
5. `NavigationGuard.UINavigationController`
6. `LinkBridge.AppDelegate`
7. `FeedFilter.FBMemModelObject`

- **If any critical hook fails or fails to report `Installed` (or Policy Store fails initialization):**
  `criticalEnforcementHealthy` becomes `NO`. Instead of reverting to normal Facebook, `FBPKosherPolicyEngine` denies Facebook content surfaces and [`FBPKosherChromeHooks.xm`](../src/Features/AppChrome/FBPChromeHooks.xm) / [`FBPKosherHomeController.m`](../src/Kosher/FBPKosherHomeController.m) presents [`FBPKosherRestrictedViewController`](../src/Kosher/FBPKosherHomeController.m) with:
  > **"לא ניתן להפעיל את הסינון בצורה בטוחה בגרסה זו של פייסבוק."**
  The user can view diagnostics or open Admin Management, without exposing unfiltered feeds.
- **Surface Hooks** (e.g., `MediaGuard.FBWebImageView`, `MediaGuard.RCTImageView`, `MediaGuard.FNFAVPlayer`, `Marketplace.RCTNetworking`, `Notifications.UNUserNotificationCenter`):
  Reported with severity `Surface`; Marketplace access stays hard-locked whenever `Marketplace.RCTNetworking` and verified capability are not both satisfied.
- **Cosmetic Hooks** (UI polish / button hiding):
  Tracked with `Cosmetic` severity; never cause unfiltered content leakage if absent because underlying URL/controller/model gates still deny access.

---

## 3. Upstream Build 587+ Internal Architecture Notes

Per upstream [`TODO.md`](../TODO.md) and code audit:
- **Reels Surveys (`FB587`):** `FBPPositionalFeedSurveyModel` and ComponentKit C++ Reels survey components are stripped or denied via model class checks (`FBPKosherContentFilter.m`) and parent Reels navigation blocks (`FBPKosherNavigationGuard.xm`), avoiding fragile C++ `MSHookFunction` detours.
- **Marketplace (React Native / Hermes / Relay):** Marketplace renders predominantly inside React Native (`RCTNetworking` + Hermes bytecode). Until a real Facebook IPA is audited and live Relay schemas are tested on device, `marketplaceEnforcementVerified` remains `NO` by default.
- **Tab Bar & Home Replacement (`FBTabBarView` vs Safe Tab Trimming):** Removing entertainment tabs visually is paired with `UIViewController`/`UINavigationController`/`selectedIndex` interception so deep links, restored navigation states, and hidden buttons still hit `FBPKosherPolicyEngine`.

---

## 4. Build Toolchain Prerequisites

Current workspace environment (**Windows 11 + Python 3.14.6 + Git**) lacks Apple/Theos build tools (`theos`, `clang`, `make`, `plutil`, `perl` / `logos.pl`, `radare2`, `xcrun`, and iOS SDK) as well as a lawful `test/com.facebook.Facebook.ipa`.

To compile and package on **macOS (Apple Silicon / Intel) or Linux**:
1. Install [Theos](https://theos.dev/docs/installation) (`export THEOS=~/theos`) and an iOS 14.0+ SDK in `$THEOS/sdks/`.
2. Install Xcode Command Line Tools (`clang`, `xcrun`, `plutil`) on macOS (or Apple toolchain / `plutil` equivalent on Linux).
3. Ensure submodules are initialized (`git submodule update --init --recursive` for `src/Core/fishhook`).
4. Run:
   - `python3 scripts/verify.py check` (preprocesses Logos `.xm` files + compiles all 4 configurations: `tweak`, `tweak+diag`, `bridge`, `bridge+diag` with `-Wall -Werror`)
   - `make -C test/KosherTests test-sim` (compiles & runs 21 Objective-C policy unit tests)
   - `python3 scripts/audit.py` (when you supply your own decrypted lawful `test/com.facebook.Facebook.ipa`)
   - `python3 build.py --rootless` / `--rootfull` / `--roothide` / `--trollfools`
