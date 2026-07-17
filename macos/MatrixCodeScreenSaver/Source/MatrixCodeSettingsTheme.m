#import "MatrixCodeSettingsTheme.h"

#import <QuartzCore/QuartzCore.h>

NSNotificationName const MatrixCodeSettingsThemeDidChangeNotification =
    @"MatrixCodeSettingsThemeDidChangeNotification";

typedef NS_ENUM(NSInteger, MatrixCodeStyledControlRole) {
    MatrixCodeStyledControlRoleHeading1,
    MatrixCodeStyledControlRoleHeading2,
    MatrixCodeStyledControlRoleLabel,
    MatrixCodeStyledControlRoleHint,
    MatrixCodeStyledControlRoleButton,
    MatrixCodeStyledControlRoleCloseButton,
    MatrixCodeStyledControlRoleIconButton,
    MatrixCodeStyledControlRoleToggle,
    MatrixCodeStyledControlRoleTextField,
    MatrixCodeStyledControlRolePopup,
    MatrixCodeStyledControlRoleSlider,
    MatrixCodeStyledControlRoleReadout,
    MatrixCodeStyledControlRoleScrollView,
};

static NSColor *MatrixCodeSRGB(NSUInteger hex, CGFloat alpha) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 0xff) / 255.0
                              green:((hex >> 8) & 0xff) / 255.0
                               blue:(hex & 0xff) / 255.0
                              alpha:alpha];
}

static NSDictionary<NSString *, NSArray<NSNumber *> *> *MatrixCodeSettingsPalettes(void) {
    static NSDictionary<NSString *, NSArray<NSNumber *> *> *palettes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // background, body/dim, bright/accent -- identical to colorPresets.ts.
        palettes = @{
            @"classic": @[@0x0d0208, @0x008f11, @0x00ff41],
            @"amber":   @[@0x0a0600, @0xa85b00, @0xffb000],
            @"gold":    @[@0x0d0b00, @0xa89000, @0xffe21f],
            @"red":     @[@0x0d0202, @0xa80008, @0xff2a2a],
            @"pink":    @[@0x0d0207, @0xa80060, @0xff3da0],
            @"purple":  @[@0x08020d, @0x6e00a8, @0xb23bff],
            @"blue":    @[@0x02060d, @0x0066a8, @0x27d6ff],
            @"white":   @[@0x060606, @0x8c8c8c, @0xededed],
        };
    });
    return palettes;
}

@interface MatrixCodeSettingsTheme ()
@property (nonatomic) NSMapTable<NSView *, NSNumber *> *styledViews;
@property (nonatomic, readwrite) NSColor *accentColor;
@property (nonatomic, readwrite) NSColor *dimColor;
@property (nonatomic, readwrite) NSColor *backgroundColor;
@property (nonatomic, readwrite) NSColor *panelColor;
@property (nonatomic, readwrite) NSColor *borderColor;
@property (nonatomic, readwrite) NSColor *labelColor;
@end

@implementation MatrixCodeSettingsTheme

+ (MatrixCodeSettingsTheme *)sharedTheme {
    static MatrixCodeSettingsTheme *theme;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        theme = [[self alloc] init];
    });
    return theme;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _styledViews = [NSMapTable weakToStrongObjectsMapTable];
        _presetName = @"classic";
        [self updateColors];
    }
    return self;
}

- (void)setPresetName:(NSString *)presetName {
    NSString *validated = MatrixCodeSettingsPalettes()[presetName] ? presetName : @"classic";
    if ([_presetName isEqualToString:validated]) return;
    _presetName = [validated copy];
    [self updateColors];
    [self restyleRegisteredViews];
    [NSNotificationCenter.defaultCenter
        postNotificationName:MatrixCodeSettingsThemeDidChangeNotification object:self];
}

