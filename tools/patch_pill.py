with open('runtime/ui/switch_horizon.h', 'rb') as f:
    content = f.read().decode('utf-8')

content_lf = content.replace('\r\n', '\n')

old_pill = """    // Bottom-Right: Sleek Dark Capsule with (+ Options) and (A Launch)
    float pill_rx = ds.x - 45 * s;
    float r_pill_w = 210 * s, r_pill_h = 42 * s;
    ImVec2 rp_min(pill_rx - r_pill_w, bot_y - r_pill_h * 0.5f);
    ImVec2 rp_max(pill_rx, bot_y + r_pill_h * 0.5f);

    dl->AddRectFilled(rp_min, rp_max, IM_COL32(22, 26, 32, 220), r_pill_h * 0.5f);
    dl->AddRect(rp_min, rp_max, IM_COL32(65, 72, 82, 160), r_pill_h * 0.5f, 0, 1.4f * s);

    // (+ Options) Button inside capsule
    float opt_x = rp_min.x + 14 * s;
    dl->AddCircleFilled(ImVec2(opt_x + 10 * s, bot_y), 9 * s, IM_COL32(245, 245, 245, 255));
    dl->AddText(font_small, font_small->FontSize * 0.75f, ImVec2(opt_x + 6 * s, bot_y - 7 * s), IM_COL32(20, 20, 20, 255), "+");
    dl->AddText(font_menu, font_menu->FontSize * 0.60f, ImVec2(opt_x + 24 * s, bot_y - 8 * s), IM_COL32(240, 240, 240, 255), "Options");

    // Make (+ Options) touchable
    ImGui::SetCursorScreenPos(ImVec2(rp_min.x, rp_min.y));
    if (ImGui::InvisibleButton("##options_pill_btn", ImVec2(r_pill_w * 0.5f, r_pill_h))) {
        page = 1; // SETTINGS
    }

    // (A Launch) Button inside capsule
    float launch_x = rp_min.x + r_pill_w * 0.52f;
    const char *launch_lbl = cards[selected_idx].is_installed ? "Launch" : "Select ROM";
    dl->AddCircleFilled(ImVec2(launch_x + 10 * s, bot_y), 9 * s, IM_COL32(245, 245, 245, 255));
    dl->AddText(font_small, font_small->FontSize * 0.75f, ImVec2(launch_x + 6 * s, bot_y - 7 * s), IM_COL32(20, 20, 20, 255), "A");
    dl->AddText(font_menu, font_menu->FontSize * 0.60f, ImVec2(launch_x + 24 * s, bot_y - 8 * s), IM_COL32(240, 240, 240, 255), launch_lbl);

    // Make (A Launch) touchable
    ImGui::SetCursorScreenPos(ImVec2(rp_min.x + r_pill_w * 0.5f, rp_min.y));
    if (ImGui::InvisibleButton("##launch_pill_btn", ImVec2(r_pill_w * 0.5f, r_pill_h))) {
        if (cards[selected_idx].is_installed) {
            play = true;
        } else if (on_pick_game) {
            on_pick_game();
        }
    }"""

new_pill = """    // Bottom-Right: Sleek Dark Capsule with (+ Options) and (A Launch)
    float pill_rx = ds.x - 45 * s;
    float r_pill_w = 265 * s, r_pill_h = 42 * s;
    ImVec2 rp_min(pill_rx - r_pill_w, bot_y - r_pill_h * 0.5f);
    ImVec2 rp_max(pill_rx, bot_y + r_pill_h * 0.5f);

    dl->AddRectFilled(rp_min, rp_max, IM_COL32(22, 26, 32, 220), r_pill_h * 0.5f);
    dl->AddRect(rp_min, rp_max, IM_COL32(65, 72, 82, 160), r_pill_h * 0.5f, 0, 1.4f * s);

    // (+ Options) Button inside capsule
    float opt_x = rp_min.x + 14 * s;
    dl->AddCircleFilled(ImVec2(opt_x + 10 * s, bot_y), 9 * s, IM_COL32(245, 245, 245, 255));
    dl->AddText(font_small, font_small->FontSize * 0.75f, ImVec2(opt_x + 6 * s, bot_y - 7 * s), IM_COL32(20, 20, 20, 255), "+");
    dl->AddText(font_menu, font_menu->FontSize * 0.60f, ImVec2(opt_x + 24 * s, bot_y - 8 * s), IM_COL32(240, 240, 240, 255), "Options");

    // Make (+ Options) touchable
    ImGui::SetCursorScreenPos(ImVec2(rp_min.x, rp_min.y));
    if (ImGui::InvisibleButton("##options_pill_btn", ImVec2(125 * s, r_pill_h))) {
        page = 1; // SETTINGS
    }

    // (A Launch) Button inside capsule
    float launch_x = rp_min.x + 135 * s;
    const char *launch_lbl = cards[selected_idx].is_installed ? "Launch" : "Select ROM";
    dl->AddCircleFilled(ImVec2(launch_x + 10 * s, bot_y), 9 * s, IM_COL32(245, 245, 245, 255));
    dl->AddText(font_small, font_small->FontSize * 0.75f, ImVec2(launch_x + 6 * s, bot_y - 7 * s), IM_COL32(20, 20, 20, 255), "A");
    dl->AddText(font_menu, font_menu->FontSize * 0.60f, ImVec2(launch_x + 24 * s, bot_y - 8 * s), IM_COL32(240, 240, 240, 255), launch_lbl);

    // Make (A Launch) touchable
    ImGui::SetCursorScreenPos(ImVec2(launch_x - 5 * s, rp_min.y));
    if (ImGui::InvisibleButton("##launch_pill_btn", ImVec2(135 * s, r_pill_h))) {
        if (cards[selected_idx].is_installed) {
            play = true;
        } else if (on_pick_game) {
            on_pick_game();
        }
    }"""

assert old_pill in content_lf, "old_pill not found"
content_lf = content_lf.replace(old_pill, new_pill)

final_content = content_lf.replace('\n', '\r\n')
with open('runtime/ui/switch_horizon.h', 'wb') as f:
    f.write(final_content.encode('utf-8'))

print("Updated bottom pill spacing in switch_horizon.h successfully!")
