#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
#include <ksmedia.h>
#include <mmsystem.h>
#include <avrt.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "lan_auth.h"
#include "latency_pulse.h"
#include "stereo_mix.h"

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "winmm.lib")
#pragma comment(lib, "avrt.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "comdlg32.lib")
#pragma comment(lib, "dnsapi.lib")

static constexpr uint16_t TARGET_PORT = 55123;
static constexpr uint32_t OUT_SAMPLE_RATE = 48000;
static constexpr size_t PACKET_FRAMES = 120; // 2.5ms @ 48kHz
static constexpr size_t PACKET_PCM_BYTES = PACKET_FRAMES * 4; // Stereo Int16
static constexpr uint16_t FLAG_HEARTBEAT = 1;
static constexpr uint16_t FLAG_CAPTURE_RESUMED = 2;

#pragma pack(push, 1)
struct AudioPacketHeader {
    char magic[4];       // "NIKA"
    uint32_t seq;        // little-endian
    uint16_t payloadLen; // bytes
    uint16_t flags;      // 0 = 48kHz Stereo Int16
};

struct UsbmuxHeader {
    uint32_t length;
    uint32_t version;
    uint32_t type;
    uint32_t tag;
};
#pragma pack(pop)

// MARK: - Helper: Send / Recv exact bytes on TCP

static bool sendAll(SOCKET s, const char* data, int len) {
    int sent = 0;
    while (sent < len) {
        int n = send(s, data + sent, len - sent, 0);
        if (n <= 0) return false;
        sent += n;
    }
    return true;
}

static bool recvAll(SOCKET s, char* data, int len) {
    int got = 0;
    while (got < len) {
        int n = recv(s, data + got, len - got, 0);
        if (n <= 0) return false;
        got += n;
    }
    return true;
}

#include "file_transfer.h"
#include "tray.h"

// MARK: - Windows usbmuxd Client (127.0.0.1:27015)

static SOCKET connectLocalhostUsbmux() {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return INVALID_SOCKET;

    DWORD timeout = 1500;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&timeout, sizeof(timeout));
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char*)&timeout, sizeof(timeout));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(27015);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);

    if (connect(s, (sockaddr*)&addr, sizeof(addr)) != 0) {
        closesocket(s);
        return INVALID_SOCKET;
    }
    return s;
}

static bool usbmuxPlistRPC(SOCKET s, const std::string& plistXml, uint32_t tag, std::string& outXml) {
    UsbmuxHeader hdr{};
    hdr.length = static_cast<uint32_t>(sizeof(UsbmuxHeader) + plistXml.size());
    hdr.version = 1;
    hdr.type = 8; // plist message
    hdr.tag = tag;

    if (!sendAll(s, (const char*)&hdr, sizeof(hdr))) return false;
    if (!sendAll(s, plistXml.data(), static_cast<int>(plistXml.size()))) return false;

    UsbmuxHeader resp{};
    if (!recvAll(s, (char*)&resp, sizeof(resp))) return false;
    if (resp.length < sizeof(UsbmuxHeader) || resp.length > 1024 * 1024) return false;

    size_t bodyLen = resp.length - sizeof(UsbmuxHeader);
    outXml.resize(bodyLen);
    if (bodyLen > 0 && !recvAll(s, outXml.data(), static_cast<int>(bodyLen))) return false;
    return true;
}

static bool extractPlistStringAfterKey(const std::string& block, const std::string& key, std::string& outVal) {
    std::string needle = "<key>" + key + "</key>";
    size_t kPos = block.find(needle);
    if (kPos == std::string::npos) return false;
    size_t sStart = block.find("<string>", kPos + needle.size());
    if (sStart == std::string::npos) return false;
    size_t sEnd = block.find("</string>", sStart + 8);
    if (sEnd == std::string::npos) return false;
    outVal = block.substr(sStart + 8, sEnd - (sStart + 8));
    return true;
}

static bool extractPlistIntAfterKey(const std::string& block, const std::string& key, int& outVal) {
    std::string needle = "<key>" + key + "</key>";
    size_t kPos = block.find(needle);
    if (kPos == std::string::npos) return false;
    size_t iStart = block.find("<integer>", kPos + needle.size());
    if (iStart == std::string::npos) return false;
    size_t iEnd = block.find("</integer>", iStart + 9);
    if (iEnd == std::string::npos) return false;
    try {
        outVal = std::stoi(block.substr(iStart + 9, iEnd - (iStart + 9)));
        return true;
    } catch (...) {
        return false;
    }
}

