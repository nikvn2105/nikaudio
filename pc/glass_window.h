#pragma once

#include <gdiplus.h>
#include <iterator>

#include "font_resources.h"

namespace GlassWindow {
constexpr int width = 560;
constexpr int height = 540;

inline void roundedPath(Gdiplus::GraphicsPath& path, Gdiplus::RectF bounds, float radius) {
    const float diameter = radius * 2;
    path.AddArc(bounds.X, bounds.Y, diameter, diameter, 180, 90);
    path.AddArc(bounds.GetRight() - diameter, bounds.Y, diameter, diameter, 270, 90);
    path.AddArc(bounds.GetRight() - diameter, bounds.GetBottom() - diameter, diameter, diameter, 0, 90);
    path.AddArc(bounds.X, bounds.GetBottom() - diameter, diameter, diameter, 90, 90);
    path.CloseFigure();
}

inline void panel(Gdiplus::Graphics& graphics, Gdiplus::RectF bounds, float radius,
                  Gdiplus::Color fill, Gdiplus::Color border) {
    Gdiplus::GraphicsPath path;
    roundedPath(path, bounds, radius);
    Gdiplus::SolidBrush surface(fill);
    Gdiplus::Pen edge(border);
    graphics.FillPath(&surface, &path);
    graphics.DrawPath(&edge, &path);
}

inline void band(Gdiplus::Graphics& graphics, float x, float y, Gdiplus::Color tint) {
    const auto state = graphics.Save();
    graphics.TranslateTransform(x, y);
    graphics.RotateTransform(-24);
    Gdiplus::GraphicsPath path;
    path.AddEllipse(-360.0f, -118.0f, 720.0f, 236.0f);
    Gdiplus::PathGradientBrush glow(&path);
    glow.SetCenterColor(tint);
    Gdiplus::Color edge(0, tint.GetR(), tint.GetG(), tint.GetB());
    int count = 1;
    glow.SetSurroundColors(&edge, &count);
    graphics.FillPath(&glow, &path);
    graphics.Restore(state);
}

class Fonts {
public:
    Fonts() {
        if (!add(IDR_FONT_REGULAR) || !add(IDR_FONT_BOLD)) return;
        int found = 0;
        available_ = collection_.GetFamilies(1, &family_, &found) == Gdiplus::Ok && found == 1;
    }

    const Gdiplus::FontFamily* family() const {
        if (available_) return &family_;
        return Gdiplus::FontFamily::GenericSansSerif();
    }

private:
    bool add(unsigned id) {
        const HMODULE module = GetModuleHandleW(nullptr);
        const HRSRC resource = FindResourceW(module, MAKEINTRESOURCEW(id), MAKEINTRESOURCEW(10));
        if (!resource) return false;
        const HGLOBAL bytes = LoadResource(module, resource);
        const void* data = bytes ? LockResource(bytes) : nullptr;
        const DWORD size = SizeofResource(module, resource);
        return data && size &&
               collection_.AddMemoryFont(data, static_cast<int>(size)) == Gdiplus::Ok;
    }

    Gdiplus::PrivateFontCollection collection_;
    Gdiplus::FontFamily family_;
    bool available_{false};
};

inline void text(Gdiplus::Graphics& graphics, const Fonts& fonts, const std::wstring& value, Gdiplus::RectF bounds,
                 float size, Gdiplus::Color color, bool bold = false, bool centered = false) {
    Gdiplus::Font font(fonts.family(), size, bold ? Gdiplus::FontStyleBold : Gdiplus::FontStyleRegular,
                       Gdiplus::UnitPixel);
    Gdiplus::StringFormat format;
    format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
    format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
    format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    if (centered) format.SetAlignment(Gdiplus::StringAlignmentCenter);
    Gdiplus::SolidBrush brush(color);
    graphics.DrawString(value.c_str(), static_cast<int>(value.size()), &font, bounds, &format, &brush);
}

inline bool highContrast() {
    HIGHCONTRASTW contrast{};
    contrast.cbSize = sizeof(contrast);
    return SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0) &&
           (contrast.dwFlags & HCF_HIGHCONTRASTON);
}

inline Gdiplus::Color systemColor(int index) {
    const COLORREF color = GetSysColor(index);
    return Gdiplus::Color(GetRValue(color), GetGValue(color), GetBValue(color));
}

inline void backdrop(Gdiplus::Graphics& graphics, bool contrast) {
    using namespace Gdiplus;
    graphics.Clear(contrast ? systemColor(COLOR_WINDOW) : Color(4, 5, 8));
    if (!contrast) {
        band(graphics, 104, 100, Color(67, 112, 218, 197));
        band(graphics, 450, 334, Color(72, 157, 129, 232));
        panel(graphics, RectF(24, 91, 512, 152), 22, Color(34, 210, 229, 254), Color(53, 222, 235, 252));
        panel(graphics, RectF(24, 391, 512, 123), 22, Color(34, 210, 229, 254), Color(53, 222, 235, 252));
    }
}

