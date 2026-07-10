#import "MatrixCodeAppDelegate.h"

#import "MatrixCodePreferences.h"
#import "MatrixCodeMetalView.h"
#import "MatrixCodeRainHostView.h"
#import "MatrixCodeSession.h"

@interface MatrixCodePresentationWindow : NSWindow
@end

@implementation MatrixCodePresentationWindow

- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen {
    return frameRect;
}

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (BOOL)canBecomeMainWindow {
    return YES;
}

@end

NSWindowCollectionBehavior MatrixCodeMultiMonitorWindowCollectionBehavior(void) {
    return NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorStationary |
        NSWindowCollectionBehaviorIgnoresCycle;
}

@interface MatrixCodeAppDelegate () <NSMenuItemValidation>
@property(nonatomic, strong) NSMutableArray<NSWindow *> *windows;
@property(nonatomic, strong) NSMutableArray<NSWindow *> *multiMonitorWindows;
@property(nonatomic, weak, nullable) NSWindow *preMultiMonitorKeyWindow;
@property(nonatomic) BOOL applicationIsTerminating;
@end

@implementation MatrixCodeAppDelegate

static NSString * const MatrixCodeDisplayName = @"Matrix Code";

- (instancetype)init {
    self = [super init];
    if (self) {
        _windows = [NSMutableArray array];
        _multiMonitorWindows = [NSMutableArray array];
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(enterMultiMonitorFromNotification:)
                   name:MatrixCodeRainHostRequestMultiMonitorNotification
                 object:nil];
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(exitMultiMonitor:)
                   name:MatrixCodeRainHostRequestExitMultiMonitorNotification
                 object:nil];
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(fpsOverlayVisibilityDidChange:)
                   name:MatrixCodeRainHostFPSOverlayVisibilityDidChangeNotification
                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self buildMenuBar];
    [self newWindow:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self restoreSavedPresentationMode];
    });
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    self.applicationIsTerminating = YES;
    [self persistCurrentPresentationMode];
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (!self.applicationIsTerminating) {
        self.applicationIsTerminating = YES;
        [self persistCurrentPresentationMode];
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    if (!flag) {
        [self newWindow:nil];
    }
    return YES;
}

- (IBAction)newWindow:(id)sender {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 600)
                                                  styleMask:NSWindowStyleMaskTitled |
                                                            NSWindowStyleMaskClosable |
                                                            NSWindowStyleMaskMiniaturizable |
                                                            NSWindowStyleMaskResizable
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    window.title = MatrixCodeDisplayName;
    window.minSize = NSMakeSize(480, 300);
    window.releasedWhenClosed = NO;
    window.delegate = self;
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    BOOL restoredFrame = [window setFrameUsingName:@"MatrixCodeMainWindow"];
    [window setFrameAutosaveName:@"MatrixCodeMainWindow"];

    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone];
    hostView.usesInternalAnimationTimer = YES;
    window.contentView = hostView;
    [hostView startAnimation];

    [self.windows addObject:window];
    if (!restoredFrame) {
        [window center];
    }
    [window makeKeyAndOrderFront:nil];
    [window makeFirstResponder:hostView];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)restoreSavedPresentationMode {
    MatrixCodeAppPresentationMode mode = [MatrixCodePreferences savedAppPresentationMode];
    if ([mode isEqualToString:MatrixCodeAppPresentationModeMultiMonitor]) {
        [self enterMultiMonitorFromHost:[self hostViewForSettings]];
        return;
    }
    if ([mode isEqualToString:MatrixCodeAppPresentationModeFullScreen]) {
        MatrixCodeRainHostView *hostView = [self hostViewForSettings];
        NSWindow *window = hostView.window;
        if (window && !(window.styleMask & NSWindowStyleMaskFullScreen)) {
            [window toggleFullScreen:self];
        }
    }
}

- (void)persistPresentationMode:(MatrixCodeAppPresentationMode)mode {
    [MatrixCodePreferences setSavedAppPresentationMode:mode];
}

- (MatrixCodeAppPresentationMode)presentationModeForWindow:(NSWindow *)window {
    return window && (window.styleMask & NSWindowStyleMaskFullScreen)
        ? MatrixCodeAppPresentationModeFullScreen
        : MatrixCodeAppPresentationModeWindowed;
}

- (BOOL)hasFullScreenMainWindow {
    for (NSWindow *window in self.windows) {
        if (window.styleMask & NSWindowStyleMaskFullScreen) {
            return YES;
        }
    }
    return NO;
}

