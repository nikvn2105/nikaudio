#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
#include <ksmedia.h>
#include <mmsystem.h>
#include <avrt.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "winmm.lib")
#pragma comment(lib, "avrt.lib")

static constexpr uint16_t TARGET_PORT = 55123;
static constexpr uint32_t OUT_SAMPLE_RATE = 48000;
static constexpr size_t PACKET_FRAMES = 120; // 2.5ms @ 48kHz
static constexpr size_t PACKET_PCM_BYTES = PACKET_FRAMES * 4; // Stereo Int16

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

    size_t pos = 0;
    while (true) {
        size_t idKey = resp.find("<key>DeviceID</key>", pos);
        if (idKey == std::string::npos) break;
        size_t intStart = resp.find("<integer>", idKey);
        size_t intEnd = resp.find("</integer>", intStart);
        if (intStart == std::string::npos || intEnd == std::string::npos) break;
        int devId = std::stoi(resp.substr(intStart + 9, intEnd - (intStart + 9)));

        size_t chunkStart = (idKey > 400) ? (idKey - 400) : 0;
        size_t chunkEnd = std::min(resp.size(), intEnd + 600);
        std::string chunk = resp.substr(chunkStart, chunkEnd - chunkStart);
        if (chunk.find("<string>USB</string>") != std::string::npos) {
            return devId;
        }
        pos = intEnd;
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

    if (resp.find("<key>Number</key>") == std::string::npos ||
        resp.find("<integer>0</integer>") == std::string::npos) {
        closesocket(s);
        return INVALID_SOCKET;
    }

    BOOL nodelay = TRUE;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char*)&nodelay, sizeof(nodelay));
    DWORD sendTimeout = 500;
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char*)&sendTimeout, sizeof(sendTimeout));
    return s;
}

// MARK: - Transport Manager (Auto USB + LAN UDP fallback)

class DualTransport {
public:
    explicit DualTransport(const std::string& manualIP) : manualLanIP_(manualIP) {
        udpSock_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        BOOL bcast = TRUE;
        setsockopt(udpSock_, SOL_SOCKET, SO_BROADCAST, (const char*)&bcast, sizeof(bcast));
        DWORD recvTimeout = 100;
        setsockopt(udpSock_, SOL_SOCKET, SO_RCVTIMEO, (const char*)&recvTimeout, sizeof(recvTimeout));

        if (!manualLanIP_.empty()) {
            setLanTarget(manualLanIP_);
        }
        monitorThread_ = std::thread(&DualTransport::monitorLoop, this);
    }

    ~DualTransport() {
        running_ = false;
        if (monitorThread_.joinable()) monitorThread_.join();
        std::lock_guard<std::mutex> lk(mu_);
        if (usbSock_ != INVALID_SOCKET) closesocket(usbSock_);
        if (udpSock_ != INVALID_SOCKET) closesocket(udpSock_);
    }

    void sendAudioPacket(uint32_t seq, const int16_t* pcmStereo, size_t frames) {
        uint8_t pkt[sizeof(AudioPacketHeader) + PACKET_PCM_BYTES];
        auto* hdr = reinterpret_cast<AudioPacketHeader*>(pkt);
        std::memcpy(hdr->magic, "NIKA", 4);
        hdr->seq = seq;
        hdr->payloadLen = static_cast<uint16_t>(frames * 4);
        hdr->flags = 0;
        std::memcpy(pkt + sizeof(AudioPacketHeader), pcmStereo, hdr->payloadLen);
        int totalLen = static_cast<int>(sizeof(AudioPacketHeader) + hdr->payloadLen);

        std::lock_guard<std::mutex> lk(mu_);
        if (usbSock_ != INVALID_SOCKET) {
            if (!sendAll(usbSock_, reinterpret_cast<const char*>(pkt), totalLen)) {
                closesocket(usbSock_);
                usbSock_ = INVALID_SOCKET;
                std::cout << "\n[USB] Mat ket noi cap Lightning -> chuyen sang Wi-Fi LAN...\n";
            } else {
                return;
            }
        }

        if (hasLanTarget_ && udpSock_ != INVALID_SOCKET) {
            sendto(udpSock_, reinterpret_cast<const char*>(pkt), totalLen, 0,
                   reinterpret_cast<const sockaddr*>(&lanAddr_), sizeof(lanAddr_));
        }
    }

    std::string statusText() {
        std::lock_guard<std::mutex> lk(mu_);
        if (usbSock_ != INVALID_SOCKET) return "USB Lightning (usbmuxd)";
        if (hasLanTarget_) return "Wi-Fi LAN (" + currentLanIP_ + ")";
        return "Dang tim iPhone (USB / LAN)...";
    }

private:
    void setLanTarget(const std::string& ip) {
        std::lock_guard<std::mutex> lk(mu_);
        lanAddr_ = {};
        lanAddr_.sin_family = AF_INET;
        lanAddr_.sin_port = htons(TARGET_PORT);
        if (inet_pton(AF_INET, ip.c_str(), &lanAddr_.sin_addr) == 1) {
            hasLanTarget_ = true;
            currentLanIP_ = ip;
        }
    }

