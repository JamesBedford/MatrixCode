#import "MatrixCodeConfigurationController.h"

#import "MatrixCodeIntroOverlayView.h"
#import "MatrixCodeMetalView.h"
#import "MatrixCodeConstants.h"
#import "MatrixCodePreferences.h"
#import "MatrixCodeSettingsTheme.h"
#import "MatrixCodeTokenResolver.h"

#import <QuartzCore/QuartzCore.h>

NSNotificationName const MatrixCodePreviewValuesDidChangeNotification =
    @"MatrixCodePreviewValuesDidChangeNotification";
NSString * const MatrixCodePreviewValuesKey = @"values";

static const NSTimeInterval MatrixCodeSettingsFadeDuration = 0.24;
static const NSTimeInterval MatrixCodeSettingsHideDelay = 2.8;
static const CGFloat MatrixCodeSettingsPanelWidth = 320.0;
static const CGFloat MatrixCodeSettingsPanelContentWidth = 284.0;
static const CGFloat MatrixCodeSettingsPanelInset = 16.0;
static const CGFloat MatrixCodeEditorCardWidth = 620.0;
static const CGFloat MatrixCodeEditorCardMaxHeight = 610.0;
static const CGFloat MatrixCodeEditorCardVerticalMargin = 48.0;
static const NSUInteger MatrixCodeImageMaskMaxDimension = 96;
static const NSUInteger MatrixCodeImageMaskMaxStoredCharacters = 49152;

static NSRect MatrixCodeFramePinnedToSuperviewEdges(NSView *superview, NSEdgeInsets insets) {
    if (!superview) return NSZeroRect;
    NSRect bounds = superview.bounds;
    CGFloat width = fmax(0, NSWidth(bounds) - insets.left - insets.right);
    CGFloat height = fmax(0, NSHeight(bounds) - insets.top - insets.bottom);
    return NSMakeRect(insets.left, insets.bottom, width, height);
}

static void MatrixCodeSyncPinnedViewToSuperviewEdges(NSView *view,
                                                     NSView *superview,
                                                     NSEdgeInsets insets) {
    if (!view || !superview) return;
    view.frame = MatrixCodeFramePinnedToSuperviewEdges(superview, insets);
    [view setNeedsLayout:YES];
}

static void MatrixCodePinViewToSuperviewEdges(NSView *view,
                                               NSView *superview,
                                               NSEdgeInsets insets) {
    if (!view || !superview) return;
    view.translatesAutoresizingMaskIntoConstraints = YES;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    MatrixCodeSyncPinnedViewToSuperviewEdges(view, superview, insets);
}

static void MatrixCodeSyncSettingsPanelFrame(NSView *panel, NSView *overlay) {
    if (!panel || !overlay) return;
    CGFloat height = fmax(0, NSHeight(overlay.bounds) - MatrixCodeSettingsPanelInset * 2.0);
    panel.frame = NSMakeRect(MatrixCodeSettingsPanelInset,
                             MatrixCodeSettingsPanelInset,
                             MatrixCodeSettingsPanelWidth,
                             height);
    [panel setNeedsLayout:YES];
}

static void MatrixCodePinSettingsPanelToOverlay(NSView *panel, NSView *overlay) {
    if (!panel || !overlay) return;
    panel.translatesAutoresizingMaskIntoConstraints = YES;
    panel.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
    MatrixCodeSyncSettingsPanelFrame(panel, overlay);
}

static void MatrixCodeSyncEditorCardFrame(NSView *card, NSView *backdrop) {
    if (!card || !backdrop) return;
    CGFloat width = MatrixCodeEditorCardWidth;
    CGFloat height = fmin(MatrixCodeEditorCardMaxHeight,
                          fmax(0, NSHeight(backdrop.bounds) - MatrixCodeEditorCardVerticalMargin));
    card.frame = NSMakeRect((NSWidth(backdrop.bounds) - width) * 0.5,
                            (NSHeight(backdrop.bounds) - height) * 0.5,
                            width,
                            height);
    [card setNeedsLayout:YES];
}

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

static NSNumber *MatrixCodeSettingBoolObject(BOOL value) {
    return (__bridge NSNumber *)(value ? kCFBooleanTrue : kCFBooleanFalse);
}

static NSString *MatrixCodeSettingText(id value, NSUInteger maximumLength) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *text = value;
    return [text substringToIndex:MIN(maximumLength, text.length)];
}

static NSString *MatrixCodeSettingChoice(NSDictionary *dictionary,
                                         NSString *key,
                                         NSArray<NSString *> *allowed,
                                         NSString *fallback) {
    id value = dictionary[key];
    return [value isKindOfClass:NSString.class] && [allowed containsObject:value]
        ? value : fallback;
}

static BOOL MatrixCodeIsValidIndex(NSInteger index, NSUInteger count) {
    return index >= 0 && (NSUInteger)index < count;
}

static BOOL MatrixCodePreferredMirrorForGlyphMode(NSString *glyphMode) {
    return [glyphMode isEqualToString:@"matrix"] ||
        [glyphMode isEqualToString:@"katakana"];
}

static NSMutableDictionary *MatrixCodeSanitizedImageItem(NSDictionary *item) {
    if (![item isKindOfClass:NSDictionary.class]) return nil;
    NSInteger width = (NSInteger)MatrixCodeSettingNumber(item, @"width", 0, 1, MatrixCodeImageMaskMaxDimension);
    NSInteger height = (NSInteger)MatrixCodeSettingNumber(item, @"height", 0, 1, MatrixCodeImageMaskMaxDimension);
    NSString *data = MatrixCodeSettingText(item[@"data"], MatrixCodeImageMaskMaxStoredCharacters);
    NSData *mask = [[NSData alloc] initWithBase64EncodedString:data options:0];
    if (width <= 0 || height <= 0 || mask.length != (NSUInteger)(width * height)) return nil;
    NSString *name = MatrixCodeSettingText(item[@"name"], 80);
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length) name = @"Image";
    return [@{
        @"name": name,
        @"width": @(width),
        @"height": @(height),
        @"data": data,
    } mutableCopy];
}

@interface MatrixCodeFlippedDocumentView : NSView
@end

@implementation MatrixCodeFlippedDocumentView

- (BOOL)isFlipped {
    return YES;
}

@end

@interface MatrixCodeSettingsHoverView : NSView
@property(nonatomic, copy) dispatch_block_t activityHandler;
@property(nonatomic, copy) dispatch_block_t exitHandler;
@end

@implementation MatrixCodeSettingsHoverView {
    NSTrackingArea *_trackingArea;
}

- (void)updateTrackingAreas {
    if (_trackingArea) [self removeTrackingArea:_trackingArea];
    _trackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited |
                     NSTrackingMouseMoved |
                     NSTrackingActiveInKeyWindow |
                     NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:_trackingArea];
    [super updateTrackingAreas];
}

- (NSView *)hitTest:(NSPoint)point {
    for (NSView *subview in self.subviews.reverseObjectEnumerator) {
        if (subview.hidden || subview.alphaValue <= 0.01) continue;
        NSPoint converted = [self convertPoint:point toView:subview];
        NSView *hit = [self interactiveHitInsideView:subview atPoint:converted];
        if (hit) return hit;
    }
    return nil;
}

- (NSView *)interactiveHitInsideView:(NSView *)view atPoint:(NSPoint)point {
    if (view.hidden || view.alphaValue <= 0.01 || !NSPointInRect(point, view.bounds)) return nil;
    for (NSView *subview in view.subviews.reverseObjectEnumerator) {
        NSPoint converted = [view convertPoint:point toView:subview];
        NSView *hit = [self interactiveHitInsideView:subview atPoint:converted];
        if (hit) return hit;
    }
    if ([view isKindOfClass:NSControl.class] || [view isKindOfClass:NSScrollView.class]) {
        return [view hitTest:point] ?: view;
    }
    return nil;
}

- (void)mouseEntered:(NSEvent *)event {
    if (self.activityHandler) self.activityHandler();
}

- (void)mouseMoved:(NSEvent *)event {
    if (self.activityHandler) self.activityHandler();
}

- (void)mouseDown:(NSEvent *)event {
    if (self.activityHandler) self.activityHandler();
    [super mouseDown:event];
}

- (void)mouseExited:(NSEvent *)event {
    if (self.exitHandler) self.exitHandler();
}

@end

@interface MatrixCodeSettingsBackdropView : NSView
@end

@implementation MatrixCodeSettingsBackdropView

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    // Custom settings editors are dismissed by explicit buttons or Escape.
    // Background clicks should be absorbed so accidental misses do not close them.
}

@end

@interface MatrixCodeNativePreviewController : NSWindowController <NSWindowDelegate>
@property(nonatomic, strong) MatrixCodeMetalView *metalView;
@property(nonatomic, strong) MatrixCodeIntroOverlayView *introView;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSDate *startDate;
@property(nonatomic) BOOL showsIntro;
@property(nonatomic) BOOL showsMessage;
@property(nonatomic) BOOL showsImage;
@end

@implementation MatrixCodeNativePreviewController

- (instancetype)initWithStoredValues:(NSDictionary<NSString *, NSString *> *)values
                           showIntro:(BOOL)showIntro
                         showMessage:(BOOL)showMessage
                           showImage:(BOOL)showImage {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 500)
                                                  styleMask:NSWindowStyleMaskTitled |
                                                            NSWindowStyleMaskClosable |
                                                            NSWindowStyleMaskResizable
                                                    backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Matrix Code Preview";
    window.minSize = NSMakeSize(480, 300);
    self = [super initWithWindow:window];
    if (!self) return nil;
    window.delegate = self;
    _showsIntro = showIntro;
    _showsMessage = showMessage;
    _showsImage = showImage;
    _startDate = NSDate.date;
    NSDictionary *previewValues = [self previewValuesFromValues:values];
    _metalView = [[MatrixCodeMetalView alloc] initWithFrame:window.contentView.bounds
                                                    session:nil
                                               storedValues:previewValues];
    [window.contentView addSubview:_metalView];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:previewValues runStartDate:_startDate];
    _introView = [[MatrixCodeIntroOverlayView alloc] initWithFrame:window.contentView.bounds
                                                     storedValues:previewValues
                                                    tokenResolver:resolver
                                                       completion:^{}];
    if (showIntro) {
        [window.contentView addSubview:_introView positioned:NSWindowAbove relativeTo:_metalView];
        [_introView startAtDate:_startDate];
        __weak typeof(self) weakSelf = self;
        _metalView.frameHandler =
            ^(MatrixCodeMetalView *view, NSDate *date, double framesPerSecond) {
            [weakSelf.introView updateAtDate:date framesPerSecond:framesPerSecond];
        };
    }
    [_metalView setAnimationActive:YES];
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
    if (self.showsImage) {
        NSMutableDictionary *images =
            [MatrixCodeJSONObject(previewValues[@"mx-images"], NSDictionary.class) mutableCopy];
        if (!images) images = [NSMutableDictionary dictionary];
        images[@"enabled"] = @YES;
        images[@"frequencyMs"] = @500;
        previewValues[@"mx-images"] = MatrixCodeJSONString(images);
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
    self.metalView.frameHandler = nil;
    [self.metalView setAnimationActive:NO];
}

- (void)dealloc {
    _metalView.frameHandler = nil;
    [_metalView setAnimationActive:NO];
}

@end