- (void)persistCurrentPresentationMode {
    if (self.multiMonitorWindows.count > 0) {
        [self persistPresentationMode:MatrixCodeAppPresentationModeMultiMonitor];
    } else if ([self hasFullScreenMainWindow]) {
        [self persistPresentationMode:MatrixCodeAppPresentationModeFullScreen];
    } else {
        [self persistPresentationMode:MatrixCodeAppPresentationModeWindowed];
    }
}

- (IBAction)showSettings:(id)sender {
    MatrixCodeRainHostView *hostView = [self hostViewForSettings];
    [hostView showSettingsOverlay];
    [NSApp activateIgnoringOtherApps:YES];
}

- (IBAction)toggleFullScreenFromMenu:(id)sender {
    if (self.multiMonitorWindows.count > 0) return;
    MatrixCodeRainHostView *hostView = [self hostViewForSettings];
    [hostView.window toggleFullScreen:sender ?: self];
}

- (IBAction)toggleMultiMonitorFromMenu:(id)sender {
    if (self.multiMonitorWindows.count > 0) {
        [self exitMultiMonitor:sender];
        return;
    }
    MatrixCodeRainHostView *hostView = [self hostViewForSettings];
    [self enterMultiMonitorFromHost:hostView];
}

- (void)enterMultiMonitorFromNotification:(NSNotification *)notification {
    MatrixCodeRainHostView *hostView = [notification.object isKindOfClass:MatrixCodeRainHostView.class]
        ? notification.object
        : [self hostViewForSettings];
    [self enterMultiMonitorFromHost:hostView];
}

- (void)enterMultiMonitorFromHost:(MatrixCodeRainHostView *)requestingHost {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (screens.count <= 1) {
        NSWindow *window = requestingHost.window ?: NSApp.keyWindow;
        if (window && !(window.styleMask & NSWindowStyleMaskFullScreen)) {
            [window toggleFullScreen:requestingHost ?: self];
        }
        [self persistPresentationMode:MatrixCodeAppPresentationModeFullScreen];
        return;
    }

    [self exitMultiMonitor:nil];
    self.preMultiMonitorKeyWindow = requestingHost.window ?: NSApp.keyWindow;
    [NSApp activateIgnoringOtherApps:YES];
    NSMutableDictionary<NSString *, id> *sharedSession =
        [[MatrixCodeSession sessionForScreen:screens.firstObject] mutableCopy];
    NSInteger sharedFramesPerSecond = 0;
    for (NSScreen *screen in screens) {
        NSInteger framesPerSecond = [MatrixCodeMetalView maximumFramesPerSecondForScreen:screen];
        if (framesPerSecond <= 0) continue;
        sharedFramesPerSecond = sharedFramesPerSecond <= 0
            ? framesPerSecond
            : MIN(sharedFramesPerSecond, framesPerSecond);
    }
    if (sharedFramesPerSecond > 0) {
        sharedSession[@"preferredFramesPerSecond"] = @(sharedFramesPerSecond);
    }
    NSString *controlsScreenId = [sharedSession[@"controlsScreenId"] isKindOfClass:NSString.class]
        ? sharedSession[@"controlsScreenId"] : nil;
    BOOL showFPSOverlay = requestingHost.fpsOverlayVisible;
    NSWindow *controlsWindow = nil;
    MatrixCodeRainHostView *controlsHostView = nil;

    for (NSScreen *screen in screens) {
        NSRect frame = screen.frame;
        MatrixCodePresentationWindow *window =
            [[MatrixCodePresentationWindow alloc] initWithContentRect:frame
                                                            styleMask:NSWindowStyleMaskBorderless
                                                              backing:NSBackingStoreBuffered
                                                                defer:NO
                                                               screen:screen];
        window.title = @"Matrix Code Multi-monitor";
        window.backgroundColor = NSColor.blackColor;
        window.opaque = YES;
        window.hasShadow = NO;
        window.animationBehavior = NSWindowAnimationBehaviorNone;
        window.releasedWhenClosed = NO;
        window.delegate = self;
        window.level = NSScreenSaverWindowLevel;
        window.collectionBehavior = MatrixCodeMultiMonitorWindowCollectionBehavior();
        [window setFrame:frame display:NO];

        NSMutableDictionary<NSString *, id> *screenSession = [sharedSession mutableCopy];
        screenSession[@"currentScreenId"] = [MatrixCodeSession identifierForScreen:screen];
        MatrixCodeRainHostView *hostView =
            [[MatrixCodeRainHostView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)
                                                     mode:MatrixCodeRainHostModeStandalone
                                                  session:screenSession
                                    suppressesIntroOverlay:YES];
        hostView.usesInternalAnimationTimer = YES;
        window.contentView = hostView;
        [hostView startAnimation];
        if (showFPSOverlay) {
            [hostView setFPSOverlayVisible:YES];
        }
        if (controlsScreenId &&
            [controlsScreenId isEqualToString:[MatrixCodeSession identifierForScreen:screen]]) {
            controlsWindow = window;
            controlsHostView = hostView;
        }

        [self.multiMonitorWindows addObject:window];
        [window makeKeyAndOrderFront:nil];
        [window orderFrontRegardless];
        [window setFrame:frame display:YES];
        [window displayIfNeeded];
        [window makeFirstResponder:hostView];
    }

    NSWindow *keyWindow = controlsWindow ?: self.multiMonitorWindows.firstObject;
    MatrixCodeRainHostView *keyHostView = controlsHostView ?: [self hostViewInWindow:keyWindow];
    [keyWindow makeKeyAndOrderFront:nil];
    if (keyHostView) [keyWindow makeFirstResponder:keyHostView];
    [self persistPresentationMode:MatrixCodeAppPresentationModeMultiMonitor];
}

