#import <XCTest/XCTest.h>

#import "MatrixCodeRainHostView.h"
#import "MatrixCodeScreenSaverView.h"

@interface MatrixCodeScreenSaverView (Testing)
- (NSNotificationCenter *)screenSaverNotificationCenter;
- (void)terminateLegacyScreenSaverHost;
+ (BOOL)resolvedPreviewForRequestedPreview:(BOOL)isPreview
                                     frame:(NSRect)frame
               operatingSystemMajorVersion:(NSInteger)majorVersion;
+ (BOOL)retiresLegacyScreenSaverHostForOperatingSystemMajorVersion:(NSInteger)majorVersion;
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
@property(nonatomic) NSUInteger terminationCount;
@end

@implementation MatrixCodeNotificationTestScreenSaver

- (NSNotificationCenter *)screenSaverNotificationCenter {
    if (!_testNotificationCenter) {
        _testNotificationCenter = [[MatrixCodeStopNotificationCenter alloc] init];
    }
    return _testNotificationCenter;
}

- (void)terminateLegacyScreenSaverHost {
    self.terminationCount++;
}

@end

@interface MatrixCodeSequoiaNotificationTestScreenSaver : MatrixCodeNotificationTestScreenSaver
@end

@implementation MatrixCodeSequoiaNotificationTestScreenSaver

+ (BOOL)resolvedPreviewForRequestedPreview:(BOOL)isPreview
                                     frame:(NSRect)frame
               operatingSystemMajorVersion:(NSInteger)majorVersion {
    (void)majorVersion;
    return [super resolvedPreviewForRequestedPreview:isPreview
                                               frame:frame
                         operatingSystemMajorVersion:15];
}

+ (BOOL)retiresLegacyScreenSaverHostForOperatingSystemMajorVersion:(NSInteger)majorVersion {
    (void)majorVersion;
    return [super retiresLegacyScreenSaverHostForOperatingSystemMajorVersion:15];
}

@end

@interface MatrixCodeTahoeNotificationTestScreenSaver : MatrixCodeNotificationTestScreenSaver
@end

@implementation MatrixCodeTahoeNotificationTestScreenSaver

+ (BOOL)resolvedPreviewForRequestedPreview:(BOOL)isPreview
                                     frame:(NSRect)frame
               operatingSystemMajorVersion:(NSInteger)majorVersion {
    (void)majorVersion;
    return [super resolvedPreviewForRequestedPreview:isPreview
                                               frame:frame
                         operatingSystemMajorVersion:26];
}