@interface MatrixCodeConfigurationController () <NSTextFieldDelegate>
@property(nonatomic, strong) MatrixCodePreferences *preferences;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *stagedValues;
@property(nonatomic, strong) NSMutableDictionary *controls;
@property(nonatomic, strong) NSMutableDictionary *intro;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *introLines;
@property(nonatomic, strong) NSMutableDictionary *messages;
@property(nonatomic, strong) NSMutableArray<NSString *> *messageLines;
@property(nonatomic, strong) NSMutableDictionary *images;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *imageItems;
@property(nonatomic, strong) NSMutableDictionary *countdown;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *moments;
@property(nonatomic, copy) dispatch_block_t closeHandler;
@property(nonatomic, strong) NSStackView *introLinesStack;
@property(nonatomic, strong) NSStackView *messageLinesStack;
@property(nonatomic, strong) NSStackView *imageItemsStack;
@property(nonatomic, strong) NSStackView *momentsStack;
@property(nonatomic, strong) MatrixCodeNativePreviewController *previewController;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *originalValues;
@property(nonatomic, strong) NSMutableSet<NSString *> *explicitlyClearedStorageKeys;
@property(nonatomic, strong) NSTextField *postIntroDelayField;
@property(nonatomic, strong) NSDatePicker *defaultCountdownDatePicker;
@property(nonatomic, strong) NSButton *mirrorButton;
@property(nonatomic, strong) NSView *editorBackdrop;
@property(nonatomic, strong) NSView *editorCard;
@property(nonatomic, copy) NSString *editorKind;
@property(nonatomic, copy) NSDictionary *editorSnapshot;
@property(nonatomic, strong) NSTextField *panelNameField;
@property(nonatomic, strong) MatrixCodeMetalView *settingsMetalView;
@property(nonatomic, strong) NSTimer *settingsAnimationTimer;
@property(nonatomic, strong) MatrixCodeSettingsHoverView *settingsOverlayView;
@property(nonatomic, strong) NSView *settingsPanel;
@property(nonatomic, strong) NSTimer *settingsHideTimer;
@property(nonatomic, strong) MatrixCodeMetalView *charactersPreviewView;
@property(nonatomic) BOOL settingsPanelVisible;
@property(nonatomic, weak) NSView *embeddedHostView;
@property(nonatomic) BOOL embeddedPresentation;
@end

@implementation MatrixCodeConfigurationController

- (instancetype)initWithCloseHandler:(dispatch_block_t)closeHandler {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 920, 700)
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                                    backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Matrix Code Options";
    window.minSize = NSMakeSize(700, 560);
    window.acceptsMouseMovedEvents = YES;
    self = [super initWithWindow:window];
    if (!self) return nil;
    _preferences = [[MatrixCodePreferences alloc] init];
    _stagedValues = [[_preferences storedValues] mutableCopy];
    _originalValues = [_stagedValues copy];
    _explicitlyClearedStorageKeys = [NSMutableSet set];
    _closeHandler = [closeHandler copy];
    [self loadModels];
    [self buildInterface];
    return self;
}

- (instancetype)initEmbeddedInView:(NSView *)hostView closeHandler:(dispatch_block_t)closeHandler {
    self = [super initWithWindow:nil];
    if (!self) return nil;
    _embeddedHostView = hostView;
    _embeddedPresentation = YES;
    _preferences = [[MatrixCodePreferences alloc] init];
    _stagedValues = [[_preferences storedValues] mutableCopy];
    _originalValues = [_stagedValues copy];
    _explicitlyClearedStorageKeys = [NSMutableSet set];
    _closeHandler = [closeHandler copy];
    [self loadModels];
    [self buildInterface];
    return self;
}

- (NSView *)presentationContentView {
    return self.embeddedPresentation ? self.embeddedHostView : self.window.contentView;
}

- (void)refreshEmbeddedPresentationLayout {
    if (!self.embeddedPresentation) return;
    NSView *root = [self presentationContentView];
    if (!root) return;
    if (self.settingsOverlayView.superview == root) {
        MatrixCodeSyncPinnedViewToSuperviewEdges(self.settingsOverlayView,
                                                 root,
                                                 NSEdgeInsetsMake(0, 0, 0, 0));
        MatrixCodeSyncSettingsPanelFrame(self.settingsPanel, self.settingsOverlayView);
    }
    if (self.editorBackdrop.superview == root) {
        MatrixCodeSyncPinnedViewToSuperviewEdges(self.editorBackdrop,
                                                 root,
                                                 NSEdgeInsetsMake(0, 0, 0, 0));
        MatrixCodeSyncEditorCardFrame(self.editorCard, self.editorBackdrop);
    }
}

- (void)publishPreviewValues:(NSDictionary<NSString *, NSString *> *)values {
    [self.settingsMetalView reloadStoredValues:values];
    [self.settingsMetalView draw];
    [self redrawCharactersPreviewWithValues:values];
    [self.previewController reloadStoredValues:values];
    [NSNotificationCenter.defaultCenter
        postNotificationName:MatrixCodePreviewValuesDidChangeNotification
                      object:self
                    userInfo:@{MatrixCodePreviewValuesKey: values}];
}

- (void)draftDidChange {
    NSDictionary *values = [self serializedValues];
    if (!self.editorBackdrop) {
        values = [self commitSerializedValues:values];
    }
    [self publishPreviewValues:values];
}

- (BOOL)originalValueForKey:(NSString *)key
    matchesSerializedValues:(NSDictionary<NSString *, NSString *> *)values {
    NSString *original = self.originalValues[key];
    NSString *serialized = values[key];
    return original == serialized || (original && serialized && [original isEqualToString:serialized]);
}

- (NSDictionary<NSString *, NSString *> *)valuesForCommitFromSerializedValues:
    (NSDictionary<NSString *, NSString *> *)values {
    NSMutableDictionary<NSString *, NSString *> *merged = [[self.preferences storedValues] mutableCopy];
    for (NSString *key in MatrixCodeStorageKeys()) {
        BOOL changed = ![self originalValueForKey:key matchesSerializedValues:values] ||
            [self.explicitlyClearedStorageKeys containsObject:key];
        if (!changed) continue;
        NSString *value = values[key];
        if ([value isKindOfClass:NSString.class]) merged[key] = value;
        else [merged removeObjectForKey:key];
    }
    return merged;
}

- (NSDictionary<NSString *, NSString *> *)commitSerializedValues:
    (NSDictionary<NSString *, NSString *> *)values {
    NSDictionary<NSString *, NSString *> *committed =
        [self valuesForCommitFromSerializedValues:values];
    [self.preferences commitValues:committed];
    self.stagedValues = [committed mutableCopy];
    self.originalValues = [committed copy];
    [self.explicitlyClearedStorageKeys removeAllObjects];
    return committed;
}

- (BOOL)settingsPanelContainsMouse {
    NSWindow *window = self.settingsPanel.window ?: self.window;
    if (!self.settingsPanel || self.settingsPanel.hidden || !window) return NO;
    NSPoint windowPoint = window.mouseLocationOutsideOfEventStream;
    NSPoint panelPoint = [self.settingsPanel convertPoint:windowPoint fromView:nil];
    return NSPointInRect(panelPoint, self.settingsPanel.bounds);
}

- (void)scheduleSettingsPanelHide {
    [self.settingsHideTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.settingsHideTimer =
        [NSTimer scheduledTimerWithTimeInterval:MatrixCodeSettingsHideDelay
                                        repeats:NO
                                          block:^(NSTimer *timer) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (self.editorBackdrop || [self settingsPanelContainsMouse]) {
            [self scheduleSettingsPanelHide];
            return;
        }
        [self setSettingsPanelVisible:NO immediate:NO];
    }];
}

- (void)setSettingsPanelVisible:(BOOL)visible immediate:(BOOL)immediate {
    self.settingsPanelVisible = visible;
    if (visible) {
        self.settingsPanel.hidden = NO;
    } else {
        [self.settingsHideTimer invalidate];
        self.settingsHideTimer = nil;
    }

    void (^changes)(void) = ^{
        self.settingsPanel.alphaValue = visible ? 1.0 : 0.0;
    };
    void (^completion)(void) = ^{
        if (!self.settingsPanelVisible) {
            self.settingsPanel.hidden = YES;
        }
    };

    if (immediate) {
        changes();
        completion();
    } else {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = MatrixCodeSettingsFadeDuration;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            self.settingsPanel.animator.alphaValue = visible ? 1.0 : 0.0;
        } completionHandler:completion];
    }

    if (visible) [self scheduleSettingsPanelHide];
}

- (void)settingsPointerActivity {
    [self setSettingsPanelVisible:YES immediate:NO];
}

- (void)showSettingsPanel {
    [self settingsPointerActivity];
}

- (void)loadModels {
    NSDictionary *storedControls =
        MatrixCodeJSONObject(self.stagedValues[@"mx-controls"], NSDictionary.class) ?: @{};
    NSMutableDictionary *controls = [@{
        @"speed": @1, @"trailLength": @0.255, @"trailVariation": @1,
        @"density": @2, @"rampUpMs": @8000,
        @"glyphRate": @1, @"glyphScale": @1, @"glow": @0.9, @"leadBrightness": @1.6,
        @"glyphMode": @"matrix", @"glyphFont": @"matrix", @"preset": @"classic", @"mirror": @YES, @"scanlines": @NO, @"vignette": @0,
        @"allowOverlap": @YES, @"quality": @"high",
    } mutableCopy];
    NSArray *controlNumbers = @[
        @[@"speed", @0.1, @3], @[@"trailLength", @0.01, @0.5],
        @[@"trailVariation", @0, @1],
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
        controls[key] = MatrixCodeSettingBoolObject(
            MatrixCodeSettingBool(storedControls, key, [controls[key] boolValue]));
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
        @"rainDuringIntro": MatrixCodeSettingBoolObject(
            MatrixCodeSettingBool(storedIntro, @"rainDuringIntro", NO)),
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
        @"enabled": MatrixCodeSettingBoolObject(
            MatrixCodeSettingBool(storedMessageDoc, @"enabled", NO)),
        @"frequencyMs": @(MatrixCodeSettingNumber(storedMessageDoc, @"frequencyMs", 8000, 500, 600000)),
        @"persistenceMs": @(MatrixCodeSettingNumber(storedMessageDoc, @"persistenceMs", 10000, 500, 600000)),
        @"appearMs": @(MatrixCodeSettingNumber(storedMessageDoc, @"appearMs", 4000, 0, 600000)),
        @"disappearMs": @(MatrixCodeSettingNumber(storedMessageDoc, @"disappearMs", 4000, 0, 600000)),
        @"flickerOut": MatrixCodeSettingBoolObject(
            MatrixCodeSettingBool(storedMessageDoc, @"flickerOut", YES)),
        @"brightnessFade": MatrixCodeSettingBoolObject(
            MatrixCodeSettingBool(storedMessageDoc, @"brightnessFade", NO)),
        @"messageLayout": MatrixCodeSettingChoice(storedMessageDoc, @"messageLayout",
                                                  @[@"row", @"drop"], @"row"),
        @"messageDirection": MatrixCodeSettingChoice(storedMessageDoc, @"messageDirection",
                                                     @[@"topToBottom", @"bottomToTop"], @"topToBottom"),
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

    NSDictionary *storedImages =
        MatrixCodeJSONObject(self.stagedValues[@"mx-images"], NSDictionary.class) ?: @{};
    self.images = [@{
        @"enabled": MatrixCodeSettingBoolObject(
            MatrixCodeSettingBool(storedImages, @"enabled", NO)),
        @"frequencyMs": @(MatrixCodeSettingNumber(storedImages, @"frequencyMs", 14000, 500, 600000)),
        @"persistenceMs": @(MatrixCodeSettingNumber(storedImages, @"persistenceMs", 12000, 500, 600000)),
        @"appearMs": @(MatrixCodeSettingNumber(storedImages, @"appearMs", 4500, 0, 600000)),
        @"disappearMs": @(MatrixCodeSettingNumber(storedImages, @"disappearMs", 4500, 0, 600000)),
        @"flickerOut": MatrixCodeSettingBoolObject(
            MatrixCodeSettingBool(storedImages, @"flickerOut", YES)),
        @"brightnessFade": MatrixCodeSettingBoolObject(
            MatrixCodeSettingBool(storedImages, @"brightnessFade", NO)),
        @"imageScale": @(MatrixCodeSettingNumber(storedImages, @"imageScale", 0.72, 0.05, 1)),
        @"imagePlacementJitter": @(MatrixCodeSettingNumber(storedImages, @"imagePlacementJitter", 0.35, 0, 1)),
    } mutableCopy];
    self.imageItems = [NSMutableArray array];
    NSArray *storedImageItems = [storedImages[@"images"] isKindOfClass:NSArray.class]
        ? storedImages[@"images"] : @[];
    for (NSUInteger index = 0; index < storedImageItems.count; index++) {
        NSMutableDictionary *image = MatrixCodeSanitizedImageItem(storedImageItems[index]);
        if (image) [self.imageItems addObject:image];
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
        initWithFrame:NSMakeRect(0, 0, 600, 700)];
    [document addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:document.topAnchor],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:document.bottomAnchor],
        [stack.widthAnchor constraintGreaterThanOrEqualToConstant:560],
    ]];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.documentView = document;
    if (stackOut) *stackOut = stack;
    return scroll;
}