    void tryDiscoverLAN() {
        if (!manualLanIP_.empty() || udpSock_ == INVALID_SOCKET) return;
        sockaddr_in bcast{};
        bcast.sin_family = AF_INET;
        bcast.sin_port = htons(TARGET_PORT);
        bcast.sin_addr.s_addr = INADDR_BROADCAST;

        const char ping[4] = {'N', 'I', 'K', 'D'};
        sendto(udpSock_, ping, 4, 0, reinterpret_cast<const sockaddr*>(&bcast), sizeof(bcast));

        char buf[32]{};
        sockaddr_in from{};
        int fromLen = sizeof(from);
        int n = recvfrom(udpSock_, buf, sizeof(buf), 0, reinterpret_cast<sockaddr*>(&from), &fromLen);
        if (n >= 4 && std::memcmp(buf, "NIKR", 4) == 0) {
            char ipStr[INET_ADDRSTRLEN]{};
            inet_ntop(AF_INET, &from.sin_addr, ipStr, sizeof(ipStr));
            std::string foundIP(ipStr);
            bool changed = false;
            {
                std::lock_guard<std::mutex> lk(mu_);
                if (currentLanIP_ != foundIP) changed = true;
            }
            setLanTarget(foundIP);
            if (changed) {
                std::cout << "\n[LAN] Tim thay iPhone tai IP: " << foundIP << "\n";
            }
        }
    }

    void monitorLoop() {
        while (running_) {
            bool needUSB = false;
            {
                std::lock_guard<std::mutex> lk(mu_);
                needUSB = (usbSock_ == INVALID_SOCKET);
            }
            if (needUSB) {
                SOCKET s = openUSBTunnelToPhone(TARGET_PORT);
                if (s != INVALID_SOCKET) {
                    std::lock_guard<std::mutex> lk(mu_);
                    usbSock_ = s;
                    std::cout << "\n[USB] Da ket noi iPhone qua cap Lightning!\n";
                } else {
                    tryDiscoverLAN();
                }
            }
            for (int i = 0; i < 15 && running_; ++i) {
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        }
    }

    std::atomic<bool> running_{true};
    std::mutex mu_;
    SOCKET usbSock_{INVALID_SOCKET};
    SOCKET udpSock_{INVALID_SOCKET};
    sockaddr_in lanAddr_{};
    bool hasLanTarget_{false};
    std::string manualLanIP_;
    std::string currentLanIP_;
    std::thread monitorThread_;
};

// MARK: - Main: WASAPI Loopback -> 48kHz Stereo Int16 -> DualTransport

static inline int16_t floatToInt16(float v) {
    if (v > 1.0f) v = 1.0f;
    if (v < -1.0f) v = -1.0f;
    return static_cast<int16_t>(v * 32767.0f);
}

int main(int argc, char* argv[]) {
    std::cout << "=== NiKAudio PC Sender (USB Lightning + Wi-Fi LAN) ===\n";
    std::cout << "Cach dung: NiKAudioPC.exe [IP_iPhone_tuy_chon]\n";
    std::cout << "- Cam cap Lightning (da cai iTunes/Apple Devices): tu dong uu tien USB.\n";
    std::cout << "- Rut cap / chung Wi-Fi: tu dong tim iPhone qua LAN (hoac truyen IP).\n\n";

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
    IMMDevice* device = nullptr;
    IAudioClient* audioClient = nullptr;
    IAudioCaptureClient* captureClient = nullptr;
    WAVEFORMATEX* mixFmt = nullptr;

    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          __uuidof(IMMDeviceEnumerator), (void**)&enumerator);
    if (FAILED(hr)) { std::cerr << "Khong tao duoc MMDeviceEnumerator\n"; return 1; }

    hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(hr)) { std::cerr << "Khong tim thay thiet bi phat am thanh mac dinh\n"; return 1; }

    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&audioClient);
    if (FAILED(hr)) { std::cerr << "Khong kich hoat duoc IAudioClient\n"; return 1; }

    hr = audioClient->GetMixFormat(&mixFmt);
    if (FAILED(hr)) { std::cerr << "Khong lay duoc MixFormat\n"; return 1; }

    bool isFloat = false;
    if (mixFmt->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        isFloat = true;
    } else if (mixFmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        auto* ext = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(mixFmt);
        if (IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)) {
            isFloat = true;
        }
    }

    uint32_t inRate = mixFmt->nSamplesPerSec;
    uint16_t inChannels = mixFmt->nChannels;
    std::cout << "[WASAPI] Bat am thanh he thong: " << inRate << " Hz, "
              << inChannels << " kenh, " << (isFloat ? "Float32" : "PCM16") << "\n";

    REFERENCE_TIME hnsDuration = 200000;
    hr = audioClient->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
                                 hnsDuration, 0, mixFmt, nullptr);
    if (FAILED(hr)) { std::cerr << "Loi khoi tao WASAPI Loopback: 0x" << std::hex << hr << "\n"; return 1; }

    hr = audioClient->GetService(__uuidof(IAudioCaptureClient), (void**)&captureClient);
    if (FAILED(hr)) { std::cerr << "Khong lay duoc IAudioCaptureClient\n"; return 1; }

    DWORD taskIndex = 0;
    AvSetMmThreadCharacteristicsW(L"Pro Audio", &taskIndex);

    DualTransport transport(manualIP);

    hr = audioClient->Start();
    if (FAILED(hr)) { std::cerr << "Khong bat dau duoc WASAPI capture\n"; return 1; }

    std::vector<int16_t> outQueue;
    outQueue.reserve(PACKET_FRAMES * 8);

    double resampleStep = static_cast<double>(inRate) / static_cast<double>(OUT_SAMPLE_RATE);
    double resamplePos = 0.0;
    float prevL = 0.0f, prevR = 0.0f;

    uint32_t seq = 0;
    auto lastLog = std::chrono::steady_clock::now();

    while (true) {
        UINT32 packetLength = 0;
        hr = captureClient->GetNextPacketSize(&packetLength);
        if (FAILED(hr)) break;

        if (packetLength == 0) {
            Sleep(1);
        } else {
            while (packetLength > 0) {
                BYTE* data = nullptr;
                UINT32 framesAvailable = 0;
                DWORD flags = 0;

                hr = captureClient->GetBuffer(&data, &framesAvailable, &flags, nullptr, nullptr);
                if (FAILED(hr)) break;

                std::vector<float> stereoIn(framesAvailable * 2, 0.0f);
                if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT) && data != nullptr) {
                    if (isFloat) {
                        const float* f = reinterpret_cast<const float*>(data);
                        for (UINT32 i = 0; i < framesAvailable; ++i) {
                            float l = f[i * inChannels];
                            float r = (inChannels >= 2) ? f[i * inChannels + 1] : l;
                            stereoIn[i * 2] = l;
                            stereoIn[i * 2 + 1] = r;
                        }
                    } else {
                        const int16_t* p = reinterpret_cast<const int16_t*>(data);
                        for (UINT32 i = 0; i < framesAvailable; ++i) {
                            float l = p[i * inChannels] / 32768.0f;
                            float r = (inChannels >= 2) ? (p[i * inChannels + 1] / 32768.0f) : l;
                            stereoIn[i * 2] = l;
                            stereoIn[i * 2 + 1] = r;
                        }
                    }
                }

                captureClient->ReleaseBuffer(framesAvailable);

                if (inRate == OUT_SAMPLE_RATE) {
                    for (UINT32 i = 0; i < framesAvailable; ++i) {
                        outQueue.push_back(floatToInt16(stereoIn[i * 2]));
                        outQueue.push_back(floatToInt16(stereoIn[i * 2 + 1]));
                    }
                } else {
                    while (resamplePos < static_cast<double>(framesAvailable)) {
                        int idx = static_cast<int>(resamplePos);
                        float frac = static_cast<float>(resamplePos - idx);
                        float l0 = (idx == 0) ? prevL : stereoIn[(idx - 1) * 2];
                        float r0 = (idx == 0) ? prevR : stereoIn[(idx - 1) * 2 + 1];
                        float l1 = stereoIn[idx * 2];
                        float r1 = stereoIn[idx * 2 + 1];
                        outQueue.push_back(floatToInt16(l0 + (l1 - l0) * frac));
                        outQueue.push_back(floatToInt16(r0 + (r1 - r0) * frac));
                        resamplePos += resampleStep;
                    }
                    resamplePos -= static_cast<double>(framesAvailable);
                    if (framesAvailable > 0) {
                        prevL = stereoIn[(framesAvailable - 1) * 2];
                        prevR = stereoIn[(framesAvailable - 1) * 2 + 1];
                    }
                }

                size_t offset = 0;
                while (outQueue.size() - offset >= PACKET_FRAMES * 2) {
                    transport.sendAudioPacket(++seq, outQueue.data() + offset, PACKET_FRAMES);
                    offset += PACKET_FRAMES * 2;
                }
                if (offset > 0) {
                    outQueue.erase(outQueue.begin(), outQueue.begin() + offset);
                }

                hr = captureClient->GetNextPacketSize(&packetLength);
                if (FAILED(hr)) break;
            }
        }

        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::seconds>(now - lastLog).count() >= 2) {
            std::cout << "\rTrang thai: " << transport.statusText()
                      << " | Goi da gui: " << seq << "        " << std::flush;
            lastLog = now;
        }
    }

    audioClient->Stop();
    CoTaskMemFree(mixFmt);
    captureClient->Release();
    audioClient->Release();
    device->Release();
    enumerator->Release();
    CoUninitialize();
    timeEndPeriod(1);
    WSACleanup();
    return 0;
}
