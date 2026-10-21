// runtime/ui/switch_horizon.h: the start screen's look, after the Switch home menu - a row of game tiles under a bar
// of round icons, the selected game's name under the row, button hints along the bottom; and the settings pages
// (sidebar + content, as the Switch's System Settings). Drawing and input only: what the tiles, icons and hints are,
// and what pressing them does, is launcher.mm's - nothing here is shown that isn't backed by real state there.
#pragma once

#include <string>
#include <vector>
#include <time.h>
#include <math.h>
#include <stdio.h>
#include "imgui.h"

// the palette (the home menu's dark theme)
#define HZ_TEXT      IM_COL32(255, 255, 255, 255)
#define HZ_TEXT_DIM  IM_COL32(190, 194, 200, 255)
#define HZ_LINE      IM_COL32(255, 255, 255, 60)
#define HZ_PANEL     IM_COL32(28, 30, 36, 236)
#define HZ_BAR       IM_COL32(12, 14, 18, 150)
#define HZ_ACCENT    IM_COL32(0, 200, 230, 255)
#define HZ_ICON_BG   IM_COL32(52, 56, 64, 225)

enum HzGlyph { HZ_GLYPH_GEAR, HZ_GLYPH_POWER, HZ_GLYPH_DOWNLOAD, HZ_GLYPH_CONTROLLER, HZ_GLYPH_TOUCH };

struct HzTile {
    std::string title;
    std::string badge;     // "" = none (a pill in the tile's lower left: "Set up", "Not supported yet", ...)
    ImTextureID art = 0;   // 0: a gradient with the title on it
    ImVec2 uv0{0, 0}, uv1{1, 1};
    ImU32 col1 = 0, col2 = 0;
    float progress = -1;   // 0..1: a bar along the tile's bottom (setting up)
    bool dim = false;
};

struct HzIcon {
    HzGlyph glyph;
    const char *label;  // shown under it while it's selected
    bool dot;           // the small "something new" dot
};

struct HzHint {
    char button;        // 'A', 'B', '+' ...
    const char *label;
};

struct HzHomeResult {
    int start_tile = -1;   // A / a tap on the selected tile
    int icon = -1;         // an icon pressed
    int hint = -1;         // a bottom hint pressed (index into hints)
};

// focus: 0 = the tiles, 1 = the icons (controllers move between them with up / down)
struct HzHomeState {
    int sel = 0, icon_sel = 0, focus = 0;
    float scroll = 0;
};

static inline void hz_text(ImDrawList *dl, ImFont *f, float size, ImVec2 p, ImU32 col, const char *t,
                           const char *end = NULL, float wrap = 0) {
    dl->AddText(f, size, ImVec2(p.x + 1, p.y + 1), IM_COL32(0, 0, 0, 110), t, end, wrap);  // (readable on any wallpaper)
    dl->AddText(f, size, p, col, t, end, wrap);
}

// a round button glyph as the Switch draws them: a white disc, the button's mark cut out of it
static inline void hz_button_glyph(ImDrawList *dl, ImFont *f, ImVec2 c, float r, char b) {
    dl->AddCircleFilled(c, r, IM_COL32(255, 255, 255, 255), 24);
    ImU32 ink = IM_COL32(30, 32, 38, 255);
    if (b == '+' || b == '-') {
        float t = r * 0.18f, l = r * 0.5f;
        dl->AddRectFilled(ImVec2(c.x - l, c.y - t * 0.5f), ImVec2(c.x + l, c.y + t * 0.5f), ink);
        if (b == '+') dl->AddRectFilled(ImVec2(c.x - t * 0.5f, c.y - l), ImVec2(c.x + t * 0.5f, c.y + l), ink);
        return;
    }
    char s[2] = {b, 0};
    float size = r * 1.45f;
    ImVec2 sz = f->CalcTextSizeA(size, FLT_MAX, 0, s);
    dl->AddText(f, size, ImVec2(c.x - sz.x * 0.5f, c.y - sz.y * 0.52f), ink, s);
}