- (void)buildInterface {
    NSView *content = [self presentationContentView];
    if (!content) return;
    content.window.acceptsMouseMovedEvents = YES;
    MatrixCodeSettingsTheme *theme = MatrixCodeSettingsTheme.sharedTheme;
    theme.presetName = [self.controls[@"preset"] isKindOfClass:NSString.class]
        ? self.controls[@"preset"] : @"classic";
    [self.settingsAnimationTimer invalidate];
    self.settingsAnimationTimer = nil;
    self.settingsMetalView = nil;
    if (!self.embeddedPresentation) {
        content.wantsLayer = YES;
        content.layer.backgroundColor = theme.backgroundColor.CGColor;
        self.settingsMetalView = [[MatrixCodeMetalView alloc] initWithFrame:content.bounds
                                                                    session:nil
                                                               storedValues:[self serializedValues]];
        self.settingsMetalView.translatesAutoresizingMaskIntoConstraints = NO;
        self.settingsMetalView.identifier = @"settings-rain-backdrop";
        [self.settingsMetalView setAnimationActive:YES];
        [content addSubview:self.settingsMetalView];
    }

    MatrixCodeSettingsHoverView *overlay = [[MatrixCodeSettingsHoverView alloc] initWithFrame:NSZeroRect];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.identifier = @"settings-hover-overlay";
    __weak typeof(self) weakSelfForHover = self;
    overlay.activityHandler = ^{
        [weakSelfForHover settingsPointerActivity];
    };
    overlay.exitHandler = ^{
        [weakSelfForHover scheduleSettingsPanelHide];
    };

    NSView *panel = [self controlsPanel];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
    [overlay addSubview:panel];
    self.settingsOverlayView = overlay;
    self.settingsPanel = panel;
    MatrixCodePinViewToSuperviewEdges(overlay, content, NSEdgeInsetsMake(0, 0, 0, 0));
    MatrixCodePinSettingsPanelToOverlay(panel, overlay);
    if (self.settingsMetalView) {
        MatrixCodePinViewToSuperviewEdges(self.settingsMetalView, content, NSEdgeInsetsMake(0, 0, 0, 0));
    }
    [self setSettingsPanelVisible:YES immediate:YES];
    [self refreshEmbeddedPresentationLayout];
}

- (NSFont *)settingsFontOfSize:(CGFloat)size weight:(NSFontWeight)weight {
    return [MatrixCodeSettingsTheme.sharedTheme monospacedFontOfSize:size weight:weight];
}

- (void)styleLabel:(NSTextField *)label uppercase:(BOOL)uppercase {
    if (uppercase) [MatrixCodeSettingsTheme.sharedTheme styleLabel:label];
    else {
        label.font = [self settingsFontOfSize:11 weight:NSFontWeightRegular];
        label.textColor = MatrixCodeSettingsTheme.sharedTheme.accentColor;
    }
}

- (void)styleButton:(NSButton *)button {
    [MatrixCodeSettingsTheme.sharedTheme styleButton:button];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:30].active = YES;
}

- (NSButton *)settingsButton:(NSString *)title action:(SEL)action identifier:(NSString *)identifier {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.identifier = identifier;
    [self styleButton:button];
    return button;
}

- (NSView *)panelFlexibleSpacer {
    NSView *spacer = [[NSView alloc] initWithFrame:NSZeroRect];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [spacer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    return spacer;
}

- (NSPopUpButton *)settingsPopupWithIdentifier:(NSString *)identifier
                                 selectedValue:(NSString *)selectedValue
                                         items:(NSArray<NSArray<NSString *> *> *)items
                                        action:(SEL)action {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSArray<NSString *> *item in items) {
        [popup addItemWithTitle:item[0]];
        popup.lastItem.representedObject = item[1];
        if ([item[1] isEqualToString:selectedValue]) [popup selectItem:popup.lastItem];
    }
    popup.identifier = identifier;
    popup.target = self;
    popup.action = action;
    [MatrixCodeSettingsTheme.sharedTheme stylePopupButton:popup];
    return popup;
}

- (NSView *)panelSlider:(NSString *)label
                    key:(NSString *)key
                    min:(double)minimum
                    max:(double)maximum {
    NSTextField *name = [NSTextField labelWithString:label];
    name.identifier = [key stringByAppendingString:@"-label"];
    [self styleLabel:name uppercase:YES];
    NSSlider *slider = [NSSlider sliderWithValue:[self.controls[key] doubleValue]
                                        minValue:minimum
                                        maxValue:maximum
                                          target:self
                                          action:@selector(controlChanged:)];
    slider.identifier = key;
    slider.continuous = YES;
    NSTextField *value = [NSTextField labelWithString:[self displayValueForSlider:slider]];
    value.identifier = [key stringByAppendingString:@"-value"];
    value.alignment = NSTextAlignmentRight;
    [MatrixCodeSettingsTheme.sharedTheme styleSlider:slider readout:value];
    [value.widthAnchor constraintEqualToConstant:58].active = YES;
    NSStackView *header = [NSStackView stackViewWithViews:@[name, [self panelFlexibleSpacer], value]];
    header.distribution = NSStackViewDistributionFill;
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 8;
    NSStackView *row = [NSStackView stackViewWithViews:@[header, slider]];
    row.orientation = NSUserInterfaceLayoutOrientationVertical;
    row.alignment = NSLayoutAttributeLeading;
    row.spacing = 3;
    row.identifier = [@"row-" stringByAppendingString:key];
    [row.widthAnchor constraintEqualToConstant:MatrixCodeSettingsPanelContentWidth].active = YES;
    [header.widthAnchor constraintEqualToConstant:MatrixCodeSettingsPanelContentWidth].active = YES;
    [slider.widthAnchor constraintEqualToConstant:MatrixCodeSettingsPanelContentWidth].active = YES;
    return row;
}

- (NSView *)panelInlineRow:(NSString *)label control:(NSView *)control {
    NSTextField *name = [NSTextField labelWithString:label];
    [self styleLabel:name uppercase:YES];
    NSStackView *row = [NSStackView stackViewWithViews:@[name, [self panelFlexibleSpacer], control]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.distribution = NSStackViewDistributionFill;
    row.spacing = 8;
    [row.widthAnchor constraintEqualToConstant:MatrixCodeSettingsPanelContentWidth].active = YES;
    return row;
}

- (NSButton *)panelToggle:(NSString *)label key:(NSString *)key {
    NSButton *button = [NSButton buttonWithTitle:label target:self action:@selector(controlChanged:)];
    button.identifier = key;
    button.buttonType = NSButtonTypeToggle;
    [MatrixCodeSettingsTheme.sharedTheme styleToggleButton:button on:[self.controls[key] boolValue]];
    [button.widthAnchor constraintEqualToConstant:54].active = YES;
    return button;
}

- (NSPopUpButton *)panelPopup:(NSString *)identifier
                         items:(NSArray<NSArray<NSString *> *> *)items {
    NSString *selectedValue = [self.controls[identifier] isKindOfClass:NSString.class]
        ? self.controls[identifier] : @"";
    return [self settingsPopupWithIdentifier:identifier
                               selectedValue:selectedValue
                                       items:items
                                      action:@selector(controlChanged:)];
}

- (NSView *)controlsPanel {
    MatrixCodeSettingsPanelView *surface = [[MatrixCodeSettingsPanelView alloc] initWithFrame:NSZeroRect];
    surface.identifier = @"settings-panel";

    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 9;
    stack.edgeInsets = NSEdgeInsetsMake(16, 18, 18, 18);

    NSTextField *title = [NSTextField labelWithString:@"MATRIX"];
    title.identifier = @"settings-title";
    [MatrixCodeSettingsTheme.sharedTheme styleHeading:title level:1];
    [stack addArrangedSubview:title];
    [stack setCustomSpacing:10 afterView:title];

    NSTextField *name = [[NSTextField alloc] initWithFrame:NSZeroRect];
    name.placeholderString = @"Neo";
    name.stringValue = self.stagedValues[@"mx-user-name"] ?: @"";
    name.identifier = @"mx-user-name";
    name.target = self;
    name.action = @selector(nameChanged:);
    name.delegate = self;
    [MatrixCodeSettingsTheme.sharedTheme styleTextField:name];
    self.panelNameField = name;
    [name.widthAnchor constraintEqualToConstant:142].active = YES;
    NSView *nameRow = [self panelInlineRow:@"Viewer name" control:name];
    [stack addArrangedSubview:nameRow];
    [stack setCustomSpacing:12 afterView:nameRow];

    NSArray *specs = @[
        @[@"Density", @"density", @0.2, @100],
        @[@"Ramp-up", @"rampUpMs", @0, @30000],
        @[@"Trail length", @"trailLength", @0.01, @0.5],
        @[@"Trail variation", @"trailVariation", @0, @1],
        @[@"Speed", @"speed", @0.2, @3],
        @[@"Glyph size", @"glyphScale", @0.5, @10],
        @[@"Glow", @"glow", @0, @2.5],
        @[@"Lead glow", @"leadBrightness", @0, @3],
        @[@"Vignette", @"vignette", @0, @1],
    ];
    for (NSArray *spec in specs) {
        NSView *row = [self panelSlider:spec[0] key:spec[1]
                                   min:[spec[2] doubleValue] max:[spec[3] doubleValue]];
        [stack addArrangedSubview:row];
    }

    NSPopUpButton *preset = [self panelPopup:@"preset" items:@[
        @[@"Green (Classic)", @"classic"], @[@"Amber", @"amber"], @[@"Gold", @"gold"],
        @[@"Red", @"red"], @[@"Pink", @"pink"], @[@"Purple", @"purple"],
        @[@"Blue", @"blue"], @[@"White", @"white"],
    ]];
    [stack addArrangedSubview:[self panelInlineRow:@"Color" control:preset]];
    NSPopUpButton *quality = [self panelPopup:@"quality" items:@[
        @[@"Low", @"low"], @[@"Medium", @"med"], @[@"High", @"high"],
    ]];
    [stack addArrangedSubview:[self panelInlineRow:@"Quality" control:quality]];
    [stack addArrangedSubview:[self panelInlineRow:@"Scanlines" control:[self panelToggle:@"Scanlines" key:@"scanlines"]]];
    NSView *overlapRow = [self panelInlineRow:@"Allow overlap" control:[self panelToggle:@"Allow overlap" key:@"allowOverlap"]];
    [stack addArrangedSubview:overlapRow];
    [stack setCustomSpacing:12 afterView:overlapRow];

    NSStackView *actions = [NSStackView stackViewWithViews:@[]];
    actions.identifier = @"settings-panel-actions";
    actions.orientation = NSUserInterfaceLayoutOrientationVertical;
    actions.alignment = NSLayoutAttributeLeading;
    actions.spacing = 8;
    actions.edgeInsets = NSEdgeInsetsMake(2, 0, 0, 0);
    [actions.widthAnchor constraintEqualToConstant:MatrixCodeSettingsPanelContentWidth].active = YES;

    NSArray *buttons = @[
        @[@"▦ Characters", @"characters"],
        @[@"▷ Replay intro", @"replay"],
        @[@"✎ Edit intro", @"intro"],
        @[@"✎ Edit messages", @"messages"],
        @[@"▧ Edit images", @"images"],
        @[@"⏱ Edit countdown", @"countdowns"],
    ];
    for (NSArray *spec in buttons) {
        SEL action = [spec[1] isEqualToString:@"replay"] ? @selector(previewIntro:) : @selector(openEditor:);
        NSButton *button = [self settingsButton:spec[0] action:action identifier:spec[1]];
        [button.widthAnchor constraintEqualToConstant:MatrixCodeSettingsPanelContentWidth].active = YES;
        [actions addArrangedSubview:button];
    }
    NSButton *reset = [self settingsButton:@"↺ Reset to defaults"
                                    action:@selector(resetControls:)
                                identifier:@"reset-controls"];
    [reset.widthAnchor constraintEqualToConstant:MatrixCodeSettingsPanelContentWidth].active = YES;
    [actions addArrangedSubview:reset];
    [stack addArrangedSubview:actions];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    [MatrixCodeSettingsTheme.sharedTheme styleScrollView:scroll];
    MatrixCodeFlippedDocumentView *document = [[MatrixCodeFlippedDocumentView alloc]
        initWithFrame:NSMakeRect(0, 0, MatrixCodeSettingsPanelWidth, 760)];
    [document addSubview:stack];
    scroll.documentView = document;
    [surface addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:surface.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:surface.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:surface.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:surface.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:document.topAnchor],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:document.bottomAnchor],
    ]];
    return surface;
}

