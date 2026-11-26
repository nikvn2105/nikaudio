#pragma once

#include <shellapi.h>
#include <functional>
#include <utility>

class Tray {
public:
    using Status = std::function<std::string()>;
    using Pair = std::function<bool(const PairingKey&)>;
    using Forget = std::function<bool()>;

    Tray(Status status, Pair pair, Forget forget)
        : status_(std::move(status)), pair_(std::move(pair)), forget_(std::move(forget)) {
        worker_ = std::thread(&Tray::run, this);
    }

    ~Tray() {
        closing_ = true;
        if (const HWND window = window_.load()) PostMessageW(window, WM_CLOSE, 0, 0);
        if (worker_.joinable()) worker_.join();
    }

    std::atomic<bool> enabled{true};
    std::atomic<bool> quitting{false};

private:
    static constexpr UINT trayMessage = WM_APP + 1;
    enum Menu { toggle = 1, pair, forget, pulse, stopPulse, console, quit };

    static LRESULT CALLBACK windowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
        if (message == WM_NCCREATE) {
            auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
            SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
        }
        auto* tray = reinterpret_cast<Tray*>(GetWindowLongPtrW(window, GWLP_USERDATA));
        if (!tray) return DefWindowProcW(window, message, wParam, lParam);
        if (message == trayMessage && (lParam == WM_RBUTTONUP || lParam == WM_LBUTTONUP)) {
            tray->showMenu(window);
            return 0;
        }
        if (message == WM_TIMER) {
            if (!tray->updateIcon(window, NIM_MODIFY)) tray->updateIcon(window, NIM_ADD);
            return 0;
        }
        if (message == tray->taskbarCreated_) {
            tray->updateIcon(window, NIM_ADD);
            return 0;
        }
        if (message == WM_DESTROY) {
            tray->updateIcon(window, NIM_DELETE);
            PlaySoundW(nullptr, nullptr, 0);
            tray->window_ = nullptr;
            tray->quitting = true;
            PostQuitMessage(0);
            return 0;
        }
        return DefWindowProcW(window, message, wParam, lParam);
    }

    void run() {
        taskbarCreated_ = RegisterWindowMessageW(L"TaskbarCreated");
        const HINSTANCE instance = GetModuleHandleW(nullptr);
        WNDCLASSW wc{};
        wc.lpfnWndProc = windowProc;
        wc.hInstance = instance;
        wc.lpszClassName = L"NiKAudioTrayWindow";
        if (!RegisterClassW(&wc)) return;
        HWND window = CreateWindowExW(0, wc.lpszClassName, L"NiKAudio", WS_OVERLAPPED,
                                      0, 0, 0, 0, nullptr, nullptr, instance, this);
        if (!window) return;
        window_ = window;
        if (closing_) {
            DestroyWindow(window);
            return;
        }
        DWORD consoleProcesses[2]{};
        ownsConsole_ = GetConsoleProcessList(consoleProcesses, 2) == 1;
        if (updateIcon(window, NIM_ADD) && ownsConsole_) {
            if (HWND consoleWindow = GetConsoleWindow()) ShowWindow(consoleWindow, SW_HIDE);
        }
        SetTimer(window, 1, 1000, nullptr);
        MSG message{};
        while (GetMessageW(&message, nullptr, 0, 0) > 0) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }

    bool updateIcon(HWND window, DWORD action) {
        NOTIFYICONDATAW icon{};
        icon.cbSize = sizeof(icon);
        icon.hWnd = window;
        icon.uID = 1;
        icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        icon.uCallbackMessage = trayMessage;
        icon.hIcon = LoadIconW(nullptr, MAKEINTRESOURCEW(32512));
        const std::string text = enabled ? status_() : "Da tam dung";
        const std::wstring tip = L"NiKAudio | " + std::wstring(text.begin(), text.end());
        wcsncpy_s(icon.szTip, _countof(icon.szTip), tip.c_str(), _TRUNCATE);
        return Shell_NotifyIconW(action, &icon) != FALSE;
    }

    void showMenu(HWND window) {
        HMENU menu = CreatePopupMenu();
        if (!menu) return;
        const std::string text = status_();
        const std::wstring status(text.begin(), text.end());
        AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, status.c_str());
        AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(menu, MF_STRING, toggle, enabled ? L"Pause streaming" : L"Resume streaming");
        AppendMenuW(menu, MF_STRING, pair, L"Pair using key from clipboard");
        AppendMenuW(menu, MF_STRING, forget, L"Forget paired iPhone");
        AppendMenuW(menu, enabled ? MF_STRING : MF_STRING | MF_GRAYED, pulse, L"Play latency test pulses");
        AppendMenuW(menu, MF_STRING, stopPulse, L"Stop latency test");
        if (ownsConsole_) AppendMenuW(menu, MF_STRING, console, L"Show or hide console");
        AppendMenuW(menu, MF_STRING, quit, L"Quit NiKAudio");
        POINT point{};
        GetCursorPos(&point);
        SetForegroundWindow(window);
        const UINT choice = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
                                           point.x, point.y, 0, window, nullptr);
        DestroyMenu(menu);
        switch (choice) {
        case toggle: enabled = !enabled; break;
        case pair: importKey(window); break;
        case forget:
            if (MessageBoxW(window, L"Forget the saved LAN pairing key?", L"NiKAudio",
                            MB_YESNO | MB_ICONQUESTION) == IDYES && !forget_()) {
                MessageBoxW(window, L"The saved pairing key could not be removed.", L"NiKAudio",
                            MB_OK | MB_ICONWARNING);
            }
            break;
        case pulse:
            if (!playLatencyPulses()) {
                MessageBoxW(window, L"Could not play the test pulses.", L"NiKAudio", MB_OK | MB_ICONWARNING);
            }
            break;
        case stopPulse: PlaySoundW(nullptr, nullptr, 0); break;
        case console:
            if (HWND consoleWindow = GetConsoleWindow()) {
                ShowWindow(consoleWindow, IsWindowVisible(consoleWindow) ? SW_HIDE : SW_SHOW);
            }
            break;
        case quit: DestroyWindow(window); break;
        }
        PostMessageW(window, WM_NULL, 0, 0);
    }

    void importKey(HWND window) {
        PairingKey key{};
        bool parsed = false;
        if (OpenClipboard(window)) {
            if (HANDLE data = GetClipboardData(CF_UNICODETEXT)) {
                if (const auto* text = static_cast<const wchar_t*>(GlobalLock(data))) {
                    const size_t capacity = GlobalSize(data) / sizeof(wchar_t);
                    const size_t length = wcsnlen(text, capacity);
                    if (length < capacity && length <= 128) {
                        std::wstring clipboardKey(text, length);
                        parsed = parsePairingKey(clipboardKey, key);
                        SecureZeroMemory(clipboardKey.data(), clipboardKey.size() * sizeof(wchar_t));
                    }
                    GlobalUnlock(data);
                }
            }
            CloseClipboard();
        }
        if (!parsed || !pair_(key)) {
            MessageBoxW(window, L"Copy the pairing key from NiKAudio on iPhone and try again.",
                        L"NiKAudio", MB_OK | MB_ICONWARNING);
        }
        SecureZeroMemory(key.data(), key.size());
    }

    Status status_;
    Pair pair_;
    Forget forget_;
    UINT taskbarCreated_{0};
    bool ownsConsole_{false};
    std::atomic<HWND> window_{nullptr};
    std::atomic<bool> closing_{false};
    std::thread worker_;
};
