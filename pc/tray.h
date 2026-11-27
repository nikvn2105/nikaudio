#pragma once

#include <dwmapi.h>
#include <commdlg.h>
#include <shellapi.h>
#include <functional>
#include <utility>

#include "glass_window.h"

class Tray {
public:
    using Status = std::function<std::wstring()>;
    using Pair = std::function<bool(const PairingKey&)>;
    using Forget = std::function<bool()>;

    Tray(Status status, Pair pair, Forget forget, FileTransfer::Server& files)
        : status_(std::move(status)), pair_(std::move(pair)), forget_(std::move(forget)), files_(files) {
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
    enum Menu { toggle = 100, pair, forget, pulse, stopPulse, console, quit, open, chooseFile };

    static LRESULT CALLBACK windowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
        if (message == WM_NCCREATE) {
            auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
            SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
        }
        auto* tray = reinterpret_cast<Tray*>(GetWindowLongPtrW(window, GWLP_USERDATA));
        if (!tray) return DefWindowProcW(window, message, wParam, lParam);
        switch (message) {
        case trayMessage:
            if (lParam == WM_LBUTTONUP) tray->showWindow(window);
            if (lParam == WM_RBUTTONUP) tray->showMenu(window);
            return 0;
        case WM_TIMER:
            tray->refresh(window);
            tray->iconVisible_ = tray->updateIcon(window, NIM_MODIFY) || tray->updateIcon(window, NIM_ADD);
            return 0;
        case WM_COMMAND:
            if (LOWORD(wParam) == IDCANCEL) {
                PostMessageW(window, WM_CLOSE, 0, 0);
                return 0;
            }
            if (HIWORD(wParam) == BN_CLICKED) tray->perform(window, LOWORD(wParam));
            return 0;
        case WM_DRAWITEM: {
            const auto* item = reinterpret_cast<const DRAWITEMSTRUCT*>(lParam);
            if (item && item->CtlType == ODT_BUTTON) {
                GlassWindow::button(*item, *tray->fonts_, tray->scale_, item->CtlID == toggle);
                return TRUE;
            }
            break;
        }
        case WM_DROPFILES: {
            const HDROP drop = reinterpret_cast<HDROP>(wParam);
            const auto count = DragQueryFileW(drop, 0xffffffffu, nullptr, 0);
            if (count == 1) {
                const auto length = DragQueryFileW(drop, 0, nullptr, 0);
                if (length > 0) {
                    std::wstring path(length + 1, L'\0');
                    if (DragQueryFileW(drop, 0, path.data(), static_cast<UINT>(path.size())) == length) {
                        path.resize(length);
                        tray->files_.offer(path);
                        tray->refresh(window);
                    }
                }
            }
            DragFinish(drop);
            return 0;
        }
        case WM_PAINT:
            GlassWindow::paint(window, *tray->fonts_, tray->scale_, tray->visibleStatus_, !tray->enabled,
                               tray->fileStatus_, tray->fileAddress_);
            return 0;
        case WM_ERASEBKGND:
            return TRUE;
        case WM_SETTINGCHANGE:
        case WM_SYSCOLORCHANGE:
            RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_ALLCHILDREN);
            break;
        case WM_CLOSE:
            if (!tray->closing_ && tray->iconVisible_) {
                ShowWindow(window, SW_HIDE);
                return 0;
            }
            DestroyWindow(window);
            return 0;
        }
        if (message == tray->taskbarCreated_) {
            tray->iconVisible_ = tray->updateIcon(window, NIM_ADD);
            if (!tray->iconVisible_) tray->showWindow(window);
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
        Gdiplus::GdiplusStartupInput input;
        ULONG_PTR graphicsToken = 0;
        if (Gdiplus::GdiplusStartup(&graphicsToken, &input, nullptr) != Gdiplus::Ok) return;
        {
            GlassWindow::Fonts fonts;
            fonts_ = &fonts;
            runWindow();
            fonts_ = nullptr;
        }
        Gdiplus::GdiplusShutdown(graphicsToken);
    }

