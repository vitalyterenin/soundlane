#import "AudioBridge.h"
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#include <atomic>
#include <algorithm>
#include <array>
#include <cmath>
#include <vector>
#include <memory>
#include <unistd.h>

namespace {
constexpr UInt32 MaxFrames = 8192;
AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return {selector, scope, kAudioObjectPropertyElementMain};
}
template <typename T> T property(AudioObjectID id, AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal, T fallback = {}) {
    auto a = address(selector, scope); T value = fallback; UInt32 size = sizeof(T);
    if (AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, &value) != noErr) return fallback;
    return value;
}
NSString* textProperty(AudioObjectID id, AudioObjectPropertySelector selector) {
    CFStringRef value = property<CFStringRef>(id, selector);
    return value ? CFBridgingRelease(value) : @"";
}
UInt32 channels(AudioObjectID id, AudioObjectPropertyScope scope) {
    auto a = address(kAudioDevicePropertyStreamConfiguration, scope); UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(id, &a, 0, nullptr, &size) || size < sizeof(AudioBufferList)) return 0;
    std::vector<uint8_t> storage(size); auto list = reinterpret_cast<AudioBufferList*>(storage.data());
    if (AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, list)) return 0;
    UInt32 count = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) count += list->mBuffers[i].mNumberChannels;
    return count;
}
BOOL fail(NSError** error, NSString* message, OSStatus status = -1) {
    if (error) *error = [NSError errorWithDomain:@"SoundLane.Audio" code:status
        userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}
BOOL check(OSStatus status, NSError** error, NSString* operation) {
    if (status == noErr) return YES;
    return fail(error, [NSString stringWithFormat:@"%@ (Core Audio: %d).", operation, int(status)], status);
}
BOOL validateFloatStreams(AudioDeviceID id, AudioObjectPropertyScope scope, NSError** error) {
    auto a = address(kAudioDevicePropertyStreams, scope); UInt32 size = 0;
    if (!check(AudioObjectGetPropertyDataSize(id, &a, 0, nullptr, &size), error, @"Could not verify the audio format")) return NO;
    std::vector<AudioStreamID> streams(size / sizeof(AudioStreamID));
    if (!check(AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, streams.data()), error, @"Could not read the audio format")) return NO;
    for (auto stream : streams) {
        auto f = property<AudioStreamBasicDescription>(stream, kAudioStreamPropertyVirtualFormat);
        if (f.mFormatID != kAudioFormatLinearPCM || !(f.mFormatFlags & kAudioFormatFlagIsFloat) || f.mBitsPerChannel != 32)
            return fail(error, @"This device does not support 32-bit floating-point audio. Choose another device.");
    }
    return YES;
}
float sample(const AudioBufferList* list, UInt32 channel, UInt32 frame) noexcept {
    if (!list) return 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
        const auto& b = list->mBuffers[i];
        if (channel < b.mNumberChannels) {
            auto index = frame * b.mNumberChannels + channel;
            if (!b.mData || (index+1)*sizeof(float) > b.mDataByteSize) return 0;
            return static_cast<const float*>(b.mData)[index];
        }
        channel -= b.mNumberChannels;
    }
    return 0;
}
void putSample(AudioBufferList* list, UInt32 channel, UInt32 frame, float value) noexcept {
    if (!list) return;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
        auto& b = list->mBuffers[i];
        if (channel < b.mNumberChannels) {
            auto index = frame * b.mNumberChannels + channel;
            if (b.mData && (index+1)*sizeof(float) <= b.mDataByteSize)
                static_cast<float*>(b.mData)[index] = value;
            return;
        }
        channel -= b.mNumberChannels;
    }
}
UInt32 frameCount(const AudioBufferList* list) noexcept {
    if (!list) return 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
        const auto& b = list->mBuffers[i];
        if (b.mData && b.mNumberChannels) return b.mDataByteSize / (sizeof(float)*b.mNumberChannels);
    }
    return 0;
}
void silence(AudioBufferList* list) noexcept {
    if (list) for (UInt32 i=0; i<list->mNumberBuffers; ++i)
        if (list->mBuffers[i].mData) memset(list->mBuffers[i].mData, 0, list->mBuffers[i].mDataByteSize);
}
struct StereoList { UInt32 count = 2; AudioBuffer buffers[2]; };
struct RenderContext {
    std::array<float, MaxFrames> input[2]{}, output[2]{};
    UInt32 frames = 0, cursor = 0, inputOffset = 0;
    bool mono = false;
    double rate = 48000;
    std::atomic<bool> bypass{false}, muted{false};
    std::atomic<float> gain{1}, inputPeak{0}, outputPeak{0};
    std::atomic<uint64_t> errors{0}, consecutiveErrors{0}, callbacks{0};
    float smoothedGain = 1;
    AVAudioEngineManualRenderingBlock __strong render = nil;

