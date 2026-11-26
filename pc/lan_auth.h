#pragma once

#include <array>
#include <bcrypt.h>
#include <wincred.h>

using PairingKey = std::array<uint8_t, 32>;
using LanNonce = std::array<uint8_t, 16>;
using LanTag = std::array<uint8_t, 32>;

inline constexpr wchar_t pairingCredential[] = L"NiKAudio/LAN";

inline bool loadPairingKey(PairingKey& key) {
    PCREDENTIALW credential = nullptr;
    if (!CredReadW(pairingCredential, CRED_TYPE_GENERIC, 0, &credential)) return false;
    const bool valid = credential->CredentialBlobSize == key.size();
    if (valid) std::memcpy(key.data(), credential->CredentialBlob, key.size());
    CredFree(credential);
    return valid;
}

inline bool savePairingKey(const PairingKey& key) {
    CREDENTIALW credential{};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = const_cast<wchar_t*>(pairingCredential);
    credential.CredentialBlobSize = static_cast<DWORD>(key.size());
    credential.CredentialBlob = const_cast<BYTE*>(key.data());
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    return CredWriteW(&credential, 0) != FALSE;
}

inline bool parsePairingKey(const std::wstring& text, PairingKey& key) {
    const auto start = text.find_first_not_of(L" \r\n\t");
    const auto end = text.find_last_not_of(L" \r\n\t");
    if (start == std::wstring::npos || end - start + 1 != key.size() * 2) return false;
    auto hex = [](wchar_t character) -> int {
        if (character >= L'0' && character <= L'9') return character - L'0';
        if (character >= L'a' && character <= L'f') return character - L'a' + 10;
        if (character >= L'A' && character <= L'F') return character - L'A' + 10;
        return -1;
    };
    for (size_t i = 0; i < key.size(); ++i) {
        const int high = hex(text[start + 2 * i]);
        const int low = hex(text[start + 2 * i + 1]);
        if (high < 0 || low < 0) return false;
        key[i] = static_cast<uint8_t>((high << 4) | low);
    }
    return true;
}

class LanAuthenticator {
public:
    LanAuthenticator() {
        BCryptOpenAlgorithmProvider(&algorithm_, BCRYPT_SHA256_ALGORITHM, nullptr,
                                    BCRYPT_ALG_HANDLE_HMAC_FLAG);
    }

    ~LanAuthenticator() {
        if (algorithm_) BCryptCloseAlgorithmProvider(algorithm_, 0);
    }

    bool sign(const PairingKey& key, const void* bytes, size_t size, LanTag& tag) const {
        if (!algorithm_) return false;
        BCRYPT_HASH_HANDLE hash = nullptr;
        if (BCryptCreateHash(algorithm_, &hash, nullptr, 0, const_cast<PUCHAR>(key.data()),
                             static_cast<ULONG>(key.size()), 0) != 0) return false;
        const bool signedOk =
            BCryptHashData(hash, static_cast<PUCHAR>(const_cast<void*>(bytes)),
                           static_cast<ULONG>(size), 0) == 0 &&
            BCryptFinishHash(hash, tag.data(), static_cast<ULONG>(tag.size()), 0) == 0;
        BCryptDestroyHash(hash);
        return signedOk;
    }

    static bool matches(const LanTag& expected, const uint8_t* received) {
        unsigned difference = 0;
        for (size_t i = 0; i < expected.size(); ++i) difference |= expected[i] ^ received[i];
        return difference == 0;
    }

private:
    BCRYPT_ALG_HANDLE algorithm_{nullptr};
};

using LanCipherTag = std::array<uint8_t, 16>;

class LanCipher {
public:
    LanCipher() {
        if (BCryptOpenAlgorithmProvider(&algorithm_, BCRYPT_AES_ALGORITHM, nullptr, 0) != 0) return;
        if (BCryptSetProperty(algorithm_, BCRYPT_CHAINING_MODE,
                              reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(BCRYPT_CHAIN_MODE_GCM)),
                              sizeof(BCRYPT_CHAIN_MODE_GCM), 0) != 0) {
            BCryptCloseAlgorithmProvider(algorithm_, 0);
            algorithm_ = nullptr;
        }
    }

    ~LanCipher() {
        if (key_) BCryptDestroyKey(key_);
        if (algorithm_) BCryptCloseAlgorithmProvider(algorithm_, 0);
    }

    bool setSessionKey(LanTag& keyMaterial) {
        if (!algorithm_) return false;
        BCRYPT_KEY_HANDLE next = nullptr;
        if (BCryptGenerateSymmetricKey(algorithm_, &next, nullptr, 0, keyMaterial.data(),
                                       static_cast<ULONG>(keyMaterial.size()), 0) != 0) return false;
        if (key_) BCryptDestroyKey(key_);
        key_ = next;
        return true;
    }

    bool encrypt(uint32_t seq, bool heartbeat, uint8_t* header, ULONG headerSize,
                 const uint8_t* plaintext, ULONG size, uint8_t* ciphertext, LanCipherTag& tag) const {
        if (!key_) return false;
        // Sequence counters are separate for the two frame types.
        uint8_t iv[12]{};
        std::memcpy(iv, &seq, sizeof(seq));
        iv[4] = heartbeat ? 1 : 0;
        BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
        BCRYPT_INIT_AUTH_MODE_INFO(info);
        info.pbNonce = iv;
        info.cbNonce = sizeof(iv);
        info.pbAuthData = header;
        info.cbAuthData = headerSize;
        info.pbTag = tag.data();
        info.cbTag = static_cast<ULONG>(tag.size());
        ULONG written = 0;
        if (!size) {
            // CNG uses NULL output and zero lengths for an authentication-only operation.
            return BCryptEncrypt(key_, nullptr, 0, &info, nullptr, 0, nullptr, 0, &written, 0) == 0;
        }
        return BCryptEncrypt(key_, const_cast<PUCHAR>(plaintext), size, &info, nullptr, 0,
                             ciphertext, size, &written, 0) == 0 && written == size;
    }

private:
    BCRYPT_ALG_HANDLE algorithm_{nullptr};
    BCRYPT_KEY_HANDLE key_{nullptr};
};