static inline void hz_glyph(ImDrawList *dl, HzGlyph g, ImVec2 c, float r, ImU32 col) {
    float t = r * 0.13f;
    switch (g) {
    case HZ_GLYPH_GEAR: {
        for (int i = 0; i < 8; i++) {  // teeth
            float a = i * 3.14159265f / 4;
            ImVec2 d(cosf(a), sinf(a)), n(-d.y, d.x);
            ImVec2 p0(c.x + d.x * r * 0.62f, c.y + d.y * r * 0.62f), p1(c.x + d.x * r * 0.92f, c.y + d.y * r * 0.92f);
            float w = r * 0.16f;
            dl->AddQuadFilled(ImVec2(p0.x - n.x * w, p0.y - n.y * w), ImVec2(p1.x - n.x * w, p1.y - n.y * w),
                              ImVec2(p1.x + n.x * w, p1.y + n.y * w), ImVec2(p0.x + n.x * w, p0.y + n.y * w), col);
        }
        dl->AddCircle(c, r * 0.55f, col, 24, r * 0.2f);
        break;
    }
    case HZ_GLYPH_POWER:
        dl->PathArcTo(c, r * 0.7f, -3.14159265f * 0.5f + 0.75f, -3.14159265f * 0.5f + 2 * 3.14159265f - 0.75f, 24);
        dl->PathStroke(col, 0, t * 1.4f);
        dl->AddLine(ImVec2(c.x, c.y - r * 0.85f), ImVec2(c.x, c.y - r * 0.05f), col, t * 1.4f);
        break;
    case HZ_GLYPH_DOWNLOAD:
        dl->AddLine(ImVec2(c.x, c.y - r * 0.8f), ImVec2(c.x, c.y + r * 0.25f), col, t * 1.4f);
        dl->AddLine(ImVec2(c.x - r * 0.45f, c.y - r * 0.15f), ImVec2(c.x, c.y + r * 0.3f), col, t * 1.4f);
        dl->AddLine(ImVec2(c.x + r * 0.45f, c.y - r * 0.15f), ImVec2(c.x, c.y + r * 0.3f), col, t * 1.4f);
        dl->AddLine(ImVec2(c.x - r * 0.7f, c.y + r * 0.7f), ImVec2(c.x + r * 0.7f, c.y + r * 0.7f), col, t * 1.4f);
        break;
    case HZ_GLYPH_CONTROLLER: {
        ImVec2 a(c.x - r, c.y - r * 0.5f), b(c.x + r, c.y + r * 0.5f);
        dl->AddRect(a, b, col, r * 0.45f, 0, t);
        dl->AddLine(ImVec2(c.x - r * 0.6f, c.y), ImVec2(c.x - r * 0.25f, c.y), col, t);
        dl->AddLine(ImVec2(c.x - r * 0.425f, c.y - r * 0.18f), ImVec2(c.x - r * 0.425f, c.y + r * 0.18f), col, t);
        dl->AddCircleFilled(ImVec2(c.x + r * 0.35f, c.y - r * 0.08f), r * 0.1f, col);
        dl->AddCircleFilled(ImVec2(c.x + r * 0.58f, c.y + r * 0.1f), r * 0.1f, col);
        break;
    }
    case HZ_GLYPH_TOUCH: {  // a phone held sideways
        ImVec2 a(c.x - r, c.y - r * 0.55f), b(c.x + r, c.y + r * 0.55f);
        dl->AddRect(a, b, col, r * 0.15f, 0, t);
        dl->AddRect(ImVec2(a.x + r * 0.28f, a.y + r * 0.15f), ImVec2(b.x - r * 0.28f, b.y - r * 0.15f), col, 0, 0, t * 0.7f);
        break;
    }
    }
}

