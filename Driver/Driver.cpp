#include <aspl/Driver.hpp>
#include <mach/mach_time.h>
#include "../Common/TimelineBuffer.hpp"

namespace {
constexpr UInt32 Rate = 48000;
constexpr UInt32 Channels = 2;

class Loopback final : public aspl::IORequestHandler, public aspl::ControlRequestHandler {
    soundlane::TimelineBuffer<> timeline_;
public:
    OSStatus OnStartIO() override { timeline_.clear(); return noErr; }
    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>&, Float64,
                            Float64 time, const void* bytes, UInt32 count) override {
        timeline_.write(static_cast<int64_t>(time), static_cast<const float*>(bytes), count / 8);
    }
    void OnReadClientInput(const std::shared_ptr<aspl::Client>&,
                           const std::shared_ptr<aspl::Stream>&, Float64,
                           Float64 time, void* bytes, UInt32 count) override {
        timeline_.read(static_cast<int64_t>(time), static_cast<float*>(bytes), count / 8);
    }
};

// Advance directly to the present after sleep; never tick one period at a time.
class Device final : public aspl::Device {
    std::atomic<uint64_t> anchor_{0}, seed_{1};
    double ticksPerFrame_;
public:
    Device(std::shared_ptr<aspl::Context> context, const aspl::DeviceParameters& params)
        : aspl::Device(context, params) {
        mach_timebase_info_data_t info; mach_timebase_info(&info);
        ticksPerFrame_ = 1e9 * double(info.denom) / double(info.numer) / Rate;
    }
    OSStatus GetPropertyData(AudioObjectID objectID, pid_t pid,
        const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
        const void* qualifier, UInt32 dataSize, UInt32* resultSize, void* data) const override {
        // It is a selectable microphone, never a default speaker. The output
        // stream exists only to feed processed samples from the app into HAL.
        if (address && address->mSelector == kAudioDevicePropertyDeviceCanBeDefaultDevice &&
            objectID == GetID()) {
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            if (resultSize) *resultSize = sizeof(UInt32);
            if (data) *static_cast<UInt32*>(data) = address->mScope == kAudioObjectPropertyScopeInput;
            return noErr;
        }
        return aspl::Device::GetPropertyData(objectID, pid, address, qualifierSize,
                                             qualifier, dataSize, resultSize, data);
    }
protected:
    OSStatus StartIOImpl(UInt32 clientID, UInt32 startCount) override {
        if (startCount == 0) { anchor_.store(mach_absolute_time()); seed_.fetch_add(1); }
        return aspl::Device::StartIOImpl(clientID, startCount);
    }
    OSStatus GetZeroTimeStampImpl(UInt32, Float64* sample, UInt64* host, UInt64* seed) override {
        const auto anchor = anchor_.load();
        const double period = 256;
        const double frames = std::floor(double(mach_absolute_time()-anchor) / ticksPerFrame_ / period) * period;
        *sample = frames; *host = anchor + uint64_t(frames * ticksPerFrame_); *seed = seed_.load();
        return noErr;
    }
};

std::shared_ptr<aspl::Driver> createDriver() {
    auto context = std::make_shared<aspl::Context>();
    aspl::DeviceParameters params;
    params.Name = "SoundLane Microphone";
    params.Manufacturer = "SoundLane";
    params.DeviceUID = "in.teren.soundlane.microphone";
    params.ModelUID = "in.teren.soundlane.microphone.v1";
    params.ConfigurationApplicationBundleID = "in.teren.SoundLane";
    params.SampleRate = Rate; params.ChannelCount = Channels;
    params.ZeroTimeStampPeriod = 256; params.SafetyOffset = 128;
    params.CanBeDefault = true; params.CanBeDefaultForSystemSounds = false;
    auto device = std::make_shared<Device>(context, params);
    aspl::StreamParameters stream;
    stream.Format = {48000, kAudioFormatLinearPCM,
        kAudioFormatFlagsNativeFloatPacked, 8, 1, 8, 2, 32, 0};
    stream.Direction = aspl::Direction::Input;
    device->AddStreamAsync(stream);
    stream.Direction = aspl::Direction::Output;
    device->AddStreamAsync(stream);
    auto loopback = std::make_shared<Loopback>();
    device->SetIOHandler(loopback); device->SetControlHandler(loopback);
    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);
    return std::make_shared<aspl::Driver>(context, plugin);
}
}

extern "C" __attribute__((visibility("default")))
void* SoundLaneDriverFactory(CFAllocatorRef, CFUUIDRef type) {
    if (!CFEqual(type, kAudioServerPlugInTypeUUID)) return nullptr;
    static auto driver = createDriver();
    return driver->GetReference();
}