static int findFirstUSBDeviceID() {
    SOCKET s = connectLocalhostUsbmux();
    if (s == INVALID_SOCKET) return -1;

    const std::string req =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">"
        "<plist version=\"1.0\"><dict>"
        "<key>MessageType</key><string>ListDevices</string>"
        "<key>ClientVersionString</key><string>NiKAudioPC</string>"
        "<key>ProgName</key><string>NiKAudioPC</string>"
        "</dict></plist>";

    std::string resp;
    bool ok = usbmuxPlistRPC(s, req, 1, resp);
    closesocket(s);
    if (!ok) return -1;

    size_t listKey = resp.find("<key>DeviceList</key>");
    if (listKey == std::string::npos) return -1;
    size_t arrStart = resp.find("<array>", listKey);
    if (arrStart == std::string::npos) return -1;
    size_t arrEnd = resp.find("</array>", arrStart);
    if (arrEnd == std::string::npos) return -1;

    size_t pos = arrStart + 7;
    while (pos < arrEnd) {
        size_t dStart = resp.find("<dict>", pos);
        if (dStart == std::string::npos || dStart >= arrEnd) break;

        int depth = 1;
        size_t scan = dStart + 6;
        while (scan < arrEnd && depth > 0) {
            size_t nextOpen = resp.find("<dict>", scan);
            size_t nextClose = resp.find("</dict>", scan);
            if (nextClose == std::string::npos || nextClose >= arrEnd) break;
            if (nextOpen != std::string::npos && nextOpen < nextClose) {
                depth++;
                scan = nextOpen + 6;
            } else {
                depth--;
                scan = nextClose + 7;
            }
        }
        if (depth != 0) break;

        std::string deviceBlock = resp.substr(dStart, scan - dStart);
        std::string connType;
        int devId = -1;
        if (extractPlistStringAfterKey(deviceBlock, "ConnectionType", connType) &&
            connType == "USB" &&
            extractPlistIntAfterKey(deviceBlock, "DeviceID", devId) &&
            devId >= 0) {
            return devId;
        }
        pos = scan;
    }
    return -1;
}

static SOCKET openUSBTunnelToPhone(uint16_t phonePort) {
    int devId = findFirstUSBDeviceID();
    if (devId < 0) return INVALID_SOCKET;

    SOCKET s = connectLocalhostUsbmux();
    if (s == INVALID_SOCKET) return INVALID_SOCKET;

    uint16_t netPort = htons(phonePort);
    std::string req =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">"
        "<plist version=\"1.0\"><dict>"
        "<key>MessageType</key><string>Connect</string>"
        "<key>ClientVersionString</key><string>NiKAudioPC</string>"
        "<key>ProgName</key><string>NiKAudioPC</string>"
        "<key>DeviceID</key><integer>" + std::to_string(devId) + "</integer>"
        "<key>PortNumber</key><integer>" + std::to_string(netPort) + "</integer>"
        "</dict></plist>";

    std::string resp;
    if (!usbmuxPlistRPC(s, req, 2, resp)) {
        closesocket(s);
        return INVALID_SOCKET;
    }

    int errNum = -1;
    if (!extractPlistIntAfterKey(resp, "Number", errNum) || errNum != 0) {
        closesocket(s);
        return INVALID_SOCKET;
    }

    BOOL nodelay = TRUE;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char*)&nodelay, sizeof(nodelay));
    DWORD sendTimeout = 15;
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char*)&sendTimeout, sizeof(sendTimeout));
    return s;
}

static bool readUSBPairingKey(PairingKey& key) {
    const SOCKET socket = openUSBTunnelToPhone(TARGET_PORT);
    if (socket == INVALID_SOCKET) return false;

    constexpr char request[] = {'N', 'I', 'K', 'P', 1, 0, 0, 0};
    constexpr char expected[] = {'N', 'I', 'K', 'Q', 1, 0, 32, 0};
    char response[sizeof(expected) + 32]{};
    const bool received = sendAll(socket, request, sizeof(request)) &&
                          recvAll(socket, response, sizeof(response)) &&
                          std::memcmp(response, expected, sizeof(expected)) == 0 &&
                          std::any_of(response + sizeof(expected), response + sizeof(response),
                                      [](char byte) { return byte != 0; });
    if (received) std::memcpy(key.data(), response + sizeof(expected), key.size());
    SecureZeroMemory(response, sizeof(response));
    closesocket(socket);
    return received;
}

// MARK: - Local IPv4 Subnet Enumeration for Unicast LAN Discovery

struct LocalIPv4 {
    uint32_t ipHostOrder;
    uint8_t prefixLength;
};

static std::vector<LocalIPv4> getActiveLocalIPv4s() {
    std::vector<LocalIPv4> results;
    ULONG bufSize = 16384;
    std::vector<uint8_t> buf(bufSize);
    auto* adapters = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buf.data());

    ULONG ret = GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
                                     nullptr, adapters, &bufSize);
    if (ret == ERROR_BUFFER_OVERFLOW) {
        buf.resize(bufSize);
        adapters = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buf.data());
        ret = GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
                                   nullptr, adapters, &bufSize);
    }
    if (ret != NO_ERROR) return results;

    for (auto* a = adapters; a != nullptr; a = a->Next) {
        if (a->OperStatus != IfOperStatusUp) continue;
        if (a->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
        for (auto* u = a->FirstUnicastAddress; u != nullptr; u = u->Next) {
            if (!u->Address.lpSockaddr || u->Address.lpSockaddr->sa_family != AF_INET) continue;
            auto* sin = reinterpret_cast<sockaddr_in*>(u->Address.lpSockaddr);
            uint32_t ip = ntohl(sin->sin_addr.s_addr);
            uint8_t firstOctet = static_cast<uint8_t>((ip >> 24) & 0xFF);
            uint8_t secondOctet = static_cast<uint8_t>((ip >> 16) & 0xFF);
            bool isPrivate = (firstOctet == 10) ||
                             (firstOctet == 192 && secondOctet == 168) ||
                             (firstOctet == 172 && secondOctet >= 16 && secondOctet <= 31);
            if (isPrivate) {
                results.push_back({ip, u->OnLinkPrefixLength});
            }
        }
    }
    return results;
}

