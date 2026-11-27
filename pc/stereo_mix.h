#pragma once

#include <windows.h>
#include <mmreg.h>
#include <ks.h>
#include <ksmedia.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

struct StereoGain {
    float left;
    float right;
};

static std::vector<StereoGain> stereoGains(unsigned channels, DWORD mask) {
    if (channels == 1) return {{1.0f, 1.0f}};
    if (channels == 2) return {{1.0f, 0.0f}, {0.0f, 1.0f}};

    // Extensible PCM orders its channels by ascending speaker bit.
    unsigned maskChannels = 0;
    for (DWORD bits = mask; bits != 0; bits &= bits - 1) ++maskChannels;
    if (maskChannels != channels) {
        if (channels == 6) mask = KSAUDIO_SPEAKER_5POINT1;
        else if (channels == 8) mask = KSAUDIO_SPEAKER_7POINT1_SURROUND;
        else mask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
    }

    constexpr float surroundGain = 0.70710678f;
    std::vector<StereoGain> gains(channels);
    unsigned channel = 0;
    for (; mask != 0 && channel < channels; ++channel) {
        const DWORD speaker = mask & (0u - mask);
        mask &= mask - 1;
        auto& gain = gains[channel];
        switch (speaker) {
        case SPEAKER_FRONT_LEFT:  gain = {1.0f, 0.0f}; break;
        case SPEAKER_FRONT_RIGHT: gain = {0.0f, 1.0f}; break;
        case SPEAKER_BACK_LEFT:
        case SPEAKER_SIDE_LEFT:
        case SPEAKER_FRONT_LEFT_OF_CENTER:
        case SPEAKER_TOP_FRONT_LEFT:
        case SPEAKER_TOP_BACK_LEFT: gain = {surroundGain, 0.0f}; break;
        case SPEAKER_BACK_RIGHT:
        case SPEAKER_SIDE_RIGHT:
        case SPEAKER_FRONT_RIGHT_OF_CENTER:
        case SPEAKER_TOP_FRONT_RIGHT:
        case SPEAKER_TOP_BACK_RIGHT: gain = {0.0f, surroundGain}; break;
        case SPEAKER_LOW_FREQUENCY: break;
        default: gain = {surroundGain, surroundGain}; break;
        }
    }
    return gains;
}

static inline int16_t floatToInt16(float v) {
    if (!std::isfinite(v)) return 0;
    if (v > 1.0f) v = 1.0f;
    if (v < -1.0f) v = -1.0f;
    return static_cast<int16_t>(v * 32767.0f);
}

class StereoLimiter {
public:
    explicit StereoLimiter(bool enabled) : enabled_(enabled) {}

    void append(float left, float right, bool hasSurround, std::vector<int16_t>& output) {
        if (enabled_) {
            if (!std::isfinite(left)) left = 0;
            if (!std::isfinite(right)) right = 0;
            constexpr float ceiling = 0.89125094f; // -1 dBFS
            constexpr float release = 0.00041658f; // 50 ms at 48 kHz
            const float peak = std::max(std::abs(left), std::abs(right));
            const float required = hasSurround && peak > ceiling ? ceiling / peak : 1.0f;
            gain_ = std::min(required, gain_ + (1.0f - gain_) * release);
            left *= gain_;
            right *= gain_;
        }
        output.push_back(floatToInt16(left));
        output.push_back(floatToInt16(right));
    }

private:
    bool enabled_;
    float gain_ = 1.0f;
};
