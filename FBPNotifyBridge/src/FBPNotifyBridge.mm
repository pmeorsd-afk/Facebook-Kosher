// FBPNotifyBridge — the slim half of the sideload compatibility layer, loaded
// into Facebook's NotificationServiceExtension.appex (the NSE) instead of the
// full tweak.
//
// Why a separate dylib: FacebookPlus.dylib's constructor registers preferences
// and installs every feature hook unconditionally, and it links UIKit. An NSE
// runs under a hard ~24 MB memory limit and a ~30 s execution window — being
// killed there makes notifications *worse* (iOS falls back to the generic
// payload), so the extension gets only the two container redirects it needs.
//
// What it does: the NSE resolves a push into real text only when it can find the
// logged-in session. On a re-signed build that session is not where Facebook
// looks — the Meta app groups (group.com.facebook.*) and the T84QZS65DQ keychain
// group cannot be claimed by a third-party signer. The main app already works
// around this (src/PluginsInject/), and this dylib applies the *same* mapping
// inside the extension so both processes read and write the same container:
//
//   <real app group container>/<requested group id>
//
// The path construction below is a line-for-line match of
// src/PluginsInject/SideloadFix.xm — including the "group" prefix check and the
// Documents/<group id> fallback — because an identical mapping in both processes
// is the entire point. Change one, change the other.
//
// The keychain half (probe + SecItem rebinds) comes from the shared
// src/PluginsInject/PluginsInject.mm + SecRebinds.xm, compiled in here too: the
// NSE asks for kSecAttrAccessGroup "T84QZS65DQ.platformFamily" (see its
// Info.plist's FBKeychainAccessGroup), which a re-signed extension can never be
// granted, so without the rebinds the container redirect alone cannot surface a
// session. The probe asks the keychain which group a throwaway item actually
// landed in, so the app and the extension converge on the same group whenever
// the signer gives them the same keychain entitlement — which is what a signer's
// "merge entitlements" step does by re-prefixing Facebook's own keychain groups
// with the signer's team id. Note that the rebind is blanket — it forces
// kSecAttrAccessGroup on *every* SecItem call in the process — and project notes
// record a suspicion that this aggravates crashes elsewhere. See
// FBPNotifyBridge/README.md.
//
// Hooks are installed with plain objc runtime swizzling rather than Logos so the
// dylib carries no Cydia Substrate / ElleKit dependency: cyan drops
// CydiaSubstrate.framework into Facebook.app/Frameworks, which an appex binary
// has no guaranteed rpath to.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "Header.h"

#pragma mark - App-Group container

@interface NSFileManager (FBPNotifyBridge)
- (NSURL *)fbp_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier;
@end

@implementation NSFileManager (FBPNotifyBridge)

// Mirrors -[NSFileManager containerURLForSecurityApplicationGroupIdentifier:] in
// SideloadFix.xm: never defers to the original, because the original returns nil
// for a group this build does not hold.
- (NSURL *)fbp_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
	if (NSURL *ourAppGroupURL = getAppGroupPathIfExists()) {
		NSURL *fakeAppGroupURL = [ourAppGroupURL URLByAppendingPathComponent:groupIdentifier];
		createDirectoryIfNotExists(fakeAppGroupURL.path);
		FBPDiagLog(@"containerURL for %@ -> %@", groupIdentifier, fakeAppGroupURL.path);
		return fakeAppGroupURL;
	}

	// fallback to a fake App Group path in Documents/App Group
	//
	// Unlike in the main app this fallback cannot actually share anything: an
	// app extension gets its own data container, so the extension's Documents/
	// is not the app's. It is kept only so the mapping stays identical and the
	// call never returns nil.
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *fakePath = [[paths lastObject] stringByAppendingPathComponent:groupIdentifier];
	createDirectoryIfNotExists(fakePath);
	return [NSURL fileURLWithPath:fakePath];
}

@end

#pragma mark - group-suite NSUserDefaults

