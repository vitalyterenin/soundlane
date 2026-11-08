#include "../Driver/Driver.cpp"
#include <cassert>
#include <iostream>
#include <thread>
#include <vector>

int main() {
    soundlane::TimelineBuffer<1024> ring;
    float input[512], output[512];
    for (int i=0;i<512;++i) input[i]=float(i)/1024;
    ring.read(0,output,256);
    for (float v:output) assert(v==0);
    ring.write(100,input,256); ring.read(100,output,256);
    for (int i=0;i<512;++i) assert(output[i]==input[i]);
    float second[512]; ring.read(100,second,256);
    for (int i=0;i<512;++i) assert(second[i]==input[i]); // independent readers
    ring.read(1124,output,256);
    for (float v:output) assert(v==0); // no stale speech on ring wrap
    ring.write(1124,input,256); ring.read(100,output,256);
    for (float v:output) assert(v==0); // overwritten data never reused
    ring.clear(); ring.read(1124,output,256);
    for (float v:output) assert(v==0);
    input[0]=NAN; input[1]=INFINITY; ring.write(-200,input,256); ring.read(-200,output,256);
    assert(output[0]==0 && output[1]==0);
    // Concurrent wraparound: each nonzero frame must match its requested sample time.
    soundlane::TimelineBuffer<1024> concurrent;
    std::atomic<bool> done{false};
    std::atomic<int64_t> latest{0};
    std::thread writer([&] {
        float frame[2];
        for (int64_t t=1;t<200000;++t) {
            frame[0]=float(t); frame[1]=-float(t);
            concurrent.write(t,frame,1); latest.store(t);
        }
        done.store(true);
    });
    std::vector<std::thread> readers;
    for (int i=0;i<3;++i) readers.emplace_back([&] {
        float frame[2];
        while (!done.load()) {
            int64_t t=latest.load()-128;
            concurrent.read(t,frame,1);
            assert((frame[0]==0 && frame[1]==0) || (frame[0]==float(t) && frame[1]==-float(t)));
        }
    });
    writer.join(); for(auto& r:readers) r.join();
    auto driver=createDriver();
    auto device=driver->GetPlugin()->GetDeviceByIndex(0);
    assert(device->GetDeviceUID()=="in.teren.soundlane.microphone");
    assert(device->GetStreamCount(aspl::Direction::Input)==1);
    assert(device->GetStreamCount(aspl::Direction::Output)==1);
    assert(device->GetNominalSampleRate()==48000);
    AudioObjectPropertyAddress address{kAudioDevicePropertyDeviceCanBeDefaultDevice,kAudioObjectPropertyScopeOutput,kAudioObjectPropertyElementMain};
    UInt32 allowed=1, size=0;
    assert(device->GetPropertyData(device->GetID(),getpid(),&address,0,nullptr,sizeof(allowed),&size,&allowed)==noErr);
    assert(allowed==0 && size==sizeof(UInt32));
    address.mScope=kAudioObjectPropertyScopeInput;
    assert(device->GetPropertyData(device->GetID(),getpid(),&address,0,nullptr,sizeof(allowed),&size,&allowed)==noErr);
    assert(allowed==1);
    auto stream=device->GetStreamByIndex(aspl::Direction::Input,0);
    assert(stream->GetPhysicalFormat().mBitsPerChannel==32);
    assert(stream->GetPhysicalFormat().mFormatFlags & kAudioFormatFlagIsFloat);
    Loopback loop;
    assert(loop.OnStartIO()==noErr);
    for(int i=0;i<512;++i) input[i]=.125f;
    loop.OnWriteMixedOutput(stream,0,2048,input,sizeof input);
    loop.OnReadClientInput({},stream,0,2048,output,sizeof output);
    for(float v:output) assert(v==.125f);
    loop.OnReadClientInput({},stream,0,4096,output,sizeof output);
    for(float v:output) assert(v==0); // stopped writer produces silence
    loop.OnStartIO();
    loop.OnReadClientInput({},stream,0,2048,output,sizeof output);
    for(float v:output) assert(v==0); // restart invalidates prior session
    assert(SoundLaneDriverFactory(nullptr,CFUUIDGetConstantUUIDWithBytes(nullptr,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))==nullptr);
    std::cout << "PASS: driver format, loopback, multiple readers, wraparound, concurrent access, silence after stop/restart, finite samples\n";
}
