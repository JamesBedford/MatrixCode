#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** Seed used by src/app.ts for the scheduler's independent Mulberry32 stream. */
FOUNDATION_EXPORT const uint32_t MatrixCodeMessageSchedulerSeed;

/** Apply the same coercion, limits, and defaults as sanitizeMessages(). */
FOUNDATION_EXPORT NSDictionary<NSString *, id> *
    MatrixCodeSanitizeMessagesDocument(id _Nullable rawDocument);

/**
 * Resolve one message character to the dedicated, unmirrored glyph-atlas
 * index used by src/sim/glyphSet.ts. Unsupported characters return NSNotFound.
 */
FOUNDATION_EXPORT NSInteger MatrixCodeMessageGlyphIndexForCharacter(NSString *character);

typedef NSInteger (^MatrixCodeMessageGlyphIndexResolver)(NSString *character);
typedef NSString * _Nonnull (^MatrixCodeMessageTextResolver)(NSString *rawText);

/** Minimal surface consumed by MatrixCodeMessageScheduler. */
@protocol MatrixCodeMessageSink <NSObject>
@property(nonatomic, readonly) NSInteger columns;
@property(nonatomic, readonly) NSInteger rows;
- (void)setMessageTargets:(NSDictionary<NSNumber *, NSNumber *> *)targets;
- (void)updateMessageTargets:(NSDictionary<NSNumber *, NSNumber *> *)targets;
- (void)clearMessageTargets;
- (void)setMessageIntensity:(double)intensity;
- (void)setMessageScramble:(double)probability;
@end

/** Caller-provided rectangular region in simulation-grid coordinates. */
@interface MatrixCodeMessageRegion : NSObject <NSCopying>

- (instancetype)initWithColumnStart:(double)columnStart
                           rowStart:(double)rowStart
                            columns:(double)columns
                               rows:(double)rows NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) double columnStart;
@property(nonatomic, readonly) double rowStart;
@property(nonatomic, readonly) double columns;
@property(nonatomic, readonly) double rows;

@end

/**
 * Direct deterministic port of src/sim/messageScheduler.ts.
 *
 * Times are milliseconds, matching the web scheduler. Configuration documents
 * use the persisted MessagesDoc keys from src/config/messagesStore.ts.
 */
@interface MatrixCodeMessageScheduler : NSObject {
@private
    uint32_t _rngState;
    MatrixCodeMessageGlyphIndexResolver _glyphIndexResolver;
    MatrixCodeMessageTextResolver _textResolver;
    id _state;
}

- (instancetype)init;
- (instancetype)initWithSeed:(uint32_t)seed;
- (instancetype)initWithSeed:(uint32_t)seed
          glyphIndexResolver:(nullable MatrixCodeMessageGlyphIndexResolver)glyphIndexResolver
                textResolver:(nullable MatrixCodeMessageTextResolver)textResolver
    NS_DESIGNATED_INITIALIZER;

/** Cancel the current activation and arm the new document on the next update. */
- (void)configureWithDocument:(NSDictionary<NSString *, id> *)document;

- (void)updateAtTimeMilliseconds:(double)nowMilliseconds
                            sink:(id<MatrixCodeMessageSink>)sink;

- (void)updateAtTimeMilliseconds:(double)nowMilliseconds
                            sink:(id<MatrixCodeMessageSink>)sink
                         regions:(nullable NSArray<MatrixCodeMessageRegion *> *)regions;

/** Fire immediately, optionally adopting a document first. */
- (void)previewOneAtTimeMilliseconds:(double)nowMilliseconds
                                sink:(id<MatrixCodeMessageSink>)sink
                            document:(nullable NSDictionary<NSString *, id> *)document;

- (void)previewOneAtTimeMilliseconds:(double)nowMilliseconds
                                sink:(id<MatrixCodeMessageSink>)sink
                            document:(nullable NSDictionary<NSString *, id> *)document
                             regions:(nullable NSArray<MatrixCodeMessageRegion *> *)regions;

@end

NS_ASSUME_NONNULL_END