    void process(UInt32 n) noexcept {
        float inPeak = 0;
        for (UInt32 c=0; c<2; ++c) for (UInt32 i=0; i<n; ++i) {
            if (!std::isfinite(input[c][i])) input[c][i]=0;
            inPeak=std::max(inPeak, std::abs(input[c][i]));
        }
        inputPeak.store(inPeak, std::memory_order_relaxed);
        if (bypass.load(std::memory_order_relaxed)) {
            consecutiveErrors.store(0, std::memory_order_relaxed);
            for (int c=0;c<2;++c) std::copy_n(input[c].data(),n,output[c].data());
        } else {
            StereoList list{2, {{1, n*4, output[0].data()}, {1, n*4, output[1].data()}}};
            cursor = 0; frames = n;
            OSStatus status = noErr;
            const auto result = render(n, reinterpret_cast<AudioBufferList*>(&list), &status);
            if (result != AVAudioEngineManualRenderingStatusSuccess || status != noErr) {
                errors.fetch_add(1, std::memory_order_relaxed);
                consecutiveErrors.fetch_add(1, std::memory_order_relaxed);
                for (int c=0;c<2;++c) std::fill_n(output[c].data(), n, 0);
            } else { consecutiveErrors.store(0, std::memory_order_relaxed); }
        }
        const float target = muted.load(std::memory_order_relaxed) ? 0 : gain.load(std::memory_order_relaxed);
        const float step = 1.f / float(rate * .005);
        float outPeak=0;
        for (UInt32 i=0; i<n; ++i) {
            smoothedGain += std::clamp(target-smoothedGain, -step, step);
            for (int c=0; c<2; ++c) {
                float v = output[c][i] * smoothedGain;
                if (!std::isfinite(v)) v=0;
                // A final safety ceiling prevents full-scale overflow from a plugin.
                output[c][i] = std::clamp(v, -1.f, 1.f);
                outPeak=std::max(outPeak,std::abs(output[c][i]));
            }
        }
        outputPeak.store(outPeak, std::memory_order_relaxed);
    }
};
OSStatus ioCallback(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* in,
    const AudioTimeStamp*, AudioBufferList* out, const AudioTimeStamp*, void* user) {
    auto& c = *static_cast<RenderContext*>(user);
    c.callbacks.fetch_add(1, std::memory_order_relaxed);
    const UInt32 n = frameCount(out);
    silence(out);
    if (!n || n > MaxFrames || !c.render) { c.errors.fetch_add(1); c.consecutiveErrors.fetch_add(1); return noErr; }
    for (UInt32 i=0; i<n; ++i) {
        c.input[0][i]=sample(in, c.inputOffset, i);
        c.input[1][i]=sample(in, c.inputOffset+(c.mono ? 0 : 1), i);
    }
    c.process(n);
    for (UInt32 i=0; i<n; ++i) {
        putSample(out,0,i,c.output[0][i]);
        putSample(out,1,i,c.output[1][i]);
    }
    return noErr;
}
}