static std::wstring localFileAddresses() {
    std::string addresses;
    for (const auto& local : getActiveLocalIPv4s()) {
        in_addr address{};
        address.s_addr = htonl(local.ipHostOrder);
        char text[INET_ADDRSTRLEN]{};
        if (!inet_ntop(AF_INET, &address, text, sizeof(text))) continue;
        if (!addresses.empty()) addresses += " · ";
        addresses += text;
    }
    return FileTransfer::widen(addresses);
}

// MARK: - Transport Manager (Auto USB + Continuous Unicast LAN Discovery)

class DualTransport {
public:
    explicit DualTransport(const std::string& manualIP) : manualLanIP_(manualIP) {
        udpSock_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (udpSock_ != INVALID_SOCKET) {
            const DWORD timeout = 15;
            setsockopt(udpSock_, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
        }
        discoverySock_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (discoverySock_ != INVALID_SOCKET) {
            BOOL bcast = TRUE;
            setsockopt(discoverySock_, SOL_SOCKET, SO_BROADCAST, (const char*)&bcast, sizeof(bcast));
            BOOL newBehavior = FALSE;
            DWORD bytesReturned = 0;
            DWORD sioUdpConnReset = _WSAIOW(IOC_VENDOR, 12);
            WSAIoctl(discoverySock_, sioUdpConnReset, &newBehavior, sizeof(newBehavior),
                     nullptr, 0, &bytesReturned, nullptr, nullptr);
        }

        hasPairingKey_ = loadPairingKey(pairingKey_);
        monitorThread_ = std::thread(&DualTransport::monitorLoop, this);
        senderThread_ = std::thread(&DualTransport::senderLoop, this);
    }

    ~DualTransport() {
        {
            std::lock_guard<std::mutex> lock(queueMutex_);
            running_ = false;
        }
        queueReady_.notify_one();
        if (senderThread_.joinable()) senderThread_.join();
        if (monitorThread_.joinable()) monitorThread_.join();
        std::lock_guard<std::mutex> lk(mu_);
        if (usbSock_ != INVALID_SOCKET) closesocket(usbSock_);
        if (udpSock_ != INVALID_SOCKET) closesocket(udpSock_);
        if (discoverySock_ != INVALID_SOCKET) closesocket(discoverySock_);
    }

    void setEnabled(bool enabled) {
        std::lock_guard<std::mutex> lock(queueMutex_);
        if (enabled_.exchange(enabled) && !enabled) clearAudioQueue();
    }

    void discardQueuedAudio() {
        std::lock_guard<std::mutex> lock(queueMutex_);
        clearAudioQueue();
    }

    bool pair(const PairingKey& key) {
        if (!savePairingKey(key)) return false;
        std::lock_guard<std::mutex> lock(mu_);
        pairingKey_ = key;
        hasPairingKey_ = true;
        hasLanTarget_ = false;
        ++pairingGeneration_;
        return true;
    }

    bool forgetPairing() {
        if (!CredDeleteW(pairingCredential, CRED_TYPE_GENERIC, 0) && GetLastError() != ERROR_NOT_FOUND) return false;
        std::lock_guard<std::mutex> lock(mu_);
        SecureZeroMemory(pairingKey_.data(), pairingKey_.size());
        hasPairingKey_ = false;
        hasLanTarget_ = false;
        ++pairingGeneration_;
        return true;
    }

    void queueAudioPacket(const int16_t* pcmStereo, bool captureResumed) {
        {
            std::lock_guard<std::mutex> lock(queueMutex_);
            if (!enabled_) return;
            if (captureResumed) clearAudioQueue();
            if (audioQueue_.size() == maxQueuedAudio) {
                audioQueue_.pop_front();
                audioQueue_.front().captureResumed = true;
            }
            auto& packet = audioQueue_.emplace_back();
            std::copy_n(pcmStereo, packet.pcm.size(), packet.pcm.begin());
            packet.queuedAt = Clock::now();
            packet.captureResumed = captureResumed;
            packet.generation = audioGeneration_;
        }
        queueReady_.notify_one();
    }

    bool audioOnLAN() {
        std::lock_guard<std::mutex> lock(mu_);
        return enabled_ && usbSock_ == INVALID_SOCKET && lanReady() &&
               Clock::now() - lastAudioSent_ < std::chrono::milliseconds(500);
    }

    unsigned sequence() const { return seq_; }

    std::wstring windowStatus() {
        std::lock_guard<std::mutex> lock(mu_);
        if (usbSock_ != INVALID_SOCKET) return L"Đang gửi qua Lightning";
        if (lanReady()) return L"Đang gửi qua Wi-Fi";
        return hasPairingKey_ ? L"Đang tìm iPhone" : L"Cần ghép đôi để dùng Wi-Fi";
    }

    std::string statusText() {
        std::unique_lock<std::mutex> lk(mu_, std::try_to_lock);
        if (!lk.owns_lock()) return "Dang gui am thanh";
        if (usbSock_ != INVALID_SOCKET) {
            if (lanReady()) return "USB Lightning (LAN san sang: " + currentLanIP_ + ")";
            return "USB Lightning (usbmuxd)";
        }
        if (lanReady()) return "Wi-Fi LAN (" + currentLanIP_ + ")";
        return hasPairingKey_ ? "Dang tim iPhone (USB / LAN)..." : "Can ghep doi de dung Wi-Fi LAN";
    }

private:
    using Clock = std::chrono::steady_clock;
    static constexpr size_t maxQueuedAudio = 8;
    static constexpr auto maxAudioAge = std::chrono::milliseconds(20);

    struct QueuedAudio {
        std::array<int16_t, PACKET_FRAMES * 2> pcm;
        Clock::time_point queuedAt;
        bool captureResumed;
        uint64_t generation;
    };

    // Called with queueMutex_ held. Invalidate a packet the sender dequeued before the reset.
    void clearAudioQueue() {
        audioQueue_.clear();
        ++audioGeneration_;
    }

    bool lanReady() const {
        return hasLanTarget_ && Clock::now() - lanConfirmed_ < std::chrono::seconds(12);
    }

    // Called with mu_ held, so heartbeats and audio share one ordered sequence.
    void sendPacket(const int16_t* pcm, size_t frames, bool captureResumed = false) {
        std::array<uint8_t, sizeof(AudioPacketHeader) + PACKET_PCM_BYTES> packet{};
        const bool heartbeat = frames == 0;
        const uint16_t flags = heartbeat ? FLAG_HEARTBEAT : (captureResumed ? FLAG_CAPTURE_RESUMED : 0);
        const AudioPacketHeader header{{'N','I','K','A'}, heartbeat ? ++heartbeatSeq_ : ++seq_,
                                       static_cast<uint16_t>(frames * 4), flags};
        std::memcpy(packet.data(), &header, sizeof(header));
        if (!heartbeat) std::memcpy(packet.data() + sizeof(header), pcm, header.payloadLen);
        const int length = sizeof(header) + header.payloadLen;
        lastSent_ = Clock::now();
        if (!heartbeat) lastAudioSent_ = lastSent_;

        if (usbSock_ != INVALID_SOCKET) {
            if (!sendAll(usbSock_, reinterpret_cast<const char*>(packet.data()), length)) {
                closesocket(usbSock_);
                usbSock_ = INVALID_SOCKET;
                std::cout << "\n[USB] Mat ket noi cap Lightning -> chuyen sang Wi-Fi LAN.\n";
            } else if (lastSent_ >= usbOverlapUntil_) {
                return;
            }
        }

        if (!lanReady() || udpSock_ == INVALID_SOCKET) return;
        constexpr ULONG prefixSize = sizeof(AudioPacketHeader) + sizeof(LanNonce);
        std::array<uint8_t, prefixSize + PACKET_PCM_BYTES + sizeof(LanCipherTag)> encrypted{};
        std::memcpy(encrypted.data(), &header, sizeof(header));
        std::memcpy(encrypted.data() + sizeof(header), lanNonce_.data(), lanNonce_.size());
        LanCipherTag tag{};
        if (!cipher_.encrypt(header.seq, heartbeat, encrypted.data(), prefixSize,
                             packet.data() + sizeof(header), header.payloadLen,
                             encrypted.data() + prefixSize, tag)) return;
        const size_t taggedLength = prefixSize + header.payloadLen;
        std::memcpy(encrypted.data() + taggedLength, tag.data(), tag.size());
        sendto(udpSock_, reinterpret_cast<const char*>(encrypted.data()), static_cast<int>(taggedLength + tag.size()),
               0, reinterpret_cast<const sockaddr*>(&lanAddr_), sizeof(lanAddr_));
    }

    void tryDiscoverLAN() {
        if (discoverySock_ == INVALID_SOCKET) return;
        PairingKey key{};
        unsigned generation;
        sockaddr_in lastTarget{};
        {
            std::lock_guard<std::mutex> lock(mu_);
            if (!hasPairingKey_) return;
            key = pairingKey_;
            generation = pairingGeneration_;
            if (lanReady()) lastTarget = lanAddr_;
        }
        LanNonce nonce{};
        if (BCryptGenRandom(nullptr, nonce.data(), static_cast<ULONG>(nonce.size()),
                            BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) return;
        char ping[4 + sizeof(LanNonce) + sizeof(LanTag)] = {'N', 'I', 'K', 'D'};
        std::memcpy(ping + 4, nonce.data(), nonce.size());
        LanTag tag{};
        if (!auth_.sign(key, ping, 4 + nonce.size(), tag)) return;
        std::memcpy(ping + 4 + nonce.size(), tag.data(), tag.size());
        char replyHeader[4 + sizeof(LanNonce)] = {'N', 'I', 'K', 'R'};
        std::memcpy(replyHeader + 4, nonce.data(), nonce.size());

        sockaddr_in manual{};
        manual.sin_family = AF_INET;
        manual.sin_port = htons(TARGET_PORT);
        if (!manualLanIP_.empty()) {
            if (inet_pton(AF_INET, manualLanIP_.c_str(), &manual.sin_addr) != 1) return;
            sendto(discoverySock_, ping, sizeof(ping), 0, reinterpret_cast<const sockaddr*>(&manual), sizeof(manual));
        }
        if (lastTarget.sin_family == AF_INET && manualLanIP_.empty()) {
            sendto(discoverySock_, ping, sizeof(ping), 0,
                   reinterpret_cast<const sockaddr*>(&lastTarget), sizeof(lastTarget));
        }
        const auto locals = manualLanIP_.empty() && lastTarget.sin_family != AF_INET
                            ? getActiveLocalIPv4s() : std::vector<LocalIPv4>{};

        // Probe the directed broadcast and a rolling batch of unicast addresses.
        // Bounding the batch avoids an ARP storm on large private networks.
        for (const auto& local : locals) {
            const unsigned prefix = local.prefixLength;
            if (prefix == 0 || prefix >= 32) continue;
            const uint32_t hostMask = UINT32_MAX >> prefix;
            const uint32_t subnetBase = local.ipHostOrder & ~hostMask;
            sockaddr_in dst{};
            dst.sin_family = AF_INET;
            dst.sin_port = htons(TARGET_PORT);
            if (prefix < 31) {
                dst.sin_addr.s_addr = htonl(subnetBase | hostMask);
                sendto(discoverySock_, ping, sizeof(ping), 0, reinterpret_cast<const sockaddr*>(&dst), sizeof(dst));
            }

            const uint32_t firstHost = prefix == 31 ? 0 : 1;
            const uint32_t hostCount = prefix == 31 ? 2 : hostMask - 1;
            const uint32_t batchSize = std::min(hostCount, 256u);
            for (uint32_t i = 0; i < batchSize && running_; ++i) {
                const uint32_t host = firstHost + static_cast<uint32_t>((discoveryOffset_ + i) % hostCount);
                const uint32_t ip = subnetBase | host;
                if (ip == local.ipHostOrder) continue;
                dst.sin_addr.s_addr = htonl(ip);
                sendto(discoverySock_, ping, sizeof(ping), 0, reinterpret_cast<const sockaddr*>(&dst), sizeof(dst));
            }
        }
        if (!locals.empty()) discoveryOffset_ += 256;

        const auto deadline = Clock::now() + std::chrono::milliseconds(500);
        while (running_) {
            const auto remaining = std::chrono::ceil<std::chrono::microseconds>(deadline - Clock::now()).count();
            if (remaining <= 0) break;

            fd_set readable;
            FD_ZERO(&readable);
            FD_SET(discoverySock_, &readable);
            timeval timeout{0, static_cast<long>(remaining)};
            if (select(0, &readable, nullptr, nullptr, &timeout) <= 0) break;

            uint8_t buf[4 + 2 * sizeof(LanNonce) + sizeof(LanTag)]{};
            sockaddr_in from{};
            int fromLen = sizeof(from);
            int n = recvfrom(discoverySock_, reinterpret_cast<char*>(buf), sizeof(buf), 0, reinterpret_cast<sockaddr*>(&from), &fromLen);
            if (n == SOCKET_ERROR) {
                const int error = WSAGetLastError();
                if (error == WSAEMSGSIZE || error == WSAECONNRESET) continue;
                break;
            }
            if (n != sizeof(buf) || from.sin_port != htons(TARGET_PORT) ||
                (!manualLanIP_.empty() && from.sin_addr.s_addr != manual.sin_addr.s_addr) ||
                std::memcmp(buf, replyHeader, sizeof(replyHeader)) != 0) continue;
            const size_t signedLength = sizeof(replyHeader) + sizeof(LanNonce);
            LanTag expectedReply{};
            if (!auth_.sign(key, buf, signedLength, expectedReply) ||
                !LanAuthenticator::matches(expectedReply, buf + signedLength)) continue;

            char ip[INET_ADDRSTRLEN]{};
            if (!inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip))) continue;
            std::lock_guard<std::mutex> lock(mu_);
            if (generation != pairingGeneration_) return;
            LanNonce sessionNonce{};
            std::memcpy(sessionNonce.data(), buf + sizeof(replyHeader), sessionNonce.size());
            LanTag keyMaterial{};
            if (!auth_.sign(key, sessionNonce.data(), sessionNonce.size(), keyMaterial)) return;
            const bool cipherReady = cipher_.setSessionKey(keyMaterial);
            SecureZeroMemory(keyMaterial.data(), keyMaterial.size());
            if (!cipherReady) return;
            if (currentLanIP_ != ip) std::cout << "\n[LAN] Ghep doi thanh cong: " << ip << "\n";
            currentLanIP_ = ip;
            lanAddr_ = from;
            lanNonce_ = sessionNonce;
            lanConfirmed_ = Clock::now();
            hasLanTarget_ = true;
            break;
        }
    }

