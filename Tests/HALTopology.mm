// Optional hardware regression: requires installed SoundLane HAL and built-in Mac I/O.
// Does not start I/O or capture audio. Run scripts/test-hal-topology.sh.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#include <vector>
#include <cstdio>

static UInt32 channelCount(AudioObjectID device, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a{kAudioDevicePropertyStreamConfiguration, scope, 0};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &a, 0, nullptr, &size) || !size) return 0;
    std::vector<char> storage(size);
    if (AudioObjectGetPropertyData(device, &a, 0, nullptr, &size, storage.data())) return 0;
    auto* list = reinterpret_cast<AudioBufferList*>(storage.data());
    UInt32 result = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) result += list->mBuffers[i].mNumberChannels;
    return result;
}
int main() { @autoreleasepool {
    for (bool extraOutput : {false, true}) {
        NSMutableArray* subdevices = [@[
            @{@kAudioSubDeviceUIDKey:@"in.teren.soundlane.microphone"},
            @{@kAudioSubDeviceUIDKey:@"BuiltInMicrophoneDevice", @kAudioSubDeviceDriftCompensationKey:@1}
        ] mutableCopy];
        if (extraOutput) [subdevices addObject:@{@kAudioSubDeviceUIDKey:@"BuiltInSpeakerDevice"}];
        NSDictionary* config = @{
            @kAudioAggregateDeviceNameKey:@"SoundLane Topology Test",
            @kAudioAggregateDeviceUIDKey:NSUUID.UUID.UUIDString,
            @kAudioAggregateDeviceSubDeviceListKey:subdevices,
            @kAudioAggregateDeviceMainSubDeviceKey:@"in.teren.soundlane.microphone",
            @kAudioAggregateDeviceIsPrivateKey:@1,
            @kAudioAggregateDeviceIsStackedKey:@0
        };
        AudioObjectID device = 0;
        OSStatus status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)config, &device);
        if (status) { fprintf(stderr, "FAIL: create aggregate %d\n", status); return 1; }
        UInt32 inputs = channelCount(device, kAudioObjectPropertyScopeInput);
        UInt32 outputs = channelCount(device, kAudioObjectPropertyScopeOutput);
        AudioHardwareDestroyAggregateDevice(device);
        if (inputs != 3 || outputs != (extraOutput ? 4 : 2)) {
            fprintf(stderr, "FAIL: inputs=%u outputs=%u extraOutput=%d\n", inputs, outputs, extraOutput);
            return 1;
        }
        printf("PASS: real HAL inputs=%u outputs=%u (independent output streams)\n", inputs, outputs);
    }
} }