- (NSView *)editorContentForKind:(NSString *)kind {
    if ([kind isEqualToString:@"characters"]) return [self charactersTab];
    if ([kind isEqualToString:@"intro"]) return [self introTab];
    if ([kind isEqualToString:@"messages"]) return [self messagesTab];
    if ([kind isEqualToString:@"images"]) return [self imagesTab];
    return [self countdownTab];
}

- (BOOL)editorKindUsesDoneOnlyFlow:(NSString *)kind {
    return [kind isEqualToString:@"characters"];
}

- (BOOL)editorKindShowsCancelButton:(NSString *)kind {
    return ![self editorKindUsesDoneOnlyFlow:kind];
}

- (NSString *)editorResetButtonTitleForKind:(NSString *)kind {
    return [self editorKindUsesDoneOnlyFlow:kind] ? @"Reset Characters" : @"Reset to default";
}

- (NSString *)editorPrimaryButtonTitleForKind:(NSString *)kind {
    return [self editorKindUsesDoneOnlyFlow:kind] ? @"Done" : @"Save";
}

- (void)closeCurrentEditorFromDismissAction:(id)sender {
    if ([self editorKindShowsCancelButton:self.editorKind]) [self closeEditorCancel:sender];
    else [self closeEditorSave:sender];
}

- (void)styleEditorViewHierarchy:(NSView *)view {
    MatrixCodeSettingsTheme *theme = MatrixCodeSettingsTheme.sharedTheme;
    if ([view isKindOfClass:NSScrollView.class]) {
        [theme styleScrollView:(NSScrollView *)view];
    } else if ([view isKindOfClass:NSPopUpButton.class]) {
        [theme stylePopupButton:(NSPopUpButton *)view];
    } else if ([view isKindOfClass:NSSlider.class]) {
        [theme styleSlider:(NSSlider *)view readout:nil];
    } else if ([view isKindOfClass:NSTextField.class]) {
        NSTextField *field = (NSTextField *)view;
        if (field.editable) [theme styleTextField:field];
        else if (field.font.pointSize >= 15) [theme styleHeading:field level:1];
        else [theme styleLabel:field];
    } else if ([view isKindOfClass:NSButton.class]) {
        NSButton *button = (NSButton *)view;
        BOOL switchLike =
            [button.title isEqualToString:@"Rain during intro"] ||
            [button.title isEqualToString:@"Enable messages"] ||
            [button.title isEqualToString:@"Enable images"] ||
            [button.title isEqualToString:@"Flicker dissolve"] ||
            [button.title isEqualToString:@"Brightness fade"] ||
            [button.title isEqualToString:@"Enable default target"] ||
            [button.title isEqualToString:@"Set"] ||
            [button.title isEqualToString:@"Mirror glyphs"];
        if (switchLike) {
            button.font = [theme monospacedFontOfSize:11 weight:NSFontWeightRegular];
            button.contentTintColor = theme.accentColor;
        } else {
            [theme styleButton:button];
        }
    } else if ([view isKindOfClass:NSDatePicker.class]) {
        NSControl *picker = (NSControl *)view;
        picker.font = [theme monospacedFontOfSize:11 weight:NSFontWeightRegular];
    }
    for (NSView *subview in view.subviews) [self styleEditorViewHierarchy:subview];
}

