#pragma once

// Play through the default Windows endpoint so WASAPI captures the same signal.
inline bool playLatencyPulses() {
#pragma pack(push, 1)
    struct WaveHeader {
        char riff[4];
        uint32_t riffSize;
        char wave[4];
        char format[4];
        uint32_t formatSize;
        uint16_t encoding;
        uint16_t channels;
        uint32_t sampleRate;
        uint32_t byteRate;
        uint16_t blockAlign;
        uint16_t bitsPerSample;
        char data[4];
        uint32_t dataSize;
    };
#pragma pack(pop)

    static const auto wave = [] {
        constexpr unsigned rate = 48000;
        constexpr unsigned seconds = 42;
        constexpr unsigned samples = rate * seconds;
        std::vector<char> bytes(sizeof(WaveHeader) + samples * sizeof(int16_t));
        const WaveHeader header{{'R','I','F','F'}, static_cast<uint32_t>(bytes.size() - 8), {'W','A','V','E'},
                                {'f','m','t',' '}, 16, 1, 1, rate, rate * 2, 2, 16,
                                {'d','a','t','a'}, samples * 2};
        std::memcpy(bytes.data(), &header, sizeof(header));

        // Two seconds of lead-in, then 20 short pulses two seconds apart.
        for (unsigned pulse = 1; pulse <= 20; ++pulse) {
            constexpr int length = 480;
            for (int frame = 0; frame < length; ++frame) {
                constexpr double pi = 3.141592653589793;
                const double envelope = std::sin(pi * frame / length);
                const auto sample = static_cast<int16_t>(12000 * envelope * std::sin(2 * pi * frame / 48));
                const size_t offset = sizeof(header) + (pulse * 2 * rate + frame) * sizeof(sample);
                std::memcpy(bytes.data() + offset, &sample, sizeof(sample));
            }
        }
        return bytes;
    }();
    return PlaySoundA(wave.data(), nullptr, SND_ASYNC | SND_MEMORY | SND_NODEFAULT) != FALSE;
}
