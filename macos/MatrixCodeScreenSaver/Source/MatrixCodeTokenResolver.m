#import "MatrixCodeTokenResolver.h"

@interface MatrixCodeTokenResolver ()
@property(nonatomic, copy) NSString *viewerName;
@property(nonatomic, strong, nullable) NSDate *defaultTarget;
@property(nonatomic, copy) NSDictionary<NSString *, id> *moments;
@property(nonatomic, strong) NSDate *runStartDate;
@end

@implementation MatrixCodeTokenResolver

- (instancetype)initWithStoredValues:(NSDictionary<NSString *,NSString *> *)storedValues
                         runStartDate:(NSDate *)runStartDate {
    self = [super init];
    if (!self) return nil;
    NSString *name = [storedValues[@"mx-user-name"] isKindOfClass:NSString.class]
        ? [storedValues[@"mx-user-name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        : @"";
    _viewerName = name.length ? name : @"Neo";
    _runStartDate = runStartDate;
    NSDictionary *countdown = [self.class dictionaryFromJSONString:storedValues[@"mx-countdown"]];
    NSNumber *target = [countdown[@"targetMs"] isKindOfClass:NSNumber.class] ? countdown[@"targetMs"] : nil;
    _defaultTarget = target != nil
        ? [NSDate dateWithTimeIntervalSince1970:target.doubleValue / 1000.0]
        : nil;
    NSMutableDictionary *moments = [NSMutableDictionary dictionary];
    NSArray *rawMoments = [countdown[@"moments"] isKindOfClass:NSArray.class] ? countdown[@"moments"] : @[];
    for (NSDictionary *moment in rawMoments) {
        if (![moment isKindOfClass:NSDictionary.class]) continue;
        NSString *momentName = [moment[@"name"] isKindOfClass:NSString.class] ? moment[@"name"] : nil;
        if (!momentName.length || moments[momentName]) continue;
        NSNumber *momentTarget = [moment[@"targetMs"] isKindOfClass:NSNumber.class] ? moment[@"targetMs"] : nil;
        moments[momentName] = momentTarget ?: NSNull.null;
    }
    _moments = moments;
    return self;
}

+ (NSDictionary *)dictionaryFromJSONString:(NSString *)raw {
    if (![raw isKindOfClass:NSString.class]) return @{};
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}

+ (NSString *)formatDuration:(NSTimeInterval)seconds {
    NSInteger total = MAX(0, (NSInteger)floor(seconds));
    NSInteger days = total / 86400;
    total -= days * 86400;
    NSInteger hours = total / 3600;
    total -= hours * 3600;
    NSInteger minutes = total / 60;
    NSInteger secs = total - minutes * 60;
    if (days > 0) return [NSString stringWithFormat:@"%02ld:%02ld:%02ld:%02ld",
                          (long)days, (long)hours, (long)minutes, (long)secs];
    if (hours > 0) return [NSString stringWithFormat:@"%02ld:%02ld:%02ld",
                           (long)hours, (long)minutes, (long)secs];
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)minutes, (long)secs];
}

+ (NSString *)greetingAtDate:(NSDate *)date {
    NSInteger hour = [NSCalendar.currentCalendar component:NSCalendarUnitHour fromDate:date];
    if (hour < 4) return @"PARTY ON";
    if (hour < 12) return @"GOOD MORNING";
    if (hour < 18) return @"GOOD AFTERNOON";
    if (hour < 23) return @"GOOD EVENING";
    return @"GOOD NIGHT";
}

+ (NSString *)strftime:(NSString *)format date:(NSDate *)date {
    NSDictionary<NSString *, NSString *> *formats = @{
        @"H": @"HH", @"I": @"hh", @"M": @"mm", @"S": @"ss", @"p": @"a",
        @"Y": @"yyyy", @"y": @"yy", @"m": @"MM", @"d": @"dd", @"e": @"d",
        @"A": @"EEEE", @"a": @"EEE", @"B": @"MMMM", @"b": @"MMM", @"j": @"DDD",
    };
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger index = 0; index < format.length; index++) {
        unichar character = [format characterAtIndex:index];
        if (character != '%' || index + 1 >= format.length) {
            [result appendFormat:@"%C", character];
            continue;
        }
        unichar directive = [format characterAtIndex:++index];
        if (directive == '%') {
            [result appendString:@"%"];
            continue;
        }
        NSString *key = [NSString stringWithCharacters:&directive length:1];
        NSString *dateFormat = formats[key];
        if (!dateFormat) {
            [result appendFormat:@"%%%C", directive];
            continue;
        }
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = dateFormat;
        NSString *value = [formatter stringFromDate:date];
        if ([key isEqualToString:@"e"]) value = [value stringByPaddingToLength:2 withString:@" " startingAtIndex:0];
        [result appendString:value];
    }
    return result;
}

