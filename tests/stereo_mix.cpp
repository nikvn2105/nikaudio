#define NOMINMAX
#include <iostream>
#include "../pc/stereo_mix.h"

int main() {
    for (auto count : {6u, 8u}) {
        const auto gains = stereoGains(count, 0);
        std::vector<int16_t> output;
        StereoLimiter limiter(true);
        constexpr float sample = 1.0f;
        limiter.append(sample * gains[0].left, -sample * gains[1].right, false, output);
        const auto level = 20 * std::log10(std::abs(float(output[0])) / floatToInt16(sample));
        if (std::abs(level) > 0.1 || output[1] != -output[0] ||
            std::abs(gains[2].left - 0.70710678f) > 1e-5f || gains[2].left != gains[2].right) return 1;
        float left = 0, right = 0;
        for (auto gain : gains) { left += gain.left; right -= gain.right; }
        limiter.append(left, right, true, output);
        if (std::abs(output[2]) > 29205 || std::abs(output[3]) > 29205 || output[2] < 20000) return 2;
        const auto firstLimited = output[2];
        output.clear();
        for (unsigned i = 0; i < 2400; ++i) limiter.append(0.75f, -0.75f, false, output);
        if (output.front() >= floatToInt16(0.75f) || output[4798] <= output.front() ||
            output[4798] >= floatToInt16(0.75f) || firstLimited == 0) return 3;
    }
    const auto mono = stereoGains(1, 0);
    const auto stereo = stereoGains(2, 0);
    if (mono[0].left != 1 || mono[0].right != 1 ||
        stereo[0].left != 1 || stereo[0].right != 0 || stereo[1].left != 0 || stereo[1].right != 1) return 4;
    std::vector<int16_t> output;
    StereoLimiter bypass(false);
    for (float value : {-1.0f, -0.5f, 0.0f, 0.75f, 1.0f}) {
        bypass.append(value, value, false, output);
        if (output.back() != floatToInt16(value) || output[output.size()-2] != output.back()) return 5;
    }
    std::cout << "Surround downmix, limiter and mono/stereo bypass passed.\n";
}
