#import "MatrixCodeIntroOverlayView.h"

#import "MatrixCodeConstants.h"
#import "MatrixCodeSettingsTheme.h"
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
@property(nonatomic) CGFloat overlayOpacity;
@property(nonatomic) BOOL cursorVisible;
@property(nonatomic, strong) MatrixCodeTokenResolver *tokenResolver;
@property(nonatomic, strong) NSColor *accentColor;
@property(nonatomic, copy) dispatch_block_t completion;
- (NSAttributedString *)displayAttributedStringWithAttributes:
    (NSDictionary<NSAttributedStringKey, id> *)attributes
                                                      fontSize:(CGFloat)fontSize;
- (NSRect)layoutRectForAttributedString:(NSAttributedString *)attributedString;
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
    _completion = [completion copy];
    _hasIntro = ![storedValues[@"mx-intro-seen"] isEqualToString:@"1"];

    [self reloadStoredValues:storedValues tokenResolver:tokenResolver];
    self.hidden = YES;
    return self;
}

- (void)reloadStoredValues:(NSDictionary<NSString *,NSString *> *)storedValues
             tokenResolver:(MatrixCodeTokenResolver *)tokenResolver {
    self.tokenResolver = tokenResolver;

    NSDictionary *controls = MatrixCodeSanitizeControlsDocument(
        [self.class dictionaryFromJSONString:storedValues[@"mx-controls"]]);
    NSString *preset = controls[@"preset"];
    MatrixCodeSettingsTheme.sharedTheme.presetName = preset;
    self.accentColor = MatrixCodeSettingsTheme.sharedTheme.accentColor;

    NSDictionary *intro = [self.class dictionaryFromJSONString:storedValues[@"mx-intro"]];
    NSArray *rawLines = [intro[@"lines"] isKindOfClass:NSArray.class] ? intro[@"lines"] : nil;
    NSMutableArray *lines = [NSMutableArray array];
    NSUInteger rawLineLimit = MIN((NSUInteger)12, rawLines.count);
    for (NSUInteger index = 0; index < rawLineLimit; index++) {
        id item = rawLines[index];
        if (![item isKindOfClass:NSDictionary.class] || ![item[@"text"] isKindOfClass:NSString.class]) continue;
        [lines addObject:@{
            @"text": [item[@"text"] substringToIndex:MIN((NSUInteger)120, [item[@"text"] length])],
            @"holdMs": @(MatrixCodeClampedNumber(item, @"holdMs", 2800, 0, 20000)),
            @"pauseMs": @(MatrixCodeClampedNumber(item, @"pauseMs", 0, 0, 20000)),
        }];
    }
    if (!lines.count) {
        lines = [@[
            @{@"text": @"Wake up, {name}...", @"holdMs": @2800, @"pauseMs": @0},
            @{@"text": @"The Matrix has you...", @"holdMs": @2800, @"pauseMs": @0},
            @{@"text": @"Follow the white rabbit.", @"holdMs": @2800, @"pauseMs": @0},
            @{@"text": @"Knock, knock, {name}.", @"holdMs": @2800, @"pauseMs": @0},
        ] mutableCopy];
    }
    self.lines = lines;
    self.characterDuration = MatrixCodeClampedNumber(intro, @"charMs", 95, 10, 500) / 1000.0;
    self.startDelay = MatrixCodeClampedNumber(intro, @"startDelayMs", 600, 0, 10000) / 1000.0;
    self.fadeDuration = MatrixCodeClampedNumber(intro, @"fadeOutMs", 900, 0, 10000) / 1000.0;
    id rainDuringIntro = intro[@"rainDuringIntro"];
    self.rainDuringIntro = [rainDuringIntro isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)rainDuringIntro) == CFBooleanGetTypeID()
        ? [rainDuringIntro boolValue] : NO;
    self.postIntroDelay = MatrixCodeClampedNumber(intro, @"postIntroDelayMs", 0, 0, 10000) / 1000.0;
    self.totalDuration = self.startDelay + self.fadeDuration;
    for (NSUInteger index = 0; index < self.lines.count; index++) {
        NSDictionary *line = self.lines[index];
        self.totalDuration += [line[@"text"] length] * self.characterDuration +
            [line[@"holdMs"] doubleValue] / 1000.0;
        if (index + 1 < self.lines.count) self.totalDuration += [line[@"pauseMs"] doubleValue] / 1000.0;
    }
    [self setNeedsDisplay:YES];
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
    self.overlayOpacity = 1;
    [self setNeedsDisplay:YES];
}

- (void)replayAtDate:(NSDate *)date {
    self.hasIntro = YES;
    [self startAtDate:date];
}

