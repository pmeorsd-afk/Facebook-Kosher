// Resource-bundle location and the image, tint, and font helper implementations.

#import "FBPResources.h"
#import "FBPPrefs.h"

#if __has_include(<rootless.h>)
#import <rootless.h>
#endif

static NSString *const kBundleName = @"FacebookPlus.bundle";

@implementation NSBundle (FBPlus)

+ (NSBundle *)fbp_resourceBundle {
    static NSBundle *bundle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];

#if __has_include(<rootless.h>)
        // Rootless / roothide: the real path is prefixed at build time.
        [candidates addObject:ROOT_PATH_NS(@"/Library/Application Support/FacebookPlus.bundle")];
#endif
        [candidates addObject:@"/var/jb/Library/Application Support/FacebookPlus.bundle"];
        [candidates addObject:@"/Library/Application Support/FacebookPlus.bundle"];

        for (NSString *path in candidates) {
            if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
                bundle = [NSBundle bundleWithPath:path];
                if (bundle) break;
            }
        }

        if (!bundle) {
            // Embedded-in-IPA layout: the bundle sits next to the executable.
            NSString *embedded = [NSBundle.mainBundle.bundlePath
                stringByAppendingPathComponent:kBundleName];
            bundle = [NSBundle bundleWithPath:embedded];
        }

        if (!bundle) {
            FBPLog(@"resource bundle not found — falling back to main bundle");
            bundle = NSBundle.mainBundle;
        }
    });
    return bundle;
}

@end

@implementation UIImage (FBPlus)

+ (UIImage *)fbp_imageNamed:(NSString *)name {
    UIImage *image = [UIImage imageNamed:name
                                inBundle:NSBundle.fbp_resourceBundle
           compatibleWithTraitCollection:nil];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

+ (UIImage *)fbp_symbolNamed:(NSString *)name size:(CGFloat)size {
    return [self fbp_symbolNamed:name size:size weight:UIImageSymbolWeightRegular];
}

+ (UIImage *)fbp_symbolNamed:(NSString *)name
                        size:(CGFloat)size
                      weight:(UIImageSymbolWeight)weight {
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:size weight:weight];
    UIImage *image = [UIImage systemImageNamed:name withConfiguration:config];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

@end

UIColor *FBPTintColor(void) {
    static UIColor *tint;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tint = [UIColor colorWithRed:0.710 green:0.855 blue:0.988 alpha:1.0]; // #B5DAFC
    });
    return tint;
}

UIColor *FBPPanelColor(void) { return UIColor.blackColor; }

UIColor *FBPCardColor(void) {
    static UIColor *card;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        card = [UIColor colorWithRed:28.0/255.0 green:28.0/255.0 blue:30.0/255.0 alpha:1.0]; // #1C1C1E
    });
    return card;
}

UIColor *FBPIconColor(void) { return UIColor.whiteColor; }

#pragma mark - Localization

// Loads <lang>.lproj/Localizable.strings from the resource bundle for the
// language picked inside the tweak (not the system language) and caches the two
// dictionaries currently in play: the chosen language and Base (the fallback).

static NSDictionary<NSString *, NSString *> *FBPStringsForLanguage(NSString *language) {
    static NSMutableDictionary<NSString *, NSDictionary *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });

    if (language.length == 0) language = @"Base";

    @synchronized(cache) {
        NSDictionary *strings = cache[language];
        if (strings) return strings;

        NSString *path = [NSBundle.fbp_resourceBundle pathForResource:@"Localizable"
                                                               ofType:@"strings"
                                                          inDirectory:nil
                                                      forLocalization:language];
        strings = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
        if (!strings) strings = @{};   // negative-cache so a missing file is not re-probed
        cache[language] = strings;
        return strings;
    }
}

NSString *FBPLocalizedString(NSString *key) {
    if (key.length == 0) return key;
    NSString *language = [FBPPrefs.shared stringForKey:FBPKeyLanguage];
    if (!language) language = @"he";

    NSString *value = FBPStringsForLanguage(language)[key];
    if (value) return value;

    value = FBPStringsForLanguage(@"Base")[key];
    return value ?: key;
}

BOOL FBPIsRTLLanguage(void) {
    NSString *language = [FBPPrefs.shared stringForKey:FBPKeyLanguage];
    if (!language) return YES;
    return [language isEqualToString:@"he"] || [language isEqualToString:@"ar"];
}

void FBPApplySemanticDirection(UIView *view) {
    if (!view) return;
    UISemanticContentAttribute attr = FBPIsRTLLanguage()
        ? UISemanticContentAttributeForceRightToLeft
        : UISemanticContentAttributeForceLeftToRight;
    view.semanticContentAttribute = attr;
    if ([view isKindOfClass:UITextField.class]) {
        ((UITextField *)view).textAlignment = FBPIsRTLLanguage() ? NSTextAlignmentRight : NSTextAlignmentLeft;
    } else if ([view isKindOfClass:UITextView.class]) {
        ((UITextView *)view).textAlignment = FBPIsRTLLanguage() ? NSTextAlignmentRight : NSTextAlignmentLeft;
    }
}

NSString *FBPBidiIsolateLTR(NSString *text) {
    if (text.length == 0) return text ?: @"";
    return [NSString stringWithFormat:@"\u2066%@\u2069", text];
}

UIFont *FBPFont(CGFloat size, UIFontWeight weight) {
    UIFont *base = [UIFont systemFontOfSize:size weight:weight];
    if (@available(iOS 13.0, *)) {
        UIFontDescriptor *rounded = [base.fontDescriptor
            fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
        if (rounded) return [UIFont fontWithDescriptor:rounded size:size];
    }
    return base;
}

UIFont *FBPScaledFont(CGFloat baseSize, UIFontWeight weight, UIFontTextStyle textStyle) {
    CGFloat multiplier = FBPEnabled(FBPKeyKosherLargeText) ? 1.20 : 1.0;
    UIFont *base = FBPFont(baseSize * multiplier, weight);
    UIFontMetrics *metrics = [UIFontMetrics metricsForTextStyle:textStyle ?: UIFontTextStyleBody];
    return [metrics scaledFontForFont:base];
}

UIColor *FBPKosherSurfaceColor(void) {
    return FBPPanelColor();
}

UIColor *FBPKosherCardColor(void) {
    if (FBPEnabled(FBPKeyKosherHighContrast)) {
        return [UIColor colorWithRed:18.0/255.0 green:18.0/255.0 blue:22.0/255.0 alpha:1.0];
    }
    return FBPCardColor();
}

UIColor *FBPKosherAccentColor(void) {
    if (FBPEnabled(FBPKeyKosherHighContrast)) {
        return [UIColor colorWithRed:0.35 green:0.78 blue:1.0 alpha:1.0];
    }
    return FBPTintColor();
}

UIColor *FBPKosherSecondaryTextColor(void) {
    if (FBPEnabled(FBPKeyKosherHighContrast)) {
        return [UIColor colorWithWhite:0.90 alpha:1.0];
    }
    return UIColor.secondaryLabelColor;
}
