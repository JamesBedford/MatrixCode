#import "MatrixCodeConstants.h"

NSString * const MatrixCodeModuleIdentifier = @"com.matrixcode.screensaver";
NSString * const MatrixCodeSessionDefaultsKey = @"MatrixCodeNativeSession";

NSArray<NSString *> *MatrixCodeStorageKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"mx-controls",
            @"mx-intro",
            @"mx-messages",
            @"mx-images",
            @"mx-ui-state",
            @"mx-countdown",
            @"mx-user-name",
            @"mx-intro-seen",
        ];
    });
    return keys;
}
