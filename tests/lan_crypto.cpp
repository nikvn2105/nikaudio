#include <windows.h>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>

#include "../pc/lan_auth.h"

static std::string hex(const uint8_t* bytes, size_t count) {
    static constexpr char digits[] = "0123456789abcdef";
    std::string result;
    result.reserve(count * 2);
    for (size_t i = 0; i < count; ++i) {
        result.push_back(digits[bytes[i] >> 4]);
        result.push_back(digits[bytes[i] & 0xf]);
    }
    return result;
}

int main() {
    PairingKey key{};
    for (size_t i = 0; i < key.size(); ++i) key[i] = static_cast<uint8_t>(i);

    uint8_t reply[4 + 32]{'N', 'I', 'K', 'R'};
    for (unsigned i = 0; i < 32; ++i) reply[4 + i] = static_cast<uint8_t>(i + 32);
    LanAuthenticator auth;
    LanTag tag{};
    if (!auth.sign(key, reply, sizeof(reply), tag) ||
        hex(tag.data(), tag.size()) != "d542d2a1e2bde4a717adf15fbe99e4dcde752f012ce894536024557b16b7a261") {
        std::cerr << "Discovery HMAC does not match the protocol vector.\n";
        return 1;
    }

    constexpr uint32_t seq = 0x12345678;
    const uint8_t* nonce = reply + 20;
    LanCipher cipher;
    if (!auth.sign(key, nonce, 16, tag) || !cipher.setSessionKey(tag)) {
        std::cerr << "Could not derive a session key.\n";
        return 1;
    }

    uint8_t header[12 + 16]{'N', 'I', 'K', 'A', 0x78, 0x56, 0x34, 0x12, 4, 0, 0, 0};
    std::memcpy(header + 12, nonce, 16);
    const uint8_t audio[]{1, 2, 3, 4};
    uint8_t output[sizeof(audio)]{};
    LanCipherTag cipherTag{};
    if (!cipher.encrypt(seq, false, header, sizeof(header), audio, sizeof(audio), output, cipherTag) ||
        hex(output, sizeof(output)) + hex(cipherTag.data(), cipherTag.size()) !=
            "178f403e206e4814c75709c573c84e70fbfe5bf6") {
        std::cerr << "AES-GCM audio does not match the protocol vector.\n";
        return 1;
    }

    header[8] = 0;
    header[10] = 1;
    if (!cipher.encrypt(seq, true, header, sizeof(header), nullptr, 0, nullptr, cipherTag) ||
        hex(cipherTag.data(), cipherTag.size()) != "53bc3b3fef014091229203c4b538cc6d") {
        std::cerr << "AES-GCM heartbeat does not match the protocol vector.\n";
        return 1;
    }
    std::cout << "LAN discovery, audio, and heartbeat vectors passed.\n";
}
