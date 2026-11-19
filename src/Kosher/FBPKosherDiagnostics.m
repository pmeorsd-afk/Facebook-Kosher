// Privacy-scrubbed diagnostics implementation.

#import "FBPKosherDiagnostics.h"
#import "FBPTrace.h"

static const NSUInteger kMaxDiagnosticEvents = 250;

@interface FBPKosherDiagnosticEvent ()
@property (nonatomic, copy, readwrite) NSDate *timestamp;
@property (nonatomic, assign, readwrite) FBPKosherDecision decision;
@property (nonatomic, assign, readwrite) BOOL effectiveAllowed;
@property (nonatomic, assign, readwrite) FBPKosherDestinationType destination;
@property (nonatomic, assign, readwrite) FBPKosherContentType contentType;
@property (nonatomic, copy, readwrite) NSString *reasonCode;
@property (nonatomic, copy, readwrite, nullable) NSString *surfaceDetail;
@end

@implementation FBPKosherDiagnosticEvent
@end

@implementation FBPKosherDiagnostics {
    NSLock *_lock;
    NSMutableArray<FBPKosherDiagnosticEvent *> *_events;
    NSUInteger _allowCount;
    NSUInteger _blockCount;
    NSUInteger _unknownCount;
}

+ (FBPKosherDiagnostics *)shared {
    static FBPKosherDiagnostics *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [[NSLock alloc] init];
        _events = [NSMutableArray array];
    }
    return self;
}

- (NSString *)scrubSensitiveText:(NSString *)raw {
    if (raw.length == 0) return @"";
    NSString *text = raw;
    // Strip query parameters & fragments that could contain access tokens, cookies, or PII.
    NSRange q = [text rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        text = [[text substringToIndex:q.location] stringByAppendingString:@"?[redacted]"];
    }
    NSRange f = [text rangeOfString:@"#"];
    if (f.location != NSNotFound) {
        text = [text substringToIndex:f.location];
    }
    if (text.length > 120) {
        text = [[text substringToIndex:120] stringByAppendingString:@"..."];
    }
    return text;
}

- (void)recordPolicyResult:(FBPKosherPolicyResult *)result {
    if (!result) return;
    FBPKosherDiagnosticEvent *event = [[FBPKosherDiagnosticEvent alloc] init];
    event.timestamp = result.evaluatedAt ?: [NSDate date];
    event.decision = result.decision;
    event.effectiveAllowed = result.effectiveAllowed;
    event.destination = result.context.destinationType;
    event.contentType = result.context.contentType;
    event.reasonCode = result.reasonCode ?: @"unknown";

    NSString *detail = result.context.viewControllerClassName
        ?: result.context.modelClassName
        ?: (result.context.rawURL ? [self scrubSensitiveText:result.context.rawURL.absoluteString] : nil);
    event.surfaceDetail = detail ? [self scrubSensitiveText:detail] : nil;

    [_lock lock];
    if (result.decision == FBPKosherDecisionAllow) _allowCount++;
    else if (result.decision == FBPKosherDecisionBlock) _blockCount++;
    else _unknownCount++;

    [_events insertObject:event atIndex:0];
    if (_events.count > kMaxDiagnosticEvents) {
        [_events removeLastObject];
    }
    [_lock unlock];

    // Trace only non-sensitive metadata.
    FBPLogRecord(result.effectiveAllowed, @"KosherPolicy",
                 [NSString stringWithFormat:@"%@ dest=%@ content=%@ reason=%@",
                  FBPKosherDecisionName(result.decision),
                  FBPKosherDestinationName(result.context.destinationType),
                  FBPKosherContentTypeName(result.context.contentType),
                  result.reasonCode ?: @"-"]);
}

- (void)recordSecurityEvent:(NSString *)code detail:(NSString *)detail {
    FBPKosherPolicyContext *ctx = [FBPKosherPolicyContext contextWithDestination:FBPKosherDestinationAdmin
                                                                     contentType:FBPKosherContentNavigation];
    FBPKosherDiagnosticEvent *event = [[FBPKosherDiagnosticEvent alloc] init];
    event.timestamp = [NSDate date];
    event.decision = FBPKosherDecisionBlock;
    event.effectiveAllowed = NO;
    event.destination = ctx.destinationType;
    event.contentType = ctx.contentType;
    event.reasonCode = code ?: @"security_event";
    event.surfaceDetail = detail ? [self scrubSensitiveText:detail] : nil;

    [_lock lock];
    [_events insertObject:event atIndex:0];
    if (_events.count > kMaxDiagnosticEvents) {
        [_events removeLastObject];
    }
    [_lock unlock];

    FBPLogRecord(NO, @"KosherSecurity",
                 [NSString stringWithFormat:@"%@ (%@)", event.reasonCode, event.surfaceDetail ?: @"-"]);
}

- (NSUInteger)allowCount {
    [_lock lock];
    NSUInteger c = _allowCount;
    [_lock unlock];
    return c;
}

- (NSUInteger)blockCount {
    [_lock lock];
    NSUInteger c = _blockCount;
    [_lock unlock];
    return c;
}

- (NSUInteger)unknownCount {
    [_lock lock];
    NSUInteger c = _unknownCount;
    [_lock unlock];
    return c;
}

- (NSArray<FBPKosherDiagnosticEvent *> *)recentEvents {
    [_lock lock];
    NSArray *copy = [_events copy];
    [_lock unlock];
    return copy;
}

- (void)clearEvents {
    [_lock lock];
    [_events removeAllObjects];
    _allowCount = 0;
    _blockCount = 0;
    _unknownCount = 0;
    [_lock unlock];
}

- (NSString *)exportSanitizedSummary {
    [_lock lock];
    NSUInteger allow = _allowCount;
    NSUInteger block = _blockCount;
    NSUInteger unknown = _unknownCount;
    NSArray<FBPKosherDiagnosticEvent *> *snapshot = [_events copy];
    [_lock unlock];

    NSMutableString *out = [NSMutableString string];
    [out appendString:@"=== Facebook Kosher Sanitized Diagnostics ===\n"];
    [out appendFormat:@"Allow: %lu | Block: %lu | Unknown(Fail-Closed): %lu\n\n",
     (unsigned long)allow, (unsigned long)block, (unsigned long)unknown];

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    for (FBPKosherDiagnosticEvent *ev in snapshot) {
        [out appendFormat:@"[%@] %@ -> %@ | dest=%@ | type=%@ | reason=%@ | detail=%@\n",
         [fmt stringFromDate:ev.timestamp],
         FBPKosherDecisionName(ev.decision),
         ev.effectiveAllowed ? @"ALLOWED" : @"DENIED",
         FBPKosherDestinationName(ev.destination),
         FBPKosherContentTypeName(ev.contentType),
         ev.reasonCode,
         ev.surfaceDetail ?: @"-"];
    }
    return [out copy];
}

@end
