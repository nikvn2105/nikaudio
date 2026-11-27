#pragma once

#include <filesystem>
#include <fstream>
#include <functional>
#include <stdexcept>
#include <shlobj.h>
#include "bonjour_service.h"

namespace FileTransfer {
constexpr uint16_t port = 55124;
constexpr size_t blockSize = 256 * 1024;
constexpr uint64_t maxBytes = 1ull << 40; // 1 TiB
using Bytes = std::vector<uint8_t>;
using Path = std::filesystem::path;

inline void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

inline std::wstring widen(const std::string& text) {
    if (text.empty()) return {};
    int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
    require(size > 0, "Invalid UTF-8");
    std::wstring result(size, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), size);
    return result;
}

inline std::string narrow(const std::wstring& text) {
    if (text.empty()) return {};
    int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()),
                                   nullptr, 0, nullptr, nullptr);
    require(size > 0, "Invalid filename");
    std::string result(size, '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()),
                        result.data(), size, nullptr, nullptr);
    return result;
}

template<class T> inline void append(Bytes& buffer, T value) {
    const auto* bytes = reinterpret_cast<const uint8_t*>(&value);
    buffer.insert(buffer.end(), bytes, bytes + sizeof(value));
}

template<class T> inline T read(const Bytes& buffer, size_t offset = 0) {
    require(offset <= buffer.size() && sizeof(T) <= buffer.size() - offset, "Invalid protocol frame");
    T value{};
    std::memcpy(&value, buffer.data() + offset, sizeof(value));
    return value;
}

inline LanTag digestFile(const Path& path, const std::function<bool()>& keepGoing) {
    struct Hash {
        BCRYPT_ALG_HANDLE algorithm{};
        BCRYPT_HASH_HANDLE handle{};
        ~Hash() {
            if (handle) BCryptDestroyHash(handle);
            if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
        }
    } hash;
    require(BCryptOpenAlgorithmProvider(&hash.algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) == 0 &&
            BCryptCreateHash(hash.algorithm, &hash.handle, nullptr, 0, nullptr, 0, 0) == 0,
            "Cannot initialize SHA-256");
    std::ifstream file(path, std::ios::binary);
    require(file.is_open(), "Cannot open file");
    Bytes bytes(blockSize);
    while (file.read(reinterpret_cast<char*>(bytes.data()), bytes.size()) || file.gcount()) {
        require(keepGoing(), "Transfer stopped");
        require(BCryptHashData(hash.handle, bytes.data(), static_cast<ULONG>(file.gcount()), 0) == 0, "Cannot hash file");
    }
    LanTag digest{};
    require(file.eof() && !file.bad() && BCryptFinishHash(hash.handle, digest.data(), digest.size(), 0) == 0,
            "Cannot read file");
    return digest;
}

inline std::wstring hex(const LanTag& tag) {
    const wchar_t chars[] = L"0123456789abcdef";
    std::wstring result;
    for (uint8_t byte : tag) {
        result += chars[byte >> 4];
        result += chars[byte & 15];
    }
    return result;
}

struct Offer {
    std::string name;
    uint64_t size;
    LanTag digest;

    Bytes encode(uint8_t kind) const {
        Bytes bytes{kind};
        append(bytes, size);
        append(bytes, static_cast<uint16_t>(name.size()));
        bytes.insert(bytes.end(), digest.begin(), digest.end());
        bytes.insert(bytes.end(), name.begin(), name.end());
        return bytes;
    }

    static Offer decode(const Bytes& bytes) {
        const auto length = read<uint16_t>(bytes, 9);
        require(length > 0 && length <= 1000 && bytes.size() == 43u + length, "Invalid file offer");
        Offer offer{std::string(bytes.begin() + 43, bytes.end()), read<uint64_t>(bytes, 1), {}};
        require(offer.size <= maxBytes, "File exceeds transfer limit");
        std::memcpy(offer.digest.data(), bytes.data() + 11, offer.digest.size());
        return offer;
    }
};