@implementation SLDevice
- (instancetype)initWithID:(AudioDeviceID)deviceID {
    if ((self=[super init])) {
        _deviceID=deviceID; _uid=textProperty(deviceID,kAudioDevicePropertyDeviceUID);
        _name=textProperty(deviceID,kAudioObjectPropertyName);
        _inputChannels=channels(deviceID,kAudioObjectPropertyScopeInput);
        _outputChannels=channels(deviceID,kAudioObjectPropertyScopeOutput);
        _sampleRate=property<Float64>(deviceID,kAudioDevicePropertyNominalSampleRate);
    }
    return self;
}
+ (NSArray<SLDevice*>*)allDevices {
    auto a=address(kAudioHardwarePropertyDevices); UInt32 size=0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,nullptr,&size)) return @[];
    std::vector<AudioDeviceID> ids(size/sizeof(AudioDeviceID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,nullptr,&size,ids.data())) return @[];
    NSMutableArray* result=[NSMutableArray array];
    for (auto id : ids) {
        if (property<UInt32>(id,kAudioDevicePropertyIsHidden) ||
            !property<UInt32>(id,kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal,1)) continue;
        SLDevice* device=[[SLDevice alloc] initWithID:id];
        if ([device.uid hasPrefix:@"in.teren.soundlane.aggregate."]) continue;
        [result addObject:device];
    }
    return result;
}
+ (AudioDeviceID)defaultInput { return property<AudioDeviceID>(kAudioObjectSystemObject,kAudioHardwarePropertyDefaultInputDevice); }
+ (AudioDeviceID)defaultOutput { return property<AudioDeviceID>(kAudioObjectSystemObject,kAudioHardwarePropertyDefaultOutputDevice); }
@end

@implementation SLPipeline {
    AudioObjectID _tap;
    AudioDeviceID _aggregate;
    AudioDeviceIOProcID _proc;
    AVAudioEngine* _engine;
    NSArray<AVAudioUnit*>* _units;
    std::unique_ptr<RenderContext> _context;
}
- (instancetype)init {
    if ((self=[super init])) _context=std::make_unique<RenderContext>();
    return self;
}
- (void)dealloc { [self stop]; }
- (BOOL)running { return _proc != nullptr && _engine.isRunning; }
- (float)inputPeak { return _context->inputPeak.load(); }
- (float)outputPeak { return _context->outputPeak.load(); }
- (uint64_t)renderErrors { return _context->errors.load(); }
- (uint64_t)consecutiveRenderErrors { return _context->consecutiveErrors.load(); }
- (uint64_t)callbackCount { return _context->callbacks.load(); }
- (double)sampleRate { return _context->rate; }
- (BOOL)bypass { return _context->bypass.load(); }
- (void)setBypass:(BOOL)value { _context->bypass.store(value); }
- (BOOL)muted { return _context->muted.load(); }
- (void)setMuted:(BOOL)value { _context->muted.store(value); }
- (float)gain { return _context->gain.load(); }
- (void)setGain:(float)value { _context->gain.store(std::clamp(value,0.f,2.f)); }

