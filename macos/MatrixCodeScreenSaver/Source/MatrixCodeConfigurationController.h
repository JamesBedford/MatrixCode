#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MatrixCodeConfigurationController : NSWindowController
- (instancetype)initWithCloseHandler:(dispatch_block_t)closeHandler;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