- (NSArray<MatrixCodeRainHostView *> *)multiMonitorHostViews {
    NSMutableArray<MatrixCodeRainHostView *> *hostViews = [NSMutableArray array];
    for (NSWindow *window in self.multiMonitorWindows) {
        MatrixCodeRainHostView *hostView = [self hostViewInWindow:window];
        if (hostView) [hostViews addObject:hostView];
    }
    return hostViews;
}

- (void)setFPSOverlayVisible:(BOOL)visible
                forHostViews:(NSArray<MatrixCodeRainHostView *> *)hostViews {
    for (MatrixCodeRainHostView *hostView in hostViews) {
        [hostView setFPSOverlayVisible:visible];
    }
}

- (void)fpsOverlayVisibilityDidChange:(NSNotification *)notification {
    if (self.multiMonitorWindows.count == 0) return;
    NSNumber *visible = notification.userInfo[MatrixCodeRainHostFPSOverlayVisibleKey];
    if (![visible isKindOfClass:NSNumber.class]) return;
    [self setFPSOverlayVisible:visible.boolValue
                  forHostViews:[self multiMonitorHostViews]];
}

- (IBAction)exitMultiMonitor:(id)sender {
    if (self.multiMonitorWindows.count == 0) return;
    NSWindow *restoreWindow = self.preMultiMonitorKeyWindow;
    NSArray<NSWindow *> *windows = [self.multiMonitorWindows copy];
    [self.multiMonitorWindows removeAllObjects];
    for (NSWindow *window in windows) {
        if ([window.contentView isKindOfClass:MatrixCodeRainHostView.class]) {
            [(MatrixCodeRainHostView *)window.contentView stopAnimation];
        }
        window.delegate = nil;
        [window close];
    }
    [restoreWindow makeKeyAndOrderFront:nil];
    self.preMultiMonitorKeyWindow = nil;
    [self persistPresentationMode:[self presentationModeForWindow:restoreWindow]];
}

- (MatrixCodeRainHostView *)hostViewForSettings {
    MatrixCodeRainHostView *hostView = [self hostViewInWindow:NSApp.keyWindow];
    if (!hostView) {
        hostView = [self hostViewInWindow:NSApp.keyWindow.sheetParent];
    }
    if (!hostView) {
        hostView = [self hostViewInWindow:self.windows.firstObject];
    }
    if (!hostView) {
        [self newWindow:nil];
        hostView = [self hostViewInWindow:NSApp.keyWindow ?: self.windows.firstObject];
    }
    return hostView;
}

- (MatrixCodeRainHostView *)hostViewForPresentationMenu {
    MatrixCodeRainHostView *hostView = [self hostViewInWindow:NSApp.keyWindow];
    if (!hostView) hostView = [self hostViewInWindow:self.windows.firstObject];
    return hostView;
}

