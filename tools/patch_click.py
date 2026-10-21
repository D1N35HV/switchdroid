with open('runtime/ui/switch_horizon.h', 'rb') as f:
    content = f.read().decode('utf-8')

content_lf = content.replace('\r\n', '\n')

old_part = """    // Active card touch / click button
    ImGui::SetCursorScreenPos(act_min);
    if (ImGui::InvisibleButton("##active_card_btn", ImVec2(active_w, active_h))) {
        if (cards[selected_idx].is_add_slot) {
            if (on_pick_game) on_pick_game();
        } else if (cards[selected_idx].is_installed) {
            play = true;
        } else if (on_pick_game) {
            on_pick_game();
        }
    }"""

new_part = """    // Active card touch / click button
    ImGui::SetCursorScreenPos(act_min);
    bool act_clicked = ImGui::InvisibleButton("##active_card_btn", ImVec2(active_w, active_h), ImGuiButtonFlags_EnableNav);
    if (act_clicked || ImGui::IsItemClicked() || ImGui::IsItemActivated()) {
        if (cards[selected_idx].is_add_slot) {
            if (on_pick_game) on_pick_game();
        } else if (cards[selected_idx].is_installed) {
            play = true;
        } else if (on_pick_game) {
            on_pick_game();
        }
    }"""

assert old_part in content_lf, "old_part not found"
content_lf = content_lf.replace(old_part, new_part)

old_card = """        char c_id[32];
        snprintf(c_id, sizeof(c_id), "##inact_card_%d", i);
        ImGui::SetCursorScreenPos(c_min);
        bool clicked = ImGui::InvisibleButton(c_id, ImVec2(normal_sz, normal_sz));
        bool hov = ImGui::IsItemHovered();

        if (clicked) {
            selected_idx = i;
        }"""

new_card = """        char c_id[32];
        snprintf(c_id, sizeof(c_id), "##inact_card_%d", i);
        ImGui::SetCursorScreenPos(c_min);
        bool clicked = ImGui::InvisibleButton(c_id, ImVec2(normal_sz, normal_sz), ImGuiButtonFlags_EnableNav);
        bool hov = ImGui::IsItemHovered();

        if (clicked || ImGui::IsItemClicked() || ImGui::IsItemActivated()) {
            selected_idx = i;
        }"""

assert old_card in content_lf, "old_card not found"
content_lf = content_lf.replace(old_card, new_card)

old_bot = """    // Make (+ Options) touchable
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

new_bot = """    // Make (+ Options) touchable
    ImGui::SetCursorScreenPos(ImVec2(rp_min.x, rp_min.y));
    bool opt_btn = ImGui::InvisibleButton("##options_pill_btn", ImVec2(125 * s, r_pill_h), ImGuiButtonFlags_EnableNav);
    if (opt_btn || ImGui::IsItemClicked() || ImGui::IsItemActivated()) {
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
    bool launch_btn = ImGui::InvisibleButton("##launch_pill_btn", ImVec2(135 * s, r_pill_h), ImGuiButtonFlags_EnableNav);
    if (launch_btn || ImGui::IsItemClicked() || ImGui::IsItemActivated()) {
        if (cards[selected_idx].is_installed) {
            play = true;
        } else if (on_pick_game) {
            on_pick_game();
        }
    }"""

assert old_bot in content_lf, "old_bot not found"
content_lf = content_lf.replace(old_bot, new_bot)

final_content = content_lf.replace('\n', '\r\n')
with open('runtime/ui/switch_horizon.h', 'wb') as f:
    f.write(final_content.encode('utf-8'))

print("Updated button click triggers in switch_horizon.h successfully!")
