#import "MatrixCodeConfigurationController.h"

#import "MatrixCodeIntroOverlayView.h"
#import "MatrixCodeMetalView.h"
#import "MatrixCodePreferences.h"
#import "MatrixCodeTokenResolver.h"

NSNotificationName const MatrixCodePreviewValuesDidChangeNotification =
    @"MatrixCodePreviewValuesDidChangeNotification";
NSString * const MatrixCodePreviewValuesKey = @"values";

static NSDictionary *MatrixCodeJSONObject(NSString *raw, Class expectedClass) {
    if (![raw isKindOfClass:NSString.class]) return nil;
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    return [object isKindOfClass:expectedClass] ? object : nil;
}

static NSString *MatrixCodeJSONString(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

static double MatrixCodeSettingNumber(NSDictionary *dictionary, NSString *key,
                                      double fallback, double minimum, double maximum) {
    id value = dictionary[key];
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
        !isfinite([value doubleValue])) return fallback;
    return fmin(maximum, fmax(minimum, [value doubleValue]));
}

static BOOL MatrixCodeSettingBool(NSDictionary *dictionary, NSString *key, BOOL fallback) {
    id value = dictionary[key];
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()
        ? [value boolValue] : fallback;
}

static NSString *MatrixCodeSettingText(id value, NSUInteger maximumLength) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *text = value;
    return [text substringToIndex:MIN(maximumLength, text.length)];
}

static BOOL MatrixCodePreferredMirrorForGlyphMode(NSString *glyphMode) {
    return [glyphMode isEqualToString:@"matrix"] ||
        [glyphMode isEqualToString:@"katakana"];
}

@interface MatrixCodeFlippedDocumentView : NSView
@end

@implementation MatrixCodeFlippedDocumentView

- (BOOL)isFlipped {
    return YES;
}

@end

@interface MatrixCodeNativePreviewController : NSWindowController <NSWindowDelegate>
@property(nonatomic, strong) MatrixCodeMetalView *metalView;
@property(nonatomic, strong) MatrixCodeIntroOverlayView *introView;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSDate *startDate;
@property(nonatomic) BOOL showsIntro;
@property(nonatomic) BOOL showsMessage;
@end

@implementation MatrixCodeNativePreviewController

- (instancetype)initWithStoredValues:(NSDictionary<NSString *, NSString *> *)values
                           showIntro:(BOOL)showIntro
                         showMessage:(BOOL)showMessage {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 500)
                                                  styleMask:NSWindowStyleMaskTitled |
                                                            NSWindowStyleMaskClosable |
                                                            NSWindowStyleMaskResizable
                                                    backing:NSBackingStoreBuffered defer:NO];
    window.title = @"MatrixCode Preview";
    window.minSize = NSMakeSize(480, 300);
    self = [super initWithWindow:window];
    if (!self) return nil;
    window.delegate = self;
    _showsIntro = showIntro;
    _showsMessage = showMessage;
    _startDate = NSDate.date;
    NSDictionary *previewValues = [self previewValuesFromValues:values];
    _metalView = [[MatrixCodeMetalView alloc] initWithFrame:window.contentView.bounds
                                                    session:nil
                                               storedValues:previewValues];
    [window.contentView addSubview:_metalView];
    [_metalView setAnimationActive:YES];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:previewValues runStartDate:_startDate];
    _introView = [[MatrixCodeIntroOverlayView alloc] initWithFrame:window.contentView.bounds
                                                     storedValues:previewValues
                                                    tokenResolver:resolver
                                                       completion:^{}];
    if (showIntro) {
        [window.contentView addSubview:_introView positioned:NSWindowAbove relativeTo:_metalView];
        [_introView startAtDate:_startDate];
    }
    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf.metalView draw];
        [weakSelf.introView updateAtDate:NSDate.date framesPerSecond:60];
    }];
    [window center];
    return self;
}

- (NSDictionary<NSString *, NSString *> *)previewValuesFromValues:
    (NSDictionary<NSString *, NSString *> *)values {
    NSMutableDictionary *previewValues = [values mutableCopy];
    if (self.showsIntro) [previewValues removeObjectForKey:@"mx-intro-seen"];
    if (self.showsMessage) {
        NSMutableDictionary *messages =
            [MatrixCodeJSONObject(previewValues[@"mx-messages"], NSDictionary.class) mutableCopy];
        if (!messages) messages = [NSMutableDictionary dictionary];
        messages[@"enabled"] = @YES;
        messages[@"frequencyMs"] = @500;
        previewValues[@"mx-messages"] = MatrixCodeJSONString(messages);
    }
    return previewValues;
}

- (void)reloadStoredValues:(NSDictionary<NSString *, NSString *> *)values {
    NSDictionary *previewValues = [self previewValuesFromValues:values];
    [self.metalView reloadStoredValues:previewValues];
    if (!self.showsIntro) return;

    [self.introView removeFromSuperview];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:previewValues
                                                 runStartDate:self.startDate];
    self.introView = [[MatrixCodeIntroOverlayView alloc]
        initWithFrame:self.window.contentView.bounds
         storedValues:previewValues
        tokenResolver:resolver
           completion:^{}];
    [self.window.contentView addSubview:self.introView
                              positioned:NSWindowAbove
                              relativeTo:self.metalView];
    [self.introView startAtDate:NSDate.date];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self.timer invalidate];
    self.timer = nil;
}

- (void)dealloc {
    [_timer invalidate];
}

@end

@interface MatrixCodeConfigurationController ()
@property(nonatomic, strong) MatrixCodePreferences *preferences;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *stagedValues;
@property(nonatomic, strong) NSMutableDictionary *controls;
@property(nonatomic, strong) NSMutableDictionary *intro;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *introLines;
@property(nonatomic, strong) NSMutableDictionary *messages;
@property(nonatomic, strong) NSMutableArray<NSString *> *messageLines;
@property(nonatomic, strong) NSMutableDictionary *countdown;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *moments;
@property(nonatomic, copy) dispatch_block_t closeHandler;
@property(nonatomic, strong) NSStackView *introLinesStack;
@property(nonatomic, strong) NSStackView *messageLinesStack;
@property(nonatomic, strong) NSStackView *momentsStack;
@property(nonatomic, strong) MatrixCodeNativePreviewController *previewController;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *originalValues;
@property(nonatomic, strong) NSTextField *postIntroDelayField;
@property(nonatomic, strong) NSDatePicker *defaultCountdownDatePicker;
@property(nonatomic, strong) NSButton *mirrorButton;
@end

