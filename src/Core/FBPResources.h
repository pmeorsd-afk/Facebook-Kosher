// Resource-bundle lookup plus image, tint, and font helpers for the tweak UI.

#import "FBPlus.h"

NS_ASSUME_NONNULL_BEGIN

/// Resource bundle lookup.
///
/// The bundle lives outside the app, so it is located by absolute path; on
/// rootless jailbreaks that path is relative to the jbroot, so several
/// candidates are tried in order.
@interface NSBundle (FBPlus)
@property (class, readonly) NSBundle *fbp_resourceBundle;
@end

@interface UIImage (FBPlus)
/// Template-rendered image from the tweak bundle.
+ (nullable UIImage *)fbp_imageNamed:(NSString *)name;
/// Configured SF Symbol, template-rendered.
+ (nullable UIImage *)fbp_symbolNamed:(NSString *)name size:(CGFloat)size;
+ (nullable UIImage *)fbp_symbolNamed:(NSString *)name
                                 size:(CGFloat)size
                               weight:(UIImageSymbolWeight)weight;
@end

// The .xm hook files compile as Objective-C++, the rest as Objective-C, so
// these need C linkage or the two halves will not agree on the symbol names.
#ifdef __cplusplus
extern "C" {
#endif

/// Tint used across the whole UI; a pale blue.
extern UIColor *FBPTintColor(void);

/// Fixed dark palette for the tweak's own screens — pinned regardless of the
/// host app's OLED / dark / light setting. A pure-black panel, dark-grey cards,
/// and white glyphs. Every tweak screen paints from these so the look never
/// shifts with Facebook's theme. (Views that use these must be FBP-prefixed so
/// the OLED sweep leaves their colours alone.)
extern UIColor *FBPPanelColor(void);
extern UIColor *FBPCardColor(void);
extern UIColor *FBPIconColor(void);

/// The tweak's typeface: rounded system design, distinct from Facebook's own UI.
/// Falls back to the plain system font before iOS 13.
extern UIFont *FBPFont(CGFloat size, UIFontWeight weight);

/// Localized string for the language chosen inside the tweak (FBPKeyLanguage) —
/// deliberately independent of the system language. Loads <lang>.lproj from the
/// resource bundle, falls back to Base, then to the key itself. The per-language
/// dictionaries are cached, so switching language and re-reading is cheap; a
/// screen rebuilds (reloads) to pick up the new strings.
extern NSString *FBPLocalizedString(NSString *key);

/// Short alias used at call sites.
#define FBPL(key) FBPLocalizedString(key)

/// YES when the active in-tweak language is RTL (Hebrew "he" or Arabic "ar").
extern BOOL FBPIsRTLLanguage(void);

/// Applies RTL or LTR semantic content attribute to tweak-owned views only
/// (never mutating host app UIView appearance globally).
extern void FBPApplySemanticDirection(UIView *view);

/// Wraps URLs, numeric IDs, prices, and Latin tokens in Unicode First-Strong /
/// LRI isolate markers (U+2066 ... U+2069) for clean bidirectional rendering.
extern NSString *FBPBidiIsolateLTR(NSString *text);

/// Dynamic Type-scaled rounded font respecting FBPKeyKosherLargeText.
extern UIFont *FBPScaledFont(CGFloat baseSize, UIFontWeight weight, UIFontTextStyle textStyle);

/// High-contrast surface colors for Kosher accessible UI.
extern UIColor *FBPKosherSurfaceColor(void);
extern UIColor *FBPKosherCardColor(void);
extern UIColor *FBPKosherAccentColor(void);
extern UIColor *FBPKosherSecondaryTextColor(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
