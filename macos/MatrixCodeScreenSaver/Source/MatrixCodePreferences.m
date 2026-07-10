#import "MatrixCodePreferences.h"

#import <ScreenSaver/ScreenSaver.h>

#import "MatrixCodeConstants.h"

@interface MatrixCodePreferences ()
@property(nonatomic, strong) ScreenSaverDefaults *defaults;
@end

@implementation MatrixCodePreferences

- (instancetype)init {
    self = [super init];
    if (self) {
        _defaults = [ScreenSaverDefaults defaultsForModuleWithName:MatrixCodeModuleIdentifier];
    }
    return self;
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