@implementation MatrixCodeConfigurationController

- (instancetype)initWithCloseHandler:(dispatch_block_t)closeHandler {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 860, 680)
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                                    backing:NSBackingStoreBuffered defer:NO];
    window.title = @"MatrixCode Options";
    window.minSize = NSMakeSize(700, 540);
    self = [super initWithWindow:window];
    if (!self) return nil;
    _preferences = [[MatrixCodePreferences alloc] init];
    _stagedValues = [[_preferences storedValues] mutableCopy];
    _originalValues = [_stagedValues copy];
    _closeHandler = [closeHandler copy];
    [self loadModels];
    [self buildInterface];
    return self;
}

- (void)publishPreviewValues:(NSDictionary<NSString *, NSString *> *)values {
    [self.previewController reloadStoredValues:values];
    [NSNotificationCenter.defaultCenter
        postNotificationName:MatrixCodePreviewValuesDidChangeNotification
                      object:self
                    userInfo:@{MatrixCodePreviewValuesKey: values}];
}

- (void)draftDidChange {
    [self publishPreviewValues:[self serializedValues]];
}

- (void)loadModels {
    NSDictionary *storedControls =
        MatrixCodeJSONObject(self.stagedValues[@"mx-controls"], NSDictionary.class) ?: @{};
    NSMutableDictionary *controls = [@{
        @"speed": @1, @"trailLength": @0.255, @"density": @2, @"rampUpMs": @8000,
        @"glyphRate": @1, @"glyphScale": @1, @"glow": @0.9, @"leadBrightness": @1.6,
        @"glyphMode": @"matrix", @"glyphFont": @"matrix", @"preset": @"classic", @"mirror": @YES, @"scanlines": @NO, @"vignette": @0,
        @"allowOverlap": @YES, @"quality": @"high",
    } mutableCopy];
    NSArray *controlNumbers = @[
        @[@"speed", @0.1, @3], @[@"trailLength", @0.01, @0.5],
        @[@"density", @0.1, @100], @[@"rampUpMs", @0, @60000],
        @[@"glyphRate", @0, @5], @[@"glyphScale", @0.5, @10],
        @[@"glow", @0, @2.5], @[@"leadBrightness", @0, @3],
        @[@"vignette", @0, @1],
    ];
    for (NSArray *spec in controlNumbers) {
        NSString *key = spec[0];
        controls[key] = @(MatrixCodeSettingNumber(storedControls, key,
            [controls[key] doubleValue], [spec[1] doubleValue], [spec[2] doubleValue]));
    }
    id storedVignette = storedControls[@"vignette"];
    if ([storedVignette isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)storedVignette) == CFBooleanGetTypeID()) {
        controls[@"vignette"] = @([storedVignette boolValue] ? 0.42 : 0);
    }
    for (NSString *key in @[@"mirror", @"scanlines", @"allowOverlap"]) {
        controls[key] = @(MatrixCodeSettingBool(storedControls, key, [controls[key] boolValue]));
    }
    NSArray *presets = @[@"classic", @"amber", @"gold", @"red", @"pink", @"purple", @"blue", @"white"];
    if ([storedControls[@"preset"] isKindOfClass:NSString.class] &&
        [presets containsObject:storedControls[@"preset"]]) controls[@"preset"] = storedControls[@"preset"];
    NSArray *qualities = @[@"low", @"med", @"high"];
    if ([storedControls[@"quality"] isKindOfClass:NSString.class] &&
        [qualities containsObject:storedControls[@"quality"]]) controls[@"quality"] = storedControls[@"quality"];
    NSArray *glyphModes = @[@"matrix", @"katakana", @"binary", @"digits", @"latin", @"symbols"];
    if ([storedControls[@"glyphMode"] isKindOfClass:NSString.class] &&
        [glyphModes containsObject:storedControls[@"glyphMode"]]) controls[@"glyphMode"] = storedControls[@"glyphMode"];
    NSArray *glyphFonts = @[@"matrix", @"gothic", @"mono", @"terminal", @"rounded", @"mincho"];
    if ([storedControls[@"glyphFont"] isKindOfClass:NSString.class] &&
        [glyphFonts containsObject:storedControls[@"glyphFont"]]) controls[@"glyphFont"] = storedControls[@"glyphFont"];
    self.controls = controls;

    NSDictionary *storedIntro =
        MatrixCodeJSONObject(self.stagedValues[@"mx-intro"], NSDictionary.class) ?: @{};
    self.intro = [@{
        @"charMs": @(MatrixCodeSettingNumber(storedIntro, @"charMs", 95, 10, 500)),
        @"startDelayMs": @(MatrixCodeSettingNumber(storedIntro, @"startDelayMs", 600, 0, 10000)),
        @"fadeOutMs": @(MatrixCodeSettingNumber(storedIntro, @"fadeOutMs", 900, 0, 10000)),
        @"rainDuringIntro": @(MatrixCodeSettingBool(storedIntro, @"rainDuringIntro", YES)),
        @"postIntroDelayMs": @(MatrixCodeSettingNumber(storedIntro, @"postIntroDelayMs", 0, 0, 10000)),
    } mutableCopy];
    NSArray *storedIntroLines = [storedIntro[@"lines"] isKindOfClass:NSArray.class]
        ? storedIntro[@"lines"] : nil;
    NSArray *defaultIntroLines = @[
        @{@"text": @"Wake up, {name}...", @"holdMs": @2800, @"pauseMs": @0},
        @{@"text": @"The Matrix has you...", @"holdMs": @2800, @"pauseMs": @0},
        @{@"text": @"Follow the white rabbit.", @"holdMs": @2800, @"pauseMs": @0},
        @{@"text": @"Knock, knock, {name}.", @"holdMs": @2800, @"pauseMs": @0},
    ];
    self.introLines = [NSMutableArray array];
    NSArray *introSource = storedIntroLines.count ? storedIntroLines : defaultIntroLines;
    for (NSUInteger index = 0; index < MIN((NSUInteger)12, introSource.count); index++) {
        NSDictionary *line = introSource[index];
        if (![line isKindOfClass:NSDictionary.class] ||
            ![line[@"text"] isKindOfClass:NSString.class]) continue;
        [self.introLines addObject:[@{
            @"text": MatrixCodeSettingText(line[@"text"], 120),
            @"holdMs": @(MatrixCodeSettingNumber(line, @"holdMs", 2800, 0, 20000)),
            @"pauseMs": @(MatrixCodeSettingNumber(line, @"pauseMs", 0, 0, 20000)),
        } mutableCopy]];
    }
    if (!self.introLines.count) {
        for (NSDictionary *line in defaultIntroLines) [self.introLines addObject:[line mutableCopy]];
    }

    NSDictionary *parsedMessageDoc =
        MatrixCodeJSONObject(self.stagedValues[@"mx-messages"], NSDictionary.class);
    NSDictionary *storedMessageDoc = parsedMessageDoc ?: @{};
    self.messages = [@{
        @"enabled": @(MatrixCodeSettingBool(storedMessageDoc, @"enabled", NO)),
        @"frequencyMs": @(MatrixCodeSettingNumber(storedMessageDoc, @"frequencyMs", 8000, 500, 600000)),
        @"persistenceMs": @(MatrixCodeSettingNumber(storedMessageDoc, @"persistenceMs", 10000, 500, 600000)),
        @"appearMs": @(MatrixCodeSettingNumber(storedMessageDoc, @"appearMs", 4000, 0, 600000)),
        @"disappearMs": @(MatrixCodeSettingNumber(storedMessageDoc, @"disappearMs", 4000, 0, 600000)),
        @"flickerOut": @(MatrixCodeSettingBool(storedMessageDoc, @"flickerOut", YES)),
        @"brightnessFade": @(MatrixCodeSettingBool(storedMessageDoc, @"brightnessFade", NO)),
        @"verticalPosition": @(MatrixCodeSettingNumber(storedMessageDoc, @"verticalPosition", 0.475, 0, 1)),
        @"verticalJitter": @(MatrixCodeSettingNumber(storedMessageDoc, @"verticalJitter", 0.25, 0, 1)),
    } mutableCopy];
    NSArray *storedMessages = [storedMessageDoc[@"messages"] isKindOfClass:NSArray.class]
        ? storedMessageDoc[@"messages"]
        : (parsedMessageDoc ? @[] : @[@"WAKE UP", @"THE MATRIX HAS YOU",
                                      @"FOLLOW THE WHITE RABBIT", @"{countup}"]);
    self.messageLines = [NSMutableArray array];
    for (NSUInteger index = 0; index < MIN((NSUInteger)12, storedMessages.count); index++) {
        NSString *message = MatrixCodeSettingText(storedMessages[index], 120);
        if ([message stringByTrimmingCharactersInSet:
             NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
            [self.messageLines addObject:message];
        }
    }

    NSDictionary *storedCountdown =
        MatrixCodeJSONObject(self.stagedValues[@"mx-countdown"], NSDictionary.class) ?: @{};
    NSNumber *target = [storedCountdown[@"targetMs"] isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)storedCountdown[@"targetMs"]) != CFBooleanGetTypeID() &&
        isfinite([storedCountdown[@"targetMs"] doubleValue])
        ? @(fmin(8.64e15, fmax(0, [storedCountdown[@"targetMs"] doubleValue])))
        : nil;
    self.countdown = [@{@"targetMs": target ?: NSNull.null, @"moments": @[]} mutableCopy];
    self.moments = [NSMutableArray array];
    NSMutableSet<NSString *> *momentNames = [NSMutableSet set];
    NSArray *storedMoments = [storedCountdown[@"moments"] isKindOfClass:NSArray.class]
        ? storedCountdown[@"moments"] : @[];
    for (NSUInteger index = 0; index < MIN((NSUInteger)12, storedMoments.count); index++) {
        NSDictionary *moment = storedMoments[index];
        if (![moment isKindOfClass:NSDictionary.class]) continue;
        NSString *name = MatrixCodeSettingText(moment[@"name"], 40);
        name = [[name componentsSeparatedByCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@":{}"]]
            componentsJoinedByString:@""];
        name = [name stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length || [momentNames containsObject:name]) continue;
        [momentNames addObject:name];
        NSNumber *momentTarget = [moment[@"targetMs"] isKindOfClass:NSNumber.class] &&
            CFGetTypeID((__bridge CFTypeRef)moment[@"targetMs"]) != CFBooleanGetTypeID() &&
            isfinite([moment[@"targetMs"] doubleValue])
            ? @(fmin(8.64e15, fmax(0, [moment[@"targetMs"] doubleValue])))
            : nil;
        [self.moments addObject:[@{
            @"name": name, @"targetMs": momentTarget ?: NSNull.null,
        } mutableCopy]];
    }
}