// the clock and the battery (upper right); percent < 0: no battery to show
static inline void hz_status(ImDrawList *dl, ImFont *f, ImVec2 ds, float s, int battery_pct, bool charging) {
    float y = 58 * s, right = ds.x - 60 * s, size = 30 * s;
    float x = right;
    if (battery_pct >= 0) {
        char pct[8];
        snprintf(pct, sizeof pct, "%d%%", battery_pct);
        float bw = 34 * s, bh = 17 * s;
        ImVec2 b0(x - bw - 4 * s, y - bh * 0.5f), b1(x - 4 * s, y + bh * 0.5f);
        dl->AddRect(b0, b1, HZ_TEXT, 3 * s, 0, 2 * s);
        dl->AddRectFilled(ImVec2(b1.x, y - 4 * s), ImVec2(b1.x + 3 * s, y + 4 * s), HZ_TEXT, 1 * s);
        float fill = (bw - 6 * s) * (battery_pct > 100 ? 1.0f : battery_pct / 100.0f);
        ImU32 fc = battery_pct <= 15 && !charging ? IM_COL32(240, 70, 60, 255) : HZ_TEXT;
        dl->AddRectFilled(ImVec2(b0.x + 3 * s, b0.y + 3 * s), ImVec2(b0.x + 3 * s + fill, b1.y - 3 * s), fc, 1.5f * s);
        if (charging) {  // a bolt across it
            ImVec2 m((b0.x + b1.x) * 0.5f, y);
            dl->AddTriangleFilled(ImVec2(m.x + 2 * s, m.y - 8 * s), ImVec2(m.x - 5 * s, m.y + 1 * s), ImVec2(m.x + 1 * s, m.y + 1 * s),
                                  IM_COL32(40, 200, 90, 255));
            dl->AddTriangleFilled(ImVec2(m.x - 2 * s, m.y + 8 * s), ImVec2(m.x + 5 * s, m.y - 1 * s), ImVec2(m.x - 1 * s, m.y - 1 * s),
                                  IM_COL32(40, 200, 90, 255));
        }
        ImVec2 tsz = f->CalcTextSizeA(size, FLT_MAX, 0, pct);
        x = b0.x - 10 * s - tsz.x;
        hz_text(dl, f, size, ImVec2(x, y - tsz.y * 0.5f), HZ_TEXT, pct);
        x -= 28 * s;
    }
    char clock[16] = "";
    time_t now = time(NULL);
    struct tm *lt = localtime(&now);
    if (lt) strftime(clock, sizeof clock, "%H:%M", lt);
    ImVec2 tsz = f->CalcTextSizeA(size, FLT_MAX, 0, clock);
    hz_text(dl, f, size, ImVec2(x - tsz.x, y - tsz.y * 0.5f), HZ_TEXT, clock);
}

// The bottom bar: a line across, an input glyph on the left (controller / touch), the hints on the right. Returns
// the hint tapped / clicked, or -1.
static inline int hz_bottom_bar(ImDrawList *dl, ImFont *f, ImVec2 ds, float s, bool controller, const HzHint *hints,
                                int n) {
    float top = ds.y - 72 * s, y = ds.y - 36 * s;
    dl->AddRectFilledMultiColor(ImVec2(0, top - 30 * s), ImVec2(ds.x, ds.y), IM_COL32(8, 10, 14, 0), IM_COL32(8, 10, 14, 0),
                                HZ_BAR, HZ_BAR);
    dl->AddLine(ImVec2(40 * s, top), ImVec2(ds.x - 40 * s, top), HZ_LINE, 1.2f * s);
    hz_glyph(dl, controller ? HZ_GLYPH_CONTROLLER : HZ_GLYPH_TOUCH, ImVec2(92 * s, y), 22 * s, HZ_TEXT);
    float size = 30 * s, x = ds.x - 60 * s, r = 15 * s;
    int hit = -1;
    for (int i = n - 1; i >= 0; i--) {
        ImVec2 tsz = f->CalcTextSizeA(size, FLT_MAX, 0, hints[i].label);
        float x0 = x - tsz.x - 2 * r - 10 * s;
        hz_button_glyph(dl, f, ImVec2(x0 + r, y), r, hints[i].button);
        hz_text(dl, f, size, ImVec2(x0 + 2 * r + 10 * s, y - tsz.y * 0.5f), HZ_TEXT, hints[i].label);
        char id[24];
        snprintf(id, sizeof id, "##hzhint%d", i);
        ImGui::SetCursorScreenPos(ImVec2(x0 - 8 * s, top + 4 * s));
        if (ImGui::InvisibleButton(id, ImVec2(x - x0 + 16 * s, ds.y - top - 4 * s))) hit = i;
        if (ImGui::IsItemHovered()) dl->AddRectFilled(ImVec2(x0 - 8 * s, y - 22 * s), ImVec2(x + 8 * s, y + 22 * s),
                                                      IM_COL32(255, 255, 255, 22), 22 * s);
        x = x0 - 44 * s;
    }
    return hit;
}