    void runWindow() {
        taskbarCreated_ = RegisterWindowMessageW(L"TaskbarCreated");
        const HINSTANCE instance = GetModuleHandleW(nullptr);
        WNDCLASSW wc{};
        wc.lpfnWndProc = windowProc;
        wc.hInstance = instance;
        wc.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
        wc.hIcon = appIcon(instance);
        wc.lpszClassName = L"NiKAudioTrayWindow";
        if (!RegisterClassW(&wc)) return;

        if (HDC screen = GetDC(nullptr)) {
            scale_ = std::max(1.0f, GetDeviceCaps(screen, LOGPIXELSX) / 96.0f);
            ReleaseDC(nullptr, screen);
        }
        constexpr DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_CLIPCHILDREN;
        RECT frame{0, 0, scaled(GlassWindow::width), scaled(GlassWindow::height)};
        AdjustWindowRectEx(&frame, style, FALSE, WS_EX_CONTROLPARENT);
        HWND window = CreateWindowExW(WS_EX_CONTROLPARENT, wc.lpszClassName, L"NiKAudio", style,
                                      CW_USEDEFAULT, CW_USEDEFAULT, frame.right - frame.left, frame.bottom - frame.top,
                                      nullptr, nullptr, instance, this);
        if (!window) return;
        window_ = window;
        const BOOL darkCaption = TRUE;
        constexpr DWORD immersiveDarkMode = 20;
        DwmSetWindowAttribute(window, immersiveDarkMode, &darkCaption, sizeof(darkCaption));
        if (closing_) {
            DestroyWindow(window);
            return;
        }

        createButton(window, toggle, L"Tạm dừng gửi âm thanh", 46, 187, 468, 43);
        createButton(window, pair, L"Ghép đôi từ clipboard", 24, 269, 248, 44);
        createButton(window, pulse, L"Đo độ trễ", 288, 269, 248, 44);
        createButton(window, stopPulse, L"Dừng tín hiệu thử", 24, 325, 248, 44);
        createButton(window, quit, L"Thoát NiKAudio", 288, 325, 248, 44);
        createButton(window, chooseFile, L"Chọn tệp để gửi", 292, 460, 222, 40);
        const auto& address = files_.address();
        fileAddress_ = address.empty() ? L"Xem địa chỉ IPv4 trong cài đặt mạng Windows" : L"IP máy tính: " + address;
        DragAcceptFiles(window, TRUE);

        DWORD consoleProcesses[2]{};
        ownsConsole_ = GetConsoleProcessList(consoleProcesses, 2) == 1;
        if (ownsConsole_) {
            if (HWND consoleWindow = GetConsoleWindow()) ShowWindow(consoleWindow, SW_HIDE);
        }
        refresh(window);
        iconVisible_ = updateIcon(window, NIM_ADD);
        SetTimer(window, 1, 1000, nullptr);
        showWindow(window);
        MSG message{};
        while (GetMessageW(&message, nullptr, 0, 0) > 0) {
            if (!IsDialogMessageW(window, &message)) {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
    }

    int scaled(int points) const {
        return static_cast<int>(std::lround(points * scale_));
    }

    void createButton(HWND window, unsigned id, const wchar_t* caption, int x, int y, int w, int h) {
        CreateWindowExW(0, L"BUTTON", caption, WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                        scaled(x), scaled(y), scaled(w), scaled(h), window,
                        reinterpret_cast<HMENU>(static_cast<UINT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
    }

    void showWindow(HWND window) {
        ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
        SetForegroundWindow(window);
    }

    void refresh(HWND window) {
        const auto status = enabled ? status_() : std::wstring(L"Đã tạm dừng");
        if (visibleStatus_ != status) {
            visibleStatus_ = status;
            SetWindowTextW(window, (L"NiKAudio | " + status).c_str());
            InvalidateRect(window, nullptr, FALSE);
        }
        const auto files = files_.status();
        if (fileStatus_ != files) {
            fileStatus_ = files;
            InvalidateRect(window, nullptr, FALSE);
        }
    }

    static HICON appIcon(HINSTANCE instance) {
        if (const HICON icon = LoadIconW(instance, MAKEINTRESOURCEW(IDI_NIKAUDIO))) return icon;
        return LoadIconW(nullptr, MAKEINTRESOURCEW(32512));
    }

    bool updateIcon(HWND window, DWORD action) {
        NOTIFYICONDATAW icon{};
        icon.cbSize = sizeof(icon);
        icon.hWnd = window;
        icon.uID = 1;
        icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        icon.uCallbackMessage = trayMessage;
        icon.hIcon = appIcon(GetModuleHandleW(nullptr));
        const std::wstring tip = L"NiKAudio | " + visibleStatus_;
        wcsncpy_s(icon.szTip, _countof(icon.szTip), tip.c_str(), _TRUNCATE);
        return Shell_NotifyIconW(action, &icon) != FALSE;
    }

    void showMenu(HWND window) {
        HMENU menu = CreatePopupMenu();
        if (!menu) return;
        AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, visibleStatus_.c_str());
        AppendMenuW(menu, MF_STRING, open, L"Open NiKAudio");
        AppendMenuW(menu, MF_STRING, chooseFile, L"Choose a file to send");
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
        PostMessageW(window, WM_NULL, 0, 0);
        perform(window, choice);
    }

    void perform(HWND window, UINT choice) {
        switch (choice) {
        case open: showWindow(window); break;
        case chooseFile: chooseOutgoing(window); break;
        case toggle:
            enabled = !enabled;
            if (!enabled) PlaySoundW(nullptr, nullptr, 0);
            SetDlgItemTextW(window, toggle, enabled ? L"Tạm dừng gửi âm thanh" : L"Tiếp tục gửi âm thanh");
            EnableWindow(GetDlgItem(window, pulse), enabled);
            refresh(window);
            updateIcon(window, NIM_MODIFY);
            break;
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
    }

    void chooseOutgoing(HWND window) {
        std::vector<wchar_t> file(32768);
        OPENFILENAMEW dialog{};
        dialog.lStructSize = sizeof(dialog);
        dialog.hwndOwner = window;
        dialog.lpstrFile = file.data();
        dialog.nMaxFile = static_cast<DWORD>(file.size());
        dialog.lpstrTitle = L"Chọn tệp để gửi sang iPhone";
        dialog.Flags = OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST | OFN_FILEMUSTEXIST;
        if (GetOpenFileNameW(&dialog)) {
            files_.offer(file.data());
            refresh(window);
        }
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
    FileTransfer::Server& files_;
    UINT taskbarCreated_{0};
    bool ownsConsole_{false};
    bool iconVisible_{false};
    float scale_{1.0f};
    const GlassWindow::Fonts* fonts_{nullptr};
    std::wstring visibleStatus_;
    std::wstring fileStatus_, fileAddress_;
    std::atomic<HWND> window_{nullptr};
    std::atomic<bool> closing_{false};
    std::thread worker_;
};