- (void)presentEditorKind:(NSString *)kind {
    [self.editorBackdrop removeFromSuperview];
    [self stopCharactersPreview];
    NSView *root = [self presentationContentView];
    if (!root) return;
    MatrixCodeSettingsBackdropView *backdrop =
        [[MatrixCodeSettingsBackdropView alloc] initWithFrame:NSZeroRect];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.identifier = @"settings-editor-backdrop";
    backdrop.wantsLayer = YES;
    backdrop.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.60].CGColor;

    MatrixCodeSettingsPanelView *card = [[MatrixCodeSettingsPanelView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.identifier = [@"settings-editor-card-" stringByAppendingString:kind];
    card.modal = YES;

    NSView *body = [self editorContentForKind:kind];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [self styleEditorViewHierarchy:body];
    NSButton *reset = [self settingsButton:[self editorResetButtonTitleForKind:kind]
                                    action:@selector(resetCurrentEditor:)
                                identifier:@"editor-reset"];
    NSButton *cancel = [self editorKindShowsCancelButton:kind]
        ? [self settingsButton:@"Cancel"
                        action:@selector(closeEditorCancel:)
                    identifier:@"editor-cancel"]
        : nil;
    cancel.keyEquivalent = @"\e";
    NSButton *save = [self settingsButton:[self editorPrimaryButtonTitleForKind:kind]
                                  action:@selector(closeEditorSave:)
                              identifier:@"editor-save"];
    save.keyEquivalent = @"\r";
    for (NSButton *button in @[reset, save]) {
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:36].active = YES;
        [button.widthAnchor constraintGreaterThanOrEqualToConstant:112].active = YES;
    }
    [reset.widthAnchor constraintGreaterThanOrEqualToConstant:156].active = YES;
    if (cancel) {
        [cancel.heightAnchor constraintGreaterThanOrEqualToConstant:36].active = YES;
        [cancel.widthAnchor constraintGreaterThanOrEqualToConstant:112].active = YES;
    }
    NSView *footerSpacer = [[NSView alloc] initWithFrame:NSZeroRect];
    footerSpacer.identifier = @"editor-footer-spacer";
    [footerSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    [footerSpacer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                           forOrientation:NSLayoutConstraintOrientationHorizontal];
    [footerSpacer.widthAnchor constraintGreaterThanOrEqualToConstant:12].active = YES;
    NSArray<NSView *> *actionViews = cancel ? @[cancel, save] : @[save];
    NSStackView *footerActions = [NSStackView stackViewWithViews:actionViews];
    footerActions.identifier = @"editor-footer-actions";
    footerActions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    footerActions.alignment = NSLayoutAttributeCenterY;
    footerActions.spacing = 16;
    [footerActions setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                              forOrientation:NSLayoutConstraintOrientationHorizontal];
    [footerActions setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSArray<NSView *> *footerViews = @[reset, footerSpacer, footerActions];
    NSStackView *footer = [NSStackView stackViewWithViews:footerViews];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    footer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    footer.alignment = NSLayoutAttributeCenterY;
    footer.distribution = NSStackViewDistributionFill;
    footer.spacing = 16;
    [reset setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    if (cancel) {
        [cancel setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    [save setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];

    [card addSubview:body];
    [card addSubview:footer];
    [backdrop addSubview:card];
    [root addSubview:backdrop positioned:NSWindowAbove relativeTo:nil];
    NSLayoutConstraint *cardPreferredHeight =
        [card.heightAnchor constraintEqualToConstant:MatrixCodeEditorCardMaxHeight];
    cardPreferredHeight.priority = NSLayoutPriorityDefaultLow;
    NSLayoutConstraint *cardViewportHeight =
        [card.heightAnchor constraintEqualToAnchor:backdrop.heightAnchor
                                          constant:-MatrixCodeEditorCardVerticalMargin];
    cardViewportHeight.priority = NSLayoutPriorityDefaultHigh;
    MatrixCodePinViewToSuperviewEdges(backdrop, root, NSEdgeInsetsMake(0, 0, 0, 0));
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:backdrop.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:backdrop.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:MatrixCodeEditorCardWidth],
        cardPreferredHeight,
        cardViewportHeight,
        [card.heightAnchor constraintLessThanOrEqualToConstant:MatrixCodeEditorCardMaxHeight],
        [card.heightAnchor constraintLessThanOrEqualToAnchor:backdrop.heightAnchor
                                                    constant:-MatrixCodeEditorCardVerticalMargin],
        [body.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [body.topAnchor constraintEqualToAnchor:card.topAnchor],
        [body.bottomAnchor constraintEqualToAnchor:footer.topAnchor constant:-18],
        [footer.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:28],
        [footer.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-28],
        [footer.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-26],
    ]];
    self.editorBackdrop = backdrop;
    self.editorCard = card;
    self.editorKind = kind;
    [self refreshEmbeddedPresentationLayout];
}

- (NSString *)canonicalEditorKind:(NSString *)kind {
    if ([kind isEqualToString:@"characters"]) return @"characters";
    if ([kind isEqualToString:@"intro"]) return @"intro";
    if ([kind isEqualToString:@"messages"]) return @"messages";
    if ([kind isEqualToString:@"images"]) return @"images";
    if ([kind isEqualToString:@"countdown"] || [kind isEqualToString:@"countdowns"]) {
        return @"countdowns";
    }
    return nil;
}

- (NSSlider *)sliderWithIdentifier:(NSString *)identifier inView:(NSView *)view {
    if ([view isKindOfClass:NSSlider.class] && [view.identifier isEqualToString:identifier]) {
        return (NSSlider *)view;
    }
    for (NSView *subview in view.subviews) {
        NSSlider *match = [self sliderWithIdentifier:identifier inView:subview];
        if (match) return match;
    }
    return nil;
}

- (void)openEditorKind:(NSString *)kind {
    NSString *canonical = [self canonicalEditorKind:kind];
    if (!canonical) return;
    [self setSettingsPanelVisible:YES immediate:YES];
    self.editorSnapshot = [self serializedValues];
    [self presentEditorKind:canonical];
}

- (BOOL)toggleMessagesEnabled {
    BOOL enabled = [self.messages[@"enabled"] boolValue];
    BOOL nextEnabled = !enabled;
    self.messages[@"enabled"] = MatrixCodeSettingBoolObject(nextEnabled);
    [self draftDidChange];
    if ([self.editorKind isEqualToString:@"messages"]) {
        [self presentEditorKind:@"messages"];
    }
    return nextEnabled;
}

- (BOOL)toggleImagesEnabled {
    BOOL enabled = [self.images[@"enabled"] boolValue];
    BOOL nextEnabled = !enabled;
    self.images[@"enabled"] = MatrixCodeSettingBoolObject(nextEnabled);
    [self draftDidChange];
    if ([self.editorKind isEqualToString:@"images"]) {
        [self presentEditorKind:@"images"];
    }
    return nextEnabled;
}

- (void)nudgeDensityByFactor:(double)factor {
    if (!isfinite(factor) || factor <= 0) return;
    double current = [self.controls[@"density"] isKindOfClass:NSNumber.class]
        ? [self.controls[@"density"] doubleValue] : 2.0;
    double density = fmin(100.0, fmax(0.1, current * factor));
    self.controls[@"density"] = @(density);
    NSSlider *slider = [self sliderWithIdentifier:@"density" inView:self.settingsPanel];
    if (slider) {
        slider.doubleValue = density;
        [self updateReadoutForSlider:slider];
    }
    [self draftDidChange];
}

- (void)openEditor:(NSButton *)sender {
    [self openEditorKind:sender.identifier];
}

- (void)closeEditorSave:(id)sender {
    [self stopCharactersPreview];
    NSDictionary *values = [self serializedValues];
    values = [self commitSerializedValues:values];
    [self publishPreviewValues:values];
    [self.editorBackdrop removeFromSuperview];
    self.editorBackdrop = nil;
    self.editorCard = nil;
    self.editorKind = nil;
    self.editorSnapshot = nil;
}

- (void)closeEditorCancel:(id)sender {
    [self stopCharactersPreview];
    if (self.editorSnapshot) {
        self.stagedValues = [self.editorSnapshot mutableCopy];
        [self.explicitlyClearedStorageKeys removeAllObjects];
        [self loadModels];
        [self publishPreviewValues:[self serializedValues]];
    }
    [self closeEditorSave:sender];
    [self rebuildConfigurationInterface];
}

- (void)cancelOperation:(id)sender {
    if (self.editorBackdrop) {
        [self closeCurrentEditorFromDismissAction:sender];
        return;
    }
    [self cancel:sender];
}

- (void)resetCurrentEditor:(id)sender {
    if ([self.editorKind isEqualToString:@"characters"]) {
        self.controls[@"glyphMode"] = @"matrix";
        self.controls[@"glyphFont"] = @"matrix";
        self.controls[@"glyphRate"] = @1;
        self.controls[@"mirror"] = @YES;
    } else {
        NSMutableDictionary *values = [[self serializedValues] mutableCopy];
        NSString *key = [self.editorKind isEqualToString:@"intro"] ? @"mx-intro" :
            ([self.editorKind isEqualToString:@"messages"] ? @"mx-messages" :
             ([self.editorKind isEqualToString:@"images"] ? @"mx-images" : @"mx-countdown"));
        [values removeObjectForKey:key];
        self.stagedValues = values;
        [self loadModels];
    }
    [self draftDidChange];
    NSString *kind = self.editorKind;
    [self presentEditorKind:kind];
}

- (void)resetControls:(id)sender {
    self.controls = [@{
        @"speed": @1, @"trailLength": @0.255, @"trailVariation": @1,
        @"density": @2, @"rampUpMs": @8000,
        @"glyphRate": @1, @"glyphScale": @1, @"glow": @0.9, @"leadBrightness": @1.6,
        @"glyphMode": @"matrix", @"glyphFont": @"matrix", @"preset": @"classic",
        @"mirror": @YES, @"scanlines": @NO, @"vignette": @0,
        @"allowOverlap": @YES, @"quality": @"high",
    } mutableCopy];
    [self draftDidChange];
    [self rebuildConfigurationInterface];
}

- (void)rebuildConfigurationInterface {
    [self.settingsHideTimer invalidate];
    self.settingsHideTimer = nil;
    [self.editorBackdrop removeFromSuperview];
    self.editorBackdrop = nil;
    self.editorCard = nil;
    [self stopCharactersPreview];
    [self.settingsOverlayView removeFromSuperview];
    self.settingsOverlayView = nil;
    self.settingsPanel = nil;
    if (!self.embeddedPresentation) {
        for (NSView *view in self.window.contentView.subviews.copy) [view removeFromSuperview];
    }
    [self buildInterface];
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

- (NSPopUpButton *)messagePopup:(NSString *)identifier
                           items:(NSArray<NSArray<NSString *> *> *)items {
    NSString *selectedValue = [self.messages[identifier] isKindOfClass:NSString.class]
        ? self.messages[identifier] : @"";
    return [self settingsPopupWithIdentifier:identifier
                               selectedValue:selectedValue
                                       items:items
                                      action:@selector(messageChoiceChanged:)];
}

- (NSView *)settingsCardContainingView:(NSView *)view {
    MatrixCodeSettingsCardView *card = [[MatrixCodeSettingsCardView alloc] initWithFrame:NSZeroRect];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10],
        [view.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10],
        [view.topAnchor constraintEqualToAnchor:card.topAnchor constant:8],
        [view.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8],
    ]];
    return card;
}

- (NSString *)displayValueForSlider:(NSSlider *)slider {
    if ([slider.identifier isEqualToString:@"rampUpMs"]) {
        return slider.doubleValue <= 0
            ? @"off"
            : [NSString stringWithFormat:@"%.1fs", slider.doubleValue / 1000.0];
    }
    if ([slider.identifier isEqualToString:@"trailLength"]) {
        double percent = (slider.doubleValue - 0.01) / 0.49 * 100.0;
        return [NSString stringWithFormat:@"%.0f%%", fmin(100, fmax(0, percent))];
    }
    if ([slider.identifier isEqualToString:@"trailVariation"]) {
        return [NSString stringWithFormat:@"%.0f%%", slider.doubleValue * 100.0];
    }
    if ([slider.identifier isEqualToString:@"speed"]) {
        return [NSString stringWithFormat:@"%.2f×", slider.doubleValue];
    }
    if ([slider.identifier isEqualToString:@"glyphScale"]) {
        return [NSString stringWithFormat:@"%.1f×", slider.doubleValue];
    }
    if ([slider.identifier isEqualToString:@"vignette"]) {
        return slider.doubleValue <= 0
            ? @"off"
            : [NSString stringWithFormat:@"%.0f%%", slider.doubleValue * 100.0];
    }
    if ([slider.identifier isEqualToString:@"glyphRate"]) {
        return [NSString stringWithFormat:@"%.2fx", slider.doubleValue];
    }
    return [NSString stringWithFormat:@"%.2f", slider.doubleValue];
}

- (NSTextField *)readoutWithIdentifier:(NSString *)identifier inView:(NSView *)view {
    if ([view.identifier isEqualToString:identifier] &&
        [view isKindOfClass:NSTextField.class]) {
        return (NSTextField *)view;
    }
    for (NSView *subview in view.subviews) {
        NSTextField *readout = [self readoutWithIdentifier:identifier inView:subview];
        if (readout) return readout;
    }
    return nil;
}

- (void)updateReadoutForSlider:(NSSlider *)slider {
    NSString *identifier = [slider.identifier stringByAppendingString:@"-value"];
    NSTextField *readout = [self readoutWithIdentifier:identifier inView:slider.superview];
    readout.stringValue = [self displayValueForSlider:slider];
}

- (NSView *)slider:(NSString *)key min:(double)minimum max:(double)maximum {
    NSSlider *slider = [NSSlider sliderWithValue:[self.controls[key] doubleValue]
                                       minValue:minimum maxValue:maximum
                                         target:self action:@selector(controlChanged:)];
    slider.identifier = key;
    slider.continuous = YES;
    [slider.widthAnchor constraintEqualToConstant:300].active = YES;
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

- (NSDictionary<NSString *, NSString *> *)characterPreviewValuesFromValues:
    (NSDictionary<NSString *, NSString *> *)values {
    NSMutableDictionary<NSString *, NSString *> *previewValues = [values mutableCopy];
    NSMutableDictionary *controls =
        [MatrixCodeJSONObject(previewValues[@"mx-controls"], NSDictionary.class) mutableCopy]
        ?: [NSMutableDictionary dictionary];
    controls[@"density"] = @18;
    controls[@"glyphScale"] = @0.82;
    controls[@"trailLength"] = @0.32;
    controls[@"trailVariation"] = @1;
    controls[@"rampUpMs"] = @0;
    controls[@"allowOverlap"] = @YES;
    previewValues[@"mx-controls"] = MatrixCodeJSONString(controls);

    NSMutableDictionary *messages =
        [MatrixCodeJSONObject(previewValues[@"mx-messages"], NSDictionary.class) mutableCopy]
        ?: [NSMutableDictionary dictionary];
    messages[@"enabled"] = @NO;
    previewValues[@"mx-messages"] = MatrixCodeJSONString(messages);
    NSMutableDictionary *images =
        [MatrixCodeJSONObject(previewValues[@"mx-images"], NSDictionary.class) mutableCopy]
        ?: [NSMutableDictionary dictionary];
    images[@"enabled"] = @NO;
    previewValues[@"mx-images"] = MatrixCodeJSONString(images);
    return previewValues;
}

- (NSDictionary<NSString *, id> *)charactersPreviewSession {
    return @{@"seed": @0x43a71f2d, @"epoch": @1700000000000};
}

- (void)redrawCharactersPreviewWithValues:(NSDictionary<NSString *, NSString *> *)values {
    if (!self.charactersPreviewView) return;
    [self.charactersPreviewView reloadStoredValues:[self characterPreviewValuesFromValues:values]];
    [self.charactersPreviewView setDensityScale:1 rainElapsed:18.0];
    [self.charactersPreviewView draw];
}

- (void)stopCharactersPreview {
    [self.charactersPreviewView setAnimationActive:NO];
    self.charactersPreviewView = nil;
}

- (NSView *)charactersPreviewCard {
    MatrixCodeSettingsCardView *card = [[MatrixCodeSettingsCardView alloc] initWithFrame:NSZeroRect];
    card.identifier = @"settings-character-preview";
    [card.widthAnchor constraintEqualToConstant:540].active = YES;

    NSTextField *label = [NSTextField labelWithString:@"Rain preview"];
    label.identifier = @"settings-character-preview-title";

    MatrixCodeMetalView *preview = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 508, 190)
              session:[self charactersPreviewSession]
         storedValues:[self characterPreviewValuesFromValues:[self serializedValues]]];
    NSView *previewSurface = preview;
    if (preview) {
        preview.identifier = @"settings-character-preview-rain";
        preview.wantsLayer = YES;
        preview.layer.cornerRadius = 6.0;
        preview.layer.masksToBounds = YES;
        self.charactersPreviewView = preview;
        [self redrawCharactersPreviewWithValues:[self serializedValues]];
    } else {
        NSTextField *fallback = [NSTextField labelWithString:@"Preview unavailable"];
        fallback.identifier = @"settings-character-preview-unavailable";
        fallback.alignment = NSTextAlignmentCenter;
        previewSurface = fallback;
    }
    previewSurface.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *stack = [NSStackView stackViewWithViews:@[label, previewSurface]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [previewSurface.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor],
        [previewSurface.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor],
        [previewSurface.heightAnchor constraintEqualToConstant:190],
    ]];
    return card;
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
        @[@"Trail length", @"trailLength", @0.01, @0.5],
        @[@"Trail variation", @"trailVariation", @0, @1],
        @[@"Speed", @"speed", @0.1, @3],
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
    NSArray *presetItems = @[
        @[@"Green (Classic)", @"classic"], @[@"Amber", @"amber"],
        @[@"Gold", @"gold"], @[@"Red", @"red"],
        @[@"Pink", @"pink"], @[@"Purple", @"purple"],
        @[@"Blue", @"blue"], @[@"White", @"white"],
    ];
    NSPopUpButton *preset = [self settingsPopupWithIdentifier:@"preset"
                                                selectedValue:self.controls[@"preset"]
                                                        items:presetItems
                                                       action:@selector(controlChanged:)];
    [stack addArrangedSubview:[self rowWithLabel:@"Color" control:preset]];
    NSArray *qualityItems = @[
        @[@"Low", @"low"], @[@"Medium", @"med"], @[@"High", @"high"],
    ];
    NSPopUpButton *quality = [self settingsPopupWithIdentifier:@"quality"
                                                 selectedValue:self.controls[@"quality"]
                                                         items:qualityItems
                                                        action:@selector(controlChanged:)];
    [stack addArrangedSubview:[self rowWithLabel:@"Quality" control:quality]];
    for (NSArray *toggle in @[@[@"Scanlines", @"scanlines"], @[@"Allow overlap", @"allowOverlap"]]) {
        NSButton *button = [NSButton checkboxWithTitle:toggle[0] target:self action:@selector(controlChanged:)];
        button.identifier = toggle[1];
        button.state = [self.controls[toggle[1]] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        [stack addArrangedSubview:button];
    }
    NSButton *preview = [NSButton buttonWithTitle:@"Preview" target:self action:@selector(previewRain:)];
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
    [stack addArrangedSubview:[self charactersPreviewCard]];

    NSArray *glyphModeItems = @[
        @[@"Matrix mix", @"matrix"], @[@"Katakana", @"katakana"],
        @[@"Binary", @"binary"], @[@"Digits", @"digits"],
        @[@"Latin", @"latin"], @[@"Symbols", @"symbols"],
    ];
    NSPopUpButton *glyphMode = [self settingsPopupWithIdentifier:@"glyphMode"
                                                   selectedValue:self.controls[@"glyphMode"]
                                                           items:glyphModeItems
                                                          action:@selector(controlChanged:)];
    [glyphMode.widthAnchor constraintEqualToConstant:240].active = YES;
    [stack addArrangedSubview:[self rowWithLabel:@"Character set" control:glyphMode]];

    NSArray *fontItems = @[
        @[@"Movie Gothic", @"matrix"], @[@"Sharp Gothic", @"gothic"],
        @[@"SF Mono", @"mono"], @[@"Terminal Mono", @"terminal"],
        @[@"Rounded", @"rounded"], @[@"Mincho", @"mincho"],
    ];
    NSPopUpButton *glyphFont = [self settingsPopupWithIdentifier:@"glyphFont"
                                                   selectedValue:self.controls[@"glyphFont"]
                                                           items:fontItems
                                                          action:@selector(controlChanged:)];
    [glyphFont.widthAnchor constraintEqualToConstant:240].active = YES;
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
        if ([key isEqualToString:@"preset"]) {
            MatrixCodeSettingsTheme.sharedTheme.presetName = selected;
            if (!self.embeddedPresentation) {
                self.window.contentView.layer.backgroundColor =
                    MatrixCodeSettingsTheme.sharedTheme.backgroundColor.CGColor;
            }
        }
        if ([key isEqualToString:@"glyphMode"]) {
            BOOL mirror = MatrixCodePreferredMirrorForGlyphMode(selected);
            self.controls[@"mirror"] = MatrixCodeSettingBoolObject(mirror);
            self.mirrorButton.state = mirror ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
    else if ([sender isKindOfClass:NSButton.class]) {
        BOOL enabled = [sender state] == NSControlStateValueOn;
        self.controls[key] = MatrixCodeSettingBoolObject(enabled);
        if ([key isEqualToString:@"scanlines"] || [key isEqualToString:@"allowOverlap"]) {
            [MatrixCodeSettingsTheme.sharedTheme styleToggleButton:sender on:enabled];
        }
    }
    [self draftDidChange];
}

- (void)nameChanged:(NSTextField *)sender {
    NSString *name = [sender.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length) {
        self.stagedValues[@"mx-user-name"] = name;
        [self.explicitlyClearedStorageKeys removeObject:@"mx-user-name"];
    } else {
        [self.stagedValues removeObjectForKey:@"mx-user-name"];
        [self.explicitlyClearedStorageKeys addObject:@"mx-user-name"];
    }
    [self draftDidChange];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    NSTextField *field = [notification.object isKindOfClass:NSTextField.class]
        ? notification.object : nil;
    if (!field) return;
    NSString *identifier = field.identifier ?: @"";
    if ([identifier isEqualToString:@"mx-user-name"]) {
        [self nameChanged:field];
    } else if ([identifier isEqualToString:@"text"] ||
               [identifier hasPrefix:@"holdMs"] ||
               [identifier hasPrefix:@"pauseMs"]) {
        [self introLineChanged:field];
    } else if ([identifier isEqualToString:@"messageText"]) {
        [self messageLineChanged:field];
    } else if ([identifier isEqualToString:@"imageName"]) {
        [self imageItemChanged:field];
    } else if ([identifier isEqualToString:@"momentName"]) {
        [self momentChanged:field];
    } else if ([identifier isEqualToString:@"charMs"] ||
               [identifier hasPrefix:@"startDelayMs"] ||
               [identifier hasPrefix:@"fadeOutMs"] ||
               [identifier hasPrefix:@"postIntroDelayMs"]) {
        [self introTimingChanged:field];
    } else if ([identifier hasPrefix:@"frequencyMs"] ||
               [identifier hasPrefix:@"persistenceMs"] ||
               [identifier hasPrefix:@"appearMs"] ||
               [identifier hasPrefix:@"disappearMs"] ||
               [identifier hasPrefix:@"verticalPosition"] ||
               [identifier hasPrefix:@"verticalJitter"] ||
               [identifier hasPrefix:@"image"]) {
        if ([self.editorKind isEqualToString:@"images"] ||
            ([identifier hasPrefix:@"image"] && ![identifier hasPrefix:@"imageName"])) {
            [self imageNumberChanged:field];
        } else {
            [self messageNumberChanged:field];
        }
    }
}

- (NSTextField *)numberField:(double)value identifier:(NSString *)identifier action:(SEL)action {
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    field.doubleValue = value;
    field.identifier = identifier;
    field.target = self;
    field.action = action;
    field.delegate = self;
    [field.widthAnchor constraintEqualToConstant:76].active = YES;
    return field;
}

- (NSTextField *)secondsField:(double)milliseconds
                    identifier:(NSString *)identifier
                        action:(SEL)action {
    return [self numberField:milliseconds / 1000.0
                  identifier:[identifier stringByAppendingString:@"-seconds"]
                      action:action];
}

- (NSTextField *)percentField:(double)fraction
                    identifier:(NSString *)identifier
                        action:(SEL)action {
    return [self numberField:fraction * 100.0
                  identifier:[identifier stringByAppendingString:@"-percent"]
                      action:action];
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
                              @[@"Start delay (s)", @"startDelayMs"],
                              @[@"Fade out (s)", @"fadeOutMs"],
                              @[@"Delay after intro (s)", @"postIntroDelayMs"]]) {
        BOOL milliseconds = [field[1] isEqualToString:@"charMs"];
        NSTextField *number = milliseconds
            ? [self numberField:[self.intro[field[1]] doubleValue]
                     identifier:field[1] action:@selector(introTimingChanged:)]
            : [self secondsField:[self.intro[field[1]] doubleValue]
                      identifier:field[1] action:@selector(introTimingChanged:)];
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
        text.delegate = self;
        [text.widthAnchor constraintEqualToConstant:520].active = YES;
        NSTextField *hold = [self secondsField:[line[@"holdMs"] doubleValue] identifier:@"holdMs"
                                        action:@selector(introLineChanged:)];
        hold.tag = index;
        NSTextField *pause = [self secondsField:[line[@"pauseMs"] doubleValue] identifier:@"pauseMs"
                                         action:@selector(introLineChanged:)];
        pause.tag = index;
        pause.enabled = index + 1 < self.introLines.count;
        NSButton *up = [NSButton buttonWithTitle:@"↑" target:self action:@selector(moveIntroLine:)];
        up.tag = index; up.identifier = @"up"; up.enabled = index > 0;
        NSButton *down = [NSButton buttonWithTitle:@"↓" target:self action:@selector(moveIntroLine:)];
        down.tag = index; down.identifier = @"down"; down.enabled = index + 1 < self.introLines.count;
        NSButton *remove = [NSButton buttonWithTitle:@"−" target:self action:@selector(removeIntroLine:)];
        remove.tag = index; remove.enabled = self.introLines.count > 1;
        NSStackView *timings = [NSStackView stackViewWithViews:@[
            [NSTextField labelWithString:@"Show for (s)"], hold,
            [NSTextField labelWithString:@"Pause after (s)"], pause, up, down, remove
        ]];
        timings.spacing = 6;
        timings.alignment = NSLayoutAttributeCenterY;
        NSStackView *row = [NSStackView stackViewWithViews:@[text, timings]];
        row.orientation = NSUserInterfaceLayoutOrientationVertical;
        row.spacing = 6;
        row.alignment = NSLayoutAttributeLeading;
        [self.introLinesStack addArrangedSubview:[self settingsCardContainingView:row]];
    }];
}

