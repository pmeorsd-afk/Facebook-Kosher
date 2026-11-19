# Facebook Kosher — Test Plan & Verification Procedures (`docs/KOSHER-TEST-PLAN.md`)

> **Verification Honesty:**  
> On Windows, Python static, localization, hygiene, and policy-contract checks execute directly (`test/test_kosher_verification.py`).  
> Objective-C compilation (`test/KosherTests/FBPKosherPolicyTests.m`, `scripts/verify.py check`), IPA symbol auditing (`scripts/audit.py`), and live iPhone device navigation / media-flash checks remain **`UNVERIFIED`** until executed on macOS/Linux with Theos/Xcode and a physical/simulator iOS device.

---

## 1. Automated Policy Cases (21 Required Scenarios)

Implemented in both [`test/KosherTests/FBPKosherPolicyTests.m`](../test/KosherTests/FBPKosherPolicyTests.m) (Objective-C against real `src/Kosher/*.m` + `src/Core/*.m`) and [`test/test_kosher_verification.py`](../test/test_kosher_verification.py):

| # | Test Case | ObjC Function (`FBPKosherPolicyTests.m`) | Expected Outcome |
|---|---|---|---|
| 1 | Unknown content source is blocked | `test_01_unknown_content_source_is_blocked` | `effectiveAllowed == NO` (`UNKNOWN` behaves as `BLOCK`) |
| 2 | Unapproved group is blocked | `test_02_unapproved_group_is_blocked` | Group URL without allowlist entry denied |
| 3 | Approved group text is allowed | `test_03_approved_group_text_is_allowed` | Approved group URL & textual story allowed |
| 4 | Approved group image is blocked | `test_04_approved_group_image_is_blocked` | `FBPKosherContentImage`, `scontent` image URL & `/photo` denied |
| 5 | Approved group video is blocked | `test_05_approved_group_video_is_blocked` | `FBPKosherContentVideo`, `video.*.fbcdn.net` & `/watch` denied |
| 6 | Shared post from unapproved source blocked | `test_06_shared_post_from_unapproved_source_is_blocked` | Post inside approved group sharing unapproved source denied |
| 7 | Unknown profile is blocked | `test_07_unknown_profile_is_blocked` | `profile.php?id=...` and unapproved slug denied |
| 8 | Direct Reel URL is blocked | `test_08_direct_reel_url_is_blocked` | `/reel/`, `/reels/`, `fb://reels/...` and `FBMemReelsFeedUnit` denied |
| 9 | Direct Story URL is blocked | `test_09_direct_story_url_is_blocked` | `/stories/...`, `fb://stories/...` denied |
| 10 | Video opened through notification blocked | `test_10_video_opened_through_notification_is_blocked` | Watch URL or `hasAttachment:YES` notification denied; approved text alert allowed |
| 11 | Unsafe redirect is blocked | `test_11_unsafe_redirect_is_blocked` | `l.facebook.com/l.php`, `facewebmodal`, `fbplusbridge`, `user@host`, `..` denied |
| 12 | Untrusted external URL is blocked | `test_12_untrusted_external_url_is_blocked` | External links blocked unless host AND optional path prefix approved |
| 13 | Unknown search result is blocked | `test_13_unknown_search_result_is_blocked` | `/search/...` denied; local search returns approved matches only |
| 14 | Marketplace blocked when unverified | `test_14_marketplace_remains_blocked_when_unverified` | Cannot enable Marketplace without verified capability; displays `"מרקטפלייס אינו זמין במצב הסינון המחמיר."`; JSON sanitizer strips photos/ads/GYSJ |
| 15 | Admin PIN required for policy changes | `test_15_administrator_pin_required_for_modifications` | Rejects bad PIN/unauth writes; progressive lockout after 3 failures; Crockford Base32 recovery preserves Strict Mode; credential-free JSON export |
| 16 | New installations default to strict mode | `test_16_new_installations_default_to_strict_mode` | `strictModeEnabled == YES`, `marketplaceAdminEnabled == NO`, empty allowlist |
| 17 | Migrated prefs cannot disable strict mode | `test_17_migrated_preferences_cannot_disable_strict_mode` | `FBPPrefs` migration forces Strict Mode ON & disables downloaders/Safari forwarding |
| 18 | Missing critical hook -> safe blocked state | `test_18_missing_critical_hook_produces_safe_blocked_state` | Shows `"לא ניתן להפעיל את הסינון בצורה בטוחה בגרסה זו של פייסבוק."` and blocks approved group URL |
| 19 | Unknown FB version cannot bypass | `test_19_unknown_facebook_version_cannot_bypass_filtering` | Unknown version stays in Strict Mode & blocks Reels/unapproved URLs |
| 20 | RTL and localization validation | `test_20_rtl_and_localization_validation` | Default `he`, `FBPIsRTLLanguage() == YES`, BiDi isolates `U+2066..U+2069`, 19-locale parity |
| 21 | Cached media & AI moderation/privacy | `test_21_cached_media_blocked_and_moderation_privacy` | Cached media URLs denied, Core GraphQL API allowed, ML stubs report `NOT IMPLEMENTED`, Strict Mode overrides Allow verdict, token/cookie scrubbing verified |

---

## 2. Live Device & Navigation Test Procedures (`UNVERIFIED` Until Run on iOS)

