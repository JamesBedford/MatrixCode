#import <XCTest/XCTest.h>

#import "MatrixCodeScreenSaverView.h"

@interface MatrixCodeScreenSaverView (Testing)
- (NSNotificationCenter *)screenSaverNotificationCenter;
@end

@interface MatrixCodeStopNotificationCenter : NSNotificationCenter
@property(nonatomic, strong) NSMutableArray<NSNotificationName> *observedNames;
@property(nonatomic, strong) NSMutableArray<NSOperationQueue *> *observerQueues;
@property(nonatomic) NSUInteger removedObserverCount;
@end

@implementation MatrixCodeStopNotificationCenter

- (instancetype)init {
    self = [super init];
    if (self) {
        _observedNames = [NSMutableArray array];
        _observerQueues = [NSMutableArray array];
    }
    return self;
}

- (id<NSObject>)addObserverForName:(NSNotificationName)name
                           object:(id)object
                            queue:(NSOperationQueue *)queue
                       usingBlock:(void (^)(NSNotification *))block {
    [self.observedNames addObject:name];
    [self.observerQueues addObject:queue];
    return [super addObserverForName:name object:object queue:queue usingBlock:block];
}

- (void)removeObserver:(id)observer {
    self.removedObserverCount++;
    [super removeObserver:observer];
}

@end

@interface MatrixCodeNotificationTestScreenSaver : MatrixCodeScreenSaverView
@property(nonatomic, strong) MatrixCodeStopNotificationCenter *testNotificationCenter;
@end

@implementation MatrixCodeNotificationTestScreenSaver

- (NSNotificationCenter *)screenSaverNotificationCenter {
    if (!_testNotificationCenter) {
        _testNotificationCenter = [[MatrixCodeStopNotificationCenter alloc] init];
    }
    return _testNotificationCenter;
}

@end

@interface MatrixCodeScreenSaverHostProbe : NSObject
@property(nonatomic) NSUInteger startCount;
@property(nonatomic) NSUInteger stopCount;
@property(nonatomic, copy) dispatch_block_t stopHandler;
@end

@implementation MatrixCodeScreenSaverHostProbe

- (void)startAnimation {
    self.startCount++;
}

- (void)stopAnimation {
    self.stopCount++;
    if (self.stopHandler) self.stopHandler();
}

- (void)animateOneFrame {
}

@end

@interface MatrixCodeScreenSaverViewTests : XCTestCase
@end

@implementation MatrixCodeScreenSaverViewTests

- (MatrixCodeScreenSaverHostProbe *)replaceHostInScreenSaver:(MatrixCodeScreenSaverView *)screenSaver {
    NSView *host = [screenSaver valueForKey:@"rainHostView"];
    [host removeFromSuperview];
    MatrixCodeScreenSaverHostProbe *probe = [[MatrixCodeScreenSaverHostProbe alloc] init];
    [screenSaver setValue:probe forKey:@"rainHostView"];
    return probe;
}

- (void)testPlaybackStopNotificationsUseMainQueueAndAllowExplicitRestart {
    MatrixCodeNotificationTestScreenSaver *screenSaver = [[MatrixCodeNotificationTestScreenSaver alloc]
        initWithFrame:NSZeroRect isPreview:NO];
    MatrixCodeScreenSaverHostProbe *probe = [self replaceHostInScreenSaver:screenSaver];
    MatrixCodeStopNotificationCenter *center = screenSaver.testNotificationCenter;
    XCTAssertEqualObjects(center.observedNames, (@[@"com.apple.screensaver.willstop",
                                                 @"com.apple.screensaver.didstop"]));
    for (NSOperationQueue *queue in center.observerQueues) {
        XCTAssertEqual(queue, NSOperationQueue.mainQueue);
    }

    [screenSaver startAnimation];
    XCTestExpectation *stopped = [self expectationWithDescription:@"Stop delivered on main queue"];
    probe.stopHandler = ^{
        XCTAssertTrue(NSThread.isMainThread);
        [stopped fulfill];
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [center postNotificationName:@"com.apple.screensaver.willstop" object:nil];
    });
    [self waitForExpectations:@[stopped] timeout:2];
    probe.stopHandler = nil;
    XCTAssertEqual(probe.startCount, 1u);
    XCTAssertEqual(probe.stopCount, 1u);

    [screenSaver startAnimation];
    XCTAssertEqual(probe.startCount, 2u);
    [center postNotificationName:@"com.apple.screensaver.didstop" object:nil];
    XCTAssertEqual(probe.stopCount, 2u);
    [screenSaver stopAnimation];
    XCTAssertEqual(probe.stopCount, 3u);
    XCTAssertEqual(center.observedNames.count, 2u);

    [center postNotificationName:@"com.apple.screensaver.didstart" object:nil];
    XCTAssertEqual(probe.startCount, 2u);
}

- (void)testPreviewIgnoresGlobalStopNotificationsAndHonorsLifecycleCallbacks {
    MatrixCodeNotificationTestScreenSaver *screenSaver = [[MatrixCodeNotificationTestScreenSaver alloc]
        initWithFrame:NSZeroRect isPreview:YES];
    MatrixCodeScreenSaverHostProbe *probe = [self replaceHostInScreenSaver:screenSaver];
    MatrixCodeStopNotificationCenter *center = (id)[screenSaver screenSaverNotificationCenter];
    XCTAssertEqual(center.observedNames.count, 0u);

    [screenSaver startAnimation];
    [center postNotificationName:@"com.apple.screensaver.willstop" object:nil];
    [center postNotificationName:@"com.apple.screensaver.didstop" object:nil];
    XCTAssertEqual(probe.stopCount, 0u);
    [screenSaver stopAnimation];
    XCTAssertEqual(probe.stopCount, 1u);
    [screenSaver startAnimation];
    XCTAssertEqual(probe.startCount, 2u);
    [screenSaver stopAnimation];
}

- (void)testStopObserversDoNotRetainScreenSaverAndAreRemovedOnDeallocation {
    __weak MatrixCodeScreenSaverView *weakScreenSaver;
    MatrixCodeStopNotificationCenter *center;
    MatrixCodeScreenSaverHostProbe *probe;
    @autoreleasepool {
        MatrixCodeNotificationTestScreenSaver *screenSaver = [[MatrixCodeNotificationTestScreenSaver alloc]
            initWithFrame:NSZeroRect isPreview:NO];
        weakScreenSaver = screenSaver;
        center = screenSaver.testNotificationCenter;
        probe = [self replaceHostInScreenSaver:screenSaver];
    }

    XCTAssertNil(weakScreenSaver);
    XCTAssertEqual(center.removedObserverCount, 2u);
    [center postNotificationName:@"com.apple.screensaver.willstop" object:nil];
    [center postNotificationName:@"com.apple.screensaver.didstop" object:nil];
    XCTAssertEqual(probe.stopCount, 0u);
}

@end