- (NSView *)scrollingStack:(NSStackView **)stackOut {
    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    // Scroll views initially expose y=0. A normal AppKit view places that at
    // its bottom edge, which made every settings tab open at the end of its
    // form. Use a top-origin document so y=0 is the first control.
    NSView *document = [[MatrixCodeFlippedDocumentView alloc]
        initWithFrame:NSMakeRect(0, 0, 780, 700)];
    [document addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:document.topAnchor],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:document.bottomAnchor],
        [stack.widthAnchor constraintGreaterThanOrEqualToConstant:620],
    ]];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.documentView = document;
    if (stackOut) *stackOut = stack;
    return scroll;
}

- (void)buildInterface {
    NSView *content = self.window.contentView;
    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSZeroRect];
    tabs.translatesAutoresizingMaskIntoConstraints = NO;
    [tabs addTabViewItem:[self tabItem:@"Rain" view:[self rainTab]]];
    [tabs addTabViewItem:[self tabItem:@"Characters" view:[self charactersTab]]];
    [tabs addTabViewItem:[self tabItem:@"Intro" view:[self introTab]]];
    [tabs addTabViewItem:[self tabItem:@"Messages" view:[self messagesTab]]];
    [tabs addTabViewItem:[self tabItem:@"Countdowns" view:[self countdownTab]]];

    NSButton *reset = [NSButton buttonWithTitle:@"Reset All" target:self action:@selector(resetAll:)];
    reset.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\e";
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *ok = [NSButton buttonWithTitle:@"OK" target:self action:@selector(accept:)];
    ok.keyEquivalent = @"\r";
    ok.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:tabs];
    [content addSubview:reset];
    [content addSubview:cancel];
    [content addSubview:ok];
    [NSLayoutConstraint activateConstraints:@[
        [tabs.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [tabs.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [tabs.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [tabs.bottomAnchor constraintEqualToAnchor:ok.topAnchor constant:-14],
        [reset.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [reset.centerYAnchor constraintEqualToAnchor:ok.centerYAnchor],
        [ok.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [ok.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
        [cancel.trailingAnchor constraintEqualToAnchor:ok.leadingAnchor constant:-8],
        [cancel.centerYAnchor constraintEqualToAnchor:ok.centerYAnchor],
    ]];
}

- (NSTabViewItem *)tabItem:(NSString *)label view:(NSView *)view {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:label];
    item.label = label;
    item.view = view;
    return item;
}

- (NSTextField *)heading:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont preferredFontForTextStyle:NSFontTextStyleTitle2 options:@{}];
    return label;
}

- (NSStackView *)rowWithLabel:(NSString *)label control:(NSView *)control {
    NSTextField *text = [NSTextField labelWithString:label];
    [text.widthAnchor constraintEqualToConstant:155].active = YES;
    NSStackView *row = [NSStackView stackViewWithViews:@[text, control]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 10;
    return row;
}

- (NSString *)displayValueForSlider:(NSSlider *)slider {
    if ([slider.identifier isEqualToString:@"rampUpMs"]) {
        return [NSString stringWithFormat:@"%.0f", slider.doubleValue];
    }
    if ([slider.identifier isEqualToString:@"trailLength"]) {
        return [NSString stringWithFormat:@"%.3f", slider.doubleValue];
    }
    return [NSString stringWithFormat:@"%.2f", slider.doubleValue];
}

- (void)updateReadoutForSlider:(NSSlider *)slider {
    NSString *identifier = [slider.identifier stringByAppendingString:@"-value"];
    for (NSView *view in slider.superview.subviews) {
        if ([view.identifier isEqualToString:identifier] &&
            [view isKindOfClass:NSTextField.class]) {
            ((NSTextField *)view).stringValue = [self displayValueForSlider:slider];
            break;
        }
    }
}

- (NSView *)slider:(NSString *)key min:(double)minimum max:(double)maximum {
    NSSlider *slider = [NSSlider sliderWithValue:[self.controls[key] doubleValue]
                                       minValue:minimum maxValue:maximum
                                         target:self action:@selector(controlChanged:)];
    slider.identifier = key;
    slider.continuous = YES;
    [slider.widthAnchor constraintEqualToConstant:380].active = YES;
    NSTextField *readout = [NSTextField labelWithString:[self displayValueForSlider:slider]];
    readout.identifier = [key stringByAppendingString:@"-value"];
    readout.alignment = NSTextAlignmentRight;
    readout.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize
                                                   weight:NSFontWeightRegular];
    [readout.widthAnchor constraintEqualToConstant:64].active = YES;
    NSStackView *control = [NSStackView stackViewWithViews:@[slider, readout]];
    control.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    control.alignment = NSLayoutAttributeCenterY;
    control.spacing = 10;
    return control;
}

- (NSView *)rainTab {
    NSStackView *stack;
    NSView *scroll = [self scrollingStack:&stack];
    [stack addArrangedSubview:[self heading:@"Rain"]];
    NSTextField *name = [[NSTextField alloc] initWithFrame:NSZeroRect];
    name.placeholderString = @"Neo";
    name.stringValue = self.stagedValues[@"mx-user-name"] ?: @"";
    name.identifier = @"mx-user-name";
    name.target = self;
    name.action = @selector(nameChanged:);
    [name.widthAnchor constraintEqualToConstant:260].active = YES;
    [stack addArrangedSubview:[self rowWithLabel:@"Viewer name" control:name]];
    NSArray *specs = @[
        @[@"Density", @"density", @0.1, @100], @[@"Ramp-up (ms)", @"rampUpMs", @0, @60000],
        @[@"Trail decay", @"trailLength", @0.01, @0.5], @[@"Speed", @"speed", @0.1, @3],
        @[@"Glyph size", @"glyphScale", @0.5, @10],
        @[@"Glow", @"glow", @0, @2.5], @[@"Lead glow", @"leadBrightness", @0, @3],
        @[@"Vignette", @"vignette", @0, @1],
    ];
    for (NSArray *spec in specs) {
        [stack addArrangedSubview:[self rowWithLabel:spec[0]
                                            control:[self slider:spec[1]
                                                             min:[spec[2] doubleValue]
                                                             max:[spec[3] doubleValue]]]];
    }
    NSPopUpButton *preset = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [preset addItemsWithTitles:@[@"classic", @"amber", @"gold", @"red", @"pink", @"purple", @"blue", @"white"]];
    [preset selectItemWithTitle:self.controls[@"preset"]];
    preset.identifier = @"preset"; preset.target = self; preset.action = @selector(controlChanged:);
    [stack addArrangedSubview:[self rowWithLabel:@"Color" control:preset]];
    NSPopUpButton *quality = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [quality addItemsWithTitles:@[@"low", @"med", @"high"]];
    [quality selectItemWithTitle:self.controls[@"quality"]];
    quality.identifier = @"quality"; quality.target = self; quality.action = @selector(controlChanged:);
    [stack addArrangedSubview:[self rowWithLabel:@"Quality" control:quality]];
    for (NSArray *toggle in @[@[@"Scanlines", @"scanlines"], @[@"Allow overlap", @"allowOverlap"]]) {
        NSButton *button = [NSButton checkboxWithTitle:toggle[0] target:self action:@selector(controlChanged:)];
        button.identifier = toggle[1];
        button.state = [self.controls[toggle[1]] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        [stack addArrangedSubview:button];
    }
    NSButton *preview = [NSButton buttonWithTitle:@"Preview Rain" target:self action:@selector(previewRain:)];
    [stack addArrangedSubview:preview];
    return scroll;
}

- (NSView *)charactersTab {
    NSStackView *stack;
    NSView *scroll = [self scrollingStack:&stack];
    [stack addArrangedSubview:[self heading:@"Characters"]];
    NSTextField *hint = [NSTextField wrappingLabelWithString:
        @"These controls affect the ambient rain glyphs. In-rain messages keep their readable character set."];
    [hint.widthAnchor constraintLessThanOrEqualToConstant:680].active = YES;
    [stack addArrangedSubview:hint];

    NSPopUpButton *glyphMode = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    NSArray *glyphModeItems = @[
        @[@"matrix", @"matrix"], @[@"katakana", @"katakana"],
        @[@"binary", @"binary"], @[@"digits", @"digits"],
        @[@"latin", @"latin"], @[@"symbols", @"symbols"],
    ];
    for (NSArray *item in glyphModeItems) {
        [glyphMode addItemWithTitle:item[0]];
        glyphMode.lastItem.representedObject = item[1];
        if ([item[1] isEqualToString:self.controls[@"glyphMode"]]) {
            [glyphMode selectItem:glyphMode.lastItem];
        }
    }
    glyphMode.identifier = @"glyphMode";
    glyphMode.target = self;
    glyphMode.action = @selector(controlChanged:);
    [stack addArrangedSubview:[self rowWithLabel:@"Character set" control:glyphMode]];

    NSPopUpButton *glyphFont = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    NSArray *fontItems = @[
        @[@"Movie Gothic", @"matrix"], @[@"Sharp Gothic", @"gothic"],
        @[@"SF Mono", @"mono"], @[@"Terminal Mono", @"terminal"],
        @[@"Rounded", @"rounded"], @[@"Mincho", @"mincho"],
    ];
    for (NSArray *item in fontItems) {
        [glyphFont addItemWithTitle:item[0]];
        glyphFont.lastItem.representedObject = item[1];
        if ([item[1] isEqualToString:self.controls[@"glyphFont"]]) {
            [glyphFont selectItem:glyphFont.lastItem];
        }
    }
    glyphFont.identifier = @"glyphFont";
    glyphFont.target = self;
    glyphFont.action = @selector(controlChanged:);
    [stack addArrangedSubview:[self rowWithLabel:@"Font" control:glyphFont]];

    for (NSArray *spec in @[@[@"Glyph change", @"glyphRate", @0, @5]]) {
        [stack addArrangedSubview:[self rowWithLabel:spec[0]
                                            control:[self slider:spec[1]
                                                             min:[spec[2] doubleValue]
                                                             max:[spec[3] doubleValue]]]];
    }
    NSButton *mirror = [NSButton checkboxWithTitle:@"Mirror glyphs"
                                           target:self
                                           action:@selector(controlChanged:)];
    mirror.identifier = @"mirror";
    mirror.state = [self.controls[@"mirror"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    self.mirrorButton = mirror;
    [stack addArrangedSubview:mirror];
    return scroll;
}

- (void)controlChanged:(id)sender {
    NSString *key = [sender identifier];
    if ([sender isKindOfClass:NSSlider.class]) {
        self.controls[key] = @([sender doubleValue]);
        [self updateReadoutForSlider:sender];
    }
    else if ([sender isKindOfClass:NSPopUpButton.class]) {
        id value = [[sender selectedItem] representedObject];
        NSString *selected = [value isKindOfClass:NSString.class] ? value : [sender titleOfSelectedItem];
        self.controls[key] = selected;
        if ([key isEqualToString:@"glyphMode"]) {
            BOOL mirror = MatrixCodePreferredMirrorForGlyphMode(selected);
            self.controls[@"mirror"] = @(mirror);
            self.mirrorButton.state = mirror ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
    else if ([sender isKindOfClass:NSButton.class]) self.controls[key] = @([sender state] == NSControlStateValueOn);
    [self draftDidChange];
}

- (void)nameChanged:(NSTextField *)sender {
    NSString *name = [sender.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length) self.stagedValues[@"mx-user-name"] = name;
    else [self.stagedValues removeObjectForKey:@"mx-user-name"];
    [self draftDidChange];
}

- (NSTextField *)numberField:(double)value identifier:(NSString *)identifier action:(SEL)action {
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    field.doubleValue = value;
    field.identifier = identifier;
    field.target = self;
    field.action = action;
    [field.widthAnchor constraintEqualToConstant:76].active = YES;
    return field;
}

- (NSView *)introTab {
    NSStackView *stack;
    NSView *scroll = [self scrollingStack:&stack];
    [stack addArrangedSubview:[self heading:@"Typed Intro"]];
    NSTextField *hint = [NSTextField wrappingLabelWithString:
        @"Tokens: {name}, {greeting}, {uptime}, {fps}, {time:%H:%M}, {countdown}, {countup}"];
    [hint.widthAnchor constraintLessThanOrEqualToConstant:680].active = YES;
    [stack addArrangedSubview:hint];
    self.introLinesStack = [NSStackView stackViewWithViews:@[]];
    self.introLinesStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.introLinesStack.spacing = 8;
    [stack addArrangedSubview:self.introLinesStack];
    [self rebuildIntroLines];
    NSButton *add = [NSButton buttonWithTitle:@"Add Line" target:self action:@selector(addIntroLine:)];
    [stack addArrangedSubview:add];
    for (NSArray *field in @[@[@"Typing speed (ms/character)", @"charMs"],
                              @[@"Start delay (ms)", @"startDelayMs"],
                              @[@"Fade out (ms)", @"fadeOutMs"],
                              @[@"Delay after intro (ms)", @"postIntroDelayMs"]]) {
        NSTextField *number = [self numberField:[self.intro[field[1]] doubleValue]
                                     identifier:field[1]
                                         action:@selector(introTimingChanged:)];
        if ([field[1] isEqualToString:@"postIntroDelayMs"]) {
            self.postIntroDelayField = number;
        }
        [stack addArrangedSubview:[self rowWithLabel:field[0]
                                            control:number]];
    }
    self.postIntroDelayField.enabled = ![self.intro[@"rainDuringIntro"] boolValue];
    NSButton *rain = [NSButton checkboxWithTitle:@"Rain during intro" target:self action:@selector(introRainChanged:)];
    rain.state = [self.intro[@"rainDuringIntro"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    [stack addArrangedSubview:rain];
    NSButton *replay = [NSButton buttonWithTitle:@"Show Intro Again on Next Run"
                                          target:self action:@selector(replayIntroNextRun:)];
    [stack addArrangedSubview:replay];
    NSButton *preview = [NSButton buttonWithTitle:@"Preview Intro" target:self action:@selector(previewIntro:)];
    [stack addArrangedSubview:preview];
    return scroll;
}

- (void)rebuildIntroLines {
    for (NSView *view in self.introLinesStack.arrangedSubviews.copy) {
        [self.introLinesStack removeArrangedSubview:view]; [view removeFromSuperview];
    }
    [self.introLines enumerateObjectsUsingBlock:^(NSMutableDictionary *line, NSUInteger index, BOOL *stop) {
        NSTextField *text = [[NSTextField alloc] initWithFrame:NSZeroRect];
        text.stringValue = [line[@"text"] isKindOfClass:NSString.class] ? line[@"text"] : @"";
        text.tag = index; text.identifier = @"text"; text.target = self; text.action = @selector(introLineChanged:);
        [text.widthAnchor constraintEqualToConstant:330].active = YES;
        NSTextField *hold = [self numberField:[line[@"holdMs"] doubleValue] identifier:@"holdMs"
                                       action:@selector(introLineChanged:)];
        hold.tag = index;
        NSTextField *pause = [self numberField:[line[@"pauseMs"] doubleValue] identifier:@"pauseMs"
                                        action:@selector(introLineChanged:)];
        pause.tag = index;
        NSButton *up = [NSButton buttonWithTitle:@"↑" target:self action:@selector(moveIntroLine:)];
        up.tag = index; up.identifier = @"up"; up.enabled = index > 0;
        NSButton *down = [NSButton buttonWithTitle:@"↓" target:self action:@selector(moveIntroLine:)];
        down.tag = index; down.identifier = @"down"; down.enabled = index + 1 < self.introLines.count;
        NSButton *remove = [NSButton buttonWithTitle:@"−" target:self action:@selector(removeIntroLine:)];
        remove.tag = index; remove.enabled = self.introLines.count > 1;
        NSStackView *row = [NSStackView stackViewWithViews:@[
            text, [NSTextField labelWithString:@"Hold"], hold,
            [NSTextField labelWithString:@"Pause"], pause, up, down, remove
        ]];
        row.spacing = 6; row.alignment = NSLayoutAttributeCenterY;
        [self.introLinesStack addArrangedSubview:row];
    }];
}

- (void)introLineChanged:(NSTextField *)sender {
    if (sender.tag >= self.introLines.count) return;
    self.introLines[sender.tag][sender.identifier] =
        [sender.identifier isEqualToString:@"text"]
            ? MatrixCodeSettingText(sender.stringValue, 120)
            : @(MIN(20000, MAX(0, sender.doubleValue)));
    [self draftDidChange];
}
- (void)addIntroLine:(id)sender {
    if (self.introLines.count < 12) [self.introLines addObject:
        [@{@"text": @"", @"holdMs": @2800, @"pauseMs": @0} mutableCopy]];
    [self rebuildIntroLines];
    [self draftDidChange];
}
- (void)removeIntroLine:(NSButton *)sender {
    if (self.introLines.count > 1 && sender.tag < self.introLines.count)
        [self.introLines removeObjectAtIndex:sender.tag];
    [self rebuildIntroLines];
    [self draftDidChange];
}
- (void)moveIntroLine:(NSButton *)sender {
    NSInteger destination = sender.tag + ([sender.identifier isEqualToString:@"up"] ? -1 : 1);
    if (destination >= 0 && destination < self.introLines.count)
        [self.introLines exchangeObjectAtIndex:sender.tag withObjectAtIndex:destination];
    [self rebuildIntroLines];
    [self draftDidChange];
}
- (void)introTimingChanged:(NSTextField *)sender {
    BOOL characterTiming = [sender.identifier isEqualToString:@"charMs"];
    self.intro[sender.identifier] = @(MIN(characterTiming ? 500 : 10000,
        MAX(characterTiming ? 10 : 0, sender.doubleValue)));
    [self draftDidChange];
}
- (void)introRainChanged:(NSButton *)sender {
    self.intro[@"rainDuringIntro"] = @(sender.state == NSControlStateValueOn);
    self.postIntroDelayField.enabled = sender.state != NSControlStateValueOn;
    [self draftDidChange];
}
- (void)replayIntroNextRun:(id)sender {
    [self.stagedValues removeObjectForKey:@"mx-intro-seen"];
    [self draftDidChange];
}

- (NSView *)messagesTab {
    NSStackView *stack;
    NSView *scroll = [self scrollingStack:&stack];
    [stack addArrangedSubview:[self heading:@"In-rain Messages"]];
    NSButton *enabled = [NSButton checkboxWithTitle:@"Enable messages" target:self action:@selector(messageToggleChanged:)];
    enabled.identifier = @"enabled";
    enabled.state = [self.messages[@"enabled"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    [stack addArrangedSubview:enabled];
    self.messageLinesStack = [NSStackView stackViewWithViews:@[]];
    self.messageLinesStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.messageLinesStack.spacing = 8;
    [stack addArrangedSubview:self.messageLinesStack];
    [self rebuildMessageLines];
    [stack addArrangedSubview:[NSButton buttonWithTitle:@"Add Message" target:self action:@selector(addMessage:)]];
    for (NSArray *field in @[@[@"Average frequency (ms)", @"frequencyMs"],
                              @[@"Fade in (ms)", @"appearMs"],
                              @[@"Hold (ms)", @"persistenceMs"],
                              @[@"Fade out (ms)", @"disappearMs"],
                              @[@"Vertical position (0–1)", @"verticalPosition"],
                              @[@"Vertical jitter (0–1)", @"verticalJitter"]]) {
        [stack addArrangedSubview:[self rowWithLabel:field[0]
                                            control:[self numberField:[self.messages[field[1]] doubleValue]
                                                           identifier:field[1] action:@selector(messageNumberChanged:)]]];
    }
    for (NSArray *toggle in @[@[@"Flicker dissolve", @"flickerOut"],
                               @[@"Brightness fade", @"brightnessFade"]]) {
        NSButton *button = [NSButton checkboxWithTitle:toggle[0] target:self action:@selector(messageToggleChanged:)];
        button.identifier = toggle[1];
        button.state = [self.messages[toggle[1]] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        [stack addArrangedSubview:button];
    }
    [stack addArrangedSubview:[NSButton buttonWithTitle:@"Preview Message" target:self action:@selector(previewMessage:)]];
    return scroll;
}

- (void)rebuildMessageLines {
    for (NSView *view in self.messageLinesStack.arrangedSubviews.copy) {
        [self.messageLinesStack removeArrangedSubview:view]; [view removeFromSuperview];
    }
    [self.messageLines enumerateObjectsUsingBlock:^(NSString *message, NSUInteger index, BOOL *stop) {
        NSTextField *text = [[NSTextField alloc] initWithFrame:NSZeroRect];
        text.stringValue = message; text.tag = index; text.target = self; text.action = @selector(messageLineChanged:);
        [text.widthAnchor constraintEqualToConstant:480].active = YES;
        NSButton *up = [NSButton buttonWithTitle:@"↑" target:self action:@selector(moveMessage:)];
        up.tag = index; up.identifier = @"up"; up.enabled = index > 0;
        NSButton *down = [NSButton buttonWithTitle:@"↓" target:self action:@selector(moveMessage:)];
        down.tag = index; down.identifier = @"down"; down.enabled = index + 1 < self.messageLines.count;
        NSButton *remove = [NSButton buttonWithTitle:@"−" target:self action:@selector(removeMessage:)];
        remove.tag = index;
        NSStackView *row = [NSStackView stackViewWithViews:@[text, up, down, remove]];
        row.spacing = 6; row.alignment = NSLayoutAttributeCenterY;
        [self.messageLinesStack addArrangedSubview:row];
    }];
}
- (void)messageLineChanged:(NSTextField *)sender {
    if (sender.tag < self.messageLines.count)
        self.messageLines[sender.tag] = MatrixCodeSettingText(sender.stringValue, 120);
    [self draftDidChange];
}
- (void)addMessage:(id)sender {
    if (self.messageLines.count < 12) [self.messageLines addObject:@""];
    [self rebuildMessageLines];
    [self draftDidChange];
}
- (void)removeMessage:(NSButton *)sender {
    if (sender.tag < self.messageLines.count) [self.messageLines removeObjectAtIndex:sender.tag];
    [self rebuildMessageLines];
    [self draftDidChange];
}
- (void)moveMessage:(NSButton *)sender {
    NSInteger destination = sender.tag + ([sender.identifier isEqualToString:@"up"] ? -1 : 1);
    if (destination >= 0 && destination < self.messageLines.count)
        [self.messageLines exchangeObjectAtIndex:sender.tag withObjectAtIndex:destination];
    [self rebuildMessageLines];
    [self draftDidChange];
}
- (void)messageNumberChanged:(NSTextField *)sender {
    double value = sender.doubleValue;
    if ([sender.identifier hasPrefix:@"vertical"]) value = MIN(1, MAX(0, value));
    else {
        BOOL minimumGap = [sender.identifier isEqualToString:@"frequencyMs"] ||
            [sender.identifier isEqualToString:@"persistenceMs"];
        value = MIN(600000, MAX(minimumGap ? 500 : 0, value));
    }
    self.messages[sender.identifier] = @(value);
    [self draftDidChange];
}
- (void)messageToggleChanged:(NSButton *)sender {
    self.messages[sender.identifier] = @(sender.state == NSControlStateValueOn);
    [self draftDidChange];
}

- (NSView *)countdownTab {
    NSStackView *stack;
    NSView *scroll = [self scrollingStack:&stack];
    [stack addArrangedSubview:[self heading:@"Countdowns and Countups"]];
    [stack addArrangedSubview:[NSTextField wrappingLabelWithString:
        @"Use the default target with {countdown}/{countup}, or named moments with {countdown:NAME}."]];
    NSButton *defaultEnabled = [NSButton checkboxWithTitle:@"Enable default target"
                                                    target:self action:@selector(defaultCountdownEnabled:)];
    defaultEnabled.state = [self.countdown[@"targetMs"] isKindOfClass:NSNumber.class]
        ? NSControlStateValueOn : NSControlStateValueOff;
    defaultEnabled.identifier = @"defaultEnabled";
    NSDatePicker *defaultDate = [[NSDatePicker alloc] initWithFrame:NSZeroRect];
    defaultDate.datePickerElements = NSDatePickerElementFlagYearMonthDay |
        NSDatePickerElementFlagHourMinuteSecond;
    defaultDate.dateValue = [self.countdown[@"targetMs"] isKindOfClass:NSNumber.class]
        ? [NSDate dateWithTimeIntervalSince1970:[self.countdown[@"targetMs"] doubleValue] / 1000.0]
        : [NSDate dateWithTimeIntervalSinceNow:3600];
    defaultDate.enabled = [self.countdown[@"targetMs"] isKindOfClass:NSNumber.class];
    defaultDate.identifier = @"defaultDate"; defaultDate.target = self;
    defaultDate.action = @selector(defaultCountdownDateChanged:);
    self.defaultCountdownDatePicker = defaultDate;
    [stack addArrangedSubview:defaultEnabled];
    [stack addArrangedSubview:[self rowWithLabel:@"Default target" control:defaultDate]];
    self.momentsStack = [NSStackView stackViewWithViews:@[]];
    self.momentsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.momentsStack.spacing = 8;
    [stack addArrangedSubview:self.momentsStack];
    [self rebuildMoments];
    [stack addArrangedSubview:[NSButton buttonWithTitle:@"Add Named Moment" target:self action:@selector(addMoment:)]];
    return scroll;
}

- (void)rebuildMoments {
    for (NSView *view in self.momentsStack.arrangedSubviews.copy) {
        [self.momentsStack removeArrangedSubview:view]; [view removeFromSuperview];
    }
    [self.moments enumerateObjectsUsingBlock:^(NSMutableDictionary *moment, NSUInteger index, BOOL *stop) {
        NSTextField *name = [[NSTextField alloc] initWithFrame:NSZeroRect];
        name.placeholderString = @"Name"; name.stringValue = [moment[@"name"] isKindOfClass:NSString.class] ? moment[@"name"] : @"";
        name.tag = index; name.identifier = @"name"; name.target = self; name.action = @selector(momentChanged:);
        [name.widthAnchor constraintEqualToConstant:170].active = YES;
        NSDatePicker *date = [[NSDatePicker alloc] initWithFrame:NSZeroRect];
        date.datePickerElements = NSDatePickerElementFlagYearMonthDay |
            NSDatePickerElementFlagHourMinuteSecond;
        date.dateValue = [moment[@"targetMs"] isKindOfClass:NSNumber.class]
            ? [NSDate dateWithTimeIntervalSince1970:[moment[@"targetMs"] doubleValue] / 1000.0] : NSDate.date;
        date.tag = index; date.identifier = @"date"; date.target = self; date.action = @selector(momentChanged:);
        BOOL targetEnabled = [moment[@"targetMs"] isKindOfClass:NSNumber.class];
        date.enabled = targetEnabled;
        NSButton *enabled = [NSButton checkboxWithTitle:@"Set" target:self action:@selector(momentChanged:)];
        enabled.state = targetEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        enabled.tag = index; enabled.identifier = @"enabled";
        NSButton *up = [NSButton buttonWithTitle:@"↑" target:self action:@selector(moveMoment:)];
        up.tag = index; up.identifier = @"up"; up.enabled = index > 0;
        NSButton *down = [NSButton buttonWithTitle:@"↓" target:self action:@selector(moveMoment:)];
        down.tag = index; down.identifier = @"down"; down.enabled = index + 1 < self.moments.count;
        NSButton *remove = [NSButton buttonWithTitle:@"−" target:self action:@selector(removeMoment:)];
        remove.tag = index;
        NSStackView *row = [NSStackView stackViewWithViews:@[
            name, enabled, date, up, down, remove
        ]];
        row.spacing = 8; row.alignment = NSLayoutAttributeCenterY;
        [self.momentsStack addArrangedSubview:row];
    }];
}
- (void)defaultCountdownEnabled:(NSButton *)sender {
    self.countdown[@"targetMs"] = sender.state == NSControlStateValueOn
        ? @(self.defaultCountdownDatePicker.dateValue.timeIntervalSince1970 * 1000.0)
        : NSNull.null;
    self.defaultCountdownDatePicker.enabled = sender.state == NSControlStateValueOn;
    [self draftDidChange];
}
- (void)defaultCountdownDateChanged:(NSDatePicker *)sender {
    self.countdown[@"targetMs"] = @(sender.dateValue.timeIntervalSince1970 * 1000.0);
    [self draftDidChange];
}
- (void)addMoment:(id)sender {
    if (self.moments.count < 12) [self.moments addObject:
        [@{@"name": @"", @"targetMs": NSNull.null} mutableCopy]];
    [self rebuildMoments];
    [self draftDidChange];
}
- (void)moveMoment:(NSButton *)sender {
    NSInteger destination = sender.tag + ([sender.identifier isEqualToString:@"up"] ? -1 : 1);
    if (destination >= 0 && destination < self.moments.count)
        [self.moments exchangeObjectAtIndex:sender.tag withObjectAtIndex:destination];
    [self rebuildMoments];
    [self draftDidChange];
}
- (void)removeMoment:(NSButton *)sender {
    if (sender.tag < self.moments.count) [self.moments removeObjectAtIndex:sender.tag];
    [self rebuildMoments];
    [self draftDidChange];
}
- (void)momentChanged:(id)sender {
    NSInteger index = [sender tag];
    if (index >= self.moments.count) return;
    if ([[sender identifier] isEqualToString:@"name"]) {
        NSString *name = MatrixCodeSettingText([sender stringValue], 40);
        NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@":{}"];
        name = [[name componentsSeparatedByCharactersInSet:illegal] componentsJoinedByString:@""];
        self.moments[index][@"name"] = [name stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    } else if ([[sender identifier] isEqualToString:@"enabled"]) {
        BOOL enabled = [sender state] == NSControlStateValueOn;
        NSDatePicker *datePicker = nil;
        for (NSView *view in [sender superview].subviews) {
            if ([view isKindOfClass:NSDatePicker.class]) datePicker = (NSDatePicker *)view;
        }
        self.moments[index][@"targetMs"] = enabled && datePicker
            ? @(datePicker.dateValue.timeIntervalSince1970 * 1000.0) : NSNull.null;
        [self rebuildMoments];
    } else {
        self.moments[index][@"targetMs"] = @([[sender dateValue] timeIntervalSince1970] * 1000.0);
    }
    [self draftDidChange];
}

- (NSDictionary<NSString *, NSString *> *)serializedValues {
    NSMutableDictionary *values = [self.stagedValues mutableCopy];
    values[@"mx-controls"] = MatrixCodeJSONString(self.controls);
    self.intro[@"lines"] = self.introLines;
    values[@"mx-intro"] = MatrixCodeJSONString(self.intro);
    NSMutableArray<NSString *> *sanitizedMessages = [NSMutableArray array];
    for (NSUInteger index = 0; index < MIN((NSUInteger)12, self.messageLines.count); index++) {
        NSString *message = MatrixCodeSettingText(self.messageLines[index], 120);
        if ([message stringByTrimmingCharactersInSet:
             NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
            [sanitizedMessages addObject:message];
        }
    }
    self.messages[@"messages"] = sanitizedMessages;
    values[@"mx-messages"] = MatrixCodeJSONString(self.messages);
    NSMutableArray<NSDictionary *> *sanitizedMoments = [NSMutableArray array];
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    for (NSUInteger index = 0; index < MIN((NSUInteger)12, self.moments.count); index++) {
        NSDictionary *moment = self.moments[index];
        NSString *name = MatrixCodeSettingText(moment[@"name"], 40);
        name = [[name componentsSeparatedByCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@":{}"]]
            componentsJoinedByString:@""];
        name = [name stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length || [names containsObject:name]) continue;
        [names addObject:name];
        NSNumber *target = [moment[@"targetMs"] isKindOfClass:NSNumber.class] &&
            CFGetTypeID((__bridge CFTypeRef)moment[@"targetMs"]) != CFBooleanGetTypeID() &&
            isfinite([moment[@"targetMs"] doubleValue])
            ? @(fmin(8.64e15, fmax(0, [moment[@"targetMs"] doubleValue])))
            : nil;
        [sanitizedMoments addObject:@{
            @"name": name, @"targetMs": target ?: NSNull.null,
        }];
    }
    self.countdown[@"moments"] = sanitizedMoments;
    values[@"mx-countdown"] = MatrixCodeJSONString(self.countdown);
    return values;
}

- (void)showPreviewWithIntro:(BOOL)intro message:(BOOL)message {
    NSDictionary *values = [self serializedValues];
    self.previewController = [[MatrixCodeNativePreviewController alloc]
        initWithStoredValues:values showIntro:intro showMessage:message];
    [self.previewController showWindow:nil];
    [self.previewController.window makeKeyAndOrderFront:nil];
}
- (void)previewRain:(id)sender { [self showPreviewWithIntro:NO message:NO]; }
- (void)previewIntro:(id)sender { [self showPreviewWithIntro:YES message:NO]; }
- (void)previewMessage:(id)sender { [self showPreviewWithIntro:NO message:YES]; }

- (void)resetAll:(id)sender {
    [self.stagedValues removeAllObjects];
    [self loadModels];
    for (NSView *view in self.window.contentView.subviews.copy) [view removeFromSuperview];
    [self buildInterface];
    [self draftDidChange];
}

- (void)accept:(id)sender {
    NSDictionary *values = [self serializedValues];
    [self.preferences commitValues:values];
    [self publishPreviewValues:values];
    [NSApp endSheet:self.window returnCode:NSModalResponseOK];
    self.closeHandler();
}

- (void)cancel:(id)sender {
    [self publishPreviewValues:self.originalValues];
    [NSApp endSheet:self.window returnCode:NSModalResponseCancel];
    self.closeHandler();
}

@end
