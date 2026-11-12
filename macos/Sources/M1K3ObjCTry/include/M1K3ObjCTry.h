//
//  M1K3ObjCTry.h
//  M1K3ObjCTry
//
//  One function: run a block and catch an Objective-C exception it raises.
//  Swift cannot catch NSException, and a few Apple APIs still raise one for a
//  condition the caller cannot rule out first. The case that brought this in:
//  -[AVAudioPlayerNode play] raising "player did not see an IO cycle" when the
//  phone app reached the background as a spoken sentence was about to start
//  (iPhone 17 Pro drill, 2026-11-11: uncaught, SIGABRT).
//
//  Keep its use narrow: an exception unwinds past Swift frames without running
//  their cleanup, so the block must be a single call into the framework.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.8, Prior: none (new file).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`. Returns nil when it finished, or the exception's reason (its name when it has none).
NSString *_Nullable M1K3TryObjC(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
