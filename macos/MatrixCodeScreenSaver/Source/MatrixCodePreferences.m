#import "MatrixCodePreferences.h"

#import <ScreenSaver/ScreenSaver.h>

#import "MatrixCodeConstants.h"

@interface MatrixCodePreferences ()
@property(nonatomic, strong) ScreenSaverDefaults *defaults;
@end

@implementation MatrixCodePreferences

MatrixCodeAppPresentationMode const MatrixCodeAppPresentationModeWindowed = @"windowed";
MatrixCodeAppPresentationMode const MatrixCodeAppPresentationModeFullScreen = @"fullScreen";
MatrixCodeAppPresentationMode const MatrixCodeAppPresentationModeMultiMonitor = @"multiMonitor";
static NSString * const MatrixCodeAppPresentationModeDefaultsKey = @"MatrixCodeAppPresentationMode";

- (instancetype)init {
    self = [super init];
    if (self) {
        _defaults = [ScreenSaverDefaults defaultsForModuleWithName:MatrixCodeModuleIdentifier];
    }
    return self;
}

+ (NSSet<NSString *> *)allowedAppPresentationModes {
    static NSSet<NSString *> *modes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        modes = [NSSet setWithObjects:
            MatrixCodeAppPresentationModeWindowed,
            MatrixCodeAppPresentationModeFullScreen,
            MatrixCodeAppPresentationModeMultiMonitor,
            nil];
    });
    return modes;
}

+ (MatrixCodeAppPresentationMode)sanitizedAppPresentationMode:(NSString *)mode {
    return mode && [[self allowedAppPresentationModes] containsObject:mode]
        ? mode
        : MatrixCodeAppPresentationModeWindowed;
}

+ (MatrixCodeAppPresentationMode)savedAppPresentationMode {
    return [self savedAppPresentationModeInDefaults:NSUserDefaults.standardUserDefaults];
}

+ (MatrixCodeAppPresentationMode)savedAppPresentationModeInDefaults:(NSUserDefaults *)defaults {
    return [self sanitizedAppPresentationMode:[defaults stringForKey:MatrixCodeAppPresentationModeDefaultsKey]];
}

+ (void)setSavedAppPresentationMode:(MatrixCodeAppPresentationMode)mode {
    [self setSavedAppPresentationMode:mode inDefaults:NSUserDefaults.standardUserDefaults];
}

+ (void)setSavedAppPresentationMode:(MatrixCodeAppPresentationMode)mode
                          inDefaults:(NSUserDefaults *)defaults {
    [defaults setObject:[self sanitizedAppPresentationMode:mode]
                 forKey:MatrixCodeAppPresentationModeDefaultsKey];
    [defaults synchronize];
}

+ (BOOL)isAllowedStorageKey:(NSString *)key {
    return [MatrixCodeStorageKeys() containsObject:key];
}

- (NSDictionary<NSString *, NSString *> *)storedValues {
    NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
    for (NSString *key in MatrixCodeStorageKeys()) {
        id value = [self.defaults objectForKey:key];
        if ([value isKindOfClass:NSString.class]) {
            values[key] = value;
        }
    }
    return values;
}

- (void)commitValues:(NSDictionary<NSString *, NSString *> *)values {
    for (NSString *key in MatrixCodeStorageKeys()) {
        NSString *value = values[key];
        if ([value isKindOfClass:NSString.class]) {
            [self.defaults setObject:value forKey:key];
        } else {
            [self.defaults removeObjectForKey:key];
        }
    }
    [self.defaults synchronize];
}

- (void)setImmediateValue:(NSString *)value forKey:(NSString *)key {
    if (![MatrixCodePreferences isAllowedStorageKey:key]) {
        return;
    }
    if (value) {
        [self.defaults setObject:value forKey:key];
    } else {
        [self.defaults removeObjectForKey:key];
    }
    [self.defaults synchronize];
}

@end