inline void paint(HWND window, const Fonts& fonts, float scale, const std::wstring& status, bool paused,
                  const std::wstring& fileStatus, const std::wstring& addresses) {
    PAINTSTRUCT paint{};
    HDC target = BeginPaint(window, &paint);
    RECT bounds{};
    GetClientRect(window, &bounds);
    if (bounds.right <= 0 || bounds.bottom <= 0) {
        EndPaint(window, &paint);
        return;
    }

    HDC buffer = CreateCompatibleDC(target);
    HBITMAP bitmap = CreateCompatibleBitmap(target, bounds.right, bounds.bottom);
    HGDIOBJ previous = buffer && bitmap ? SelectObject(buffer, bitmap) : nullptr;
    const bool buffered = previous && previous != HGDI_ERROR;
    {
        using namespace Gdiplus;
        Graphics graphics(buffered ? buffer : target);
        graphics.SetSmoothingMode(SmoothingModeAntiAlias);
        graphics.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
        graphics.ScaleTransform(scale, scale);
        const bool contrast = highContrast();
        const Color foreground = contrast ? systemColor(COLOR_WINDOWTEXT) : Color(245, 248, 251);
        const Color secondary = contrast ? foreground : Color(182, 191, 206);
        const Color mint(172, 240, 224);

        backdrop(graphics, contrast);

        text(graphics, fonts, L"NiKAudio", RectF(27, 21, 500, 49), 35, foreground, true);
        SolidBrush dot(paused || contrast ? secondary : mint);
        graphics.FillEllipse(&dot, 46.0f, 124.0f, 8.0f, 8.0f);
        text(graphics, fonts, L"Âm thanh từ PC", RectF(64, 116, 440, 25), 15, secondary);
        text(graphics, fonts, status, RectF(46, 144, 466, 35), 25, foreground, true);
        text(graphics, fonts, L"Truyền tệp LAN", RectF(46, 404, 445, 26), 17, foreground, true);
        text(graphics, fonts, addresses, RectF(46, 430, 465, 24), 14, secondary);
        text(graphics, fonts, fileStatus, RectF(46, 465, 236, 31), 13, foreground);
    }
    if (buffered) {
        BitBlt(target, 0, 0, bounds.right, bounds.bottom, buffer, 0, 0, SRCCOPY);
        SelectObject(buffer, previous);
    }
    if (bitmap) DeleteObject(bitmap);
    if (buffer) DeleteDC(buffer);
    EndPaint(window, &paint);
}

inline void button(const DRAWITEMSTRUCT& item, const Fonts& fonts, float scale, bool primary) {
    using namespace Gdiplus;
    const bool contrast = highContrast();
    const bool disabled = (item.itemState & ODS_DISABLED) != 0;
    const bool pressed = (item.itemState & ODS_SELECTED) != 0;
    const bool focused = (item.itemState & ODS_FOCUS) != 0;
    wchar_t caption[96]{};
    GetWindowTextW(item.hwndItem, caption, static_cast<int>(std::size(caption)));

    Graphics graphics(item.hDC);
    graphics.SetSmoothingMode(SmoothingModeAntiAlias);
    graphics.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
    graphics.ScaleTransform(scale, scale);
    const float w = static_cast<float>(item.rcItem.right - item.rcItem.left) / scale;
    const float h = static_cast<float>(item.rcItem.bottom - item.rcItem.top) / scale;
    POINT origin{};
    MapWindowPoints(item.hwndItem, GetParent(item.hwndItem), &origin, 1);
    const auto state = graphics.Save();
    graphics.TranslateTransform(-origin.x / scale, -origin.y / scale);
    backdrop(graphics, contrast);
    graphics.Restore(state);
    Color fill = contrast ? systemColor(pressed ? COLOR_HIGHLIGHT : COLOR_BTNFACE)
                 : primary ? (pressed ? Color(134, 209, 196) : Color(172, 240, 224))
                           : (pressed ? Color(43, 46, 64) : Color(24, 26, 38));
    const Color ink = contrast ? systemColor(disabled ? COLOR_GRAYTEXT : pressed ? COLOR_HIGHLIGHTTEXT : COLOR_BTNTEXT)
                               : primary ? Color(5, 19, 21)
                                         : disabled ? Color(123, 129, 143) : Color(234, 239, 247);
    const Color border = contrast ? systemColor(COLOR_WINDOWTEXT)
                       : focused ? Color(202, 183, 255) : Color(104, 108, 131);
    panel(graphics, RectF(1, 1, w - 2, h - 2), 12, fill, border);
    if (focused) {
        GraphicsPath focus;
        roundedPath(focus, RectF(4, 4, w - 8, h - 8), 9);
        Pen pen(contrast ? systemColor(COLOR_WINDOWTEXT) : primary ? Color(27, 85, 76) : Color(202, 183, 255));
        pen.SetDashStyle(DashStyleDot);
        graphics.DrawPath(&pen, &focus);
    }
    text(graphics, fonts, caption, RectF(8, 0, w - 16, h), primary ? 16.0f : 14.0f, ink, primary, true);
}
}