- (void)introLineChanged:(NSTextField *)sender {
    if (!MatrixCodeIsValidIndex(sender.tag, self.introLines.count)) return;
    NSUInteger index = (NSUInteger)sender.tag;
    NSString *key = [sender.identifier stringByReplacingOccurrencesOfString:@"-seconds" withString:@""];
    self.introLines[index][key] =
        [key isEqualToString:@"text"]
            ? MatrixCodeSettingText(sender.stringValue, 120)
            : @(MIN(20000, MAX(0, sender.doubleValue * 1000.0)));
    [self draftDidChange];
}
- (void)addIntroLine:(id)sender {
    if (self.introLines.count < 12) [self.introLines addObject:
        [@{@"text": @"", @"holdMs": @2800, @"pauseMs": @0} mutableCopy]];
    [self rebuildIntroLines];
    [self draftDidChange];
}
- (void)removeIntroLine:(NSButton *)sender {
    if (self.introLines.count > 1 && MatrixCodeIsValidIndex(sender.tag, self.introLines.count))
        [self.introLines removeObjectAtIndex:(NSUInteger)sender.tag];
    [self rebuildIntroLines];
    [self draftDidChange];
}
- (void)moveIntroLine:(NSButton *)sender {
    NSInteger source = sender.tag;
    NSInteger destination = source + ([sender.identifier isEqualToString:@"up"] ? -1 : 1);
    if (MatrixCodeIsValidIndex(source, self.introLines.count) &&
        MatrixCodeIsValidIndex(destination, self.introLines.count)) {
        [self.introLines exchangeObjectAtIndex:(NSUInteger)source
                             withObjectAtIndex:(NSUInteger)destination];
    }
    [self rebuildIntroLines];
    [self draftDidChange];
}
- (void)introTimingChanged:(NSTextField *)sender {
    BOOL seconds = [sender.identifier hasSuffix:@"-seconds"];
    NSString *key = [sender.identifier stringByReplacingOccurrencesOfString:@"-seconds" withString:@""];
    BOOL characterTiming = [key isEqualToString:@"charMs"];
    double value = sender.doubleValue * (seconds ? 1000.0 : 1.0);
    self.intro[key] = @(MIN(characterTiming ? 500 : 10000,
        MAX(characterTiming ? 10 : 0, value)));
    [self draftDidChange];
}
- (void)introRainChanged:(NSButton *)sender {
    self.intro[@"rainDuringIntro"] =
        MatrixCodeSettingBoolObject(sender.state == NSControlStateValueOn);
    self.postIntroDelayField.enabled = sender.state != NSControlStateValueOn;
    [self draftDidChange];
}
- (void)replayIntroNextRun:(id)sender {
    [self.stagedValues removeObjectForKey:@"mx-intro-seen"];
    [self.explicitlyClearedStorageKeys addObject:@"mx-intro-seen"];
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
    NSPopUpButton *layout = [self messagePopup:@"messageLayout" items:@[
        @[@"Row across rain", @"row"],
        @[@"Single drop", @"drop"],
    ]];
    [stack addArrangedSubview:[self rowWithLabel:@"Message layout" control:layout]];
    NSPopUpButton *direction = [self messagePopup:@"messageDirection" items:@[
        @[@"Top to bottom", @"topToBottom"],
        @[@"Bottom to top", @"bottomToTop"],
    ]];
    BOOL dropLayout = [self.messages[@"messageLayout"] isEqualToString:@"drop"];
    direction.enabled = dropLayout;
    [stack addArrangedSubview:[self rowWithLabel:@"Drop direction" control:direction]];
    self.messageLinesStack = [NSStackView stackViewWithViews:@[]];
    self.messageLinesStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.messageLinesStack.spacing = 8;
    [stack addArrangedSubview:self.messageLinesStack];
    [self rebuildMessageLines];
    [stack addArrangedSubview:[NSButton buttonWithTitle:@"Add Message" target:self action:@selector(addMessage:)]];
    for (NSArray *field in @[@[@"Show one every (s)", @"frequencyMs"],
                              @[@"Appear over (s)", @"appearMs"],
                              @[@"Each stays for (s)", @"persistenceMs"],
                              @[@"Disappear over (s)", @"disappearMs"],
                              @[dropLayout ? @"Horizontal position (%)" : @"Vertical position (%)", @"verticalPosition"],
                              @[dropLayout ? @"Horizontal randomness (%)" : @"Vertical randomness (%)", @"verticalJitter"]]) {
        BOOL percent = [field[1] hasPrefix:@"vertical"];
        NSTextField *number = percent
            ? [self percentField:[self.messages[field[1]] doubleValue]
                      identifier:field[1] action:@selector(messageNumberChanged:)]
            : [self secondsField:[self.messages[field[1]] doubleValue]
                      identifier:field[1] action:@selector(messageNumberChanged:)];
        [stack addArrangedSubview:[self rowWithLabel:field[0]
                                            control:number]];
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
        text.stringValue = message; text.tag = index; text.identifier = @"messageText";
        text.target = self; text.action = @selector(messageLineChanged:); text.delegate = self;
        [text.widthAnchor constraintEqualToConstant:480].active = YES;
        NSButton *up = [NSButton buttonWithTitle:@"↑" target:self action:@selector(moveMessage:)];
        up.tag = index; up.identifier = @"up"; up.enabled = index > 0;
        NSButton *down = [NSButton buttonWithTitle:@"↓" target:self action:@selector(moveMessage:)];
        down.tag = index; down.identifier = @"down"; down.enabled = index + 1 < self.messageLines.count;
        NSButton *remove = [NSButton buttonWithTitle:@"−" target:self action:@selector(removeMessage:)];
        remove.tag = index;
        NSStackView *row = [NSStackView stackViewWithViews:@[text, up, down, remove]];
        row.spacing = 6; row.alignment = NSLayoutAttributeCenterY;
        [self.messageLinesStack addArrangedSubview:[self settingsCardContainingView:row]];
    }];
}
- (void)messageLineChanged:(NSTextField *)sender {
    if (MatrixCodeIsValidIndex(sender.tag, self.messageLines.count))
        self.messageLines[(NSUInteger)sender.tag] = MatrixCodeSettingText(sender.stringValue, 120);
    [self draftDidChange];
}
- (void)addMessage:(id)sender {
    if (self.messageLines.count < 12) [self.messageLines addObject:@""];
    [self rebuildMessageLines];
    [self draftDidChange];
}
- (void)removeMessage:(NSButton *)sender {
    if (MatrixCodeIsValidIndex(sender.tag, self.messageLines.count))
        [self.messageLines removeObjectAtIndex:(NSUInteger)sender.tag];
    [self rebuildMessageLines];
    [self draftDidChange];
}
- (void)moveMessage:(NSButton *)sender {
    NSInteger source = sender.tag;
    NSInteger destination = source + ([sender.identifier isEqualToString:@"up"] ? -1 : 1);
    if (MatrixCodeIsValidIndex(source, self.messageLines.count) &&
        MatrixCodeIsValidIndex(destination, self.messageLines.count)) {
        [self.messageLines exchangeObjectAtIndex:(NSUInteger)source
                               withObjectAtIndex:(NSUInteger)destination];
    }
    [self rebuildMessageLines];
    [self draftDidChange];
}
- (void)messageNumberChanged:(NSTextField *)sender {
    BOOL percent = [sender.identifier hasSuffix:@"-percent"];
    BOOL seconds = [sender.identifier hasSuffix:@"-seconds"];
    NSString *key = [[sender.identifier stringByReplacingOccurrencesOfString:@"-percent" withString:@""]
        stringByReplacingOccurrencesOfString:@"-seconds" withString:@""];
    double value = sender.doubleValue * (percent ? 0.01 : (seconds ? 1000.0 : 1.0));
    if ([key hasPrefix:@"vertical"]) value = MIN(1, MAX(0, value));
    else {
        BOOL minimumGap = [key isEqualToString:@"frequencyMs"] ||
            [key isEqualToString:@"persistenceMs"];
        value = MIN(600000, MAX(minimumGap ? 500 : 0, value));
    }
    self.messages[key] = @(value);
    [self draftDidChange];
}
- (void)messageToggleChanged:(NSButton *)sender {
    self.messages[sender.identifier] =
        MatrixCodeSettingBoolObject(sender.state == NSControlStateValueOn);
    [self draftDidChange];
}

