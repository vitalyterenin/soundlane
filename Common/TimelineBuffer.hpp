#pragma once
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>

namespace soundlane {
// One writer, any number of independent readers. Sample-time tags make unwritten,
// expired, and stopped-writer frames silence rather than replaying old speech.
template <size_t Capacity = 65536> class TimelineBuffer {
    static_assert((Capacity & (Capacity - 1)) == 0);
    static_assert(std::atomic<uint64_t>::is_always_lock_free);
    struct Slot {
        std::atomic<int64_t> tag{INT64_MIN};
        std::atomic<uint64_t> stereo{0};
    };
    std::array<Slot, Capacity> slots_{};
public:
    // Only call with I/O stopped.
    void clear() noexcept {
        for (auto& s : slots_) { s.tag.store(INT64_MIN); s.stereo.store(0); }
    }
    void write(int64_t time, const float* data, uint32_t frames) noexcept {
        for (uint32_t i = 0; i < frames; ++i) {
            auto& s = slots_[uint64_t(time + i) & (Capacity - 1)];
            uint64_t bits;
            float pair[2] = {std::isfinite(data[2*i]) ? data[2*i] : 0,
                             std::isfinite(data[2*i+1]) ? data[2*i+1] : 0};
            std::memcpy(&bits, pair, sizeof bits);
            s.tag.store(INT64_MIN, std::memory_order_seq_cst);
            s.stereo.store(bits, std::memory_order_seq_cst);
            s.tag.store(time+i, std::memory_order_seq_cst);
        }
    }
    void read(int64_t time, float* data, uint32_t frames) const noexcept {
        for (uint32_t i = 0; i < frames; ++i) {
            const auto& s = slots_[uint64_t(time+i) & (Capacity - 1)];
            const auto tag1 = s.tag.load(std::memory_order_seq_cst);
            auto bits = s.stereo.load(std::memory_order_seq_cst);
            const auto tag2 = s.tag.load(std::memory_order_seq_cst);
            if (tag1 != time+i || tag2 != tag1) bits = 0;
            std::memcpy(data+2*i, &bits, sizeof bits);
        }
    }
};
}