- (MatrixCodeRainHostView *)hostViewInWindow:(NSWindow *)window {
    return [window.contentView isKindOfClass:MatrixCodeRainHostView.class]
        ? (MatrixCodeRainHostView *)window.contentView
        : nil;
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    SEL action = menuItem.action;
    if (action == @selector(toggleFullScreenFromMenu:)) {
        MatrixCodeRainHostView *hostView = [self hostViewForPresentationMenu];
        BOOL inFullScreen = (hostView.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
        menuItem.title = inFullScreen ? @"Exit Full Screen" : @"Enter Full Screen";
        return self.multiMonitorWindows.count == 0;
    }
    if (action == @selector(toggleMultiMonitorFromMenu:)) {
        BOOL inMultiMonitor = self.multiMonitorWindows.count > 0;
        menuItem.title = inMultiMonitor ? @"Exit Multi-monitor" : @"Enter Multi-monitor";
        return YES;
    }
    return YES;
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    if (self.applicationIsTerminating) return;
    if ([self.windows containsObject:notification.object] && self.multiMonitorWindows.count == 0) {
        [self persistPresentationMode:MatrixCodeAppPresentationModeFullScreen];
    }
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
    if (self.applicationIsTerminating) return;
    if ([self.windows containsObject:notification.object] && self.multiMonitorWindows.count == 0) {
        [self persistPresentationMode:MatrixCodeAppPresentationModeWindowed];
    }
}

- (void)windowWillClose:(NSNotification *)notification {
    NSWindow *window = notification.object;
    if ([window.contentView isKindOfClass:MatrixCodeRainHostView.class]) {
        [(MatrixCodeRainHostView *)window.contentView stopAnimation];
    }
    [self.windows removeObject:window];
    [self.multiMonitorWindows removeObject:window];
}

- (void)buildMenuBar {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];
    NSApp.mainMenu = mainMenu;

    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:MatrixCodeDisplayName action:nil keyEquivalent:@""];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:MatrixCodeDisplayName];
    appItem.submenu = appMenu;
    [appMenu addItemWithTitle:@"About Matrix Code"
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *settings = [appMenu addItemWithTitle:@"Settings..."
                                              action:@selector(showSettings:)
                                       keyEquivalent:@","];
    settings.target = self;
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *servicesItem = [[NSMenuItem alloc] initWithTitle:@"Services" action:nil keyEquivalent:@""];
    NSMenu *servicesMenu = [[NSMenu alloc] initWithTitle:@"Services"];
    servicesItem.submenu = servicesMenu;
    NSApp.servicesMenu = servicesMenu;
    [appMenu addItem:servicesItem];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide Matrix Code" action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem *hideOthers = [appMenu addItemWithTitle:@"Hide Others"
                                                action:@selector(hideOtherApplications:)
                                         keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit Matrix Code" action:@selector(terminate:) keyEquivalent:@"q"];

    NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    [mainMenu addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    fileItem.submenu = fileMenu;
    NSMenuItem *newWindow = [fileMenu addItemWithTitle:@"New Window"
                                                action:@selector(newWindow:)
                                         keyEquivalent:@"n"];
    newWindow.target = self;
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];

    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
    [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    editItem.submenu = editMenu;
    [editMenu addItemWithTitle:@"Undo" action:NSSelectorFromString(@"undo:") keyEquivalent:@"z"];
    NSMenuItem *redo = [editMenu addItemWithTitle:@"Redo"
                                           action:NSSelectorFromString(@"redo:")
                                    keyEquivalent:@"Z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    NSMenuItem *viewItem = [[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""];
    [mainMenu addItem:viewItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    viewItem.submenu = viewMenu;
    NSMenuItem *fullscreen = [viewMenu addItemWithTitle:@"Enter Full Screen"
                                                 action:@selector(toggleFullScreenFromMenu:)
                                          keyEquivalent:@"f"];
    fullscreen.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    fullscreen.target = self;
    NSMenuItem *multiMonitor = [viewMenu addItemWithTitle:@"Enter Multi-monitor"
                                                   action:@selector(toggleMultiMonitorFromMenu:)
                                            keyEquivalent:@"m"];
    multiMonitor.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    multiMonitor.target = self;

    NSMenuItem *windowItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
    [mainMenu addItem:windowItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    windowItem.submenu = windowMenu;
    NSApp.windowsMenu = windowMenu;
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];

    NSMenuItem *helpItem = [[NSMenuItem alloc] initWithTitle:@"Help" action:nil keyEquivalent:@""];
    [mainMenu addItem:helpItem];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    helpItem.submenu = helpMenu;
    [helpMenu addItemWithTitle:@"Matrix Code Help" action:@selector(showHelp:) keyEquivalent:@"?"];
}

@end