> **Status:** `UNVERIFIED` in Windows build host. Execute all 18 scenarios on an actual iPhone (jailbroken Rootless/Roothide or TrollFools/sideloaded IPA built with `build.py`) running target Facebook builds (`570.*`–`587.*`).

### Prerequisite Setup Before On-Device Testing
1. Build on macOS/Linux:
   - `python3 scripts/verify.py check` (must exit 0)
   - `make -C test/KosherTests test-sim` (must print `21 passed, 0 failed`)
   - `python3 scripts/audit.py` with lawful `test/com.facebook.Facebook.ipa`
   - `python3 build.py --trollfools --ipa test/com.facebook.Facebook.ipa` (or `--rootless`)
2. Install on a clean test iPhone (and test a second device upgrading over an existing `Facebook-Plus` installation to validate Scenario #17).

### 18 Navigation & Lifecycle Checkpoints + Media-Flash Audit

| Path / Scenario | Exact Manual Procedure | Pass Criteria |
|---|---|---|
| 1. Normal app launch | Fresh install & cold launch Facebook Kosher. | Shows Hebrew welcome / `פייסבוק כשר` RTL home screen; zero unrestricted feed visible even briefly. |
| 2. Login & session restoration | Log in with test Facebook account (including 2FA flow if active), force-quit, relaunch. | Login web/API flow succeeds (`FBPKosherDestinationAuth` + GraphQL allowed); after login returns to `פייסבוק כשר`, never unrestricted Home Feed. |
| 3. Home tab | Tap Home tab / swipe gestures. | `פייסבוק כשר` stays pinned; Reels/Video tabs do not appear and cannot be opened. |
| 4. Approved & unapproved Groups | Without PIN, configure Admin PIN; add one test group (`groupID`); open it. Also try an unapproved group. | Approved group text/comments display cleanly **with zero photos, avatars, stickers, GIFs, or video frames (check slow-motion screen recording for 0-frame media flash)**. Unapproved group opens Hebrew blocked screen. |
| 5. Approved & unapproved Pages | Add one public page ID; open it. Try an unapproved page. | Approved page text renders with media stripped; unapproved page is blocked. |
| 6. Search | Tap Search button/shortcut inside app. | Opens `חיפוש מאושר` (`FBPKosherSearchController`) searching local approved list only; native global search never flashes results. |
| 7. Notifications | Trigger approved group reply notification + unapproved Reel suggestion notification; inspect lock screen & `התראות`. | Media thumbnails stripped; prohibited pushes suppressed or rewritten to generic Hebrew text; check Lock Screen behavior per `docs/KOSHER-SECURITY.md`. |
| 8. Settings | Open `הגדרות` (`FBPSettingsController`). | Appears in RTL Hebrew; downloaders/MetaPlus/Safari-bypass hidden/disabled; no user toggle can turn off Strict Mode. |
| 9. Shared links (in-app & Safari) | Tap external link inside group post, `l.facebook.com/l.php?...`, sponsored post, and Safari page with extension enabled. | Unapproved external link / prohibited path (`/reel/`, `/stories/`, `/watch/`, `/marketplace/`) shows Hebrew blocked page; never bounces out to Safari. |
| 10. Universal links | Tap `https://www.facebook.com/reel/...` and `https://www.facebook.com/groups/<approved>` from Notes/Messages. | Reel opens Hebrew blocked screen; approved group opens directly in text-only view with floating "חזרה לפייסבוק כשר" pill. |
| 11. Back navigation | Navigate deep in approved group, use edge swipe & nav back button & floating pill. | Always navigates cleanly without revealing cached native Feed behind stack. |
| 12. Pull-to-refresh | Pull to refresh inside an approved group and `פייסבוק כשר`. | Text refreshes without images/videos/Reels popping into newly fetched cells. |
| 13. Pagination | Scroll through 30+ posts inside an approved high-traffic text group. | Subsequent paginated GraphQL batches still drop sponsored cards, Reels, and media thumbnails. |
| 14. Background & foreground transitions | Unlock Admin console, background app for > 5s (or > 5m), return. Also background inside approved group & return. | Admin session locks immediately on background; returning to app does not reveal cached feed frames in app switcher snapshot. |
| 15. Force quit & restart | Force quit from iOS App Switcher and relaunch. | Strict Mode persists, allowlist persists in Application Support, Keychain PIN persists, media caches purged at launch (`FBPKosherPurgeMediaCaches`). |
| 16. Rotation | Rotate iPhone/iPad (where host supports rotation). | Hebrew RTL Home, Blocked screen, Search, and Admin layouts adapt cleanly without clipped text. |
| 17. Offline operation | Enable Airplane Mode, cold launch app, open approved group cached earlier & try prohibited cached media. | App launches cleanly; cached images/videos were purged and cannot appear offline. |
| 18. Reconnection after network failure | Disable Airplane Mode and pull-to-refresh. | Approved group text reloads; Strict Mode & media hooks stay active without race-condition bypasses. |

### Zero-Flash Verification Protocol
Record 60fps iOS screen recording while:
- Cold launching
- Opening an approved group containing rich photos/videos
- Navigating via Universal Link to a Reel
- Pulling to refresh
Step through the recording frame-by-frame in QuickTime (`<-` / `->`) and confirm **0 frames** display photographs, video thumbnails, avatars, or Reels previews before `FBPKosherMediaGuard` / `FBPKosherBlockedViewController` takes over.