- (void)messageChoiceChanged:(NSPopUpButton *)sender {
    id value = sender.selectedItem.representedObject;
    NSString *selected = [value isKindOfClass:NSString.class] ? value : sender.titleOfSelectedItem;
    if (sender.identifier.length) self.messages[sender.identifier] = selected;
    [self draftDidChange];
    if ([sender.identifier isEqualToString:@"messageLayout"]) {
        [self presentEditorKind:@"messages"];
    }
}

- (NSImage *)thumbnailForImageItem:(NSDictionary *)item {
    NSMutableDictionary *image = MatrixCodeSanitizedImageItem(item);
    if (!image) return nil;
    NSInteger width = [image[@"width"] integerValue];
    NSInteger height = [image[@"height"] integerValue];
    NSData *mask = [[NSData alloc] initWithBase64EncodedString:image[@"data"] options:0];
    if (!mask || mask.length != (NSUInteger)(width * height)) return nil;
    NSBitmapImageRep *rep =
        [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                pixelsWide:width
                                                pixelsHigh:height
                                             bitsPerSample:8
                                           samplesPerPixel:4
                                                  hasAlpha:YES
                                                  isPlanar:NO
                                            colorSpaceName:NSCalibratedRGBColorSpace
                                               bytesPerRow:width * 4
                                              bitsPerPixel:32];
    if (!rep.bitmapData) return nil;
    const uint8_t *source = mask.bytes;
    uint8_t *dest = rep.bitmapData;
    for (NSInteger index = 0; index < width * height; index++) {
        uint8_t value = source[index];
        dest[index * 4 + 0] = value;
        dest[index * 4 + 1] = value;
        dest[index * 4 + 2] = value;
        dest[index * 4 + 3] = 255;
    }
    NSImage *thumbnail = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
    [thumbnail addRepresentation:rep];
    return thumbnail;
}

- (NSMutableDictionary *)imageItemFromURL:(NSURL *)url {
    NSImage *source = [[NSImage alloc] initWithContentsOfURL:url];
    if (!source || source.size.width <= 0 || source.size.height <= 0) return nil;
    NSRect proposed = NSMakeRect(0, 0, source.size.width, source.size.height);
    CGImageRef cgImage = [source CGImageForProposedRect:&proposed context:nil hints:nil];
    if (!cgImage) return nil;
    size_t sourceWidth = CGImageGetWidth(cgImage);
    size_t sourceHeight = CGImageGetHeight(cgImage);
    if (sourceWidth == 0 || sourceHeight == 0) return nil;

    CGFloat scale = MIN((CGFloat)MatrixCodeImageMaskMaxDimension / (CGFloat)sourceWidth,
                        (CGFloat)MatrixCodeImageMaskMaxDimension / (CGFloat)sourceHeight);
    scale = MIN(1.0, MAX(scale, 1.0 / MAX(sourceWidth, sourceHeight)));
    NSInteger width = MAX(1, (NSInteger)lround((CGFloat)sourceWidth * scale));
    NSInteger height = MAX(1, (NSInteger)lround((CGFloat)sourceHeight * scale));
    width = MIN((NSInteger)MatrixCodeImageMaskMaxDimension, width);
    height = MIN((NSInteger)MatrixCodeImageMaskMaxDimension, height);

    NSMutableData *rgba = [NSMutableData dataWithLength:(NSUInteger)(width * height * 4)];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(rgba.mutableBytes,
                                                 (size_t)width,
                                                 (size_t)height,
                                                 8,
                                                 (size_t)width * 4,
                                                 colorSpace,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast |
                                                 kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) return nil;
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);

    NSUInteger count = (NSUInteger)(width * height);
    float *luminance = calloc(count, sizeof(float));
    if (!luminance) return nil;
    const uint8_t *pixels = rgba.bytes;
    float minimum = 1;
    float maximum = 0;
    for (NSUInteger index = 0; index < count; index++) {
        float alpha = pixels[index * 4 + 3] / 255.0f;
        float red = pixels[index * 4 + 0] / 255.0f;
        float green = pixels[index * 4 + 1] / 255.0f;
        float blue = pixels[index * 4 + 2] / 255.0f;
        float value = (0.2126f * red + 0.7152f * green + 0.0722f * blue) * alpha;
        luminance[index] = value;
        minimum = fminf(minimum, value);
        maximum = fmaxf(maximum, value);
    }
    NSMutableData *mask = [NSMutableData dataWithLength:count];
    uint8_t *bytes = mask.mutableBytes;
    float range = maximum - minimum;
    for (NSUInteger index = 0; index < count; index++) {
        float value = range > 0.035f ? (luminance[index] - minimum) / range : luminance[index];
        value = powf(fminf(1, fmaxf(0, value)), 0.82f);
        bytes[index] = (uint8_t)lroundf(value * 255.0f);
    }
    free(luminance);

    NSString *name = url.lastPathComponent.stringByDeletingPathExtension;
    name = MatrixCodeSettingText(name, 80);
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length) name = @"Image";
    return [@{
        @"name": name,
        @"width": @(width),
        @"height": @(height),
        @"data": [mask base64EncodedStringWithOptions:0],
    } mutableCopy];
}

