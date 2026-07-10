#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MatrixCodeRainHostMode) {
    MatrixCodeRainHostModeStandalone,
    MatrixCodeRainHostModeScreenSaverPreview,
    MatrixCodeRainHostModeScreenSaverPlayback,
};

@interface MatrixCodeRainHostView : NSView

@property(nonatomic) BOOL usesInternalAnimationTimer;

- (instancetype)initWithFrame:(NSRect)frame mode:(MatrixCodeRainHostMode)mode;
- (instancetype)initWithFrame:(NSRect)frame
                         mode:(MatrixCodeRainHostMode)mode
                      session:(nullable NSDictionary<NSString *, id> *)session
        suppressesIntroOverlay:(BOOL)suppressesIntroOverlay;
- (void)startAnimation;
- (void)stopAnimation;
- (void)animateOneFrame;
- (NSWindow *)configureWindow;

@end

extern NSString * const MatrixCodeRainHostRequestMultiMonitorNotification;
extern NSString * const MatrixCodeRainHostRequestExitMultiMonitorNotification;

NS_ASSUME_NONNULL_END
