#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const MatrixCodePreviewValuesDidChangeNotification;
FOUNDATION_EXPORT NSString * const MatrixCodePreviewValuesKey;

typedef void (^MatrixCodeIntroPreviewHandler)(
    NSDictionary<NSString *, NSString *> *storedValues,
    dispatch_block_t completion
);
typedef void (^MatrixCodeMessagePreviewHandler)(
    NSDictionary<NSString *, NSString *> *storedValues
);

@interface MatrixCodeConfigurationController : NSWindowController
- (instancetype)initWithCloseHandler:(dispatch_block_t)closeHandler;
- (instancetype)initEmbeddedInView:(NSView *)hostView closeHandler:(dispatch_block_t)closeHandler;
- (instancetype)initEmbeddedInView:(NSView *)hostView
                       closeHandler:(dispatch_block_t)closeHandler
                 replayIntroHandler:(nullable dispatch_block_t)replayIntroHandler;
- (instancetype)initEmbeddedInView:(NSView *)hostView
                       closeHandler:(dispatch_block_t)closeHandler
                 replayIntroHandler:(nullable dispatch_block_t)replayIntroHandler
                introPreviewHandler:(nullable MatrixCodeIntroPreviewHandler)introPreviewHandler
              messagePreviewHandler:(nullable MatrixCodeMessagePreviewHandler)messagePreviewHandler
                   resetRainHandler:(nullable dispatch_block_t)resetRainHandler;
- (instancetype)initEmbeddedInView:(NSView *)hostView
                       closeHandler:(dispatch_block_t)closeHandler
                 replayIntroHandler:(nullable dispatch_block_t)replayIntroHandler
                introPreviewHandler:(nullable MatrixCodeIntroPreviewHandler)introPreviewHandler
              messagePreviewHandler:(nullable MatrixCodeMessagePreviewHandler)messagePreviewHandler
                   resetRainHandler:(nullable dispatch_block_t)resetRainHandler
  restrictedToMultiMonitorControls:(BOOL)restrictedToMultiMonitorControls;
- (instancetype)init NS_UNAVAILABLE;
- (void)showSettingsPanel;
- (void)dismissSettingsPanelAnimated;
- (void)openEditorKind:(NSString *)kind;
- (void)refreshEmbeddedPresentationLayout;
- (BOOL)toggleMessagesEnabled;
- (BOOL)toggleImagesEnabled;
- (void)nudgeDensityByFactor:(double)factor;
@end

NS_ASSUME_NONNULL_END