// The selector starts with "init" followed by an uppercase letter, so ARC places
// it in the init method family — same ownership contract as the
// -_initWithSuiteName:container: it is exchanged with. A raw IMP function
// pointer would not carry that contract and would mis-balance retains.
@interface NSUserDefaults (FBPNotifyBridge)
- (instancetype)initFBPWithSuiteName:(NSString *)suiteName container:(NSURL *)container;
@end

@implementation NSUserDefaults (FBPNotifyBridge)

// Mirrors -[NSUserDefaults _initWithSuiteName:container:] in SideloadFix.xm.
// After the exchange, -initFBPWithSuiteName:container: *is* the original
// implementation, so calling it on self is the %orig equivalent.
- (instancetype)initFBPWithSuiteName:(NSString *)suiteName container:(NSURL *)container {
	PILog(@"hooking NSUserDefaults init...");

	NSURL *appGroupURL = getAppGroupPathIfExists();
	if (!appGroupURL) {
		PILog(@"no valid app group available, defaulting to original container");
		return [self initFBPWithSuiteName:suiteName container:container];
	}
	PILog(@"app group URL: %@", appGroupURL);

	if (![suiteName hasPrefix:@"group"]) {
		PILog(@"suite name '%@' does not start with 'group', defaulting to original container", suiteName);
		return [self initFBPWithSuiteName:suiteName container:container];
	}

	if (NSURL *customContainerURL = [appGroupURL URLByAppendingPathComponent:suiteName]) {
		// Without Library/Preferences underneath it the suite reads empty and
		// never persists — see prepareDefaultsContainer in Paths.mm.
		if (!prepareDefaultsContainer(customContainerURL)) {
			PILog(@"could not prepare '%@' for defaults, defaulting to original container", suiteName);
			FBPDiagLog(@"could not prepare defaults container for suite %@", suiteName);
			return [self initFBPWithSuiteName:suiteName container:container];
		}
		PILog(@"using custom container URL: %@", customContainerURL);
		FBPDiagLog(@"defaults suite %@ -> %@", suiteName, customContainerURL.path);
		return [self initFBPWithSuiteName:suiteName container:customContainerURL];
	}

	PILog(@"failed to construct valid URL for suite '%@' in app group container", suiteName);
	return [self initFBPWithSuiteName:suiteName container:container];
}

@end

#pragma mark - Kosher Notification Sanitization & Diagnostics