- (void)updateColors {
    NSArray<NSNumber *> *palette = MatrixCodeSettingsPalettes()[self.presetName]
        ?: MatrixCodeSettingsPalettes()[@"classic"];
    self.backgroundColor = MatrixCodeSRGB(palette[0].unsignedIntegerValue, 1.0);
    self.dimColor = MatrixCodeSRGB(palette[1].unsignedIntegerValue, 1.0);
    self.accentColor = MatrixCodeSRGB(palette[2].unsignedIntegerValue, 1.0);
    self.panelColor = MatrixCodeSRGB(0x040a06, 0.82);
    self.borderColor = [self.accentColor colorWithAlphaComponent:0.35];

    NSColor *accent = [self.accentColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    self.labelColor = [NSColor colorWithSRGBRed:accent.redComponent * 0.65 + 0.35
                                          green:accent.greenComponent * 0.65 + 0.35
                                           blue:accent.blueComponent * 0.65 + 0.35
                                          alpha:1.0];
}

- (NSFont *)monospacedFontOfSize:(CGFloat)size weight:(NSFontWeight)weight {
    NSString *face = weight >= NSFontWeightSemibold ? @"SFMono-Semibold" : @"SFMono-Regular";
    NSFont *font = [NSFont fontWithName:face size:size];
    return font ?: [NSFont monospacedSystemFontOfSize:size weight:weight];
}

- (void)registerView:(NSView *)view role:(MatrixCodeStyledControlRole)role {
    [self.styledViews setObject:@(role) forKey:view];
}

- (void)preserveAccessibilityForControl:(NSControl *)control originalTitle:(NSString *)original {
    if (control.accessibilityLabel.length == 0 && original.length > 0) {
        control.accessibilityLabel = original;
    }
}

- (NSAttributedString *)uppercaseString:(NSString *)string
                                   size:(CGFloat)size
                                 weight:(NSFontWeight)weight
                                  color:(NSColor *)color
                               tracking:(CGFloat)tracking {
    return [[NSAttributedString alloc] initWithString:string.uppercaseString attributes:@{
        NSFontAttributeName: [self monospacedFontOfSize:size weight:weight],
        NSForegroundColorAttributeName: color,
        NSKernAttributeName: @(size * tracking),
    }];
}

- (void)styleHeading:(NSTextField *)heading level:(NSInteger)level {
    MatrixCodeStyledControlRole role = level <= 1
        ? MatrixCodeStyledControlRoleHeading1 : MatrixCodeStyledControlRoleHeading2;
    [self registerView:heading role:role];
    NSString *original = heading.stringValue;
    [self preserveAccessibilityForControl:heading originalTitle:original];
    BOOL primary = level <= 1;
    heading.attributedStringValue =
        [self uppercaseString:original
                         size:primary ? 13.0 : 11.0
                       weight:NSFontWeightSemibold
                        color:primary ? self.accentColor : self.labelColor
                     tracking:primary ? 0.22 : 0.16];
    heading.editable = NO;
    heading.selectable = NO;
    heading.bordered = NO;
    heading.drawsBackground = NO;
    if (primary) {
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = [self.accentColor colorWithAlphaComponent:0.5];
        shadow.shadowBlurRadius = 8.0;
        heading.shadow = shadow;
    } else {
        heading.shadow = nil;
    }
}

- (void)styleLabel:(NSTextField *)label {
    [self registerView:label role:MatrixCodeStyledControlRoleLabel];
    NSString *original = label.stringValue;
    [self preserveAccessibilityForControl:label originalTitle:original];
    label.attributedStringValue =
        [self uppercaseString:original size:11 weight:NSFontWeightRegular
                        color:self.labelColor tracking:0.06];
    label.bordered = NO;
    label.drawsBackground = NO;
    label.editable = NO;
}

- (void)styleHintLabel:(NSTextField *)label {
    [self registerView:label role:MatrixCodeStyledControlRoleHint];
    label.font = [self monospacedFontOfSize:10 weight:NSFontWeightRegular];
    label.textColor = [self.accentColor colorWithAlphaComponent:0.5];
    label.bordered = NO;
    label.drawsBackground = NO;
    label.editable = NO;
}

- (void)prepareLayerForControl:(NSControl *)control radius:(CGFloat)radius {
    control.wantsLayer = YES;
    control.layer.cornerRadius = radius;
    control.layer.borderWidth = 1.0;
    control.layer.borderColor = self.borderColor.CGColor;
    control.layer.backgroundColor = [self.accentColor colorWithAlphaComponent:0.06].CGColor;
}

- (void)styleButton:(NSButton *)button {
    [self registerView:button role:MatrixCodeStyledControlRoleButton];
    NSString *original = button.title;
    [self preserveAccessibilityForControl:button originalTitle:original];
    button.bordered = NO;
    button.attributedTitle =
        [self uppercaseString:original size:12 weight:NSFontWeightRegular
                        color:self.accentColor tracking:0.08];
    [self prepareLayerForControl:button radius:6.0];
    button.layer.shadowOpacity = 0.0;
}

- (void)styleCloseButton:(NSButton *)button {
    [self registerView:button role:MatrixCodeStyledControlRoleCloseButton];
    button.bordered = NO;
    button.attributedTitle =
        [self uppercaseString:button.title.length ? button.title : @"✕"
                         size:15
                       weight:NSFontWeightSemibold
                        color:self.accentColor
                     tracking:0];
    button.wantsLayer = YES;
    button.layer.cornerRadius = 9.0;
    button.layer.masksToBounds = NO;
    button.layer.borderWidth = 1.5;
    // A bright ring plus an opaque, slightly raised fill and an accent glow keep
    // the button clearly bounded and anchored even while the rain behind it is
    // still pure black, without touching the rain preview itself.
    button.layer.borderColor = [self.accentColor colorWithAlphaComponent:0.85].CGColor;
    button.layer.backgroundColor = MatrixCodeSRGB(0x0e1d13, 0.96).CGColor;
    button.layer.shadowColor = self.accentColor.CGColor;
    button.layer.shadowOpacity = 0.5;
    button.layer.shadowRadius = 8.0;
    button.layer.shadowOffset = CGSizeZero;
}

- (void)styleIconButton:(NSButton *)button {
    [self registerView:button role:MatrixCodeStyledControlRoleIconButton];
    NSString *original = button.title;
    [self preserveAccessibilityForControl:button originalTitle:original];
    button.bordered = NO;
    button.font = [self monospacedFontOfSize:11 weight:NSFontWeightRegular];
    button.contentTintColor = self.accentColor;
    [self prepareLayerForControl:button radius:4.0];
    button.alphaValue = button.enabled ? 1.0 : 0.3;
}

- (void)styleToggleButton:(NSButton *)button on:(BOOL)on {
    [self registerView:button role:MatrixCodeStyledControlRoleToggle];
    if (button.title.length > 0 &&
        ![button.title isEqualToString:@"On"] && ![button.title isEqualToString:@"Off"]) {
        button.accessibilityLabel = button.title;
    }
    button.title = on ? @"On" : @"Off";
    button.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    button.bordered = NO;
    button.font = [self monospacedFontOfSize:12 weight:NSFontWeightRegular];
    button.contentTintColor = self.accentColor;
    [self prepareLayerForControl:button radius:5.0];
    button.layer.backgroundColor =
        [self.accentColor colorWithAlphaComponent:on ? 0.22 : 0.06].CGColor;
    button.layer.borderColor =
        (on ? self.accentColor : self.borderColor).CGColor;
}

- (void)styleTextField:(NSTextField *)textField {
    [self registerView:textField role:MatrixCodeStyledControlRoleTextField];
    textField.font = [self monospacedFontOfSize:11 weight:NSFontWeightRegular];
    textField.textColor = self.accentColor;
    textField.drawsBackground = YES;
    textField.backgroundColor = [self.accentColor colorWithAlphaComponent:0.06];
    textField.bordered = NO;
    textField.focusRingType = NSFocusRingTypeDefault;
    [self prepareLayerForControl:textField radius:5.0];
    textField.layer.backgroundColor = textField.backgroundColor.CGColor;
}

- (void)stylePopupButton:(NSPopUpButton *)popup {
    [self registerView:popup role:MatrixCodeStyledControlRolePopup];
    popup.font = [self monospacedFontOfSize:11 weight:NSFontWeightRegular];
    popup.contentTintColor = self.accentColor;
    popup.bordered = NO;
    [self prepareLayerForControl:popup radius:5.0];
}

- (void)styleSlider:(NSSlider *)slider readout:(NSTextField *)readout {
    [self registerView:slider role:MatrixCodeStyledControlRoleSlider];
    slider.trackFillColor = self.accentColor;
    if (readout) {
        [self registerView:readout role:MatrixCodeStyledControlRoleReadout];
        readout.font = [self monospacedFontOfSize:11 weight:NSFontWeightRegular];
        readout.textColor = self.accentColor;
        readout.alignment = NSTextAlignmentRight;
        readout.bordered = NO;
        readout.drawsBackground = NO;
    }
}

- (void)styleScrollView:(NSScrollView *)scrollView {
    [self registerView:scrollView role:MatrixCodeStyledControlRoleScrollView];
    scrollView.drawsBackground = NO;
    scrollView.borderType = NSNoBorder;
    scrollView.scrollerStyle = NSScrollerStyleOverlay;
}

- (void)restyleRegisteredViews {
    NSArray<NSView *> *views = self.styledViews.keyEnumerator.allObjects;
    for (NSView *view in views) {
        MatrixCodeStyledControlRole role = [self.styledViews objectForKey:view].integerValue;
        switch (role) {
            case MatrixCodeStyledControlRoleHeading1:
            case MatrixCodeStyledControlRoleHeading2:
                [self styleHeading:(NSTextField *)view
                             level:role == MatrixCodeStyledControlRoleHeading1 ? 1 : 2];
                break;
            case MatrixCodeStyledControlRoleLabel: [self styleLabel:(NSTextField *)view]; break;
            case MatrixCodeStyledControlRoleHint: [self styleHintLabel:(NSTextField *)view]; break;
            case MatrixCodeStyledControlRoleButton: [self styleButton:(NSButton *)view]; break;
            case MatrixCodeStyledControlRoleCloseButton: [self styleCloseButton:(NSButton *)view]; break;
            case MatrixCodeStyledControlRoleIconButton: [self styleIconButton:(NSButton *)view]; break;
            case MatrixCodeStyledControlRoleToggle:
                [self styleToggleButton:(NSButton *)view on:((NSButton *)view).state == NSControlStateValueOn];
                break;
            case MatrixCodeStyledControlRoleTextField: [self styleTextField:(NSTextField *)view]; break;
            case MatrixCodeStyledControlRolePopup: [self stylePopupButton:(NSPopUpButton *)view]; break;
            case MatrixCodeStyledControlRoleSlider: [self styleSlider:(NSSlider *)view readout:nil]; break;
            case MatrixCodeStyledControlRoleReadout: {
                NSTextField *field = (NSTextField *)view;
                field.font = [self monospacedFontOfSize:11 weight:NSFontWeightRegular];
                field.textColor = self.accentColor;
                break;
            }
            case MatrixCodeStyledControlRoleScrollView: [self styleScrollView:(NSScrollView *)view]; break;
        }
    }
}

@end

@implementation MatrixCodeSettingsPanelView

- (void)syncLayerAppearance {
    MatrixCodeSettingsTheme *theme = MatrixCodeSettingsTheme.sharedTheme;
    self.layer.cornerRadius = self.modal ? 12.0 : 10.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = theme.borderColor.CGColor;
    self.layer.backgroundColor = theme.panelColor.CGColor;
}

- (void)commonInit {
    self.wantsLayer = YES;
    self.layer.masksToBounds = NO;
    self.layer.shadowColor = NSColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.7;
    self.layer.shadowRadius = 30.0;
    self.layer.shadowOffset = CGSizeMake(0, -12);
    [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(themeChanged:)
                                                   name:MatrixCodeSettingsThemeDidChangeNotification
                                                 object:nil];
    [self syncLayerAppearance];
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) [self commonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self commonInit];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)isOpaque { return NO; }

