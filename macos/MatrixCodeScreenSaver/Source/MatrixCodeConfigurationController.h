#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const MatrixCodePreviewValuesDidChangeNotification;
FOUNDATION_EXPORT NSString * const MatrixCodePreviewValuesKey;

@interface MatrixCodeConfigurationController : NSWindowController
- (instancetype)initWithCloseHandler:(dispatch_block_t)closeHandler;
- (instancetype)initEmbeddedInView:(NSView *)hostView closeHandler:(dispatch_block_t)closeHandler;
- (instancetype)init NS_UNAVAILABLE;
- (void)showSettingsPanel;
- (void)openEditorKind:(NSString *)kind;
- (void)toggleMessagesEnabled;
- (void)nudgeDensityByFactor:(double)factor;
@end

NS_ASSUME_NONNULL_END