static inline void hz_tile(ImDrawList *dl, ImFont *f, const HzTile &t, ImVec2 a, ImVec2 b, float s, bool selected,
                           bool focused) {
    float rnd = 6 * s, w = b.x - a.x;
    dl->AddRectFilled(ImVec2(a.x + 3 * s, a.y + 5 * s), ImVec2(b.x + 3 * s, b.y + 6 * s), IM_COL32(0, 0, 0, 90), rnd);
    if (t.art) {
        dl->AddImageRounded(t.art, a, b, t.uv0, t.uv1, IM_COL32(255, 255, 255, 255), rnd);
    } else {
        dl->AddRectFilledMultiColor(a, b, t.col1, t.col1, t.col2, t.col2);
        float size = (selected ? 34 : 26) * s, pad = 16 * s;
        ImVec2 tsz = f->CalcTextSizeA(size, FLT_MAX, w - 2 * pad, t.title.c_str());
        hz_text(dl, f, size, ImVec2(a.x + pad, b.y - pad - tsz.y), HZ_TEXT, t.title.c_str(), NULL, w - 2 * pad);
    }
    if (t.dim) dl->AddRectFilled(a, b, IM_COL32(10, 12, 16, 120), rnd);
    if (t.progress >= 0) {
        float h = 8 * s;
        dl->AddRectFilled(ImVec2(a.x, b.y - h), b, IM_COL32(0, 0, 0, 160), rnd, ImDrawFlags_RoundCornersBottom);
        dl->AddRectFilled(ImVec2(a.x, b.y - h), ImVec2(a.x + w * (t.progress > 1 ? 1 : t.progress), b.y), HZ_ACCENT, rnd,
                          ImDrawFlags_RoundCornersBottomLeft);
    }
    if (!t.badge.empty()) {  // as the "Playing" pill: lower left, inside the tile
        float size = (selected ? 26 : 22) * s;
        ImVec2 tsz = f->CalcTextSizeA(size, FLT_MAX, 0, t.badge.c_str());
        float ph = tsz.y + 12 * s, px = 14 * s;
        ImVec2 p0(a.x + 12 * s, b.y - ph - (t.progress >= 0 ? 20 : 12) * s), p1(p0.x + tsz.x + 2 * px, p0.y + ph);
        dl->AddRectFilled(p0, p1, IM_COL32(20, 22, 28, 215), ph * 0.5f);
        dl->AddText(f, size, ImVec2(p0.x + px, p0.y + 6 * s), HZ_TEXT, t.badge.c_str());
    }
    if (selected) {  // the selection frame: white, a cyan glow pulsing around it while the row has the focus
        dl->AddRect(ImVec2(a.x - 2 * s, a.y - 2 * s), ImVec2(b.x + 2 * s, b.y + 2 * s), IM_COL32(255, 255, 255, 230),
                    rnd + 2 * s, 0, 3 * s);
        if (focused) {
            float k = 0.5f + 0.5f * sinf((float)ImGui::GetTime() * 4.0f);
            dl->AddRect(ImVec2(a.x - 7 * s, a.y - 7 * s), ImVec2(b.x + 7 * s, b.y + 7 * s),
                        IM_COL32(0, 200, 230, (int)(140 + 115 * k)), rnd + 7 * s, 0, 4 * s);
        }
    }
}