- (NSDate *)targetForKind:(NSString *)kind argument:(nullable NSString *)argument date:(NSDate *)date {
    if (argument != nil) {
        NSString *key = [argument stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        id stored = self.moments[key];
        if (stored) {
            return [stored isKindOfClass:NSNumber.class]
                ? [NSDate dateWithTimeIntervalSince1970:[stored doubleValue] / 1000.0]
                : nil;
        }
        return [self.class builtInMomentNamed:key relativeToDate:date];
    }
    if (self.defaultTarget) return self.defaultTarget;
    return [kind isEqualToString:@"countup"] ? self.runStartDate : nil;
}

- (NSString *)resolveText:(NSString *)text atDate:(NSDate *)date framesPerSecond:(double)framesPerSecond {
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:
            @"\\{(name|greeting|uptime|fps|time|countdown|countup)(?::([^}]*))?\\}"
            options:0 error:nil];
    });
    NSMutableString *resolved = [text mutableCopy];
    NSArray<NSTextCheckingResult *> *matches =
        [expression matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        NSString *kind = [text substringWithRange:[match rangeAtIndex:1]];
        NSRange argumentRange = [match rangeAtIndex:2];
        NSString *argument = argumentRange.location == NSNotFound ? nil : [text substringWithRange:argumentRange];
        NSString *replacement = nil;
        if ([kind isEqualToString:@"name"]) replacement = self.viewerName;
        else if ([kind isEqualToString:@"greeting"]) replacement = [self.class greetingAtDate:date];
        else if ([kind isEqualToString:@"uptime"]) replacement =
            [self.class formatDuration:[date timeIntervalSinceDate:self.runStartDate]];
        else if ([kind isEqualToString:@"fps"]) replacement =
            [NSString stringWithFormat:@"%ld FPS", (long)MAX(0, lround(isfinite(framesPerSecond) ? framesPerSecond : 0))];
        else if ([kind isEqualToString:@"time"]) replacement =
            [self.class strftime:argument ?: @"%H:%M" date:date];
        else {
            NSDate *target = [self targetForKind:kind argument:argument date:date];
            NSTimeInterval duration = target
                ? ([kind isEqualToString:@"countup"] ? [date timeIntervalSinceDate:target]
                                                     : [target timeIntervalSinceDate:date])
                : 0;
            replacement = [self.class formatDuration:duration];
        }
        [resolved replaceCharactersInRange:match.range withString:replacement ?: @""];
    }
    return resolved;
}

+ (NSInteger)westernEasterDayForYear:(NSInteger)year month:(NSInteger *)month {
    NSInteger a = year % 19, b = year / 100, c = year % 100, d = b / 4, e = b % 4;
    NSInteger f = (b + 8) / 25, g = (b - f + 1) / 3;
    NSInteger h = (19 * a + b - d - g + 15) % 30;
    NSInteger i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7;
    NSInteger m = (a + 11 * h + 22 * l) / 451;
    NSInteger computedMonth = (h + l - 7 * m + 114) / 31;
    *month = computedMonth;
    return ((h + l - 7 * m + 114) % 31) + 1;
}

+ (NSDate *)annualMomentMonth:(NSInteger)month day:(NSInteger)day hour:(NSInteger)hour relativeToDate:(NSDate *)date {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSInteger year = [calendar component:NSCalendarUnitYear fromDate:date];
    for (NSInteger offset = 0; offset < 4; offset++) {
        NSDateComponents *components = [[NSDateComponents alloc] init];
        components.year = year + offset;
        components.month = month;
        components.day = day;
        components.hour = hour;
        NSDate *event = [calendar dateFromComponents:components];
        NSDateComponents *nextDay = [[NSDateComponents alloc] init];
        nextDay.day = 1;
        NSDate *end = [calendar dateByAddingComponents:nextDay toDate:
            [calendar startOfDayForDate:event] options:0];
        if ([end compare:date] == NSOrderedDescending) return event;
    }
    return nil;
}

