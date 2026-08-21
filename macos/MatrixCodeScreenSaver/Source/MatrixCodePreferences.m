#import "MatrixCodePreferences.h"

#import <ScreenSaver/ScreenSaver.h>

#import "MatrixCodeConstants.h"
#import "MatrixCodeImageContract.h"

@interface MatrixCodePreferences ()
@property(nonatomic, strong) NSUserDefaults *defaults;
- (void)backupPortableImagesIfNeededBeforeReplacingWithValue:(nullable NSString *)replacement;
@end

@implementation MatrixCodePreferences

MatrixCodeAppPresentationMode const MatrixCodeAppPresentationModeWindowed = @"windowed";
MatrixCodeAppPresentationMode const MatrixCodeAppPresentationModeFullScreen = @"fullScreen";
MatrixCodeAppPresentationMode const MatrixCodeAppPresentationModeMultiMonitor = @"multiMonitor";
static NSString * const MatrixCodeAppPresentationModeDefaultsKey = @"MatrixCodeAppPresentationMode";

static NSArray * _Nullable MatrixCodeRawImagesArray(NSString * _Nullable rawJSON) {
    if (![rawJSON isKindOfClass:NSString.class]) return nil;
    NSData *data = [rawJSON dataUsingEncoding:NSUTF8StringEncoding];
    id object = data
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
        : nil;
    if (![object isKindOfClass:NSDictionary.class]) return nil;
    id images = ((NSDictionary *)object)[@"images"];
    return [images isKindOfClass:NSArray.class] ? images : nil;
}

- (instancetype)init {
    return [self initWithDefaults:
        [ScreenSaverDefaults defaultsForModuleWithName:MatrixCodeModuleIdentifier]];
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    self = [super init];
    if (self) {
        _defaults = defaults;
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
    // The Options sheet and screen-saver playback are separate processes writing one defaults
    // module, and legacyScreenSaver hosts stay alive across activations. Without discarding the
    // cached snapshot first, playback keeps serving whatever it read when the host started, so
    // settings saved in Options never take effect until that host is killed.
    [self.defaults synchronize];
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
    NSString *imagesReplacement = values[@"mx-images"];
    // commitValues is a complete snapshot: an omitted key is removed below, so it is
    // still a replacement and must preserve incompatible legacy image data first.
    [self backupPortableImagesIfNeededBeforeReplacingWithValue:
        [imagesReplacement isKindOfClass:NSString.class] ? imagesReplacement : nil];
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

- (void)setImmediateValue:(NSString * _Nullable)value forKey:(NSString *)key {
    if (![MatrixCodePreferences isAllowedStorageKey:key]) {
        return;
    }
    if ([key isEqualToString:@"mx-images"]) {
        [self backupPortableImagesIfNeededBeforeReplacingWithValue:value];
    }
    if (value) {
        [self.defaults setObject:value forKey:key];
    } else {
        [self.defaults removeObjectForKey:key];
    }
    [self.defaults synchronize];
}

- (void)backupPortableImagesIfNeededBeforeReplacingWithValue:(NSString * _Nullable)replacement {
    id existingBackup = [self.defaults objectForKey:MatrixCodeImagesPortableBackupDefaultsKey];
    if (existingBackup) return;

    id storedValue = [self.defaults objectForKey:@"mx-images"];
    if (![storedValue isKindOfClass:NSString.class]) return;
    NSString *storedJSON = storedValue;
    if ([replacement isKindOfClass:NSString.class] && [storedJSON isEqualToString:replacement]) return;
    if (!MatrixCodeImagesJSONStringRequiresPortableBackup(storedJSON)) return;
    if ([replacement isKindOfClass:NSString.class] &&
        MatrixCodeImagesJSONStringRequiresPortableBackup(replacement)) {
        // A non-portable replacement is safe only when it retains the complete raw playlist.
        // Merely checking that the replacement is also non-portable can lose one legacy mask
        // while another legacy mask (or a 65th portable mask) keeps that coarse check true.
        NSArray *storedImages = MatrixCodeRawImagesArray(storedJSON);
        NSArray *replacementImages = MatrixCodeRawImagesArray(replacement);
        if (storedImages && [storedImages isEqualToArray:replacementImages]) return;
    }

    [self.defaults setObject:storedJSON forKey:MatrixCodeImagesPortableBackupDefaultsKey];
}

@end