// The home screen. Input: left / right along the focused row, up / down between the icons and the tiles, A starts
// the selected tile or presses the selected icon; touch: a tap selects a tile, a tap on the selected one starts it.
static inline HzHomeResult hz_home(ImDrawList *dl, ImFont *f, ImVec2 ds, float s, HzHomeState &st,
                                   const std::vector<HzTile> &tiles, const HzIcon *icons, int nicons, bool controller,
                                   const HzHint *hints, int nhints, int battery_pct, bool charging, bool input_on) {
    HzHomeResult r;
    int n = (int)tiles.size();
    if (st.sel >= n) st.sel = n - 1;
    if (st.sel < 0) st.sel = 0;
    if (st.icon_sel >= nicons) st.icon_sel = nicons - 1;
    if (st.icon_sel < 0) st.icon_sel = 0;
    if (n == 0) st.focus = 1;

    if (input_on) {
        auto pressed = [](ImGuiKey k1, ImGuiKey k2, ImGuiKey k3) {
            return ImGui::IsKeyPressed(k1) || ImGui::IsKeyPressed(k2) || ImGui::IsKeyPressed(k3);
        };
        int dx = pressed(ImGuiKey_GamepadDpadRight, ImGuiKey_GamepadLStickRight, ImGuiKey_RightArrow) ? 1
               : pressed(ImGuiKey_GamepadDpadLeft, ImGuiKey_GamepadLStickLeft, ImGuiKey_LeftArrow) ? -1 : 0;
        if (pressed(ImGuiKey_GamepadDpadUp, ImGuiKey_GamepadLStickUp, ImGuiKey_UpArrow) && nicons) st.focus = 1;
        if (pressed(ImGuiKey_GamepadDpadDown, ImGuiKey_GamepadLStickDown, ImGuiKey_DownArrow) && n) st.focus = 0;
        if (st.focus == 0 && dx) st.sel = st.sel + dx < 0 ? 0 : st.sel + dx >= n ? n - 1 : st.sel + dx;
        if (st.focus == 1 && dx) st.icon_sel = st.icon_sel + dx < 0 ? 0 : st.icon_sel + dx >= nicons ? nicons - 1 : st.icon_sel + dx;
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceDown, false) || ImGui::IsKeyPressed(ImGuiKey_Enter, false) ||
            ImGui::IsKeyPressed(ImGuiKey_Space, false)) {
            if (st.focus == 0 && n) r.start_tile = st.sel;
            else if (st.focus == 1 && nicons) r.icon = st.icon_sel;
        }
    }

    // icons (upper left), each a dark disc with its glyph; the selected one's name under it
    float iy = 58 * s, ir = 29 * s, ix = 90 * s, pitch = 74 * s;
    for (int i = 0; i < nicons; i++) {
        ImVec2 c(ix + i * pitch, iy);
        bool sel = st.focus == 1 && st.icon_sel == i;
        char id[24];
        snprintf(id, sizeof id, "##hzicon%d", i);
        ImGui::SetCursorScreenPos(ImVec2(c.x - ir, c.y - ir));
        if (input_on && ImGui::InvisibleButton(id, ImVec2(2 * ir, 2 * ir))) r.icon = i, st.focus = 1, st.icon_sel = i;
        bool hov = input_on && ImGui::IsItemHovered();
        dl->AddCircleFilled(c, ir, hov ? IM_COL32(70, 76, 86, 235) : HZ_ICON_BG, 40);
        hz_glyph(dl, icons[i].glyph, c, ir * 0.55f, HZ_TEXT);
        if (icons[i].dot) dl->AddCircleFilled(ImVec2(c.x + ir * 0.78f, c.y - ir * 0.78f), 5 * s, IM_COL32(60, 210, 240, 255));
        if (sel) {
            float k = 0.5f + 0.5f * sinf((float)ImGui::GetTime() * 4.0f);
            dl->AddCircle(c, ir + 5 * s, IM_COL32(0, 200, 230, (int)(150 + 105 * k)), 40, 3.5f * s);
            ImVec2 tsz = f->CalcTextSizeA(22 * s, FLT_MAX, 0, icons[i].label);
            hz_text(dl, f, 22 * s, ImVec2(c.x - tsz.x * 0.5f, c.y + ir + 10 * s), HZ_TEXT, icons[i].label);
        }
    }
    hz_status(dl, f, ds, s, battery_pct, charging);

    // the tiles: 200 px squares, the selected one 300; the row scrolls to keep the selection on screen
    float ty = 148 * s, small = 200 * s, big = 300 * s, gap = 30 * s, left = 90 * s, right = ds.x - 60 * s;
    float sel_x = st.sel * (small + gap);  // (where the selected one starts, unscrolled)
    float want = st.scroll;
    if (sel_x - want < 0) want = sel_x;
    if (sel_x + big - want > right - left) want = sel_x + big - (right - left);
    st.scroll += (want - st.scroll) * (ImGui::GetIO().DeltaTime > 0 ? fminf(1.0f, ImGui::GetIO().DeltaTime * 14) : 1);
    if (fabsf(want - st.scroll) < 0.5f) st.scroll = want;
    float x = left - st.scroll;
    for (int i = 0; i < n; i++) {
        float w = i == st.sel ? big : small;
        ImVec2 a(x, ty), b(x + w, ty + w);
        if (b.x > 0 && a.x < ds.x) {
            char id[24];
            snprintf(id, sizeof id, "##hztile%d", i);
            ImGui::SetCursorScreenPos(a);
            if (input_on && ImGui::InvisibleButton(id, ImVec2(w, w))) {
                if (i == st.sel && st.focus == 0) r.start_tile = i;
                st.sel = i, st.focus = 0;
            }
            hz_tile(dl, f, tiles[i], a, b, s, i == st.sel, st.focus == 0);
        }
        x += w + gap;
    }

    // the selected game's name under the row
    if (n) {
        const std::string &t = tiles[st.sel].title;
        float size = 40 * s;
        hz_text(dl, f, size, ImVec2(left, ty + big + 36 * s), HZ_TEXT, t.c_str(), NULL, ds.x - left - 60 * s);
    }

    int h = hz_bottom_bar(dl, f, ds, s, controller, hints, nhints);
    if (input_on) r.hint = h;
    return r;
}

