#import "MatrixCodeIntroOverlayView.h"

#import "MatrixCodeTokenResolver.h"

static double MatrixCodeClampedNumber(NSDictionary *dictionary, NSString *key,
                                      double fallback, double minimum, double maximum) {
    id value = dictionary[key];
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
        !isfinite([value doubleValue])) return fallback;
    return fmin(maximum, fmax(minimum, [value doubleValue]));
}

@interface MatrixCodeIntroOverlayView ()
@property(nonatomic, copy) NSArray<NSDictionary *> *lines;
@property(nonatomic) NSTimeInterval characterDuration;
@property(nonatomic) NSTimeInterval startDelay;
@property(nonatomic) NSTimeInterval fadeDuration;
@property(nonatomic, readwrite) BOOL hasIntro;
@property(nonatomic, readwrite) BOOL playing;
@property(nonatomic, readwrite) BOOL rainDuringIntro;
@property(nonatomic, readwrite) NSTimeInterval postIntroDelay;
@property(nonatomic, readwrite) NSTimeInterval totalDuration;
@property(nonatomic, strong) NSDate *startDate;
@property(nonatomic, copy) NSString *visibleText;
@property(nonatomic) CGFloat textOpacity;
@property(nonatomic) BOOL cursorVisible;
@property(nonatomic, strong) MatrixCodeTokenResolver *tokenResolver;
@property(nonatomic, copy) dispatch_block_t completion;
@end

@implementation MatrixCodeIntroOverlayView

- (instancetype)initWithFrame:(NSRect)frame
                 storedValues:(NSDictionary<NSString *,NSString *> *)storedValues
                tokenResolver:(MatrixCodeTokenResolver *)tokenResolver
                   completion:(dispatch_block_t)completion {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.clearColor.CGColor;
    _tokenResolver = tokenResolver;
    _completion = [completion copy];
    _hasIntro = ![storedValues[@"mx-intro-seen"] isEqualToString:@"1"];

    NSDictionary *intro = [self.class dictionaryFromJSONString:storedValues[@"mx-intro"]];
    NSArray *rawLines = [intro[@"lines"] isKindOfClass:NSArray.class] ? intro[@"lines"] : nil;
    NSMutableArray *lines = [NSMutableArray array];
    for (id item in rawLines ?: @[]) {
        if (![item isKindOfClass:NSDictionary.class] || ![item[@"text"] isKindOfClass:NSString.class]) continue;
        [lines addObject:@{
            @"text": [item[@"text"] substringToIndex:MIN((NSUInteger)120, [item[@"text"] length])],
            @"holdMs": @(MatrixCodeClampedNumber(item, @"holdMs", 2800, 0, 20000)),
            @"pauseMs": @(MatrixCodeClampedNumber(item, @"pauseMs", 0, 0, 20000)),
        }];
        if (lines.count == 12) break;
    }
    if (!lines.count) {
        lines = [@[
            @{@"text": @"Wake up, {name}...", @"holdMs": @2800, @"pauseMs": @0},
            @{@"text": @"The Matrix has you...", @"holdMs": @2800, @"pauseMs": @0},
            @{@"text": @"Follow the white rabbit.", @"holdMs": @2800, @"pauseMs": @0},
            @{@"text": @"Knock, knock, {name}.", @"holdMs": @2800, @"pauseMs": @0},
        ] mutableCopy];
    }
    _lines = lines;
    _characterDuration = MatrixCodeClampedNumber(intro, @"charMs", 95, 10, 500) / 1000.0;
    _startDelay = MatrixCodeClampedNumber(intro, @"startDelayMs", 600, 0, 10000) / 1000.0;
    _fadeDuration = MatrixCodeClampedNumber(intro, @"fadeOutMs", 900, 0, 10000) / 1000.0;
    id rainDuringIntro = intro[@"rainDuringIntro"];
    _rainDuringIntro = [rainDuringIntro isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)rainDuringIntro) == CFBooleanGetTypeID()
        ? [rainDuringIntro boolValue] : NO;
    _postIntroDelay = MatrixCodeClampedNumber(intro, @"postIntroDelayMs", 0, 0, 10000) / 1000.0;
    _totalDuration = _startDelay + _fadeDuration;
    for (NSUInteger index = 0; index < _lines.count; index++) {
        NSDictionary *line = _lines[index];
        _totalDuration += [line[@"text"] length] * _characterDuration +
            [line[@"holdMs"] doubleValue] / 1000.0;
        if (index + 1 < _lines.count) _totalDuration += [line[@"pauseMs"] doubleValue] / 1000.0;
    }
    self.hidden = YES;
    return self;
}