- (void)setOverlayOpacity:(CGFloat)overlayOpacity {
    _overlayOpacity = fmin(1, fmax(0, overlayOpacity));
    self.alphaValue = _overlayOpacity;
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

- (void)cancel {
    if (!self.playing) return;
    self.playing = NO;
    self.hasIntro = NO;
    self.hidden = YES;
}

- (void)updateAtDate:(NSDate *)date framesPerSecond:(double)framesPerSecond {
    if (!self.playing) return;
    NSTimeInterval elapsed = [date timeIntervalSinceDate:self.startDate];
    NSTimeInterval cursorPeriod = 0.45;
    self.cursorVisible = ((NSInteger)floor(elapsed / cursorPeriod) % 2) == 0;
    NSTimeInterval time = elapsed - self.startDelay;
    if (time < 0) {
        self.visibleText = @"";
        self.overlayOpacity = 1;
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
            self.overlayOpacity = 1;
            [self setNeedsDisplay:YES];
            return;
        }
        time -= typeDuration;
        NSTimeInterval hold = [line[@"holdMs"] doubleValue] / 1000.0;
        if (time < hold) {
            self.visibleText = resolved;
            self.overlayOpacity = 1;
            [self setNeedsDisplay:YES];
            return;
        }
        time -= hold;
        if (index + 1 < self.lines.count) {
            NSTimeInterval pause = [line[@"pauseMs"] doubleValue] / 1000.0;
            if (time < pause) {
                self.visibleText = @"";
                self.overlayOpacity = 1;
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
        self.overlayOpacity = MAX(0, 1 - time / self.fadeDuration);
        [self setNeedsDisplay:YES];
        return;
    }
    [self finish];
}

- (NSAttributedString *)displayAttributedStringWithAttributes:
    (NSDictionary<NSAttributedStringKey, id> *)attributes
                                                      fontSize:(CGFloat)fontSize {
    NSMutableAttributedString *display = [[NSMutableAttributedString alloc]
        initWithString:self.visibleText ?: @""
            attributes:attributes];
    if (display.length > 0) {
        NSNumber *baseKern = attributes[NSKernAttributeName];
        [display addAttribute:NSKernAttributeName
                        value:@(baseKern.doubleValue + fontSize * 0.04)
                        range:NSMakeRange(display.length - 1, 1)];
    }
    [display appendAttributedString:[[NSAttributedString alloc]
        initWithString:self.cursorVisible ? @"█" : @" "
            attributes:attributes]];
    return display;
}

- (NSRect)layoutRectForAttributedString:(NSAttributedString *)attributedString {
    NSStringDrawingOptions options = NSStringDrawingUsesLineFragmentOrigin |
        NSStringDrawingUsesFontLeading;
    CGFloat maximumWidth = floor(self.bounds.size.width * 0.88);
    if (maximumWidth < 1 || self.bounds.size.height < 1) return NSZeroRect;
    NSRect naturalBounds = [attributedString
        boundingRectWithSize:NSMakeSize(CGFLOAT_MAX / 4, CGFLOAT_MAX / 4)
                     options:options];
    CGFloat textWidth = MIN(maximumWidth, MAX(1, ceil(naturalBounds.size.width)));
    NSRect wrappedBounds = [attributedString
        boundingRectWithSize:NSMakeSize(textWidth, CGFLOAT_MAX / 4)
                     options:options];
    CGFloat textHeight = MAX(1, ceil(wrappedBounds.size.height));
    return NSMakeRect(floor((self.bounds.size.width - textWidth) / 2),
                      floor((self.bounds.size.height - textHeight) / 2),
                      textWidth,
                      textHeight);
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (!self.playing) return;
    CGFloat fontSize = MIN(52, MAX(20, self.bounds.size.width * 0.042));
    NSColor *accent = self.accentColor ?: [NSColor colorWithSRGBRed:0 green:1 blue:0.25 alpha:1];
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.alignment = NSTextAlignmentLeft;
    paragraphStyle.lineBreakMode = NSLineBreakByWordWrapping;
    NSShadow *outerShadow = [[NSShadow alloc] init];
    outerShadow.shadowColor = [accent colorWithAlphaComponent:0.35];
    outerShadow.shadowBlurRadius = 28;
    NSDictionary *outerAttributes = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:fontSize weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: accent,
        NSKernAttributeName: @(fontSize * 0.02),
        NSShadowAttributeName: outerShadow,
        NSParagraphStyleAttributeName: paragraphStyle,
    };
    NSShadow *innerShadow = [[NSShadow alloc] init];
    innerShadow.shadowColor = [accent colorWithAlphaComponent:0.65];
    innerShadow.shadowBlurRadius = 12;
    NSDictionary *innerAttributes = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:fontSize weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: accent,
        NSKernAttributeName: @(fontSize * 0.02),
        NSShadowAttributeName: innerShadow,
        NSParagraphStyleAttributeName: paragraphStyle,
    };
    NSAttributedString *innerDisplay = [self displayAttributedStringWithAttributes:innerAttributes
                                                                           fontSize:fontSize];
    NSRect rect = [self layoutRectForAttributedString:innerDisplay];
    NSAttributedString *outerDisplay = [self displayAttributedStringWithAttributes:outerAttributes
                                                                           fontSize:fontSize];
    [outerDisplay drawWithRect:rect
                       options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading];
    [innerDisplay drawWithRect:rect
                       options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading];
}

@end