static NSDictionary *FBPBridgeReadKosherPolicy(void) {
	NSURL *groupURL = [NSFileManager.defaultManager
		containerURLForSecurityApplicationGroupIdentifier:@"group.com.facebook.Facebook"];
	if (!groupURL) return nil;
	NSURL *mirrorURL = [groupURL URLByAppendingPathComponent:@"fbp_kosher_nse_policy.json"];
	NSData *data = [NSData dataWithContentsOfURL:mirrorURL];
	if (!data.length) return nil;
	id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
	return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

static id FBPBridgeSanitizeNotificationContent(id finalContent) {
	if (!finalContent) return nil;
	NSDictionary *policy = FBPBridgeReadKosherPolicy();
	BOOL strictMode = policy ? ([policy[@"strictMode"] isKindOfClass:NSNumber.class] ? [policy[@"strictMode"] boolValue] : YES) : YES;
	if (!strictMode) return finalContent;

	BOOL safeOnly = policy ? ([policy[@"safeNotificationsOnly"] isKindOfClass:NSNumber.class] ? [policy[@"safeNotificationsOnly"] boolValue] : YES) : YES;
	NSArray *approvedGroups = [policy[@"approvedGroupIDs"] isKindOfClass:NSArray.class] ? policy[@"approvedGroupIDs"] : @[];
	NSArray *approvedPages = [policy[@"approvedPageIDs"] isKindOfClass:NSArray.class] ? policy[@"approvedPageIDs"] : @[];

	id mutableContent = nil;
	@try {
		mutableContent = [finalContent mutableCopy];
	} @catch (__unused NSException *e) {
		mutableContent = nil;
	}
	if (!mutableContent) return finalContent;

	// Strip all media attachments (photos, thumbnails, video previews, GIFs).
	@try {
		[mutableContent setValue:@[] forKey:@"attachments"];
	} @catch (__unused NSException *e) {}

	NSString *title = @"";
	NSString *body = @"";
	NSDictionary *userInfo = nil;
	@try {
		id t = [mutableContent valueForKey:@"title"];
		if ([t isKindOfClass:NSString.class]) title = t;
		id b = [mutableContent valueForKey:@"body"];
		if ([b isKindOfClass:NSString.class]) body = b;
		id u = [mutableContent valueForKey:@"userInfo"];
		if ([u isKindOfClass:NSDictionary.class]) userInfo = u;
	} @catch (__unused NSException *e) {}

	NSString *combined = [[NSString stringWithFormat:@"%@ %@", title, body] lowercaseString];
	BOOL prohibitedKeyword =
		[combined containsString:@"reel"] || [combined containsString:@"story"] ||
		[combined containsString:@"stories"] || [combined containsString:@"video"] ||
		[combined containsString:@"people you may know"] || [combined containsString:@"suggested"] ||
		[combined containsString:@"רילס"] || [combined containsString:@"סטורי"] ||
		[combined containsString:@"מומלץ"];

	BOOL approvedSource = NO;
	id gid = userInfo[@"group_id"] ?: userInfo[@"groupId"];
	if (gid && [approvedGroups containsObject:[NSString stringWithFormat:@"%@", gid]]) {
		approvedSource = YES;
	}
	id pid = userInfo[@"page_id"] ?: userInfo[@"pageId"];
	if (pid && [approvedPages containsObject:[NSString stringWithFormat:@"%@", pid]]) {
		approvedSource = YES;
	}

	if (prohibitedKeyword || (safeOnly && !approvedSource)) {
		@try {
			[mutableContent setValue:@"פייסבוק כשר" forKey:@"title"];
			[mutableContent setValue:@"" forKey:@"subtitle"];
			[mutableContent setValue:@"התראה חדשה — פתח את פייסבוק כשר לבדיקה." forKey:@"body"];
		} @catch (__unused NSException *e) {}
	}
	return mutableContent;
}

@interface FBPKosherBridgeNotificationService: NSObject
- (void)fbp_didReceiveNotificationRequest:(id)request withContentHandler:(void (^)(id))contentHandler;
- (void)fbp_serviceExtensionTimeWillExpire;
@end

@implementation FBPKosherBridgeNotificationService

// After the exchange this selector holds Facebook's own implementation, so
// calling it on self is the %orig equivalent.
- (void)fbp_didReceiveNotificationRequest:(id)request withContentHandler:(void (^)(id))contentHandler {
#if FBP_DIAG
	id content = [request valueForKey:@"content"];
	NSDictionary *userInfo = [content valueForKey:@"userInfo"];
	NSString *identifier = [request valueForKey:@"identifier"] ?: @"(none)";

	NSString *incomingTitle = [content valueForKey:@"title"] ?: @"";
	NSString *incomingBody  = [content valueForKey:@"body"] ?: @"";
	FBPDiagLog(@"NSE RAN for request %@ — incoming title '%@' body '%@'",
	           identifier, incomingTitle, incomingBody);
	FBPDiagLog(@"NSE payload keys: %@",
	           [[userInfo.allKeys sortedArrayUsingSelector:@selector(compare:)]
	               componentsJoinedByString:@","] ?: @"(none)");

	NSDate *start = NSDate.date;
#endif
	[self fbp_didReceiveNotificationRequest:request
	                    withContentHandler:^(id finalContent) {
		id sanitized = FBPBridgeSanitizeNotificationContent(finalContent);
#if FBP_DIAG
		NSString *finalTitle = [sanitized valueForKey:@"title"] ?: @"";
		NSString *finalBody  = [sanitized valueForKey:@"body"] ?: @"";

		BOOL changed = ![finalBody isEqualToString:incomingBody] ||
		               ![finalTitle isEqualToString:incomingTitle];
		FBPDiagLog(@"NSE RESULT for %@ after %.2fs: %@ — title '%@' body '%@'",
		           identifier, -start.timeIntervalSinceNow,
		           changed ? @"CONTENT REPLACED" : @"UNCHANGED (expansion failed)",
		           finalTitle, finalBody);
#endif
		if (contentHandler) contentHandler(sanitized);
	}];
}

- (void)fbp_serviceExtensionTimeWillExpire {
#if FBP_DIAG
	FBPDiagLog(@"NSE TIME EXPIRED — Facebook never called the content handler; "
	           @"iOS will deliver the original payload");
#endif
	[self fbp_serviceExtensionTimeWillExpire];
}

@end

#pragma mark - Install

// Swaps two instance methods, but only when both really exist — a future
// Foundation that drops the private initialiser then costs the group-suite
// redirect instead of taking the extension down with it.
static BOOL fbpExchange(Class cls, SEL original, SEL replacement) {
	if (!cls) {
		return NO;
	}

	Method originalMethod = class_getInstanceMethod(cls, original);
	Method replacementMethod = class_getInstanceMethod(cls, replacement);
	if (!originalMethod || !replacementMethod) {
		PILog(@"missing method for %@ on %@ — skipping", NSStringFromSelector(original), cls);
		return NO;
	}

	method_exchangeImplementations(originalMethod, replacementMethod);
	return YES;
}

__attribute__((constructor)) static void FBPNotifyBridgeInit() {
	@autoreleasepool {
		// Loaded twice in the extension — see the note in PluginsInject.mm.
		// Exchanging the same two methods a second time would undo the first.
		if (!fbpClaimProcessOnce("FBPNotifyBridgeInstalled")) {
			FBPDiagLog(@"notify bridge constructor ran again — ignoring the duplicate");
			return;
		}

		// Extensions only — see the note in PluginsInject.mm. In the main app
		// FacebookPlus.dylib already installs every one of these redirects.
		if (!fbpIsAppExtensionProcess()) {
			return;
		}

		// The exchanges must always run — only the log is debug-gated, so the
		// results are unused in the release build (PILog compiles to a no-op).
		__attribute__((unused)) BOOL container =
			fbpExchange([NSFileManager class],
						@selector(containerURLForSecurityApplicationGroupIdentifier:),
						@selector(fbp_containerURLForSecurityApplicationGroupIdentifier:));
		__attribute__((unused)) BOOL suite =
			fbpExchange([NSUserDefaults class],
						@selector(_initWithSuiteName:container:),
						@selector(initFBPWithSuiteName:container:));

		NSDictionary *extension = NSBundle.mainBundle.infoDictionary[@"NSExtension"];
		NSString *principal = [extension isKindOfClass:NSDictionary.class]
		                          ? extension[@"NSExtensionPrincipalClass"]
		                          : nil;
		Class service = principal.length ? NSClassFromString(principal) : Nil;
		if (!service) service = objc_getClass("FBNotificationService");

		FBPDiagLog(@"notification service class: %@ (from %@)",
		           service ? NSStringFromClass(service) : @"(not found)",
		           principal.length ? @"Info.plist" : @"fallback name");

		if (service) {
			SEL replacements[2] = {
				@selector(fbp_didReceiveNotificationRequest:withContentHandler:),
				@selector(fbp_serviceExtensionTimeWillExpire),
			};
			SEL originals[2] = {
				@selector(didReceiveNotificationRequest:withContentHandler:),
				@selector(serviceExtensionTimeWillExpire),
			};
			for (size_t i = 0; i < 2; i++) {
				Method donor = class_getInstanceMethod([FBPKosherBridgeNotificationService class],
				                                       replacements[i]);
				if (!donor) continue;
				class_addMethod(service, replacements[i], method_getImplementation(donor),
				                method_getTypeEncoding(donor));
				fbpExchange(service, originals[i], replacements[i]);
			}
		}

		PILog(@"notify bridge loaded into %@ (container=%d, suite=%d)",
			  NSBundle.mainBundle.bundleIdentifier, container, suite);
		FBPDiagLog(@"notify bridge loaded into %@ (container=%d, suite=%d)",
				   NSBundle.mainBundle.bundleIdentifier ?: @"(unknown)", container, suite);
	}
}