// A challenge from each peer binds both directional AES-GCM keys to one TCP connection.
class Channel {
public:
    Channel(SOCKET socket, const PairingKey& key) : socket_(socket) {
        Bytes transcript{'N','I','K','F',1};
        transcript.resize(37);
        receiveRaw(transcript.data(), 21);
        require(std::memcmp(transcript.data(), "NIKF", 4) == 0 && transcript[4] == 1, "Unsupported file protocol");
        require(BCryptGenRandom(nullptr, transcript.data() + 21, 16, BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0,
                "Cannot generate challenge");
        auto derive = [&](uint8_t label) -> LanTag {
            transcript.push_back(label);
            LanTag tag{};
            require(auth.sign(key, transcript.data(), transcript.size(), tag), "Cannot authenticate file connection");
            transcript.pop_back();
            return tag;
        };
        auto proof = derive(0);
        sendRaw(transcript.data() + 21, 16);
        sendRaw(proof.data(), proof.size());
        auto clientToServer = derive(1);
        auto serverToClient = derive(2);
        require(receiver_.setSessionKey(clientToServer) && sender_.setSessionKey(serverToClient),
                "Cannot configure encryption");
        SecureZeroMemory(clientToServer.data(), clientToServer.size());
        SecureZeroMemory(serverToClient.data(), serverToClient.size());
    }

    void authenticated() { authenticating_ = false; }

    void send(const Bytes& data) {
        require(!data.empty() && data.size() <= blockSize + 1 && sendCounter_ != UINT32_MAX, "Invalid data block");
        uint32_t size = static_cast<uint32_t>(data.size());
        Bytes wire(4 + size + sizeof(LanCipherTag));
        std::memcpy(wire.data(), &size, 4);
        LanCipherTag tag{};
        require(sender_.encrypt(sendCounter_++, false, wire.data(), 4, data.data(), size,
                                wire.data() + 4, tag), "Cannot encrypt data");
        std::memcpy(wire.data() + 4 + size, tag.data(), tag.size());
        sendRaw(wire.data(), static_cast<int>(wire.size()));
    }

    Bytes receive() {
        for (;;) {
            auto data = receiveRecord();
            if (data != Bytes{8}) return data;
        }
    }

private:
    Bytes receiveRecord() {
        uint32_t size = 0;
        auto* header = reinterpret_cast<uint8_t*>(&size);
        receiveRaw(header, 4);
        require(size != 0 && size <= blockSize + 1 && receiveCounter_ != UINT32_MAX, "Invalid data block");
        Bytes wire(size + sizeof(LanCipherTag));
        receiveRaw(wire.data(), static_cast<int>(wire.size()));
        LanCipherTag tag{};
        std::memcpy(tag.data(), wire.data() + size, tag.size());
        Bytes data(size);
        require(receiver_.decrypt(receiveCounter_++, header, 4, wire.data(), size, data.data(), tag),
                "Authentication failed");
        return data;
    }

    void sendRaw(const uint8_t* data, int size) {
        require(sendAll(socket_, reinterpret_cast<const char*>(data), size), "Connection interrupted");
    }

    void receiveRaw(uint8_t* data, int size) {
        if (!authenticating_) {
            require(recvAll(socket_, reinterpret_cast<char*>(data), size), "Connection interrupted");
            return;
        }
        while (size > 0) {
            const auto remaining = std::chrono::duration_cast<std::chrono::microseconds>(
                authDeadline_ - std::chrono::steady_clock::now()).count();
            require(remaining > 0, "Authentication timed out");
            timeval wait{static_cast<long>(remaining / 1000000), static_cast<long>(remaining % 1000000)};
            fd_set readSet;
            FD_ZERO(&readSet);
            FD_SET(socket_, &readSet);
            require(select(0, &readSet, nullptr, nullptr, &wait) == 1, "Authentication timed out");
            const int got = recv(socket_, reinterpret_cast<char*>(data), size, 0);
            require(got > 0, "Connection interrupted");
            data += got;
            size -= got;
        }
    }

    SOCKET socket_;
    const std::chrono::steady_clock::time_point authDeadline_ =
        std::chrono::steady_clock::now() + std::chrono::seconds(3);
    bool authenticating_ = true;
    LanAuthenticator auth;
    LanCipher sender_, receiver_;
    uint32_t sendCounter_ = 0, receiveCounter_ = 0;
};

inline Path targetFolder() {
    PWSTR value = nullptr;
    require(SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Downloads, KF_FLAG_CREATE, nullptr, &value)),
            "Cannot find Downloads folder");
    Path result(value);
    CoTaskMemFree(value);
    return result / L"NiKAudio";
}