+ (NSDate *)builtInMomentNamed:(NSString *)name relativeToDate:(NSDate *)date {
    NSString *key = name.lowercaseString;
    NSDictionary *aliases = @{
        @"xmas": @"christmas", @"newyears": @"newyear", @"newyearseve": @"newyear",
        @"valentine": @"valentines", @"valentinesday": @"valentines",
        @"stpatrick": @"stpatricks", @"stpatricksday": @"stpatricks", @"stpaddys": @"stpatricks",
        @"july4th": @"july4", @"fourthofjuly": @"july4", @"independenceday": @"july4",
        @"turkeyday": @"thanksgiving",
    };
    key = aliases[key] ?: key;
    NSDictionary<NSString *, NSArray<NSNumber *> *> *fixed = @{
        @"newyear": @[@1, @1, @0], @"valentines": @[@2, @14, @7],
        @"stpatricks": @[@3, @17, @7], @"aprilfools": @[@4, @1, @7],
        @"july4": @[@7, @4, @7], @"halloween": @[@10, @31, @7],
        @"christmaseve": @[@12, @24, @7], @"christmas": @[@12, @25, @7],
    };
    NSArray<NSNumber *> *parts = fixed[key];
    if (parts) return [self annualMomentMonth:parts[0].integerValue
                                          day:parts[1].integerValue
                                         hour:parts[2].integerValue
                               relativeToDate:date];

    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSInteger year = [calendar component:NSCalendarUnitYear fromDate:date];
    for (NSInteger offset = 0; offset < 4; offset++) {
        NSInteger eventYear = year + offset;
        NSInteger month = 0, day = 0;
        if ([key isEqualToString:@"easter"]) {
            day = [self westernEasterDayForYear:eventYear month:&month];
        } else if ([key isEqualToString:@"thanksgiving"]) {
            month = 11;
            NSDateComponents *first = [[NSDateComponents alloc] init];
            first.year = eventYear; first.month = month; first.day = 1;
            NSInteger weekday = [calendar component:NSCalendarUnitWeekday fromDate:[calendar dateFromComponents:first]];
            day = 1 + ((5 - weekday + 7) % 7) + 21;
        } else if ([key isEqualToString:@"diwali"]) {
            NSDictionary *dates = @{
                @2024: @[@10,@31], @2025: @[@10,@20], @2026: @[@11,@8], @2027: @[@10,@29],
                @2028: @[@10,@17], @2029: @[@11,@5], @2030: @[@10,@26], @2031: @[@11,@14],
                @2032: @[@11,@2], @2033: @[@10,@22], @2034: @[@11,@10], @2035: @[@10,@30],
                @2036: @[@10,@19], @2037: @[@11,@7], @2038: @[@10,@27], @2039: @[@10,@17],
                @2040: @[@11,@4],
            };
            NSArray *dateParts = dates[@(eventYear)];
            if (!dateParts) return nil;
            month = [dateParts[0] integerValue]; day = [dateParts[1] integerValue];
        } else if ([key isEqualToString:@"newmoon"] || [key isEqualToString:@"fullmoon"]) {
            // Mean synodic-month approximation is sufficient for an ambient display token.
            NSTimeInterval synodic = 29.530588861 * 86400.0;
            NSTimeInterval reference = 947182440.0; // 2000-01-06 18:14 UTC new moon
            if ([key isEqualToString:@"fullmoon"]) reference += synodic / 2.0;
            double cycles = floor((date.timeIntervalSince1970 - reference) / synodic) + 1;
            return [NSDate dateWithTimeIntervalSince1970:reference + cycles * synodic];
        } else {
            return nil;
        }
        NSDateComponents *components = [[NSDateComponents alloc] init];
        components.year = eventYear;
        components.month = month;
        components.day = day;
        components.hour = 7;
        NSDate *event = [calendar dateFromComponents:components];
        NSDateComponents *oneDay = [[NSDateComponents alloc] init];
        oneDay.day = 1;
        NSDate *endOfEventDay = [calendar dateByAddingComponents:oneDay
                                                          toDate:[calendar startOfDayForDate:event]
                                                         options:0];
        if ([endOfEventDay compare:date] == NSOrderedDescending) return event;
    }
    return nil;
}

@end
