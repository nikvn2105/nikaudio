#pragma once

#include <condition_variable>
#include <shellapi.h>
#include <deque>

namespace ScreenReceiver {
constexpr uint16_t videoPort = 55125;
constexpr uint16_t previewPort = 55126;

inline constexpr char previewPage[] = R"HTML(<!doctype html>
<html lang="vi"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>NiKAudio · Màn hình</title>
<style>
body{margin:0;background:#080a10;color:#eee;font:16px system-ui;display:grid;place-items:center;min-height:100vh}
main{display:grid;place-items:center;gap:12px} h1{margin:12px 0 0} p{margin:0;color:#a8ecdc}
canvas{max-width:95vw;max-height:82vh;width:auto;height:auto;background:#111827;border-radius:12px} button{padding:10px 18px}
</style><main><h1>NiKAudio · Màn hình</h1><p id="status" role="status">Đang chờ iPhone phát màn hình…</p>
<canvas id="view" width="1" height="1" aria-label="Màn hình iPhone"></canvas>
<button id="toggle">Dừng xem</button></main>
<script>
const canvas=document.getElementById('view'), status=document.getElementById('status'), button=document.getElementById('toggle');
const context=canvas.getContext('2d', {alpha:false});
let stop=null, decoder=null, previous=null, serial=0, waiting=true;
function reset() {
  if(decoder && decoder.state!=='closed') decoder.close();
  decoder=null; previous=null; waiting=true;
}
function codec(frame) {
  for(let i=0;i+7<frame.length;i++) {
    if(frame[i]===0 && frame[i+1]===0 && frame[i+2]===0 && frame[i+3]===1 && (frame[i+4]&31)===7)
      return 'avc1.'+Array.from(frame.subarray(i+5,i+8),v=>v.toString(16).padStart(2,'0')).join('');
  }
  return null;
}
function consume(record) {
  if(record.length<6) return;
  const key=record[0]===9;
  const seq=new DataView(record.buffer,record.byteOffset).getUint32(1,true);
  if(previous!==null && seq!==((previous+1)>>>0)) reset();
  previous=seq;
  if(waiting && !key) return;
  const data=record.subarray(5);
  if(key && (!decoder || decoder.state==='closed')) {
    const format=codec(data); if(!format) return;
    decoder=new VideoDecoder({output(frame) {
      if(canvas.width!==frame.displayWidth || canvas.height!==frame.displayHeight) {
        canvas.width=frame.displayWidth; canvas.height=frame.displayHeight;
      }
      context.drawImage(frame,0,0); frame.close();
      status.textContent='Đang chiếu màn hình iPhone';
    }, error() { reset(); status.textContent='Đang chờ khung hình mới…'; }});
    decoder.configure({codec:format,optimizeForLatency:true});
    waiting=false;
  }
  if(!decoder || decoder.state!=='configured') return;
  if(decoder.decodeQueueSize>5) { reset(); return; }
  try { decoder.decode(new EncodedVideoChunk({type:key?'key':'delta',timestamp:serial++*33333,data})); }
  catch { reset(); }
}
async function play() {
  if(!window.VideoDecoder) {
    status.textContent='Mở địa chỉ này bằng Microsoft Edge hoặc Google Chrome có hỗ trợ H.264.';
    button.hidden=true; return;
  }
  const run=new AbortController(); stop=run;
  button.textContent='Dừng xem';
  while(!run.signal.aborted) {
    try {
      const response=await fetch('stream',{signal:run.signal,cache:'no-store'});
      if(!response.ok) throw Error('stream unavailable');
      const reader=response.body.getReader();
      let pending=new Uint8Array(0);
      while(!run.signal.aborted) {
        const {done,value}=await reader.read(); if(done) break;
        const part=new Uint8Array(pending.length+value.length);
        part.set(pending);part.set(value,pending.length);
        let offset=0;
        while(part.length-offset>=4) {
          const size=new DataView(part.buffer,offset,4).getUint32(0,true);
          if(size<=0 || size>262145) throw Error('Invalid record');
          if(part.length-offset<4+size) break;
          const record=part.subarray(offset+4,offset+4+size);
          if(record.length===1 && record[0]===0) { reset();status.textContent='Đang chờ iPhone phát màn hình…'; }
          else consume(record);
          offset+=4+size;
        }
        pending=part.slice(offset);
      }
    } catch {}
    reset();
    if(!run.signal.aborted) {
      status.textContent='Đang chờ kết nối lại…';
      await new Promise(resolve=>setTimeout(resolve,750));
    }
  }
}
button.onclick=()=> {
  if(stop && !stop.signal.aborted) {
    stop.abort();reset();status.textContent='Đã dừng xem';button.textContent='Xem lại';
  } else play();
};
play();
</script></html>)HTML";

class Server {
public:
    Server() {
        LanNonce random{};
        if (BCryptGenRandom(nullptr, random.data(), static_cast<ULONG>(random.size()),
                            BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0) {
            constexpr char digits[] = "0123456789abcdef";
            for (auto byte : random) {
                token_ += digits[byte >> 4];
                token_ += digits[byte & 15];
            }
            captureThread_ = std::thread(&Server::listen, this, videoPort, false);
            previewThread_ = std::thread(&Server::listen, this, previewPort, true);
        }
    }

    ~Server() {
        running_ = false;
        wake_.notify_all();
        {
            std::lock_guard<std::mutex> lock(socketLock_);
            if (capture_ != INVALID_SOCKET) shutdown(capture_, SD_BOTH);
            if (preview_ != INVALID_SOCKET) shutdown(preview_, SD_BOTH);
        }
        if (captureThread_.joinable()) captureThread_.join();
        if (previewThread_.joinable()) previewThread_.join();
    }

    bool open(HWND owner) const {
        if (token_.empty()) return false;
        const std::wstring url = L"http://127.0.0.1:55126/" + std::wstring(token_.begin(), token_.end()) + L"/";
        return reinterpret_cast<INT_PTR>(ShellExecuteW(owner, L"open", url.c_str(), nullptr, nullptr, SW_SHOWNORMAL)) > 32;
    }

private:
    void listen(uint16_t port, bool loopback) {
        const SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (listener == INVALID_SOCKET) return;
        const BOOL exclusive = TRUE;
        setsockopt(listener, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char*>(&exclusive), sizeof(exclusive));
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(loopback ? INADDR_LOOPBACK : INADDR_ANY);
        address.sin_port = htons(port);
        if (bind(listener, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0 ||
            ::listen(listener, 4) != 0) {
            closesocket(listener);
            return;
        }
        if (!loopback) publishBonjour(port, L"_nikscreen._tcp");
        while (running_) {
            fd_set readable;
            FD_ZERO(&readable);
            FD_SET(listener, &readable);
            timeval deadline{0, 200000};
            if (select(0, &readable, nullptr, nullptr, &deadline) != 1) continue;
            SOCKET socket = accept(listener, nullptr, nullptr);
            if (socket == INVALID_SOCKET) continue;
            auto& active = loopback ? preview_ : capture_;
            {
                std::lock_guard<std::mutex> lock(socketLock_);
                active = socket;
                if (!running_) shutdown(socket, SD_BOTH);
            }
            DWORD timeout = loopback ? 2000 : 7000;
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
            setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
            if (running_) {
                if (loopback) serveBrowser(socket);
                else receiveVideo(socket);
            }
            {
                std::lock_guard<std::mutex> lock(socketLock_);
                closesocket(socket);
                active = INVALID_SOCKET;
            }
        }
        closesocket(listener);
    }

    void receiveVideo(SOCKET socket) {
        PairingKey key{}, screenKey{};
        if (!loadPairingKey(key)) return;
        constexpr char label[] = "NiKAudio screen v1";
        LanAuthenticator auth;
        const bool derived = auth.sign(key, label, sizeof(label) - 1, screenKey);
        SecureZeroMemory(key.data(), key.size());
        if (!derived) return;
        bool streaming = false;
        try {
            FileTransfer::Channel channel(socket, screenKey, "NIKS");
            SecureZeroMemory(screenKey.data(), screenKey.size());
            while (running_) {
                auto frame = channel.receive();
                if (frame.size() < 6 || (frame[0] != 9 && frame[0] != 10)) break;
                channel.authenticated();
                if (!streaming && frame[0] != 9) continue;
                streaming = true;
                std::lock_guard<std::mutex> lock(frameLock_);
                if (frame[0] == 9 || frames_.empty()) frames_.clear();
                frames_.push_back(std::move(frame));
                if (frames_.size() > 36) frames_.pop_front();
                ++frameID_;
                wake_.notify_all();
            }
        } catch (...) {}
        SecureZeroMemory(screenKey.data(), screenKey.size());
        if (streaming) {
            std::lock_guard<std::mutex> lock(frameLock_);
            frames_.clear();
            ++frameID_;
            wake_.notify_all();
        }
    }

    bool frameToBrowser(SOCKET socket, const FileTransfer::Bytes& value) {
        const uint32_t size = static_cast<uint32_t>(value.size());
        return sendAll(socket, reinterpret_cast<const char*>(&size), sizeof(size)) &&
               sendAll(socket, reinterpret_cast<const char*>(value.data()), size);
    }

    void serveBrowser(SOCKET socket) {
        std::string request;
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
        while (request.size() < 4096 && request.find("\r\n\r\n") == std::string::npos &&
               std::chrono::steady_clock::now() < deadline) {
            char bytes[512]{};
            const int count = recv(socket, bytes, sizeof(bytes), 0);
            if (count <= 0) return;
            request.append(bytes, static_cast<size_t>(count));
        }
        if (request.find("\r\nHost: 127.0.0.1:55126\r\n") == std::string::npos) return;
        const std::string root = "GET /" + token_ + "/";
        const bool isPage = request.rfind(root + " HTTP/1.", 0) == 0;
        const bool isStream = request.rfind(root + "stream HTTP/1.", 0) == 0;
        if (!isPage && !isStream) return;
        const std::string headers = std::string("HTTP/1.1 200 OK\r\nConnection: close\r\nCache-Control: no-store\r\n"
            "Referrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Type: ") +
            (isPage ? "text/html; charset=utf-8" : "application/octet-stream") + "\r\n\r\n";
        if (!sendAll(socket, headers.data(), static_cast<int>(headers.size()))) return;
        if (isPage) {
            sendAll(socket, previewPage, sizeof(previewPage) - 1);
            return;
        }

        uint64_t delivered = 0;
        while (running_) {
            std::deque<FileTransfer::Bytes> ready;
            {
                std::unique_lock<std::mutex> lock(frameLock_);
                wake_.wait_for(lock, std::chrono::seconds(1), [&] { return !running_ || frameID_ != delivered; });
                if (!running_) return;
                if (!frames_.empty() && frameID_ != delivered) {
                    const auto unseen = static_cast<size_t>(std::min<uint64_t>(frames_.size(), frameID_ - delivered));
                    ready.assign(frames_.end() - unseen, frames_.end());
                }
                delivered = frameID_;
            }
            if (ready.empty()) {
                if (!frameToBrowser(socket, {0})) break;
            } else {
                for (const auto& frame : ready) if (!frameToBrowser(socket, frame)) return;
            }
        }
    }

    std::string token_;
    std::atomic<bool> running_{true};
    std::mutex socketLock_, frameLock_;
    std::condition_variable wake_;
    SOCKET capture_{INVALID_SOCKET}, preview_{INVALID_SOCKET};
    std::deque<FileTransfer::Bytes> frames_;
    uint64_t frameID_ = 0;
    std::thread captureThread_, previewThread_;
};
}