- (NSView *)imagesTab {
    NSStackView *stack;
    NSView *scroll = [self scrollingStack:&stack];
    [stack addArrangedSubview:[self heading:@"In-rain Images"]];
    NSButton *enabled = [NSButton checkboxWithTitle:@"Enable images"
                                             target:self
                                             action:@selector(imageToggleChanged:)];
    enabled.identifier = @"enabled";
    enabled.state = [self.images[@"enabled"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    [stack addArrangedSubview:enabled];

    NSButton *visibility = [self settingsButton:@"Max Visibility"
                                         action:@selector(optimizeImageVisibility:)
                                     identifier:@"imageMaxVisibility"];
    visibility.toolTip = @"Set image and rain controls for clearer image reveals.";
    [stack addArrangedSubview:visibility];

    self.imageItemsStack = [NSStackView stackViewWithViews:@[]];
    self.imageItemsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.imageItemsStack.spacing = 8;
    [stack addArrangedSubview:self.imageItemsStack];
    [self rebuildImageItems];
    [stack addArrangedSubview:[NSButton buttonWithTitle:@"Add Image" target:self action:@selector(addImage:)]];

    for (NSArray *field in @[@[@"Show one every (s)", @"frequencyMs"],
                              @[@"Appear over (s)", @"appearMs"],
                              @[@"Each stays for (s)", @"persistenceMs"],
                              @[@"Disappear over (s)", @"disappearMs"],
                              @[@"Screen width (%)", @"imageScale"],
                              @[@"Placement randomness (%)", @"imagePlacementJitter"]]) {
        BOOL percent = [field[1] hasPrefix:@"image"];
        NSTextField *number = percent
            ? [self percentField:[self.images[field[1]] doubleValue]
                      identifier:field[1] action:@selector(imageNumberChanged:)]
            : [self secondsField:[self.images[field[1]] doubleValue]
                      identifier:field[1] action:@selector(imageNumberChanged:)];
        [stack addArrangedSubview:[self rowWithLabel:field[0]
                                            control:number]];
    }
    for (NSArray *toggle in @[@[@"Flicker dissolve", @"flickerOut"],
                               @[@"Brightness fade", @"brightnessFade"]]) {
        NSButton *button = [NSButton checkboxWithTitle:toggle[0]
                                                target:self
                                                action:@selector(imageToggleChanged:)];
        button.identifier = toggle[1];
        button.state = [self.images[toggle[1]] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        [stack addArrangedSubview:button];
    }
    [stack addArrangedSubview:[NSButton buttonWithTitle:@"Preview Image" target:self action:@selector(previewImage:)]];
    return scroll;
}

- (void)rebuildImageItems {
    for (NSView *view in self.imageItemsStack.arrangedSubviews.copy) {
        [self.imageItemsStack removeArrangedSubview:view]; [view removeFromSuperview];
    }
    [self.imageItems enumerateObjectsUsingBlock:^(NSMutableDictionary *image, NSUInteger index, BOOL *stop) {
        NSImageView *thumbnail = [[NSImageView alloc] initWithFrame:NSZeroRect];
        thumbnail.image = [self thumbnailForImageItem:image];
        thumbnail.imageScaling = NSImageScaleProportionallyUpOrDown;
        [thumbnail.widthAnchor constraintEqualToConstant:52].active = YES;
        [thumbnail.heightAnchor constraintEqualToConstant:40].active = YES;

        NSTextField *name = [[NSTextField alloc] initWithFrame:NSZeroRect];
        name.placeholderString = @"Image";
        name.stringValue = [image[@"name"] isKindOfClass:NSString.class] ? image[@"name"] : @"";
        name.tag = index;
        name.identifier = @"imageName";
        name.target = self;
        name.action = @selector(imageItemChanged:);
        name.delegate = self;
        [name.widthAnchor constraintEqualToConstant:210].active = YES;

        NSString *dimensions = [NSString stringWithFormat:@"%@×%@",
                                image[@"width"] ?: @0,
                                image[@"height"] ?: @0];
        NSTextField *size = [NSTextField labelWithString:dimensions];
        [size.widthAnchor constraintEqualToConstant:62].active = YES;

        NSButton *up = [NSButton buttonWithTitle:@"↑" target:self action:@selector(moveImage:)];
        up.tag = index; up.identifier = @"up"; up.enabled = index > 0;
        NSButton *down = [NSButton buttonWithTitle:@"↓" target:self action:@selector(moveImage:)];
        down.tag = index; down.identifier = @"down"; down.enabled = index + 1 < self.imageItems.count;
        NSButton *remove = [NSButton buttonWithTitle:@"−" target:self action:@selector(removeImage:)];
        remove.tag = index;

        NSStackView *row = [NSStackView stackViewWithViews:@[thumbnail, name, size, up, down, remove]];
        row.spacing = 6;
        row.alignment = NSLayoutAttributeCenterY;
        [self.imageItemsStack addArrangedSubview:[self settingsCardContainingView:row]];
    }];
}

- (void)addImage:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes = @[@"png", @"jpg", @"jpeg", @"heic", @"tif", @"tiff", @"gif", @"bmp"];
#pragma clang diagnostic pop
    __weak typeof(self) weakSelf = self;
    void (^completion)(NSModalResponse) = ^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        for (NSURL *url in panel.URLs) {
            NSMutableDictionary *image = [self imageItemFromURL:url];
            if (image) [self.imageItems addObject:image];
        }
        [self rebuildImageItems];
        [self draftDidChange];
    };
    NSWindow *window = self.editorCard.window ?: self.window;
    if (window) {
        [panel beginSheetModalForWindow:window completionHandler:completion];
    } else {
        completion([panel runModal]);
    }
}

- (void)imageItemChanged:(NSTextField *)sender {
    if (MatrixCodeIsValidIndex(sender.tag, self.imageItems.count)) {
        NSString *name = MatrixCodeSettingText(sender.stringValue, 80);
        name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        self.imageItems[(NSUInteger)sender.tag][@"name"] = name.length ? name : @"Image";
    }
    [self draftDidChange];
}

- (void)removeImage:(NSButton *)sender {
    if (MatrixCodeIsValidIndex(sender.tag, self.imageItems.count)) {
        [self.imageItems removeObjectAtIndex:(NSUInteger)sender.tag];
    }
    [self rebuildImageItems];
    [self draftDidChange];
}

- (void)moveImage:(NSButton *)sender {
    NSInteger source = sender.tag;
    NSInteger destination = source + ([sender.identifier isEqualToString:@"up"] ? -1 : 1);
    if (MatrixCodeIsValidIndex(source, self.imageItems.count) &&
        MatrixCodeIsValidIndex(destination, self.imageItems.count)) {
        [self.imageItems exchangeObjectAtIndex:(NSUInteger)source
                             withObjectAtIndex:(NSUInteger)destination];
    }
    [self rebuildImageItems];
    [self draftDidChange];
}

- (void)imageNumberChanged:(NSTextField *)sender {
    BOOL percent = [sender.identifier hasSuffix:@"-percent"];
    BOOL seconds = [sender.identifier hasSuffix:@"-seconds"];
    NSString *key = [[sender.identifier stringByReplacingOccurrencesOfString:@"-percent" withString:@""]
        stringByReplacingOccurrencesOfString:@"-seconds" withString:@""];
    double value = sender.doubleValue * (percent ? 0.01 : (seconds ? 1000.0 : 1.0));
    if ([key isEqualToString:@"imageScale"]) value = MIN(1, MAX(0.05, value));
    else if ([key isEqualToString:@"imagePlacementJitter"]) value = MIN(1, MAX(0, value));
    else {
        BOOL minimumGap = [key isEqualToString:@"frequencyMs"] ||
            [key isEqualToString:@"persistenceMs"];
        value = MIN(600000, MAX(minimumGap ? 500 : 0, value));
    }
    self.images[key] = @(value);
    [self draftDidChange];
}

- (void)imageToggleChanged:(NSButton *)sender {
    self.images[sender.identifier] =
        MatrixCodeSettingBoolObject(sender.state == NSControlStateValueOn);
    [self draftDidChange];
}

- (void)optimizeImageVisibility:(id)sender {
    (void)sender;
    [self.images addEntriesFromDictionary:@{
        @"enabled": @YES,
        @"frequencyMs": @500,
        @"persistenceMs": @60000,
        @"appearMs": @0,
        @"disappearMs": @0,
        @"flickerOut": @NO,
        @"brightnessFade": @NO,
        @"imageScale": @1,
        @"imagePlacementJitter": @0,
    }];
    [self.controls addEntriesFromDictionary:@{
        @"density": @90,
        @"rampUpMs": @0,
        @"trailLength": @0.45,
        @"trailVariation": @0.2,
        @"speed": @0.6,
        @"glyphScale": @0.7,
        @"glow": @0.6,
        @"leadBrightness": @1,
        @"vignette": @0,
        @"scanlines": @NO,
        @"allowOverlap": @NO,
        @"quality": @"high",
        @"glyphMode": @"latin",
        @"glyphFont": @"mono",
        @"glyphRate": @1,
        @"mirror": @NO,
    }];
    [self draftDidChange];
    if ([self.editorKind isEqualToString:@"images"]) {
        [self presentEditorKind:@"images"];
    }
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
        name.tag = index; name.identifier = @"momentName"; name.target = self;
        name.action = @selector(momentChanged:); name.delegate = self;
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
        [self.momentsStack addArrangedSubview:[self settingsCardContainingView:row]];
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
    NSInteger source = sender.tag;
    NSInteger destination = source + ([sender.identifier isEqualToString:@"up"] ? -1 : 1);
    if (MatrixCodeIsValidIndex(source, self.moments.count) &&
        MatrixCodeIsValidIndex(destination, self.moments.count)) {
        [self.moments exchangeObjectAtIndex:(NSUInteger)source
                          withObjectAtIndex:(NSUInteger)destination];
    }
    [self rebuildMoments];
    [self draftDidChange];
}
- (void)removeMoment:(NSButton *)sender {
    if (MatrixCodeIsValidIndex(sender.tag, self.moments.count))
        [self.moments removeObjectAtIndex:(NSUInteger)sender.tag];
    [self rebuildMoments];
    [self draftDidChange];
}
- (void)momentChanged:(id)sender {
    NSInteger index = [sender tag];
    if (!MatrixCodeIsValidIndex(index, self.moments.count)) return;
    NSUInteger momentIndex = (NSUInteger)index;
    if ([[sender identifier] isEqualToString:@"momentName"]) {
        NSString *name = MatrixCodeSettingText([sender stringValue], 40);
        NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@":{}"];
        name = [[name componentsSeparatedByCharactersInSet:illegal] componentsJoinedByString:@""];
        self.moments[momentIndex][@"name"] = [name stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    } else if ([[sender identifier] isEqualToString:@"enabled"]) {
        BOOL enabled = [sender state] == NSControlStateValueOn;
        NSDatePicker *datePicker = nil;
        for (NSView *view in [sender superview].subviews) {
            if ([view isKindOfClass:NSDatePicker.class]) datePicker = (NSDatePicker *)view;
        }
        self.moments[momentIndex][@"targetMs"] = enabled && datePicker
            ? @(datePicker.dateValue.timeIntervalSince1970 * 1000.0) : NSNull.null;
        [self rebuildMoments];
    } else {
        self.moments[momentIndex][@"targetMs"] = @([[sender dateValue] timeIntervalSince1970] * 1000.0);
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
    NSMutableArray<NSDictionary *> *sanitizedImages = [NSMutableArray array];
    for (NSUInteger index = 0; index < self.imageItems.count; index++) {
        NSMutableDictionary *image = MatrixCodeSanitizedImageItem(self.imageItems[index]);
        if (image) [sanitizedImages addObject:image];
    }
    self.images[@"images"] = sanitizedImages;
    values[@"mx-images"] = MatrixCodeJSONString(self.images);
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

- (void)showPreviewWithIntro:(BOOL)intro message:(BOOL)message image:(BOOL)image {
    NSDictionary *values = [self serializedValues];
    self.previewController = [[MatrixCodeNativePreviewController alloc]
        initWithStoredValues:values showIntro:intro showMessage:message showImage:image];
    [self.previewController showWindow:nil];
    [self.previewController.window makeKeyAndOrderFront:nil];
}
- (void)showPreviewWithIntro:(BOOL)intro message:(BOOL)message {
    [self showPreviewWithIntro:intro message:message image:NO];
}
- (void)previewRain:(id)sender { [self showPreviewWithIntro:NO message:NO image:NO]; }
- (void)previewIntro:(id)sender { [self showPreviewWithIntro:YES message:NO image:NO]; }
- (void)previewMessage:(id)sender { [self showPreviewWithIntro:NO message:YES image:NO]; }
- (void)previewImage:(id)sender { [self showPreviewWithIntro:NO message:NO image:YES]; }

- (void)resetAll:(id)sender {
    [self resetControls:sender];
}

- (void)accept:(id)sender {
    if (self.editorBackdrop) {
        [self closeEditorSave:sender];
        return;
    }
    NSDictionary *values = [self serializedValues];
    values = [self commitSerializedValues:values];
    [self publishPreviewValues:values];
    [self.settingsHideTimer invalidate];
    self.settingsHideTimer = nil;
    [self.settingsAnimationTimer invalidate];
    self.settingsAnimationTimer = nil;
    [self.settingsMetalView setAnimationActive:NO];
    if (self.embeddedPresentation) {
        [self.settingsOverlayView removeFromSuperview];
        self.settingsOverlayView = nil;
    } else {
        [NSApp endSheet:self.window returnCode:NSModalResponseOK];
    }
    self.closeHandler();
}

- (void)cancel:(id)sender {
    if (self.editorBackdrop) {
        [self closeCurrentEditorFromDismissAction:sender];
        return;
    }
    NSDictionary *values = [self serializedValues];
    [self publishPreviewValues:values];
    [self.settingsHideTimer invalidate];
    self.settingsHideTimer = nil;
    [self.settingsAnimationTimer invalidate];
    self.settingsAnimationTimer = nil;
    [self.settingsMetalView setAnimationActive:NO];
    if (self.embeddedPresentation) {
        [self.settingsOverlayView removeFromSuperview];
        self.settingsOverlayView = nil;
    } else {
        [NSApp endSheet:self.window returnCode:NSModalResponseCancel];
    }
    self.closeHandler();
}

- (void)dealloc {
    [_settingsHideTimer invalidate];
    [_settingsAnimationTimer invalidate];
    [_settingsMetalView setAnimationActive:NO];
    [_charactersPreviewView setAnimationActive:NO];
}

@end