+ (BOOL)retiresLegacyScreenSaverHostForOperatingSystemMajorVersion:(NSInteger)majorVersion {
    (void)majorVersion;
    return [super retiresLegacyScreenSaverHostForOperatingSystemMajorVersion:26];
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

- (void)testPlaybackWillStopCleansUpAndRetiresLegacyHost {
    MatrixCodeSequoiaNotificationTestScreenSaver *screenSaver =
        [[MatrixCodeSequoiaNotificationTestScreenSaver alloc]
            initWithFrame:NSZeroRect isPreview:NO];
    MatrixCodeScreenSaverHostProbe *probe = [self replaceHostInScreenSaver:screenSaver];
    MatrixCodeStopNotificationCenter *center = screenSaver.testNotificationCenter;
    XCTAssertEqualObjects(center.observedNames, (@[@"com.apple.screensaver.willstop"]));
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
    XCTAssertEqual(screenSaver.terminationCount, 1u);

    // A lagging didstop from a previous activation must not tear down a fresh renderer.
    [screenSaver startAnimation];
    XCTAssertEqual(probe.startCount, 2u);
    [center postNotificationName:@"com.apple.screensaver.didstop" object:nil];
    XCTAssertEqual(probe.stopCount, 1u);
    XCTAssertEqual(screenSaver.terminationCount, 1u);
    [screenSaver stopAnimation];
    XCTAssertEqual(probe.stopCount, 2u);
    XCTAssertEqual(center.observedNames.count, 1u);

    [center postNotificationName:@"com.apple.screensaver.didstart" object:nil];
    XCTAssertEqual(probe.startCount, 2u);
}

- (void)testTahoePlaybackWillStopCleansUpWithoutRetiringLegacyHost {
    MatrixCodeTahoeNotificationTestScreenSaver *screenSaver =
        [[MatrixCodeTahoeNotificationTestScreenSaver alloc]
            initWithFrame:NSZeroRect isPreview:NO];
    MatrixCodeScreenSaverHostProbe *probe = [self replaceHostInScreenSaver:screenSaver];
    MatrixCodeStopNotificationCenter *center = screenSaver.testNotificationCenter;
    XCTAssertEqualObjects(center.observedNames, (@[@"com.apple.screensaver.willstop"]));

    [screenSaver startAnimation];
    [center postNotificationName:@"com.apple.screensaver.willstop" object:nil];

    // Tahoe relaunches the extension as soon as the host exits and starts a fresh set of
    // saver views for the session that is already ending. Those views never receive a stop
    // callback, so they render forever and every display stays black on the next
    // activation. Cleanup must run without retiring the host.
    XCTAssertEqual(probe.stopCount, 1u);
    XCTAssertEqual(screenSaver.terminationCount, 0u);

    [screenSaver startAnimation];
    XCTAssertEqual(probe.startCount, 2u);
    [screenSaver stopAnimation];
    XCTAssertEqual(probe.stopCount, 2u);
    XCTAssertEqual(screenSaver.terminationCount, 0u);
}

- (void)testLegacyHostRetirementIsLimitedToTheAffectedSystemVersions {
    for (NSNumber *majorVersion in @[@13, @14, @15]) {
        XCTAssertTrue([MatrixCodeScreenSaverView
            retiresLegacyScreenSaverHostForOperatingSystemMajorVersion:majorVersion.integerValue]);
    }
    for (NSNumber *majorVersion in @[@26, @27]) {
        XCTAssertFalse([MatrixCodeScreenSaverView
            retiresLegacyScreenSaverHostForOperatingSystemMajorVersion:majorVersion.integerValue]);
    }
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
    XCTAssertEqual(center.removedObserverCount, 1u);
    [center postNotificationName:@"com.apple.screensaver.willstop" object:nil];
    [center postNotificationName:@"com.apple.screensaver.didstop" object:nil];
    XCTAssertEqual(probe.stopCount, 0u);
}

- (void)testPreTahoeFullscreenFrameOverridesIncorrectPreviewFlag {
    for (NSNumber *majorVersion in @[@13, @14, @15]) {
        XCTAssertFalse([MatrixCodeScreenSaverView
            resolvedPreviewForRequestedPreview:YES
                                         frame:NSMakeRect(0, 0, 1920, 1080)
                   operatingSystemMajorVersion:majorVersion.integerValue]);
    }
}

- (void)testSequoiaIncorrectPreviewFlagCreatesPlaybackHostAndWillStopObserver {
    MatrixCodeSequoiaNotificationTestScreenSaver *screenSaver =
        [[MatrixCodeSequoiaNotificationTestScreenSaver alloc]
            initWithFrame:NSMakeRect(0, 0, 1920, 1080)
               isPreview:YES];
    MatrixCodeRainHostView *host = [screenSaver valueForKey:@"rainHostView"];
    XCTAssertEqual([[host valueForKey:@"mode"] integerValue],
                   MatrixCodeRainHostModeScreenSaverPlayback);
    XCTAssertEqualObjects(screenSaver.testNotificationCenter.observedNames,
                          (@[@"com.apple.screensaver.willstop"]));
}

- (void)testSequoiaSettingsFrameRemainsPreviewWhenPreviewFlagIsTrue {
    XCTAssertTrue([MatrixCodeScreenSaverView
        resolvedPreviewForRequestedPreview:YES
                                     frame:NSMakeRect(0, 0, 296, 184)
               operatingSystemMajorVersion:15]);
}

- (void)testTahoeLeavesHostPreviewFlagUnchanged {
    XCTAssertTrue([MatrixCodeScreenSaverView
        resolvedPreviewForRequestedPreview:YES
                                     frame:NSMakeRect(0, 0, 1920, 1080)
               operatingSystemMajorVersion:26]);
}

- (void)testExplicitPlaybackFlagAlwaysRemainsPlayback {
    for (NSNumber *majorVersion in @[@13, @15, @26]) {
        XCTAssertFalse([MatrixCodeScreenSaverView
            resolvedPreviewForRequestedPreview:NO
                                         frame:NSMakeRect(0, 0, 296, 184)
                   operatingSystemMajorVersion:majorVersion.integerValue]);
    }
}

@end
