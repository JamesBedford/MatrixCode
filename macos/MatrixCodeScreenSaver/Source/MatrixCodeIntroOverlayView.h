#import <AppKit/AppKit.h>

@class MatrixCodeTokenResolver;

NS_ASSUME_NONNULL_BEGIN

@interface MatrixCodeIntroOverlayView : NSView

@property(nonatomic, readonly) BOOL hasIntro;
@property(nonatomic, readonly) BOOL playing;
@property(nonatomic, readonly) BOOL rainDuringIntro;
@property(nonatomic, readonly) NSTimeInterval postIntroDelay;
@property(nonatomic, readonly) NSTimeInterval totalDuration;

- (instancetype)initWithFrame:(NSRect)frame
                 storedValues:(NSDictionary<NSString *, NSString *> *)storedValues
                tokenResolver:(MatrixCodeTokenResolver *)tokenResolver
                   completion:(dispatch_block_t)completion;
- (void)reloadStoredValues:(NSDictionary<NSString *, NSString *> *)storedValues
             tokenResolver:(MatrixCodeTokenResolver *)tokenResolver;
- (void)startAtDate:(NSDate *)date;
- (void)replayAtDate:(NSDate *)date;
- (void)shiftTimelineBy:(NSTimeInterval)interval;
- (void)updateAtDate:(NSDate *)date framesPerSecond:(double)framesPerSecond;
- (void)skip;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