    void monitorLoop() {
        while (running_) {
            bool needUSB;
            bool needLANRefresh;
            {
                std::lock_guard<std::mutex> lk(mu_);
                needUSB = (usbSock_ == INVALID_SOCKET);
                needLANRefresh = !hasLanTarget_ || Clock::now() - lanConfirmed_ >= std::chrono::seconds(4);
            }

            if (needLANRefresh) tryDiscoverLAN();

            if (needUSB && running_) {
                SOCKET s = openUSBTunnelToPhone(TARGET_PORT);
                if (s != INVALID_SOCKET) {
                    std::lock_guard<std::mutex> lk(mu_);
                    usbSock_ = s;
                    usbOverlapUntil_ = Clock::now() + std::chrono::milliseconds(250);
                    std::cout << "\n[USB] Da ket noi iPhone qua cap Lightning!\n";
                }
            }

            for (int i = 0; i < 10 && running_; ++i) {
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        }
    }

    void senderLoop() {
        bool droppedAudio = false;
        while (true) {
            QueuedAudio packet{};
            bool hasAudio;
            {
                std::unique_lock<std::mutex> lock(queueMutex_);
                queueReady_.wait_for(lock, std::chrono::milliseconds(80), [this] {
                    return !running_ || !audioQueue_.empty();
                });
                if (!running_) return;
                const auto now = Clock::now();
                while (!audioQueue_.empty() && now - audioQueue_.front().queuedAt >= maxAudioAge) {
                    droppedAudio = true;
                    audioQueue_.pop_front();
                }
                hasAudio = !audioQueue_.empty();
                if (hasAudio) {
                    packet = audioQueue_.front();
                    audioQueue_.pop_front();
                }
            }
            std::lock_guard<std::mutex> lock(mu_);
            if (!running_) return;
            const auto now = Clock::now();
            if (hasAudio && now - packet.queuedAt < maxAudioAge) {
                if (enabled_ && packet.generation == audioGeneration_) {
                    sendPacket(packet.pcm.data(), PACKET_FRAMES, packet.captureResumed || droppedAudio);
                }
                droppedAudio = false;
            } else {
                droppedAudio = droppedAudio || hasAudio;
                if (now - lastSent_ >= std::chrono::milliseconds(250)) sendPacket(nullptr, 0);
            }
        }
    }

    std::atomic<bool> running_{true};
    std::mutex mu_;
    std::mutex queueMutex_;
    std::condition_variable queueReady_;
    std::deque<QueuedAudio> audioQueue_;
    std::atomic<uint64_t> audioGeneration_{0};
    SOCKET usbSock_{INVALID_SOCKET};
    SOCKET udpSock_{INVALID_SOCKET};
    SOCKET discoverySock_{INVALID_SOCKET};
    uint64_t discoveryOffset_{0};
    sockaddr_in lanAddr_{};
    bool hasLanTarget_{false};
    std::atomic<uint32_t> seq_{0};
    uint32_t heartbeatSeq_{0};
    std::atomic<bool> enabled_{true};
    LanAuthenticator auth_;
    LanCipher cipher_;
    PairingKey pairingKey_{};
    bool hasPairingKey_{false};
    unsigned pairingGeneration_{0};
    LanNonce lanNonce_{};
    Clock::time_point lanConfirmed_{};
    Clock::time_point usbOverlapUntil_{};
    Clock::time_point lastSent_{}, lastAudioSent_{};
    std::string manualLanIP_;
    std::string currentLanIP_;
    std::thread monitorThread_;
    std::thread senderThread_;
};

// MARK: - WASAPI Default Device Change Notifier

class DeviceChangeNotifier final : public IMMNotificationClient {
public:
    std::atomic<bool> deviceChanged{false};

    ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
    ULONG STDMETHODCALLTYPE Release() override { return 1; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        if (riid == IID_IUnknown || riid == __uuidof(IMMNotificationClient)) {
            *ppv = static_cast<IMMNotificationClient*>(this);
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role, LPCWSTR) override {
        if (flow == eRender && role == eConsole) {
            deviceChanged.store(true);
        }
        return S_OK;
    }
};

// MARK: - Main: WASAPI Loopback (Auto-Recover) -> 48kHz Stereo Int16 -> DualTransport

int main(int argc, char* argv[]) {
    std::cout << "=== NiKAudio PC Sender (USB Lightning + Wi-Fi LAN) ===\n";
    std::cout << "Cach dung: NiKAudioPC.exe [IP_iPhone_tuy_chon]\n";
    std::cout << "- Cam cap Lightning (da cai iTunes/Apple Devices): tu dong uu tien USB.\n";
    std::cout << "- Rut cap / chung Wi-Fi: tu dong quet subnet LAN (hoac truyen IP).\n\n";

    std::string manualIP = (argc >= 2) ? argv[1] : "";

    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        std::cerr << "Loi khoi tao Winsock!\n";
        return 1;
    }