- (void)setModal:(BOOL)modal {
    _modal = modal;
    [self syncLayerAppearance];
    [self setNeedsDisplay:YES];
}

- (void)themeChanged:(NSNotification *)notification {
    [self syncLayerAppearance];
    [self setNeedsDisplay:YES];
}

- (void)layout {
    [super layout];
    CGFloat radius = self.modal ? 12.0 : 10.0;
    CGPathRef path = CGPathCreateWithRoundedRect(NSRectToCGRect(self.bounds),
                                                radius, radius, NULL);
    self.layer.shadowPath = path;
    CGPathRelease(path);
}

- (void)drawRect:(NSRect)dirtyRect {
    MatrixCodeSettingsTheme *theme = MatrixCodeSettingsTheme.sharedTheme;
    CGFloat radius = self.modal ? 12.0 : 10.0;
    NSRect bounds = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *inner = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 2, 2)
                                                          xRadius:radius - 2 yRadius:radius - 2];
    [[theme.accentColor colorWithAlphaComponent:0.05] setStroke];
    inner.lineWidth = 3;
    [inner stroke];
}

@end

@implementation MatrixCodeSettingsCardView

- (void)syncLayerAppearance {
    MatrixCodeSettingsTheme *theme = MatrixCodeSettingsTheme.sharedTheme;
    self.layer.cornerRadius = 8.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = theme.borderColor.CGColor;
    self.layer.backgroundColor = [theme.accentColor colorWithAlphaComponent:0.04].CGColor;
}

- (void)commonInit {
    self.wantsLayer = YES;
    [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(themeChanged:)
                                                   name:MatrixCodeSettingsThemeDidChangeNotification
                                                 object:nil];
    [self syncLayerAppearance];
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) [self commonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self commonInit];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)isOpaque { return NO; }

- (void)themeChanged:(NSNotification *)notification {
    [self syncLayerAppearance];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
}

@end