inline Path partialFolder() {
    PWSTR value = nullptr;
    require(SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &value)),
            "Cannot find local storage");
    Path result(value);
    CoTaskMemFree(value);
    return result / L"NiKAudio" / L"Partial";
}

inline std::wstring safeName(const std::string& name) {
    std::wstring value = widen(name);
    for (auto& character : value) {
        if (character < 32 || std::wstring(L"<>:\"/\\|?*").find(character) != std::wstring::npos) character = L'_';
    }
    while (!value.empty() && (value.back() == L'.' || value.back() == L' ')) value.pop_back();
    if (value.empty() || value == L"." || value == L"..") value = L"file";
    if (value.size() > 170) {
        value.resize(170);
        if (value.back() >= 0xd800 && value.back() <= 0xdbff) value.pop_back();
    }
    // A prefix also avoids DOS device names such as CON and NUL.
    return L"NiKAudio - " + value;
}

class Server {
public:
    Server(std::wstring address, std::function<bool()> audioOnLAN)
        : address_(std::move(address)), audioOnLAN_(std::move(audioOnLAN)), worker_(&Server::run, this) {}

    ~Server() {
        running_ = false;
        {
            std::lock_guard<std::mutex> lock(socketMutex_);
            if (peer_ != INVALID_SOCKET) shutdown(peer_, SD_BOTH);
        }
        worker_.join();
    }

    void offer(Path path) {
        std::lock_guard<std::mutex> lock(mutex_);
        offered_ = std::move(path);
        status_ = L"Đã chọn tệp để gửi";
    }

    std::wstring status() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return peerAddress_.empty() ? status_ : peerAddress_ + L" · " + status_;
    }

    const std::wstring& address() const { return address_; }