+ (NSDictionary *)dictionaryFromJSONString:(NSString *)raw {
    if (![raw isKindOfClass:NSString.class]) return @{};
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}

- (BOOL)isOpaque {
    return NO;
}

- (void)startAtDate:(NSDate *)date {
    if (!self.hasIntro) return;
    self.startDate = date;
    self.playing = YES;
    self.hidden = NO;
    self.visibleText = @"";
    self.textOpacity = 1;
    [self setNeedsDisplay:YES];
}

- (void)shiftTimelineBy:(NSTimeInterval)interval {
    if (!self.startDate || !isfinite(interval) || interval <= 0) return;
    self.startDate = [self.startDate dateByAddingTimeInterval:interval];
}

- (void)finish {
    if (!self.playing) return;
    self.playing = NO;
    self.hasIntro = NO;
    self.hidden = YES;
    self.completion();
}

- (void)skip {
    [self finish];
}

- (void)updateAtDate:(NSDate *)date framesPerSecond:(double)framesPerSecond {
    if (!self.playing) return;
    NSTimeInterval elapsed = [date timeIntervalSinceDate:self.startDate];
    NSTimeInterval cursorPeriod = 0.45;
    self.cursorVisible = ((NSInteger)floor(elapsed / cursorPeriod) % 2) == 0;
    NSTimeInterval time = elapsed - self.startDelay;
    if (time < 0) {
        self.visibleText = @"";
        self.textOpacity = 1;
        [self setNeedsDisplay:YES];
        return;
    }
    for (NSUInteger index = 0; index < self.lines.count; index++) {
        NSDictionary *line = self.lines[index];
        NSString *resolved = [self.tokenResolver resolveText:line[@"text"]
                                                     atDate:date
                                            framesPerSecond:framesPerSecond];
        NSTimeInterval typeDuration = resolved.length * self.characterDuration;
        if (time < typeDuration) {
            NSUInteger count = MIN(resolved.length, (NSUInteger)floor(time / self.characterDuration));
            self.visibleText = [resolved substringToIndex:count];
            self.textOpacity = 1;
            [self setNeedsDisplay:YES];
            return;
        }
        time -= typeDuration;
        NSTimeInterval hold = [line[@"holdMs"] doubleValue] / 1000.0;
        if (time < hold) {
            self.visibleText = resolved;
            self.textOpacity = 1;
            [self setNeedsDisplay:YES];
            return;
        }
        time -= hold;
        if (index + 1 < self.lines.count) {
            NSTimeInterval pause = [line[@"pauseMs"] doubleValue] / 1000.0;
            if (time < pause) {
                self.visibleText = @"";
                self.textOpacity = 1;
                [self setNeedsDisplay:YES];
                return;
            }
            time -= pause;
        }
    }
    NSString *last = [self.tokenResolver resolveText:self.lines.lastObject[@"text"]
                                              atDate:date
                                     framesPerSecond:framesPerSecond];
    if (self.fadeDuration > 0 && time < self.fadeDuration) {
        self.visibleText = last;
        self.textOpacity = MAX(0, 1 - time / self.fadeDuration);
        [self setNeedsDisplay:YES];
        return;
    }
    [self finish];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (!self.playing) return;
    NSString *display = [self.visibleText stringByAppendingString:self.cursorVisible ? @"█" : @" "];
    CGFloat fontSize = MIN(52, MAX(20, self.bounds.size.width * 0.042));
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [NSColor colorWithSRGBRed:0 green:1 blue:0.25 alpha:0.65];
    shadow.shadowBlurRadius = 12;
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:fontSize weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0 green:1 blue:0.25 alpha:self.textOpacity],
        NSKernAttributeName: @(fontSize * 0.02),
        NSShadowAttributeName: shadow,
    };
    NSSize size = [display sizeWithAttributes:attributes];
    NSRect rect = NSMakeRect(floor((self.bounds.size.width - size.width) / 2),
                             floor((self.bounds.size.height - size.height) / 2),
                             size.width, size.height);
    [display drawInRect:rect withAttributes:attributes];
}

@end
