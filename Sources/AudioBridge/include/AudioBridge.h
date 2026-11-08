#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN
@interface SLDevice : NSObject
@property(nonatomic, readonly) AudioDeviceID deviceID;
@property(nonatomic, readonly) NSString *uid;
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) UInt32 inputChannels;
@property(nonatomic, readonly) UInt32 outputChannels;
@property(nonatomic, readonly) double sampleRate;
+ (NSArray<SLDevice *> *)allDevices;
+ (AudioDeviceID)defaultInput;
+ (AudioDeviceID)defaultOutput;
@end

@interface SLPipeline : NSObject
@property(nonatomic, readonly) BOOL running;
@property(nonatomic, readonly) float inputPeak;
@property(nonatomic, readonly) float outputPeak;
@property(nonatomic, readonly) uint64_t renderErrors;
@property(nonatomic, readonly) uint64_t consecutiveRenderErrors;
@property(nonatomic, readonly) uint64_t callbackCount;
@property(nonatomic, readonly) double sampleRate;
@property(nonatomic) BOOL bypass;
@property(nonatomic) BOOL muted;
@property(nonatomic) float gain;
// Control methods must run on the main thread. Audio callbacks contain no Swift.
- (BOOL)startSystemTo:(AudioDeviceID)output units:(NSArray<AVAudioUnit *> *)units error:(NSError **)error;
- (BOOL)startMicrophone:(AudioDeviceID)input to:(AudioDeviceID)output units:(NSArray<AVAudioUnit *> *)units error:(NSError **)error;
- (void)stop;
// Offline smoke test of the same graph/render path; no device access or recording.
+ (BOOL)selfTest:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