// ---- settings pages: a dim panel over the wallpaper, the title along the top, a sidebar on the left, the page's own
// content on the right (ImGui widgets, the caller's), button hints along the bottom.
struct HzPageRects {
    ImVec2 side_min, side_max, body_min, body_max;
};

static inline HzPageRects hz_page_frame(ImDrawList *dl, ImFont *f, ImVec2 ds, float s, const char *title,
                                        const char *subtitle, ImTextureID art, ImVec2 uv0, ImVec2 uv1) {
    dl->AddRectFilled(ImVec2(0, 0), ds, HZ_PANEL);
    float x = 60 * s, y = 46 * s, top = 104 * s;
    if (art) {
        float a = 50 * s;
        dl->AddImageRounded(art, ImVec2(x, y - a * 0.5f + 6 * s), ImVec2(x + a, y + a * 0.5f + 6 * s), uv0, uv1,
                            IM_COL32(255, 255, 255, 255), 5 * s);
        x += a + 18 * s;
    }
    ImVec2 tsz = f->CalcTextSizeA(38 * s, FLT_MAX, 0, title);
    hz_text(dl, f, 38 * s, ImVec2(x, y + 6 * s - tsz.y * 0.5f), HZ_TEXT, title);
    if (subtitle && *subtitle) {
        ImVec2 ssz = f->CalcTextSizeA(24 * s, FLT_MAX, 0, subtitle);
        dl->AddText(f, 24 * s, ImVec2(x + tsz.x + 20 * s, y + 6 * s - ssz.y * 0.5f + 3 * s), HZ_TEXT_DIM, subtitle);
    }
    dl->AddLine(ImVec2(40 * s, top), ImVec2(ds.x - 40 * s, top), HZ_LINE, 1.2f * s);
    float bottom = ds.y - 72 * s, split = fminf(380 * s, ds.x * 0.27f);
    dl->AddLine(ImVec2(split, top + 16 * s), ImVec2(split, bottom - 16 * s), HZ_LINE, 1.0f * s);
    HzPageRects r;
    r.side_min = ImVec2(40 * s, top + 16 * s);
    r.side_max = ImVec2(split - 16 * s, bottom - 12 * s);
    r.body_min = ImVec2(split + 24 * s, top + 12 * s);
    r.body_max = ImVec2(ds.x - 40 * s, bottom - 8 * s);
    return r;
}

// One sidebar entry (inside a child window the caller opened): the selected one in the accent colour with a bar on
// its left. Returns true when picked.
static inline bool hz_side_item(ImFont *f, float s, const char *label, bool selected, bool enabled = true) {
    ImVec2 p = ImGui::GetCursorScreenPos();
    float w = ImGui::GetContentRegionAvail().x, h = 64 * s;
    ImGui::BeginDisabled(!enabled);
    ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0.78f, 0.9f, 1));
    bool hit = ImGui::InvisibleButton(label, ImVec2(w, h), ImGuiButtonFlags_EnableNav);
    ImGui::PopStyleColor();
    bool hot = ImGui::IsItemHovered() || ImGui::IsItemFocused();
    ImGui::EndDisabled();
    ImDrawList *dl = ImGui::GetWindowDrawList();
    if (hot) dl->AddRectFilled(p, ImVec2(p.x + w, p.y + h), IM_COL32(255, 255, 255, 18), 4 * s);
    if (selected) dl->AddRectFilled(ImVec2(p.x + 6 * s, p.y + 14 * s), ImVec2(p.x + 11 * s, p.y + h - 14 * s), HZ_ACCENT, 2 * s);
    float size = 28 * s;
    ImVec2 tsz = f->CalcTextSizeA(size, FLT_MAX, 0, label, ImGui::FindRenderedTextEnd(label));
    dl->AddText(f, size, ImVec2(p.x + 26 * s, p.y + (h - tsz.y) * 0.5f),
                !enabled ? IM_COL32(120, 124, 130, 255) : selected ? HZ_ACCENT : HZ_TEXT, label, ImGui::FindRenderedTextEnd(label));
    return hit && enabled;
}
