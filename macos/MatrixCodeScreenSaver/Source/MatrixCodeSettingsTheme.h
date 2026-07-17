#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted after ``presetName`` and all semantic colors have changed.
FOUNDATION_EXPORT NSNotificationName const MatrixCodeSettingsThemeDidChangeNotification;

/// Native counterpart of the web settings UI's semantic design tokens.
@interface MatrixCodeSettingsTheme : NSObject

@property (class, nonatomic, readonly) MatrixCodeSettingsTheme *sharedTheme;

@property (nonatomic, copy) NSString *presetName;
@property (nonatomic, readonly) NSColor *accentColor;
@property (nonatomic, readonly) NSColor *dimColor;
@property (nonatomic, readonly) NSColor *backgroundColor;
@property (nonatomic, readonly) NSColor *panelColor;
@property (nonatomic, readonly) NSColor *borderColor;
@property (nonatomic, readonly) NSColor *labelColor;

- (NSFont *)monospacedFontOfSize:(CGFloat)size weight:(NSFontWeight)weight;

- (void)styleHeading:(NSTextField *)heading level:(NSInteger)level;
- (void)styleLabel:(NSTextField *)label;
- (void)styleHintLabel:(NSTextField *)label;
- (void)styleButton:(NSButton *)button;
- (void)styleIconButton:(NSButton *)button;
/// High-contrast floating dismiss button that stays legible over black rain.
- (void)styleCloseButton:(NSButton *)button;
- (void)styleToggleButton:(NSButton *)button on:(BOOL)on;
- (void)styleTextField:(NSTextField *)textField;
- (void)stylePopupButton:(NSPopUpButton *)popup;
- (void)styleSlider:(NSSlider *)slider readout:(nullable NSTextField *)readout;
- (void)styleScrollView:(NSScrollView *)scrollView;

@end

/// Dark translucent rounded panel matching `.mx-panel` / `.mx-modal`.
@interface MatrixCodeSettingsPanelView : NSView

/// Modal panels use a 12-point radius; compact settings panels use 10.
@property (nonatomic) BOOL modal;

@end

/// Accent-tinted bordered list row matching `.mx-line`.
@interface MatrixCodeSettingsCardView : NSView
@end

NS_ASSUME_NONNULL_END