    timeBeginPeriod(1);
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) {
        std::cerr << "Loi CoInitializeEx!\n";
        return 1;
    }

    IMMDeviceEnumerator* enumerator = nullptr;
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          __uuidof(IMMDeviceEnumerator), (void**)&enumerator);
    if (FAILED(hr)) {
        std::cerr << "Khong tao duoc MMDeviceEnumerator\n";
        return 1;
    }

    DeviceChangeNotifier notifier;
    enumerator->RegisterEndpointNotificationCallback(&notifier);

    DWORD taskIndex = 0;
    AvSetMmThreadCharacteristicsW(L"Pro Audio", &taskIndex);

    SetProcessDPIAware();
    {
        DualTransport transport(manualIP);
        FileTransfer::Server files(localFileAddresses(), [&] { return transport.audioOnLAN(); });
        Tray tray([&] { return transport.windowStatus(); },
                  [&](const PairingKey& key) { return transport.pair(key); },
                  [&] { return transport.forgetPairing(); }, readUSBPairingKey, files);
        auto lastLog = std::chrono::steady_clock::now();

        while (!tray.quitting) {
            transport.setEnabled(tray.enabled);
            if (!tray.enabled) {
                Sleep(100);
                continue;
            }
            notifier.deviceChanged.store(false);

            IMMDevice* device = nullptr;
            IAudioClient* audioClient = nullptr;
            IAudioCaptureClient* captureClient = nullptr;
            WAVEFORMATEX* mixFmt = nullptr;

            auto cleanupSession = [&]() {
                if (audioClient) { audioClient->Stop(); audioClient->Release(); audioClient = nullptr; }
                if (captureClient) { captureClient->Release(); captureClient = nullptr; }
                if (mixFmt) { CoTaskMemFree(mixFmt); mixFmt = nullptr; }
                if (device) { device->Release(); device = nullptr; }
            };

            hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
            if (FAILED(hr)) {
                std::cerr << "\n[WASAPI] Chua tim thay thiet bi phat mac dinh, thu lai sau 1s...\n";
                cleanupSession();
                Sleep(1000);
                continue;
            }

            hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&audioClient);
            if (FAILED(hr) || FAILED(audioClient->GetMixFormat(&mixFmt))) {
                cleanupSession();
                Sleep(500);
                continue;
            }

            bool isFloat = false;
            DWORD channelMask = 0;
            if (mixFmt->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
                isFloat = true;
            } else if (mixFmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
                auto* ext = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(mixFmt);
                channelMask = ext->dwChannelMask;
                if (IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)) {
                    isFloat = true;
                }
            }

            const unsigned sampleBytes = mixFmt->wBitsPerSample / 8;
            const bool isPCM = mixFmt->wFormatTag == WAVE_FORMAT_PCM ||
                (mixFmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
                 IsEqualGUID(reinterpret_cast<WAVEFORMATEXTENSIBLE*>(mixFmt)->SubFormat,
                             KSDATAFORMAT_SUBTYPE_PCM));
            const uint32_t inRate = mixFmt->nSamplesPerSec;
            const uint16_t inChannels = mixFmt->nChannels;
            const unsigned blockAlign = mixFmt->nBlockAlign;
            if (inChannels == 0 || inRate == 0 || blockAlign != inChannels * sampleBytes ||
                mixFmt->wBitsPerSample != sampleBytes * 8 ||
                (isFloat ? sampleBytes != sizeof(float) : !isPCM || sampleBytes < 2 || sampleBytes > 4)) {
                std::cerr << "[WASAPI] Dinh dang am thanh khong duoc ho tro.\n";
                cleanupSession();
                Sleep(1000);
                continue;
            }
            const auto gains = stereoGains(inChannels, channelMask);
            StereoLimiter limiter(inChannels > 2);
            std::cout << "\n[WASAPI] Bat am thanh he thong: " << inRate << " Hz, "
                      << inChannels << " kenh, " << (isFloat ? "Float" : "PCM") << mixFmt->wBitsPerSample << "\n";

            REFERENCE_TIME hnsDuration = 200000;
            hr = audioClient->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
                                         hnsDuration, 0, mixFmt, nullptr);
            if (FAILED(hr) || FAILED(audioClient->GetService(__uuidof(IAudioCaptureClient), (void**)&captureClient))) {
                std::cerr << "[WASAPI] Loi khoi tao Loopback (0x" << std::hex << hr << std::dec << "), thu lai...\n";
                cleanupSession();
                Sleep(500);
                continue;
            }

            hr = audioClient->Start();
            if (FAILED(hr)) {
                cleanupSession();
                Sleep(500);
                continue;
            }

            std::vector<int16_t> outQueue;
            outQueue.reserve(PACKET_FRAMES * 8);

            double resampleStep = static_cast<double>(inRate) / static_cast<double>(OUT_SAMPLE_RATE);
            double resamplePos = 0.0;
            float prevL = 0.0f, prevR = 0.0f;
            bool prevSurround = false;
            auto lastCapture = std::chrono::steady_clock::time_point{};
            bool markCaptureResumed = true;

            while (!tray.quitting) {
                if (!tray.enabled) break;
                if (notifier.deviceChanged.load()) {
                    std::cout << "\n[WASAPI] Thiet bi phat mac dinh thay doi -> dang khoi tao lai...\n";
                    break;
                }

                UINT32 packetLength = 0;
                hr = captureClient->GetNextPacketSize(&packetLength);
                if (FAILED(hr)) {
                    std::cout << "\n[WASAPI] Thiet bi phat bi ngat ket noi -> dang khoi tao lai...\n";
                    break;
                }

                if (packetLength == 0) {
                    Sleep(1);
                } else {
                    bool needReinit = false;
                    while (packetLength > 0 && tray.enabled && !tray.quitting) {
                        BYTE* data = nullptr;
                        UINT32 framesAvailable = 0;
                        DWORD flags = 0;

                        hr = captureClient->GetBuffer(&data, &framesAvailable, &flags, nullptr, nullptr);
                        if (FAILED(hr)) {
                            needReinit = true;
                            break;
                        }

                        const auto capturedAt = std::chrono::steady_clock::now();
                        if (framesAvailable > 0) {
                            // Normal loopback bursts can be spaced around 10 ms. Flag a sender-side gap
                            // independently of network timing or the 250 ms heartbeat cadence.
                            constexpr auto captureGap = std::chrono::milliseconds(40);
                            if (capturedAt - lastCapture >= captureGap ||
                                (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY)) {
                                markCaptureResumed = true;
                                outQueue.clear();
                                resamplePos = 0.0;
                                prevL = prevR = 0.0f;
                                prevSurround = false;
                            }
                            lastCapture = capturedAt;
                        }

                        std::vector<float> stereoIn(framesAvailable * 2, 0.0f);
                        std::vector<uint8_t> surroundIn(inChannels > 2 ? framesAvailable : 0, 0);
                        if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT) && data != nullptr) {
                            for (UINT32 i = 0; i < framesAvailable; ++i) {
                                float left = 0.0f;
                                float right = 0.0f;
                                for (uint16_t channel = 0; channel < inChannels; ++channel) {
                                    const BYTE* sampleData = data + static_cast<size_t>(i) * blockAlign
                                                                 + channel * sampleBytes;
                                    float sample;
                                    if (isFloat) {
                                        std::memcpy(&sample, sampleData, sizeof(sample));
                                    } else {
                                        // Left-align signed little-endian PCM in a 32-bit sample.
                                        int32_t pcm = 0;
                                        std::memcpy(reinterpret_cast<BYTE*>(&pcm) + sizeof(pcm) - sampleBytes,
                                                    sampleData, sampleBytes);
                                        sample = static_cast<float>(pcm) / 2147483648.0f;
                                    }
                                    if (inChannels > 2 && sample != 0 &&
                                        gains[channel].left != 1 && gains[channel].right != 1 &&
                                        (gains[channel].left != 0 || gains[channel].right != 0)) {
                                        surroundIn[i] = 1;
                                    }
                                    left += sample * gains[channel].left;
                                    right += sample * gains[channel].right;
                                }
                                stereoIn[i * 2] = left;
                                stereoIn[i * 2 + 1] = right;
                            }
                        }

                        captureClient->ReleaseBuffer(framesAvailable);

                        if (inRate == OUT_SAMPLE_RATE) {
                            for (UINT32 i = 0; i < framesAvailable; ++i) {
                                limiter.append(stereoIn[i * 2], stereoIn[i * 2 + 1],
                                               inChannels > 2 && surroundIn[i], outQueue);
                            }
                        } else {
                            while (resamplePos < static_cast<double>(framesAvailable)) {
                                int idx = static_cast<int>(resamplePos);
                                float frac = static_cast<float>(resamplePos - idx);
                                float l0 = (idx == 0) ? prevL : stereoIn[(idx - 1) * 2];
                                float r0 = (idx == 0) ? prevR : stereoIn[(idx - 1) * 2 + 1];
                                float l1 = stereoIn[idx * 2];
                                float r1 = stereoIn[idx * 2 + 1];
                                const bool mixed = inChannels > 2 &&
                                    ((idx == 0 ? prevSurround : surroundIn[idx - 1]) ||
                                     (frac > 0 && surroundIn[idx]));
                                limiter.append(l0 + (l1 - l0) * frac, r0 + (r1 - r0) * frac, mixed, outQueue);
                                resamplePos += resampleStep;
                            }
                            resamplePos -= static_cast<double>(framesAvailable);
                            if (framesAvailable > 0) {
                                prevL = stereoIn[(framesAvailable - 1) * 2];
                                prevR = stereoIn[(framesAvailable - 1) * 2 + 1];
                                prevSurround = inChannels > 2 && surroundIn.back();
                            }
                        }

                        size_t offset = 0;
                        while (outQueue.size() - offset >= PACKET_FRAMES * 2) {
                            transport.queueAudioPacket(outQueue.data() + offset, markCaptureResumed);
                            markCaptureResumed = false;
                            offset += PACKET_FRAMES * 2;
                        }
                        if (offset > 0) {
                            outQueue.erase(outQueue.begin(), outQueue.begin() + offset);
                        }

                        hr = captureClient->GetNextPacketSize(&packetLength);
                        if (FAILED(hr)) {
                            needReinit = true;
                            break;
                        }
                    }
                    if (needReinit) break;
                }

                auto now = std::chrono::steady_clock::now();
                if (std::chrono::duration_cast<std::chrono::seconds>(now - lastLog).count() >= 2) {
                    std::cout << "\rTrang thai: " << transport.statusText()
                              << " | Goi da gui: " << transport.sequence() << "        " << std::flush;
                    lastLog = now;
                }
            }

            transport.discardQueuedAudio();
            cleanupSession();
            Sleep(200);
        }

    }

    enumerator->UnregisterEndpointNotificationCallback(&notifier);
    enumerator->Release();
    CoUninitialize();
    timeEndPeriod(1);
    WSACleanup();
    return 0;
}
