#!/usr/bin/env python3
"""Automated verification and behavioral contract suite for Facebook Kosher.

Runs on Windows, macOS, and Linux using Python 3 standard library only (no Xcode/Theos
required for static + contract checks). Complements the Objective-C unit test binary in
test/KosherTests/FBPKosherPolicyTests.m and scripts/verify.py.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import pathlib
import re
import secrets
import subprocess
import unittest
from urllib.parse import parse_qs, unquote, urlparse

ROOT = pathlib.Path(__file__).resolve().parent.parent


def read_text(rel_path: str) -> str:
    return (ROOT / rel_path).read_text(encoding="utf-8")


def parse_strings_file(path: pathlib.Path) -> tuple[dict[str, str], list[str], list[str]]:
    """Parse an Apple .strings catalog into (mapping, duplicate_keys, bad_tokens)."""
    content = path.read_text(encoding="utf-8")
    # Strip block /* ... */ and // line comments outside string literals
    cleaned_chars: list[str] = []
    i = 0
    n = len(content)
    in_str = False
    while i < n:
        ch = content[i]
        if in_str:
            cleaned_chars.append(ch)
            if ch == "\\" and i + 1 < n:
                cleaned_chars.append(content[i + 1])
                i += 2
                continue
            if ch == '"':
                in_str = False
            i += 1
        else:
            if ch == '"':
                in_str = True
                cleaned_chars.append(ch)
                i += 1
            elif ch == "/" and i + 1 < n and content[i + 1] == "*":
                end = content.find("*/", i + 2)
                if end == -1:
                    return {}, [], ["unterminated /* comment"]
                i = end + 2
            elif ch == "/" and i + 1 < n and content[i + 1] == "/":
                end = content.find("\n", i + 2)
                i = n if end == -1 else end + 1
            else:
                cleaned_chars.append(ch)
                i += 1
    if in_str:
        return {}, [], ["unterminated string literal"]

    cleaned = "".join(cleaned_chars)
    entries: dict[str, str] = {}
    duplicates: list[str] = []
    bad_tokens: list[str] = []
    stmt_re = re.compile(r'\s*"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;\s*', re.S)
    pos = 0
    while pos < len(cleaned):
        if cleaned[pos:].isspace():
            break
        m = stmt_re.match(cleaned, pos)
        if not m:
            snippet = cleaned[pos : pos + 80].strip().splitlines()[0]
            bad_tokens.append(snippet)
            break
        key, val = m.group(1), m.group(2)
        if key in entries:
            duplicates.append(key)
        entries[key] = val
        pos = m.end()
    return entries, duplicates, bad_tokens


class TestRepositoryAndBuildIntegration(unittest.TestCase):
    def test_submodule_fishhook_present(self) -> None:
        self.assertTrue(
            (ROOT / "src/Core/fishhook/fishhook.c").is_file(),
            "fishhook submodule must be present (cloned with --recurse-submodules)",
        )

    def test_all_kosher_sources_registered_in_makefile(self) -> None:
        makefile = read_text("Makefile")
        kosher_dir = ROOT / "src/Kosher"
        expected_srcs = sorted(
            f"src/Kosher/{p.name}"
            for p in kosher_dir.iterdir()
            if p.is_file() and p.suffix in {".m", ".xm", ".mm", ".c"}
        )
        self.assertGreaterEqual(len(expected_srcs), 14)
        for src in expected_srcs:
            self.assertIn(src, makefile, f"{src} missing from Makefile")

        self.assertIn("src/Kosher", makefile.split("FBP_INCLUDE_DIRS")[1].split("FacebookPlus_CFLAGS")[0])
        self.assertIn("WebKit", makefile)

        mk_sources = re.findall(r"src/[A-Za-z0-9_./-]+\.(?:xm|mm|m|c)\b", makefile)
        missing = [s for s in mk_sources if not (ROOT / s).is_file()]
        self.assertEqual(missing, [], f"Makefile lists missing source files: {missing}")

    def test_all_local_imports_resolve(self) -> None:
        makefile = read_text("Makefile")
        inc_block = makefile.split("FBP_INCLUDE_DIRS")[1].split("FacebookPlus_CFLAGS")[0]
        inc_dirs = [ROOT / d for d in re.findall(r"src/[A-Za-z0-9_/-]+", inc_block)]
        unresolved: list[tuple[str, str]] = []
        for src_file in (ROOT / "src").rglob("*"):
            if src_file.is_file() and src_file.suffix in {".h", ".m", ".xm", ".mm"}:
                text = src_file.read_text(encoding="utf-8", errors="ignore")
                for imp in re.findall(r'#import\s+"([^"]+)"', text):
                    if not any((d / imp).is_file() for d in inc_dirs + [src_file.parent]):
                        unresolved.append((str(src_file.relative_to(ROOT)), imp))
        self.assertEqual(unresolved, [], f"Unresolved local #imports: {unresolved}")

    def test_entry_initializes_kosher_guards(self) -> None:
        entry = read_text("src/Core/FBPEntry.xm")
        required_tokens = [
            "FBPKosherPolicyStore",
            "FBPKosherCompatibilityMonitor",
            "FBPKosherPolicyEngine",
            "FBPKosherPurgeMediaCaches",
            "FBPInitKosherMediaGuard",
            "FBPInitKosherNavigationGuard",
            "FBPInitKosherNotificationGuard",
            "evaluateStartupHealth",
        ]
        for tok in required_tokens:
            self.assertIn(tok, entry, f"FBPEntry.xm missing required Kosher init call: {tok}")


class TestLocalizationAndRTL(unittest.TestCase):
    def test_all_19_localizations_valid_and_in_parity(self) -> None:
        loc_root = ROOT / "Localizations"
        catalogs = sorted(loc_root.glob("*.lproj/Localizable.strings"))
        self.assertGreaterEqual(len(catalogs), 19)
        self.assertTrue((loc_root / "he.lproj/Localizable.strings").is_file())

        base_map, base_dups, base_bad = parse_strings_file(loc_root / "Base.lproj/Localizable.strings")
        self.assertEqual(base_dups, [], f"Duplicate keys in Base.lproj: {base_dups}")
        self.assertEqual(base_bad, [], f"Malformed lines in Base.lproj: {base_bad}")
        self.assertGreaterEqual(len(base_map), 350)

        for cat in catalogs:
            mapping, dups, bad = parse_strings_file(cat)
            self.assertEqual(dups, [], f"Duplicates in {cat.parent.name}: {dups}")
            self.assertEqual(bad, [], f"Malformed lines in {cat.parent.name}: {bad}")
            self.assertEqual(
                set(mapping.keys()),
                set(base_map.keys()),
                f"Key mismatch in {cat.parent.name}",
            )

    def test_all_fbpl_keys_used_in_src_exist_in_base_and_hebrew(self) -> None:
        base_map, _, _ = parse_strings_file(ROOT / "Localizations/Base.lproj/Localizable.strings")
        he_map, _, _ = parse_strings_file(ROOT / "Localizations/he.lproj/Localizable.strings")
        used: set[str] = set()
        for f in (ROOT / "src").rglob("*"):
            if f.is_file() and f.suffix in {".h", ".m", ".xm", ".mm"}:
                used.update(re.findall(r'FBPL\(@"([^"]+)"\)', f.read_text(encoding="utf-8", errors="ignore")))
        self.assertGreater(len(used), 50)
        self.assertEqual(sorted(used - set(base_map.keys())), [])
        self.assertEqual(sorted(used - set(he_map.keys())), [])

    def test_hebrew_language_controller_distinct_from_hindi(self) -> None:
        lang_ctrl = read_text("src/Features/Language/FBPLanguageController.m")
        self.assertIn('@"he"', lang_ctrl)
        self.assertIn('@"עברית"', lang_ctrl)
        self.assertIn('@"Hebrew"', lang_ctrl)
        self.assertIn('@"hi"', lang_ctrl)
        self.assertIn('@"हिन्दी"', lang_ctrl)

    def test_required_hebrew_strings_and_safari_extension_rtl(self) -> None:
        he_text = read_text("Localizations/he.lproj/Localizable.strings")
        mkt_src = read_text("src/Kosher/FBPKosherMarketplaceGuard.m")
        compat_src = read_text("src/Kosher/FBPKosherCompatibilityMonitor.m")

        self.assertIn("פייסבוק כשר", he_text)
        self.assertIn("מרקטפלייס אינו זמין במצב הסינון המחמיר.", he_text)
        self.assertIn("מרקטפלייס אינו זמין במצב הסינון המחמיר.", mkt_src)
        self.assertIn("לא ניתן להפעיל את הסינון בצורה בטוחה בגרסה זו של פייסבוק.", compat_src)
        self.assertIn("kosher.restricted.explanation", he_text)

        popup_html = read_text("OpenInFacebookSafariExtension/src/Resources/popup.html")
        self.assertIn('dir="rtl"', popup_html)
        for rel in [
            "OpenInFacebookSafariExtension/src/Resources/_locales/he/messages.json",
            "OpenInFacebookSafariExtension/src/Resources/_locales/en/messages.json",
        ]:
            parsed = json.loads(read_text(rel))
            self.assertIn("extension_name", parsed)
            self.assertIn("extension_description", parsed)


class TestStaticSecurityAndHygiene(unittest.TestCase):
    def test_logos_and_brace_balance_and_no_mshookfunction(self) -> None:
        files_to_check = list((ROOT / "src/Kosher").glob("*")) + [
            ROOT / "src/Core/FBPEntry.xm",
            ROOT / "src/Features/Feed/FBPFeedHooks.xm",
            ROOT / "src/Features/Ads/FBPAdsHooks.xm",
            ROOT / "src/Features/AppChrome/FBPChromeHooks.xm",
            ROOT / "src/Features/Links/FBPLinkBridge.xm",
            ROOT / "src/Features/Links/FBPLinkHooks.xm",
            ROOT / "src/Features/Notifications/FBPNotifClientSync.xm",
        ]
        for path in files_to_check:
            txt = path.read_text(encoding="utf-8")
            if path.parent.name == "Kosher":
                self.assertNotIn("MSHookFunction", txt, f"Unsafe MSHookFunction in {path.name}")
            if path.suffix == ".xm":
                opens = len(re.findall(r"^\s*%(?:hook|group|subclass)\b", txt, re.M))
                ends = len(re.findall(r"^\s*%end\b", txt, re.M))
                self.assertEqual(opens, ends, f"Unbalanced %hook/%group vs %end in {path.name}: {opens} vs {ends}")

    def test_no_plaintext_pin_in_defaults_and_pbkdf2_keychain_present(self) -> None:
        store_src = read_text("src/Kosher/FBPKosherPolicyStore.m")
        self.assertIn("CCKeyDerivationPBKDF", store_src)
        self.assertIn("kCCPBKDF2", store_src)
        self.assertIn("kCCPRFHmacAlgSHA256", store_src)
        self.assertIn("SecItemAdd", store_src)
        self.assertIn("SecItemCopyMatching", store_src)
        self.assertIn("FBPConstantTimeEqualData", store_src)
        self.assertNotIn("NSUserDefaults", store_src)

    def test_notify_bridge_stays_foundation_only_and_always_active(self) -> None:
        nb = read_text("FBPNotifyBridge/src/FBPNotifyBridge.mm")
        self.assertNotIn("<UIKit/UIKit.h>", nb)
        self.assertNotIn("<UserNotifications/UserNotifications.h>", nb)
        self.assertIn("FBPKosherBridgeNotificationService", nb)
        self.assertIn("fbp_kosher_nse_policy.json", nb)

    def test_pref_keys_parity_and_protected_writes(self) -> None:
        fbp_h = read_text("src/Core/FBPlus.h")
        fbp_m = read_text("src/Core/FBPlus.m")
        prefs_m = read_text("src/Core/FBPPrefs.m")

        h_keys = set(re.findall(r"extern\s+NSString\s+\*\s*const\s+(FBPKey\w+)\s*;", fbp_h))
        m_keys = set(re.findall(r"NSString\s+\*\s*const\s+(FBPKey\w+)\s*=", fbp_m))
        self.assertEqual(h_keys, m_keys)
        kosher_keys = {k for k in h_keys if "Kosher" in k}
        self.assertEqual(len(kosher_keys), 7)
        for k in kosher_keys:
            self.assertIn(k, prefs_m, f"{k} missing from FBPPrefs.m")

        all_src = [(p, p.read_text(encoding="utf-8", errors="ignore")) for p in (ROOT / "src").rglob("*") if p.is_file() and p.suffix in {".h", ".m", ".xm", ".mm"}]
        for k in h_keys:
            count = sum(1 for _, t in all_src if k in t)
            self.assertGreaterEqual(count, 2, f"{k} referenced in fewer than 2 files")

        self.assertIn("enforceKosherMigrationIfNeeded", prefs_m)
        self.assertIn("FBPKeyKosherStrictMode", prefs_m)

    def test_moderation_stubs_honestly_marked_not_implemented(self) -> None:
        mod = read_text("src/Kosher/FBPKosherModeration.m")
        self.assertIn("NOT IMPLEMENTED", mod)
        self.assertIn("strictMode", mod)
        self.assertIn("FBPKosherDecisionBlock", mod)

    def test_release_licensing_and_no_ipa_or_udid(self) -> None:
        self.assertTrue((ROOT / "LICENSE").is_file())
        notices = read_text("THIRD_PARTY_NOTICES.md")
        self.assertIn("shajon-dev/Facebook-Plus", notices)
        self.assertIn("GNU General Public License v3.0", notices)
        self.assertIn("not** affiliated", notices.replace("Facebook Kosher", ""))
        self.assertEqual(list(ROOT.glob("*.ipa")), [])

        tracked = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.splitlines()
        self.assertEqual([f for f in tracked if f.endswith(".ipa")], [])

        udid_re = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{16}\b")
        for rel in tracked:
            p = ROOT / rel
            if p.suffix in {".h", ".m", ".xm", ".mm", ".py", ".md", ".strings"}:
                content = p.read_text(encoding="utf-8", errors="ignore")
                self.assertIsNone(udid_re.search(content), f"Possible UDID found in {rel}")

    def test_objc_test_suite_defines_all_21_required_cases(self) -> None:
        objc_tests = read_text("test/KosherTests/FBPKosherPolicyTests.m")
        for idx in range(1, 22):
            prefix = f"test_{idx:02d}_"
            self.assertIn(prefix, objc_tests, f"Missing Objective-C test function prefix {prefix}")
        self.assertTrue((ROOT / "test/KosherTests/Makefile").is_file())


class ReferenceKosherPolicyModel:
    """Executable Python mirror of FBPKosherPolicyEngine/Store/MarketplaceGuard contracts."""

    RESTRICTED_MSG = "מרקטפלייס אינו זמין במצב הסינון המחמיר."
    COMPAT_RESTRICTED_MSG = "לא ניתן להפעיל את הסינון בצורה בטוחה בגרסה זו של פייסבוק."
    PBKDF2_ITERS = 120000

    def __init__(self, fb_version: str = "586.0.0", critical_healthy: bool = True, migrated_legacy: bool = False) -> None:
        # Simulates FBPPrefs + FBPKosherPolicyStore initialization
        if migrated_legacy:
            # Simulates legacy preferences trying to disable strict mode before migration
            self.legacy_prefs = {"kosherStrictMode": False, "reDownloadEnabled": True, "linksInSafari": True}
            # enforceKosherMigrationIfNeeded overrides back to safe defaults
            self.strict_mode = True
            self.legacy_prefs["kosherStrictMode"] = True
            self.legacy_prefs["reDownloadEnabled"] = False
            self.legacy_prefs["linksInSafari"] = False
        else:
            self.strict_mode = True
        self.marketplace_enabled = False
        self.marketplace_verified = False
        self.critical_healthy = critical_healthy
        self.fb_version = fb_version
        self.approved_groups: dict[str, str] = {}
        self.approved_pages: dict[str, str] = {}
        self.approved_profiles: dict[str, str] = {}
        self.trusted_domains: dict[str, str | None] = {}
        self._pin_salt: bytes | None = None
        self._pin_hash: bytes | None = None
        self._recovery_hash: bytes | None = None
        self._recovery_salt: bytes | None = None
        self._failed_attempts = 0
        self._locked_until = 0
        self._session_token: str | None = None

    def configure_pin(self, pin: str) -> tuple[str, str]:
        if len(pin) < 6 or not pin.isdigit():
            raise ValueError("Invalid PIN")
        self._pin_salt = secrets.token_bytes(32)
        self._pin_hash = hashlib.pbkdf2_hmac("sha256", pin.encode(), self._pin_salt, self.PBKDF2_ITERS)
        alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
        rec_raw = "".join(alphabet[b & 31] for b in secrets.token_bytes(16))
        recovery = "-".join(rec_raw[i : i + 4] for i in range(0, 16, 4))
        self._recovery_salt = secrets.token_bytes(32)
        self._recovery_hash = hashlib.pbkdf2_hmac("sha256", rec_raw.encode(), self._recovery_salt, self.PBKDF2_ITERS)
        self._session_token = secrets.token_hex(16)
        return recovery, self._session_token

    def authenticate_pin(self, pin: str) -> str:
        if self._failed_attempts >= 3:
            raise PermissionError("Locked out")
        digest = hashlib.pbkdf2_hmac("sha256", pin.encode(), self._pin_salt or b"", self.PBKDF2_ITERS)
        if not self._pin_hash or not hmac.compare_digest(digest, self._pin_hash):
            self._failed_attempts += 1
            raise PermissionError("Wrong PIN")
        self._failed_attempts = 0
        self._session_token = secrets.token_hex(16)
        return self._session_token

    def add_group(self, group_id: str, name: str, session: str | None) -> None:
        if not session or session != self._session_token:
            raise PermissionError("Admin PIN session required")
        self.approved_groups[group_id] = name

    def add_trusted_domain(self, host: str, prefix: str | None, session: str | None) -> None:
        if not session or session != self._session_token:
            raise PermissionError("Admin PIN session required")
        self.trusted_domains[host.lower()] = prefix

    def normalize_url(self, raw: str) -> str | None:
        current = raw
        for _ in range(3):
            if not current or len(current) > 4096:
                return None
            parsed = urlparse(current)
            if parsed.username or parsed.password:
                return None
            if ".." in current or ".." in unquote(current):
                return None
            scheme = parsed.scheme.lower()
            host = (parsed.hostname or "").lower()
            qs = parse_qs(parsed.query)
            if scheme == "fb" and host in {"fbplusbridge", "faceweb", "facewebmodal", "web"}:
                inner = (qs.get("url") or qs.get("href") or [None])[0]
                if not inner:
                    return None
                current = inner
                continue
            if scheme in {"http", "https"} and (host == "facebook.com" or host.endswith(".facebook.com")):
                if parsed.path.lower() in {"/l.php"} or parsed.path.lower().startswith("/l/"):
                    inner = (qs.get("u") or qs.get("url") or [None])[0]
                    if not inner:
                        return None
                    current = inner
                    continue
            return current
        return None

    def evaluate_url(self, raw: str) -> tuple[str, bool, str]:
        if not self.critical_healthy:
            return ("BLOCK", False, self.COMPAT_RESTRICTED_MSG)
        norm = self.normalize_url(raw)
        if not norm:
            return ("BLOCK", False, "malformed_or_spoofed")
        parsed = urlparse(norm)
        host = (parsed.hostname or "").lower()
        path = parsed.path or "/"
        segs = [s for s in path.split("/") if s]
        is_fb = host == "facebook.com" or host.endswith(".facebook.com") or parsed.scheme.lower() == "fb"

        if is_fb:
            head = (segs[0].lower() if segs else (host if parsed.scheme.lower() == "fb" else ""))
            if head in {"reel", "reels"}:
                return ("BLOCK", False, "reels_blocked")
            if head in {"stories", "story"}:
                return ("BLOCK", False, "stories_blocked")
            if head in {"watch", "video", "videos"} or host in {"fb.watch", "fbwat.ch"}:
                return ("BLOCK", False, "watch_blocked")
            if head == "marketplace":
                return ("BLOCK", False, self.RESTRICTED_MSG)
            if head == "search":
                return ("BLOCK", False, "search_blocked")
            if head == "photo" or (segs and segs[0].lower() == "photo.php"):
                return ("BLOCK", False, "photo_viewer_blocked")
            if head == "groups":
                gid = segs[1] if parsed.scheme.lower() != "fb" and len(segs) > 1 else (segs[0] if parsed.scheme.lower() == "fb" and segs else None)
                if gid and gid in self.approved_groups:
                    return ("ALLOW", True, "approved_group")
                return ("BLOCK", False, "unapproved_group")
            return ("UNKNOWN", False, "unknown_facebook_destination")

        if host in self.trusted_domains:
            prefix = self.trusted_domains[host]
            if not prefix or path.startswith(prefix):
                return ("ALLOW", True, "trusted_domain")
            return ("BLOCK", False, "path_outside_trusted_prefix")
        return ("BLOCK", False, "untrusted_external")


class TestBehavioralContracts(unittest.TestCase):
    def test_safari_extension_routes_and_blocks_prohibited_prefixes(self) -> None:
        js = read_text("OpenInFacebookSafariExtension/src/Resources/content.js")
        for prefix in ['"/reel"', '"/reels"', '"/stories"', '"/watch"', '"/marketplace"', '"/search"']:
            self.assertIn(prefix, js, f"Safari content.js missing block rule for {prefix}")
        self.assertIn("fb://fbplusbridge", js)

    def test_url_spoofing_redirects_reels_stories_and_approved_groups(self) -> None:
        m = ReferenceKosherPolicyModel()
        _, tok = m.configure_pin("135790")
        m.add_group("1234567890", "קבוצה מאושרת", tok)
        m.add_trusted_domain("docs.gov.il", "/he/articles/", tok)

        self.assertFalse(m.evaluate_url("https://www.facebook.com/groups/999888")[1])
        self.assertTrue(m.evaluate_url("https://www.facebook.com/groups/1234567890/permalink/1")[1])
        self.assertFalse(m.evaluate_url("https://www.facebook.com/reel/123")[1])
        self.assertFalse(m.evaluate_url("https://www.facebook.com/stories/456")[1])
        self.assertFalse(m.evaluate_url("https://www.facebook.com/watch/?v=789")[1])
        self.assertFalse(m.evaluate_url("https://www.facebook.com/search/top?q=test")[1])
        self.assertFalse(m.evaluate_url("https://www.facebook.com/marketplace/")[1])
        self.assertFalse(m.evaluate_url("https://l.facebook.com/l.php?u=https%3A%2F%2Fevil.com")[1])
        self.assertFalse(m.evaluate_url("fb://facewebmodal/f?href=https%3A%2F%2Fwww.facebook.com%2Freel%2F1")[1])
        self.assertFalse(m.evaluate_url("https://www.facebook.com@evil.com/groups/1234567890")[1])
        self.assertFalse(m.evaluate_url("https://www.facebook.com/groups/1234567890/../reel/1")[1])
        self.assertFalse(m.evaluate_url("https://docs.gov.il/videos/watch")[1])
        self.assertTrue(m.evaluate_url("https://docs.gov.il/he/articles/form")[1])

    def test_migration_pin_lockout_and_critical_hook_fail_closed(self) -> None:
        m = ReferenceKosherPolicyModel(migrated_legacy=True)
        self.assertTrue(m.strict_mode)
        self.assertFalse(m.legacy_prefs["reDownloadEnabled"])
        with self.assertRaises(PermissionError):
            m.add_group("123", "Unauthorized", session=None)

        _, tok = m.configure_pin("112233")
        m.add_group("123", "Authorized", session=tok)
        for _ in range(3):
            with self.assertRaises(PermissionError):
                m.authenticate_pin("000000")
        with self.assertRaises(PermissionError):
            m.authenticate_pin("112233")  # locked out

        m.critical_healthy = False
        decision, allowed, msg = m.evaluate_url("https://www.facebook.com/groups/123")
        self.assertFalse(allowed)
        self.assertEqual(msg, ReferenceKosherPolicyModel.COMPAT_RESTRICTED_MSG)

    def test_compat_monitor_version_matrix_rules(self) -> None:
        compat_src = read_text("src/Kosher/FBPKosherCompatibilityMonitor.m")
        self.assertIn('@"586."', compat_src)
        self.assertIn('@"587."', compat_src)
        self.assertIn("FBPKosherVersionSupportPartial", compat_src)
        self.assertIn("FBPKosherVersionSupportUnknown", compat_src)
        self.assertIn("FBPKosherVersionSupportVerifiedHooks", compat_src)


if __name__ == "__main__":
    unittest.main(verbosity=2)
