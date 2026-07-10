#import "MatrixCodeScreenSaverView.h"

#import "MatrixCodeRainHostView.h"

@interface MatrixCodeScreenSaverView ()
@property(nonatomic, strong) MatrixCodeRainHostView *rainHostView;
@end

@implementation MatrixCodeScreenSaverView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        self.animationTimeInterval = 1.0;
        MatrixCodeRainHostMode mode = isPreview
            ? MatrixCodeRainHostModeScreenSaverPreview
            : MatrixCodeRainHostModeScreenSaverPlayback;
        _rainHostView = [[MatrixCodeRainHostView alloc] initWithFrame:self.bounds mode:mode];
        [self addSubview:_rainHostView];
    }
    return self;
}

- (void)startAnimation {
    [super startAnimation];
    [self.rainHostView startAnimation];
}

- (void)stopAnimation {
    [self.rainHostView stopAnimation];
    [super stopAnimation];
}

- (void)animateOneFrame {
    [self.rainHostView animateOneFrame];
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    [self.rainHostView mouseDown:event];
}

- (void)keyDown:(NSEvent *)event {
    [self.rainHostView keyDown:event];
}

- (void)cancelOperation:(id)sender {
    [self.rainHostView cancelOperation:sender];
}

- (BOOL)hasConfigureSheet {
    return YES;
}

- (NSWindow *)configureSheet {
    return [self.rainHostView configureWindow];
}

@end