- (BOOL)buildGraph:(NSArray<AVAudioUnit*>*)units error:(NSError**)error {
    @try {
        _engine=[AVAudioEngine new]; _units=[units copy];
        auto* context=_context.get();
        AVAudioFormat* format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:context->rate channels:2];
        if (![_engine enableManualRenderingMode:AVAudioEngineManualRenderingModeRealtime
            format:format maximumFrameCount:MaxFrames error:error]) return NO;
        AVAudioSourceNode* source=[[AVAudioSourceNode alloc] initWithFormat:format
            renderBlock:^OSStatus(BOOL* isSilence, const AudioTimeStamp*, AVAudioFrameCount count, AudioBufferList* buffers) {
                if (context->cursor+count > context->frames) { silence(buffers); *isSilence=YES; return noErr; }
                for (UInt32 i=0; i<count; ++i) {
                    putSample(buffers,0,i,context->input[0][context->cursor+i]);
                    putSample(buffers,1,i,context->input[1][context->cursor+i]);
                }
                context->cursor+=count; *isSilence=NO; return noErr;
            }];
        [_engine attachNode:source]; AVAudioNode* previous=source;
        for (AVAudioUnit* unit in units) {
            [_engine attachNode:unit];
            [_engine connect:previous to:unit format:format]; previous=unit;
        }
        [_engine connect:previous to:_engine.mainMixerNode format:format];
        [_engine connect:_engine.mainMixerNode to:_engine.outputNode format:format];
        [_engine prepare];
        if (![_engine startAndReturnError:error]) return NO;
        _context->render=_engine.manualRenderingBlock;
        _context->errors.store(0); _context->consecutiveErrors.store(0); _context->callbacks.store(0);
        return YES;
    } @catch (NSException* exception) {
        return fail(error, [NSString stringWithFormat:@"Could not connect the effects: %@", exception.reason]);
    }
}
- (BOOL)startSystemTo:(AudioDeviceID)output units:(NSArray<AVAudioUnit*>*)units error:(NSError**)error {
    [self stop];
    if (output == kAudioObjectUnknown || channels(output,kAudioObjectPropertyScopeOutput)<2)
        return fail(error,@"Choose a stereo output, such as speakers or headphones.");
    auto a=address(kAudioHardwarePropertyTranslatePIDToProcessObject);
    pid_t pid=getpid(); AudioObjectID process=0; UInt32 size=sizeof(process);
    if (!check(AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(pid),&pid,&size,&process),error,@"Could not exclude SoundLane from audio capture")) return NO;
    if (!process) return fail(error,@"Core Audio has not registered SoundLane yet. Try turning processing on again.");
    CATapDescription* description=[[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[@(process)]];
    description.name=@"SoundLane System Audio"; description.privateTap=YES;
    description.muteBehavior=CATapMutedWhenTapped;
    if (!check(AudioHardwareCreateProcessTap(description,&_tap),error,@"System audio access is unavailable. Allow it in System Settings → Privacy & Security")) return NO;
    NSString* tapUID=textProperty(_tap,kAudioTapPropertyUID);
    _context->mono=false;
    BOOL result=[self startAggregateWithInput:0 output:output tapUID:tapUID units:units error:error];
    if (!result) [self stop];
    return result;
}
- (BOOL)startMicrophone:(AudioDeviceID)input to:(AudioDeviceID)output units:(NSArray<AVAudioUnit*>*)units error:(NSError**)error {
    [self stop];
    if (!input || !channels(input,kAudioObjectPropertyScopeInput)) return fail(error,@"Choose an available microphone.");
    if (!output || channels(output,kAudioObjectPropertyScopeOutput)!=2) return fail(error,@"Install the included SoundLane Microphone audio component.");
    if (input==output) return fail(error,@"Choose a physical microphone to avoid audio feedback.");
    _context->mono=true;
    BOOL result=[self startAggregateWithInput:input output:output tapUID:nil units:units error:error];
    if (!result) [self stop];
    return result;
}
- (BOOL)startAggregateWithInput:(AudioDeviceID)input output:(AudioDeviceID)output
    tapUID:(NSString*)tapUID units:(NSArray<AVAudioUnit*>*)units error:(NSError**)error {
    NSString* outputUID=textProperty(output,kAudioDevicePropertyDeviceUID);
    NSMutableArray* subs=[NSMutableArray arrayWithObject:@{@kAudioSubDeviceUIDKey:outputUID}];
    if (input) [subs addObject:@{@kAudioSubDeviceUIDKey:textProperty(input,kAudioDevicePropertyDeviceUID),
        @kAudioSubDeviceDriftCompensationKey:@YES,
        @kAudioSubDeviceDriftCompensationQualityKey:@(kAudioAggregateDriftCompensationMaxQuality)}];
    NSMutableDictionary* config=[@{
        @kAudioAggregateDeviceNameKey:@"SoundLane Audio Engine",
        @kAudioAggregateDeviceUIDKey:[@"in.teren.soundlane.aggregate." stringByAppendingString:NSUUID.UUID.UUIDString],
        @kAudioAggregateDeviceSubDeviceListKey:subs,
        @kAudioAggregateDeviceMainSubDeviceKey:outputUID,
        @kAudioAggregateDeviceIsPrivateKey:@YES,
        // On current macOS, stacked=1 creates a multi-output device with no
        // inputs. Use a normal aggregate; its output streams remain distinct.
        @kAudioAggregateDeviceIsStackedKey:@0
    } mutableCopy];
    if (tapUID) {
        config[@kAudioAggregateDeviceTapListKey]=@[@{@kAudioSubTapUIDKey:tapUID,
            @kAudioSubTapDriftCompensationKey:@YES,
            @kAudioSubTapDriftCompensationQualityKey:@(kAudioAggregateDriftCompensationMaxQuality)}];
        config[@kAudioAggregateDeviceTapAutoStartKey]=@NO;
    }
    if (!check(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)config,&_aggregate),error,@"Could not create the audio route")) return NO;
    Float64 rate=property<Float64>(output,kAudioDevicePropertyNominalSampleRate);
    if (rate<8000 || rate>192000) return fail(error,@"Sample rates from 8 to 192 kHz are supported.");
    auto a=address(kAudioDevicePropertyNominalSampleRate);
    if (!check(AudioObjectSetPropertyData(_aggregate,&a,0,nullptr,sizeof(rate),&rate),error,@"Could not synchronize the devices’ sample rates")) return NO;
    _context->rate=property<Float64>(_aggregate,kAudioDevicePropertyNominalSampleRate);
    UInt32 totalInput=channels(_aggregate,kAudioObjectPropertyScopeInput);
    UInt32 sourceChannels=input ? channels(input,kAudioObjectPropertyScopeInput) : 2;
    if (totalInput<sourceChannels || channels(_aggregate,kAudioObjectPropertyScopeOutput)<2)
        return fail(error,@"Core Audio did not provide the required channels. Reconnect the device.");
    // Subdevices are ordered destination, microphone; process tap is appended last.
    _context->inputOffset=totalInput-sourceChannels;
    if (!validateFloatStreams(_aggregate,kAudioObjectPropertyScopeInput,error) ||
        !validateFloatStreams(_aggregate,kAudioObjectPropertyScopeOutput,error)) return NO;
    if (property<UInt32>(_aggregate,kAudioDevicePropertyBufferFrameSize)>MaxFrames)
        return fail(error,@"The device’s audio buffer is too large.");
    if (![self buildGraph:units error:error]) return NO;
    if (!check(AudioDeviceCreateIOProcID(_aggregate,ioCallback,_context.get(),&_proc),error,@"Could not create the audio processor")) return NO;
    return check(AudioDeviceStart(_aggregate,_proc),error,@"Could not start audio");
}
- (void)stop {
    if (_proc && _aggregate) {
        AudioDeviceStop(_aggregate,_proc); AudioDeviceDestroyIOProcID(_aggregate,_proc);
    }
    _proc=nullptr;
    [_engine stop]; _context->render=nil;
    for (AVAudioUnit* unit in _units) if (unit.engine==_engine) [_engine detachNode:unit];
    _units=nil; _engine=nil;
    if (_aggregate) AudioHardwareDestroyAggregateDevice(_aggregate);
    _aggregate=0;
    if (_tap) AudioHardwareDestroyProcessTap(_tap);
    _tap=0;
    _context->inputPeak.store(0); _context->outputPeak.store(0);
}
+ (BOOL)selfTest:(NSError**)error {
    SLPipeline* pipeline=[SLPipeline new];
    AVAudioUnitEQ* eq=[[AVAudioUnitEQ alloc] initWithNumberOfBands:1];
    eq.globalGain=-6;
    if (![pipeline buildGraph:@[eq] error:error]) return NO;
    auto& c=*pipeline->_context;
    for (UInt32 i=0;i<512;++i) c.input[0][i]=c.input[1][i]=.25f;
    for (int i=0;i<4;++i) c.process(512);
    if (c.errors.load() || std::abs(c.output[0][400]-.25f*std::pow(10.f,-6.f/20.f))>.002f) {
        [pipeline stop]; return fail(error,@"Audio Unit EQ validation failed.");
    }
    c.bypass.store(true); c.process(512);
    if (std::abs(c.output[0][400]-.25f)>.001f) { [pipeline stop]; return fail(error,@"Bypass validation failed."); }
    c.muted.store(true); c.process(512);
    if (std::abs(c.output[0][511])>.0001f) { [pipeline stop]; return fail(error,@"Mute validation failed."); }
    // Exercise the actual HAL callback with a duplex destination followed by a
    // mono physical microphone. The unrelated output must remain silent.
    c.muted.store(false); c.inputOffset=2; c.mono=true;
    float virtualInput[1024]{}, microphone[512], virtualOutput[1024]{}, hardwareOutput[1024];
    std::fill_n(microphone,512,.125f); std::fill_n(hardwareOutput,1024,1.f);
    StereoList inputList{2,{{2,sizeof(virtualInput),virtualInput},{1,sizeof(microphone),microphone}}};
    StereoList outputList{2,{{2,sizeof(virtualOutput),virtualOutput},{2,sizeof(hardwareOutput),hardwareOutput}}};
    ioCallback(0,nullptr,reinterpret_cast<AudioBufferList*>(&inputList),nullptr,
               reinterpret_cast<AudioBufferList*>(&outputList),nullptr,&c);
    if (std::abs(virtualOutput[1022]-.125f)>.001f || std::abs(virtualOutput[1023]-.125f)>.001f || hardwareOutput[1023]!=0) {
        [pipeline stop]; return fail(error,@"Channel routing validation failed.");
    }
    [pipeline stop];
    return YES;
}
@end
