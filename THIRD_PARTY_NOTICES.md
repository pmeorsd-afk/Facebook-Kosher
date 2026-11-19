# 📜 Third-Party Notices

Provenance and attributions for third-party ideas, code, and binaries used in
Facebook Plus. Planned work lives separately in **[TODO.md](TODO.md)**.

- **Story & Reels Downloader:** Versions **v1.0 – v1.0.4** used the media download system from **[ttlongdl](https://github.com/ttlongdl/Facebook-Plus)**'s GPLv3 fork (enhanced by **@SHAJON-404**), attributed as the license requires. From **v1.0.5** onward the download system (`src/Features/Downloads/`) is an entirely new implementation, written from scratch A-to-Z by **@SHAJON-404** (backup **@shajon-dev**), carrying over no third-party code.
- **"Open in Facebook" Safari Extension:** The bundled Safari web extension (`OpenInFacebookSafariExtension/`, built from source into the IPA) is our own, independently written implementation — its own `NSExtension` host, manifest and link-routing scripts, with no third-party binary or source bundled. See `OpenInFacebookSafariExtension/README.md` for details.
- **Marketplace Ad Removal:** The idea of removing Facebook Marketplace ads at the React Native / GraphQL layer — intercepting `-[RCTNetworking handlerForRequest:]` to fail dedicated ad queries and to buffer-and-filter blended ad stories out of responses — is adapted from **[MarketplaceAdBlock](https://github.com/adamsardo/MarketplaceAdBlock)** by adamsardo. That upstream hook alone does **not** remove every Marketplace ad, however: the logic in `src/Features/Ads/FBPAdsHooks.xm` that extends it to **every Marketplace surface** (search, category and home-pagination grids, not just feed queries) and that treats sponsored/boosted listings disguised as ordinary items as ads is new, written by **@SHAJON-404** (backup **@shajon-dev**). Gated behind the existing **Remove Ads** toggle.
- **Compatibility Layer:** The sideloading compatibility layer (`src/PluginsInject/`) is copied and derived directly from **[zxPluginsInject](https://github.com/asdfzxcvbn/zxPluginsInject)**.
- **Symbol Rebinding:** Uses **[fishhook](https://github.com/facebook/fishhook)** for dynamic symbol rebinding.

This project is distributed under the **[GNU General Public License v3.0](LICENSE)**; see the `LICENSE` file for details.


---

## Facebook Kosher Derivative Work Notice

**Facebook Kosher** (`פייסבוק כשר`) is a derivative work based on [shajon-dev/Facebook-Plus](https://github.com/shajon-dev/Facebook-Plus), licensed under the **GNU General Public License v3.0 (GPL-3.0)**.

### Preserved Upstream & Third-Party Attributions
All upstream copyright notices, MIT/BSD/GPL-3.0 attributions, and third-party notices listed above — including `Facebook-Plus` (`S. SHAJON`, `ttlongdl`), `OpenInFacebookSafariExtension`, `MarketplaceAdBlock` (`adamsardo`), `zxPluginsInject`, and `fishhook` — are preserved in full under the GPL-3.0 license terms.

### Summary of Modifications in Facebook Kosher (`facebook-kosher` branch)
- Added `src/Kosher/` strict-mode policy engine, encrypted Keychain PIN administration, URL/deep-link/navigation guard, text-only media blocking, Marketplace JSON/GraphQL guard, allowlist-only local search, notification guard, runtime compatibility monitor, diagnostics, and accessible Hebrew (`he-IL`, RTL) interfaces.
- Extended `src/Core/`, `src/Features/`, `src/Settings/`, `FBPNotifyBridge/`, `OpenInFacebookSafariExtension/`, and `Localizations/` (`he.lproj` + synchronized catalogs) to fail closed in Strict Mode.

### Disclaimers
- Facebook Kosher is an independent, community technical modification and is **not** affiliated with, endorsed by, or sponsored by Meta Platforms, Inc. or Facebook.
- Facebook Kosher provides technical client-side filtering only and does **not** claim or substitute for halachic, rabbinical, or organizational certification.
- This repository does **not** include or redistribute Meta's proprietary Facebook iOS IPA, assets, credentials, or signing certificates.