private:
    void setStatus(std::wstring value) {
        std::lock_guard<std::mutex> lock(mutex_);
        status_ = std::move(value);
    }

    void progress(uint64_t done, uint64_t total, std::chrono::steady_clock::time_point start, uint64_t offset) {
        const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        const double speed = (done - offset) / (1048576.0 * std::max(elapsed, .01));
        wchar_t text[88]{};
        swprintf_s(text, L"%u%% · %.1f MiB/s", total ? static_cast<unsigned>(done * 100 / total) : 100, speed);
        setStatus(text);
    }

    LanTag verifiedDigest(const Path& path, Channel& channel) {
        auto last = std::chrono::steady_clock::now();
        return digestFile(path, [&] {
            if (!running_) return false;
            const auto now = std::chrono::steady_clock::now();
            if (now - last >= std::chrono::seconds(5)) {
                channel.send({8});
                last = now;
            }
            return true;
        });
    }

    void upload(Channel& channel, const Bytes& request) {
        const auto offer = Offer::decode(request);
        const auto destination = targetFolder();
        std::filesystem::create_directories(destination);
        const auto filename = safeName(offer.name);
        // File name + verified contents give a stable receipt even after restart or lost ACK.
        for (unsigned i = 0; i < 10000; ++i) {
            const Path final = destination / (i ? std::to_wstring(i) + L" - " + filename : filename);
            if (!std::filesystem::exists(final)) break;
            if (std::filesystem::is_regular_file(final) && std::filesystem::file_size(final) == offer.size &&
                verifiedDigest(final, channel) == offer.digest) {
                Bytes complete{3};
                append(complete, offer.size);
                channel.send(complete);
                require(channel.receive() == Bytes{5}, "Transfer did not complete");
                setStatus(L"Tệp đã có trong Downloads / NiKAudio");
                channel.send({6});
                return;
            }
        }
        const auto staging = partialFolder();
        std::filesystem::create_directories(staging);
        const auto partial = staging / (hex(offer.digest) + L".part");
        uint64_t done = std::filesystem::exists(partial) ? std::filesystem::file_size(partial) : 0;
        if (done > offer.size) {
            std::filesystem::remove(partial);
            done = 0;
        }
        std::ofstream file(partial, std::ios::binary | std::ios::app);
        require(file.is_open(), "Cannot save incoming file");
        Bytes response{3};
        append(response, done);
        channel.send(response);
        const auto offset = done;
        const auto start = std::chrono::steady_clock::now();
        while (done < offer.size) {
            const auto data = channel.receive();
            require(data[0] == 4 && data.size() > 1 && data.size() - 1 <= offer.size - done, "Invalid file data");
            require(bool(file.write(reinterpret_cast<const char*>(data.data() + 1), data.size() - 1)),
                    "Cannot write incoming file");
            done += data.size() - 1;
            progress(done, offer.size, start, offset);
        }
        file.close();
        require(!file.fail() && channel.receive() == Bytes{5}, "Transfer did not complete");
        if (verifiedDigest(partial, channel) != offer.digest) {
            std::filesystem::remove(partial);
            throw std::runtime_error("File checksum mismatch; retry from the start");
        }

        bool saved = false;
        for (unsigned i = 0; i < 10000; ++i) {
            const Path final = destination / (i ? std::to_wstring(i) + L" - " + filename : filename);
            if (MoveFileExW(partial.c_str(), final.c_str(), MOVEFILE_COPY_ALLOWED)) {
                saved = true;
                break;
            }
            const auto error = GetLastError();
            if (error != ERROR_ALREADY_EXISTS && error != ERROR_FILE_EXISTS) break;
        }
        require(saved, "Cannot finalize incoming file");
        setStatus(L"Đã lưu tệp vào Downloads / NiKAudio");
        channel.send({6});
    }

    void download(Channel& channel) {
        Path path;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            path = offered_;
        }
        require(!path.empty() && std::filesystem::is_regular_file(path), "Select a file on Windows first");
        setStatus(L"Đang chuẩn bị tệp");
        const auto size = std::filesystem::file_size(path);
        auto name = narrow(path.filename().wstring());
        require(size <= maxBytes && !name.empty() && name.size() <= 1000, "File too large or unsupported name");
        Offer offer{std::move(name), size, verifiedDigest(path, channel)};
        std::ifstream file(path, std::ios::binary);
        require(file.is_open(), "Cannot open file");
        channel.send(offer.encode(7));
        auto response = channel.receive();
        require(response.size() == 9 && response[0] == 3, "Invalid resume response");
        uint64_t done = read<uint64_t>(response, 1);
        require(done <= offer.size && bool(file.seekg(done)), "Invalid resume position");
        const auto offset = done;
        const auto start = std::chrono::steady_clock::now();
        Bytes data(blockSize + 1);
        data[0] = 4;
        while (done < offer.size) {
            const auto sizeToRead = static_cast<size_t>(std::min<uint64_t>(blockSize, offer.size - done));
            require(bool(file.read(reinterpret_cast<char*>(data.data() + 1), sizeToRead)), "File changed while sending");
            data.resize(sizeToRead + 1);
            const auto sentAt = std::chrono::steady_clock::now();
            channel.send(data);
            if (audioOnLAN_()) {
                // Keep the bulk TCP queue shallow while the same path is carrying audio.
                const auto budget = std::chrono::duration<double>(sizeToRead / (8.0 * 1048576));
                std::this_thread::sleep_until(sentAt + budget);
            }
            done += sizeToRead;
            progress(done, offer.size, start, offset);
        }
        channel.send({5});
        require(channel.receive() == Bytes{6}, "iPhone did not confirm receipt");
        std::lock_guard<std::mutex> lock(mutex_);
        if (offered_ == path) offered_.clear();
        status_ = L"Đã gửi tệp sang iPhone";
    }

    void serve(SOCKET socket) {
        PairingKey key{};
        if (!loadPairingKey(key)) return;
        DWORD timeout = 30000;
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
        try {
            Channel channel(socket, key);
            SecureZeroMemory(key.data(), key.size());
            const auto req = channel.receive();
            channel.authenticated();
            if (req == Bytes{11}) { channel.send({12}); return; }
            sockaddr_in peer{};
            int peerLength = sizeof(peer);
            char peerIP[INET_ADDRSTRLEN]{};
            if (getpeername(socket, reinterpret_cast<sockaddr*>(&peer), &peerLength) == 0 &&
                inet_ntop(AF_INET, &peer.sin_addr, peerIP, sizeof(peerIP))) {
                std::lock_guard<std::mutex> lock(mutex_);
                peerAddress_ = widen(peerIP);
            }
            try {
                if (req[0] == 1) upload(channel, req);
                else if (req == Bytes{2}) download(channel);
                else throw std::runtime_error("Unknown file request");
            } catch (const std::exception& error) {
                setStatus(L"Truyền tệp bị gián đoạn");
                const std::string message(error.what());
                Bytes response{255};
                response.insert(response.end(), message.begin(), message.end());
                try { channel.send(response); } catch (...) {}
            }
        } catch (...) {
            // Unauthenticated peers cannot change visible state or access files.
        }
        SecureZeroMemory(key.data(), key.size());
    }

    void run() {
        const SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (listener == INVALID_SOCKET) {
            setStatus(L"Không thể mở cổng truyền tệp");
            return;
        }
        const BOOL exclusive = TRUE;
        setsockopt(listener, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char*>(&exclusive), sizeof(exclusive));
        sockaddr_in endpoint{};
        endpoint.sin_family = AF_INET;
        endpoint.sin_addr.s_addr = INADDR_ANY;
        endpoint.sin_port = htons(port);
        if (bind(listener, reinterpret_cast<const sockaddr*>(&endpoint), sizeof(endpoint)) == SOCKET_ERROR ||
            listen(listener, 2) == SOCKET_ERROR) {
            setStatus(L"Không thể mở cổng 55124");
            closesocket(listener);
            return;
        }
        publishBonjour(port, L"_nikaudio._tcp");
        while (running_) {
            fd_set readable;
            FD_ZERO(&readable);
            FD_SET(listener, &readable);
            timeval timeout{0, 200000};
            if (select(0, &readable, nullptr, nullptr, &timeout) <= 0) continue;
            const SOCKET client = accept(listener, nullptr, nullptr);
            if (client == INVALID_SOCKET) continue;
            {
                std::lock_guard<std::mutex> lock(socketMutex_);
                peer_ = client;
                if (!running_) shutdown(client, SD_BOTH);
            }
            if (running_) serve(client);
            {
                std::lock_guard<std::mutex> lock(socketMutex_);
                closesocket(client);
                peer_ = INVALID_SOCKET;
            }
        }
        closesocket(listener);
    }

    mutable std::mutex mutex_;
    Path offered_;
    std::wstring status_ = L"Sẵn sàng nhận tệp";
    std::wstring address_, peerAddress_;
    std::mutex socketMutex_;
    SOCKET peer_ = INVALID_SOCKET;
    std::atomic<bool> running_{true};
    std::function<bool()> audioOnLAN_;
    std::thread worker_;
};
}
