// Start screen, shown before the game boots, after the Switch home menu (switch_horizon.h; user 2026-10-21): a row of
// game tiles (the library: the built-in game and the installed addons), System Settings and Quit above it, and per
// game its pages - Settings, Play mode (vanilla / a seed), Game files, Information. Nothing of the game ships with
// LAS Recomp: the user sets up their own game files (v1.0.0) from the game's Game files page, we check the main
// module's build id, copy the files and build the game code; Start stays a Set up until that worked. The wallpaper
// is a frame of the game's own title movie (from the user's files) once extracted.
//
// Skipped with --play, LARECOMP_NO_LAUNCHER=1, or any scripted test run (LARECOMP_INPUT): tests boot straight in.
// The in-game menu's "Title screen" comes back here without leaving the process (runtime/main.c reboots the game).
#ifdef __APPLE__
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#endif
#include <SDL3/SDL.h>
#include <ctype.h>
#include <dirent.h>
#include <pthread.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#include <algorithm>
#include <atomic>
#ifdef __ANDROID__
#include <zlib.h>  // (font zips: import_fonts)
#endif

#include "imgui.h"
#include "touch_ui.h"
#include "switch_horizon.h"
static TouchUi g_touch;  // (touch screens: the start screen's pages)
#include "imgui_internal.h"  // (SetKeyOwner)
#include "i18n.h"
#include "option_rows.h"
#include "osk.h"
#include "pad_nav.h"
#ifdef __APPLE__
#include "imgui_impl_metal.h"
#else
#include "imgui_impl_vulkan.h"
#endif
#include "imgui_impl_sdl3.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
#include "platform.h"
#include "paths.h"
#include "gamebuild.h"
#include "build_cache.h"
#include "gamelib.h"
#include "romfs_build.h"
#include "settings.h"
#include "input_bind.h"
#ifdef __ANDROID__
#include "platform/android.h"
#endif
#include "nvn/shader_prep.h"
bool controls_ui_took_back(void);  // ui/controls_ui.mm: B went back a step on Configure inputs
void ui_window_init(void);
SDL_Window *ui_window(void);
#ifdef __APPLE__
void *ui_metal_layer(void);
void *ui_metal_device(void);
#else
// runtime/nvn/vulkan: window frames and ImGui plumbing
bool vk_frame_begin(const float clear[4]);
void vk_frame_end(const char *shot_path);
void *vk_frame_cmd(void);
bool vk_imgui_backend_init(void);
void vk_imgui_backend_shutdown(void);
uint64_t vk_imgui_texture_rgba(const void *rgba, int w, int h);
#endif
}
#ifdef __APPLE__
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// (test) BGRA texture -> PNG (the game renderer's saver isn't up yet before the game boots)
static void save_png(id<MTLTexture> tex, const char *path) {
    size_t w = tex.width, h = tex.height;
    std::vector<uint8_t> px(w * h * 4);
    [tex getBytes:px.data() bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px.data(), w, h, 8, w * 4, cs,
                                             kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (dest) {  // (NULL when the file can't be created, e.g. its folder isn't there: CFRelease(NULL) traps)
        CGImageDestinationAddImage(dest, img, NULL);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
    } else fprintf(stderr, "[launcher] can't write %s\n", path);
    CFRelease(url), CGImageRelease(img), CGContextRelease(ctx), CGColorSpaceRelease(cs);
}
#endif

static const uint8_t BUILD_ID[8] = {0xae, 0x16, 0xf7, 0x1e, 0x00, 0x2a, 0xf8, 0xcb};  // Link's Awakening v1.0.0 main
// The release tag this build is (also names the release files; Makefile / tools/bundle_macos.sh / make_dmg.sh read
// it): beta_<n> until 1.0, then v<major>.<minor>.<patch>. A test build (a pre-release for a few players to try a fix)
// is test-<name>: the start screen says "Test build <name>", and it previews LARECOMP_TEST_OF - the update check
// offers that release (or a later one) as soon as it's out, so its players move to it.
#define LARECOMP_VERSION "beta_4"
#define LARECOMP_TEST_OF "beta_5"
extern "C" const char *larecomp_version(void) { return LARECOMP_VERSION; }  // (the shader caches' tag)

// ------------------------------------------------------------------ update check
// The start screen asks GitHub for the project's releases once per launch (a background curl, which macOS and
// Windows 10+ ship) and offers the best one if it outranks this build: any v1.0.0+ above every beta, betas by
// number; other tags (the alpha_* ones) are ignored. Offline / no curl / anything unexpected: nothing is shown.
#define RELEASES_URL "https://api.github.com/repos/peiikai/LASRecomp/releases?per_page=100"
#define RELEASE_PAGE "https://github.com/peiikai/LASRecomp/releases/tag/"

static long long tag_rank(const std::string &t) {
    int n, a, b, c;
    char end;
    if (sscanf(t.c_str(), "beta_%d%c", &n, &end) == 1 && n > 0) return n;
    if (sscanf(t.c_str(), "v%d.%d.%d%c", &a, &b, &c, &end) == 3 && a >= 1 && b >= 0 && c >= 0 && b < 4096 && c < 4096)
        return (1LL << 48) + ((long long)a << 24) + ((long long)b << 12) + c;
    return -1;
}

// "Beta 2" / "1.0.0" (with_word: "Version 1.0.0")
static std::string tag_label(const std::string &t, bool with_word) {
    int n;
    char end;
    if (sscanf(t.c_str(), "beta_%d%c", &n, &end) == 1) return "Beta " + std::to_string(n);
    if (!t.compare(0, 5, "test-")) return T("Test build ") + t.substr(5);
    std::string v = t.size() > 1 && t[0] == 'v' ? t.substr(1) : t;
    return with_word ? T("Version ") + v : v;
}

static std::string g_update_tag;  // a newer release's tag (g_update_lock)
static pthread_mutex_t g_update_lock = PTHREAD_MUTEX_INITIALIZER;

static void *update_thread(void *) {
    std::string body;
    if (const char *t = getenv("LARECOMP_UPDATE_TAGS")) {  // (test) "beta_2,v1.0.0": these releases, no network
        for (const char *p = t; *p;) {
            const char *c = strchr(p, ',');
            body += "\"tag_name\": \"" + std::string(p, c ? c - p : strlen(p)) + "\"\n";
            p = c ? c + 1 : p + strlen(p);
        }
    } else {
#ifdef _WIN32
        const char *sr = getenv("SystemRoot");
        std::string curl = std::string(sr ? sr : "C:\\Windows") + "\\System32\\curl.exe";
#else
        std::string curl = "/usr/bin/curl";
#endif
        std::string out = std::string(rt_data_root()) + "/cache/releases.json";
        mkdir((std::string(rt_data_root()) + "/cache").c_str(), 0755);
        const char *av[] = {curl.c_str(), "-fsSL", "--max-time", "15", "-H", "Accept: application/vnd.github+json",
                            "-A", "LASRecomp/" LARECOMP_VERSION, RELEASES_URL, NULL};
        PlatProc p = plat_spawn(av, out.c_str(), false);
        if (!p || plat_proc_wait(p, true) != 0) { remove(out.c_str()); return NULL; }
        if (FILE *f = fopen(out.c_str(), "rb")) {
            char buf[8192];
            size_t n;
            while ((n = fread(buf, 1, sizeof buf, f)) > 0 && body.size() < (8u << 20)) body.append(buf, n);
            fclose(f);
        }
        remove(out.c_str());
    }
    std::string best;
    // (a test build ranks just below the release it previews; other test builds rank -1: never offered)
    long long best_rank = strncmp(LARECOMP_VERSION, "test-", 5) ? tag_rank(LARECOMP_VERSION) : tag_rank(LARECOMP_TEST_OF) - 1;
    for (size_t at = 0; (at = body.find("\"tag_name\"", at)) != std::string::npos;) {
        size_t q1 = body.find('"', body.find(':', at) + 1), q2 = q1 == std::string::npos ? q1 : body.find('"', q1 + 1);
        if (q2 == std::string::npos) break;
        std::string tag = body.substr(q1 + 1, q2 - q1 - 1);
        if (tag_rank(tag) > best_rank) best_rank = tag_rank(tag), best = tag;
        at = q2;
    }
    if (!best.empty()) fprintf(stderr, "[launcher] update available: %s (this build %s)\n", best.c_str(), LARECOMP_VERSION);
    pthread_mutex_lock(&g_update_lock);
    g_update_tag = best;
    pthread_mutex_unlock(&g_update_lock);
    return NULL;
}

// ------------------------------------------------------------------ game files
static std::string g_root;  // extracted game: <root>/exefs, <root>/romfs
// ------------------------------------------------------------------ library
// The games on the home screen: the one this engine runs (built in), then every addon manifest in the data folder's
// addons/<title id>/ (tools/validate_addon.py's format). An addon whose game this engine can't run yet is listed as
// such - its tile opens its details, never a setup or a start that couldn't work.
#define LA_TITLE_ID "01006bb00c6f0000"
struct LibGame {
    std::string id, name, version, build_id, author;
    bool builtin;  // the game this engine runs
};
static std::vector<LibGame> g_library;
static std::string g_game_title;  // the built-in game's name from its control.nacp, "" until read (load_artwork)

// a manifest's string field / the first string of an array field ("" if absent); manifests are small and flat
static std::string json_field(const std::string &j, const char *key, bool first_of_array = false) {
    size_t p = j.find(std::string("\"") + key + "\"");
    if (p == std::string::npos || (p = j.find(':', p)) == std::string::npos) return "";
    p = j.find_first_not_of(" \t\r\n", p + 1);
    if (p == std::string::npos) return "";
    if (first_of_array) {
        if (j[p] != '[') return "";
        p = j.find_first_not_of(" \t\r\n", p + 1);
        if (p == std::string::npos) return "";
    }
    if (j[p] != '"') return "";
    std::string out;
    for (size_t i = p + 1; i < j.size() && j[i] != '"'; i++) {
        if (j[i] == '\\' && i + 1 < j.size()) i++;
        out += j[i];
    }
    return out;
}

static void scan_library(void) {
    std::vector<LibGame> lib;
    lib.push_back({LA_TITLE_ID, g_game_title.empty() ? "The Legend of Zelda: Link's Awakening" : g_game_title, "1.0.0",
                   "ae16f71e002af8cb", "", true});
    std::string dir = std::string(rt_data_root()) + "/addons";
    std::vector<LibGame> addons;
    if (DIR *d = opendir(dir.c_str())) {
        while (struct dirent *e = readdir(d)) {
            if (e->d_name[0] == '.') continue;
            FILE *f = fopen((dir + "/" + e->d_name + "/manifest.json").c_str(), "rb");
            if (!f) continue;
            std::string j;
            char buf[4096];
            size_t n;
            while ((n = fread(buf, 1, sizeof buf, f)) > 0 && j.size() < 65536) j.append(buf, n);
            fclose(f);
            LibGame g{json_field(j, "game_id"), json_field(j, "name"), json_field(j, "version"),
                      json_field(j, "build_ids", true), json_field(j, "author"), false};
            for (char &c : g.id) c = (char)tolower((unsigned char)c);
            if (g.id.size() != 16 || g.id != e->d_name || g.id == LA_TITLE_ID) continue;  // (malformed, or the built-in)
            if (g.name.empty()) g.name = g.id;
            addons.push_back(g);
        }
        closedir(d);
    }
    std::sort(addons.begin(), addons.end(), [](const LibGame &a, const LibGame &b) { return a.name < b.name; });
    lib.insert(lib.end(), addons.begin(), addons.end());
    g_library = lib;
}

extern "C" const char *launcher_selected_root(void) {
    return g_root.c_str();
}


static bool file_exists(const std::string &p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0;
}

// The game's RomFS (v1.0.0) has exactly ROMFS_FILES files: a copy with fewer is incomplete (a copy or unzip that
// stopped partway) and the game crashes on the first one it misses (issues #24, #35). Only the number ships.
enum { ROMFS_FILES = 3836 };
static int count_files(const std::string &dir, int depth = 0) {
    DIR *d = depth < 12 ? opendir(dir.c_str()) : NULL;
    if (!d) return 0;
    int n = 0;
    while (struct dirent *e = readdir(d)) {
        if (e->d_name[0] == '.') continue;  // (".", "..", .DS_Store)
        std::string p = dir + "/" + e->d_name;
        struct stat st;
        if (stat(p.c_str(), &st) != 0) continue;
        n += S_ISDIR(st.st_mode) ? count_files(p, depth + 1) : S_ISREG(st.st_mode) ? 1 : 0;
    }
    closedir(d);
    return n;
}
// The copied romfs' file count, counted once (the checks below run every frame): -1 = count again (game files set
// up, deleted)
static int g_romfs_count = -1;
static std::atomic<bool> g_build_cache_changed{true};
static void game_files_changed(void) { g_romfs_count = -1; g_build_cache_changed = true; }
// The setup page redraws every frame; read the build cache's disk state only after the files/build state changes.
static bool g_resumable, g_has_build_cache;
static void read_build_cache(void) {
    if (!g_build_cache_changed.exchange(false)) return;
    g_resumable = build_cache_resumable(g_root.c_str());
    g_has_build_cache = build_cache_present(g_root.c_str());
}
static bool resumable_build(void) { read_build_cache(); return g_resumable; }
static bool has_build_cache(void) { read_build_cache(); return g_has_build_cache; }

static std::string incomplete(int have) {
    char b[96];
    snprintf(b, sizeof b, "Game files incomplete (%d of %d files)", have, (int)ROMFS_FILES);
    return b;
}

static bool build_id_ok(const std::string &main_path);

// The copied game files alone ("" = there), without the game code built from them
static std::string check_copied_files(const std::string &root) {
    if (!file_exists(root + "/exefs/main")) return "No game files yet";
    if (!build_id_ok(root + "/exefs/main")) return "Wrong version of the game";
    if (!getenv("SWITCHRECOMP_ANY_GAME")) {
        if (!file_exists(root + "/romfs/region_common")) return incomplete(0);
        if (g_romfs_count < 0) g_romfs_count = count_files(root + "/romfs");
        if (g_romfs_count < ROMFS_FILES) return incomplete(g_romfs_count);
    }
    return "";
}

// "" = ready to play, else what is wrong
static std::string check_game_files(const std::string &root) {
    std::string why = check_copied_files(root);
#ifdef __ANDROID__
    if (why.empty() && !gamelib_present(root.c_str())) return "Game code not installed";
#else
    if (why.empty() && !gamelib_present(root.c_str())) return "Game code not built yet";
#endif
    return why;
}

// What to do about a check_game_files() problem (the line under it on the start screen)
static const char *status_hint(const std::string &why) {
    if (why.rfind("Game files incomplete", 0) == 0)
        return T("Some of the game's files are missing, usually from a copy or unzip that stopped partway. Copy your game "
                 "files again, then choose that folder and set them up again.");
    if (why == "Wrong version of the game") return T("LAS Recomp needs version 1.0.0 of the game, without updates.");
    if (why == "Game code not built yet") return T("Set up the game files to build it (a few minutes, only once).");
    return T("Set up the game files to play.");
}
// A check_game_files() problem as shown (the checks compare the English)
static std::string status_text(const std::string &why) {
    int have, all;
    if (sscanf(why.c_str(), "Game files incomplete (%d of %d files)", &have, &all) == 2) {
        char b[160];
        snprintf(b, sizeof b, T("Game files incomplete (%d of %d files)"), have, all);
        return b;
    }
    return T(why.c_str());
}

// ------------------------------------------------------------------ setup (background thread)
// The player brings their own game files: a folder holding exefs/ and romfs/. They're copied into the data root (APFS
// clones / hard links where the file system allows); the game reads romfs/ in place (runtime/services/fs.c).
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static std::string g_src;           // the picked folder
static std::string g_job;           // current setup step / result for the status line
static std::string g_job_hint;      // a failure: what to do about it (shown under it)
static bool g_busy, g_job_failed;
static bool g_play_pending;        // PLAY as if pressed once the start screen is up (a Rando seed; Android: a finished build)
static bool g_confirm_delete;       // game-files page: "Delete the game files?" shown

static void set_job(const std::string &s, bool failed = false, const std::string &hint = "") {
    pthread_mutex_lock(&g_lock);
    g_job = s;
    g_job_failed = failed;
    g_job_hint = hint;
    pthread_mutex_unlock(&g_lock);
}

// Setup failures: a short headline and what to do next (also LARECOMP_LAUNCHER_SHOT=<f>:fail<1-6>, screenshots)
enum { FAIL_NOT_FOUND = 1, FAIL_UNUSABLE, FAIL_COPY, FAIL_VERSION, FAIL_MISSING, FAIL_BUILD, FAIL_NOKEYS, FAIL_KEYS, FAIL_PACKAGE,
       FAIL_UPDATE_ONLY };
static void set_failure(int k, int have = -1, const char *reason = NULL) {
    static const char *const head[] = {"", "No game files found in that folder", "Those are game packages, not game files",
                                       "Setup didn't finish", "Wrong version of the game", "Your game files are incomplete",
                                       "The game code didn't build", "Your keys are needed",
                                       "Your keys can't open the game", "The game package couldn't be read",
                                       "That package is only an update"};
    static const char *const hint[] = {
        "",
#ifdef __ANDROID__
        "Choose the folder with your game: its .xci or .nsp (with your prod.keys), or its exefs and romfs folders.",
        "LAS Recomp can't read compressed packages (.xcz / .nsz) or loose .nca files. Use the .xci or .nsp, or the "
        "exefs and romfs folders.",
#else
        "Choose the folder that has the game's exefs and romfs folders in it.",
        "LAS Recomp needs the game's own files (the exefs and romfs folders), not .xci / .nsp / .nca files.",
#endif
        "Make sure there's about 12 GB free and try again.",
        "LAS Recomp needs version 1.0.0 of the game, without updates.",
        "Some of the game's files are missing - usually a copy or unzip that stopped partway. Copy the game files "
        "again so none are missing, then choose the folder again.",
        "Make sure there's about 2 GB free and try again. If it keeps happening, report it on GitHub.",
        "Opening the .xci / .nsp needs the prod.keys dumped from your own Switch. Put it in the game's folder, or choose "
        "it when asked.",
        "These keys don't open this game. Use the prod.keys dumped from your own Switch, from a system version at least "
        "as new as the game's.",
        "The .xci / .nsp seems damaged or incomplete. Dump or copy it again and choose the folder again.",
        "Choose the folder with the game itself (its .xci, or the base game's .nsp). Updates aren't needed: LAS Recomp "
        "uses version 1.0.0."};
    if (k < 1 || k > 10) return;
    if (k == FAIL_MISSING && have >= 0) {
        char b[320];
        snprintf(b, sizeof b, T("The romfs folder has %d of the game's %d files - some are missing, usually from a copy or "
                 "unzip that stopped partway. Copy the game files again so none are missing, then choose the folder "
                 "again."), have, (int)ROMFS_FILES);
        set_job(head[k], true, b);
        return;
    }
    set_job(head[k], true, reason ? std::string(reason) + " " + hint[k] : hint[k]);
}

static bool is_dir(const std::string &p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

// exefs: the folder with main and main.npdm; romfs: the folder with region_common (the game's data root). Found
// in the picked folder or a few levels below it (some folder layouts nest them).
static void find_game(const std::string &dir, int depth, std::string &exefs, std::string &romfs, bool &unusable) {
    if (depth > 4 || (!exefs.empty() && !romfs.empty())) return;
    if (exefs.empty() && file_exists(dir + "/main") && file_exists(dir + "/main.npdm")) exefs = dir;
    if (romfs.empty() && is_dir(dir + "/region_common")) romfs = dir;
    DIR *d = opendir(dir.c_str());
    if (!d) return;
    std::vector<std::string> sub;
    while (struct dirent *e = readdir(d)) {
        std::string n = e->d_name;
        if (n[0] == '.') continue;
        std::string ext = n.size() > 4 ? n.substr(n.size() - 4) : "";
        for (auto &ch : ext) ch = (char)tolower((unsigned char)ch);
        if (ext == ".xci" || ext == ".nsp" || ext == ".nca" || ext == ".nsz" || ext == ".xcz") unusable = true;
        if (n != "region_common" && is_dir(dir + "/" + n)) sub.push_back(dir + "/" + n);
    }
    closedir(d);
    std::sort(sub.begin(), sub.end());
    for (auto &s : sub) find_game(s, depth + 1, exefs, romfs, unusable);
}

static bool build_id_ok(const std::string &main_path) {
    FILE *f = fopen(main_path.c_str(), "rb");
    if (!f) return false;
    uint8_t id[8] = {0};
    fseek(f, 0x40, SEEK_SET);
    size_t n = fread(id, 1, 8, f);
    fclose(f);
    if (n != 8) return false;
    if (getenv("SWITCHRECOMP_ANY_GAME")) return true;
    const char *custom_id = getenv("SWITCHRECOMP_BUILD_ID");
    if (custom_id && strlen(custom_id) >= 16) {
        uint8_t target[8] = {0};
        for (int i = 0; i < 8; i++) {
            unsigned int v = 0;
            if (sscanf(custom_id + 2 * i, "%2x", &v) == 1) target[i] = (uint8_t)v;
        }
        if (!memcmp(id, target, 8)) return true;
    }
    return !memcmp(id, BUILD_ID, 8);
}

// progress (the overlay's bar): the romfs copy (bytes)
static std::atomic<unsigned long long> g_done, g_total;
// The bar: copying is the first tenth, building the game code (runtime/gamebuild.c) the rest
static unsigned long long g_phase_base;
static std::atomic<float> g_build_frac{-1};  // -1: not building
static std::atomic<bool> g_cancel_build{false};
static bool build_cancelled(void) { return g_cancel_build.load(); }
static bool g_copy_skipped;                  // (only the game code to build: the bar is all of that)
static bool g_auto_update;                   // started by itself: game files there, game code from an older version
static void setup_progress(uint64_t done, uint64_t) { g_done = g_phase_base + done; }
// The build's time left (seconds, -1 = not known yet): its progress over the last few minutes, from 1 minute in
static std::atomic<int> g_build_eta{-1};
static void track_eta(double f) {
    static double t[32], fr[32];
    static int n, at;
    double now = SDL_GetTicks() / 1000.0;
    if (f <= 0) { n = at = 0; g_build_eta = -1; return; }  // (a new build)
    if (n && now - t[(at + 31) % 32] < 10) return;  // (a sample every 10 s, the last ~5 minutes)
    t[at] = now, fr[at] = f, at = (at + 1) % 32;
    if (n < 32) n++;
    int old = n < 32 ? 0 : at;
    double dt = now - t[old], df = f - fr[old];
    g_build_eta = dt >= 60 && df > 0.002 ? (int)((1 - f) * dt / df) : -1;
}
// "about N minutes left" (or "" when not known), translated
static std::string eta_text(void) {
    int s = g_build_eta;
    if (s < 0) return "";
    char b[96];
    if (s < 90) snprintf(b, sizeof b, "%s", T("about a minute left"));
    else if (s < 3600) snprintf(b, sizeof b, T("about %d minutes left"), (s + 30) / 60);
    else snprintf(b, sizeof b, T("about %d h %02d min left"), s / 3600, (s % 3600 + 30) / 60);
    return b;
}
static void build_progress(double f, const char *step) {
    g_build_frac = (float)f;
    track_eta(f);
    static const char *last;
    if (step != last) last = step, set_job(step);
#ifdef __ANDROID__
    static uint64_t shown_at;  // (the notification: once a second at most)
    uint64_t now = SDL_GetTicks();
    if (now - shown_at >= 1000 || f >= 1) {
        shown_at = now;
        std::string e = eta_text(), text = T(step);
        if (!e.empty()) text += " - " + e;
        android_build_progress((int)(f * 100), text.c_str());
    }
#endif
}
// Shader preparation, after the game files are ready (runtime/nvn/shader_prep.h): its own bar, and Skip
static std::atomic<float> g_prep_frac{-1};  // -1: not preparing
static volatile int g_prep_skip;
static bool g_prep_skip_ask;  // Skip pressed: "are you sure?" in front of the bar (LARECOMP_LAUNCHER_SHOT=<f>:skipask)
static void prep_progress(int done, int total) { g_prep_frac = total ? (float)done / (float)total : 0.0f; }
static void prepare_shaders(bool background = false) {
#ifdef __ANDROID__
    // (phones: off - every variant before PLAY took minutes on an Adreno 650 after each shader update, and doubled the
    // compile load with the shader head start, which builds what the player saw, in the background: exec.c)
    (void)background;
    return;
#endif
    g_prep_skip = 0, g_prep_frac = 0;
    if (!background) set_job("Preparing shaders");
    shader_prep_run((g_root + "/romfs").c_str(), prep_progress, &g_prep_skip);
    g_prep_frac = -1;
}

// Every later start: the same preparation in the background as soon as the start screen is up (quick: the system's
// shader caches already hold the compiled code). Only a PLAY before it is done shows its bar (g_prep_wait).
static std::atomic<bool> g_bg_prep{false};
static bool g_prep_wait;
static void start_background_prep(void) {
    static bool started;  // (once per process: the prepared objects stay for later boots)
    if (started) return;
    started = true;
    g_bg_prep = true;
    pthread_t th;
    pthread_create(&th, NULL, [](void *) -> void * { prepare_shaders(true); g_bg_prep = false; return NULL; }, NULL);
    pthread_detach(th);
}
// Before the game files change (setup, delete): the background preparation stops reading them
static void stop_background_prep(void) {
    if (!g_bg_prep) return;
    g_prep_skip = 1;
    while (g_bg_prep) SDL_Delay(5);
}

static float extract_progress(void) {
    if (float p = g_prep_frac; p >= 0) return p > 1 ? 1 : p;
    unsigned long long t = g_total, d = g_done;
    float b = g_build_frac, f = b >= 0 ? (g_copy_skipped ? b : 0.1f + 0.9f * b) : t ? 0.1f * (float)((double)d / (double)t) : 0;
    return f < 0 ? 0 : f > 0.99f ? 0.99f : f;
}

// Builds the game code from the copied files (a few minutes); false = failed (the job line says so)
static bool build_game_code(void) {
    int cores = SDL_GetNumLogicalCPUCores(), ram_gb = SDL_GetSystemRAM() / 1024;
    GameBuildOpts o = {build_progress, cores < ram_gb - 2 ? cores : ram_gb - 2 > 1 ? ram_gb - 2 : 1, build_cancelled};
#ifdef __ANDROID__
    o.jobs = cores;  // (phones: every core, the little ones too, at a lower priority; runtime/gamebuild.c holds new
                     // compilers back when memory runs low)
#endif
    char why[256] = "";
    g_build_frac = 0;
    bool ok = gamebuild_run(g_root.c_str(), &o, why, sizeof why);
    if (!ok) {
        fprintf(stderr, "[launcher] game code: %s\n", why);
        if (g_cancel_build) set_job("Compilation cancelled. Completed files are kept.");
        else set_failure(FAIL_BUILD, -1, gamebuild_killed() ? why : NULL);
    }
    return ok;
}

#ifdef __ANDROID__
// Android: the game files are copied out of the picked folder (the system hands out documents, not paths) straight into
// extracted/exefs and extracted/romfs (LasActivity.importGameFiles), or were put there over USB (the game reads its
// data from romfs/ itself: runtime/services/fs.c). Then the game code is built on the phone (runtime/gamebuild.c) when
// the APK carries the builder (android/app/build.gradle onDeviceBuild), inside a foreground service (BuildService: it
// goes on with the screen off), and the game starts; otherwise liblasgame.so comes from a computer
// (tools/android/build_game.sh).
static bool in_place_files(const std::string &root) {
    return file_exists(root + "/exefs/main") && is_dir(root + "/romfs/region_common");
}
static void import_progress(uint64_t done, uint64_t total) { g_total = total, g_done = done; }

static void *extract_thread(void *) {
    std::string src;
    pthread_mutex_lock(&g_lock);
    src = g_src;
    pthread_mutex_unlock(&g_lock);
    g_cancel_build = false;
    g_done = 0, g_total = 0, g_phase_base = 0, g_build_frac = -1, g_copy_skipped = src.empty();
    bool built = false;
    if (!src.empty()) {
        set_job("Copying the game files...");
        mkdir(g_root.c_str(), 0755);
        std::string dest = g_root[0] == '/' ? g_root : std::string(rt_data_root()) + "/" + g_root;  // (Java: no cwd)
        char want[17];
        const char *custom_id = getenv("SWITCHRECOMP_BUILD_ID");
        if (custom_id && strlen(custom_id) >= 16) {
            snprintf(want, sizeof want, "%.16s", custom_id);
        } else if (getenv("SWITCHRECOMP_ANY_GAME")) {
            snprintf(want, sizeof want, "auto");
        } else {
            for (int i = 0; i < 8; i++) snprintf(want + 2 * i, 3, "%02x", BUILD_ID[i]);
        }
        const char *err = android_import_game_files(dest.c_str(), want, import_progress);
        if (err) {
            fprintf(stderr, "[launcher] import: %s\n", err);
            if (!strcmp(err, "notfound") || !strcmp(err, "nofolder")) set_failure(FAIL_NOT_FOUND);
            else if (!strcmp(err, "version")) set_failure(FAIL_VERSION);
            else if (!strcmp(err, "unusable")) set_failure(FAIL_UNUSABLE);
            else if (!strcmp(err, "nokeys")) set_failure(FAIL_NOKEYS);
            else if (!strcmp(err, "badkeys") || !strncmp(err, "keys:", 5)) set_failure(FAIL_KEYS);
            else if (!strcmp(err, "notgame")) set_failure(FAIL_NOT_FOUND);
            else if (!strcmp(err, "updateonly")) set_failure(FAIL_UPDATE_ONLY);
            else if (!strncmp(err, "corrupt:", 8)) set_failure(FAIL_PACKAGE);
            else if (!strncmp(err, "space:", 6))
                set_job("Not enough free space", true, T("The game files need about ") +
                        std::to_string((unsigned long long)(atof(err + 6) / 1e9 + 1)) + T(" GB more. Free some space and try again."));
            else set_failure(FAIL_COPY);
            goto done;
        }
    }
    if (!file_exists(g_root + "/exefs/main")) { set_failure(FAIL_NOT_FOUND); goto done; }
    if (!build_id_ok(g_root + "/exefs/main")) { set_failure(FAIL_VERSION); goto done; }
    if (!in_place_files(g_root)) { set_failure(FAIL_MISSING); goto done; }
    game_files_changed();  // (counted again: the copy is new)
    pthread_mutex_lock(&g_lock);
    g_src.clear();  // (a retry - after a failed or cancelled build - uses the copied files and the build's cache)
    pthread_mutex_unlock(&g_lock);
    if (!gamelib_present(g_root.c_str())) {
        if (!gamebuild_available()) {
            set_job("Game code not installed", true, "Build liblasgame.so from these game files on a computer "
                    "(tools/android/build_game.sh) and install it.");
            goto done;
        }
        android_build_service(true, T("Recompiling the game"));
        built = build_game_code();
        android_build_service(false, NULL);
        if (!built) goto done;
    }
    {
        std::string why = check_game_files(g_root);
        if (why.empty()) {
            set_job("Game files ready.");
            if (built) g_play_pending = true;  // (the whole setup done on the phone: straight into the game)
        } else set_failure(why.find("version") != std::string::npos ? FAIL_VERSION : FAIL_MISSING);
    }
done:
    pthread_mutex_lock(&g_lock);
    g_busy = false;
    pthread_mutex_unlock(&g_lock);
    return NULL;
}
#else
static void *extract_thread(void *) {
    stop_background_prep();
    std::string src;
    pthread_mutex_lock(&g_lock);
    src = g_src;
    pthread_mutex_unlock(&g_lock);
    g_cancel_build = false;
    g_done = 0, g_total = 0, g_phase_base = 0, g_build_frac = -1, g_copy_skipped = false;
    game_files_changed();
    std::string exefs, romfs;
    bool unusable = false;  // (game packages rather than its files)
    if (src.empty() && check_copied_files(g_root).empty()) {  // copied already (an update needs new game code)
        g_copy_skipped = true;
        if (!build_game_code()) goto done;
        goto check;
    }
    set_job("Looking for the game files...");
    find_game(src, 0, exefs, romfs, unusable);
    if (exefs.empty() || romfs.empty()) { set_failure(unusable ? FAIL_UNUSABLE : FAIL_NOT_FOUND); goto done; }
    if (!build_id_ok(exefs + "/main")) { set_failure(FAIL_VERSION); goto done; }
    if (int have = count_files(romfs); have < ROMFS_FILES) {  // (an incomplete copy: refused before copying it)
        fprintf(stderr, "[launcher] %s: %d of %d romfs files\n", romfs.c_str(), have, (int)ROMFS_FILES);
        set_failure(FAIL_MISSING, have);
        goto done;
    }
    {
        // (the picked folder can't be LAS Recomp's own copy: setting up again deletes that first)
        char a[4096], b[4096];
        mkdir(g_root.c_str(), 0755);
        if (realpath(exefs.c_str(), a) && realpath(g_root.c_str(), b) && !strncmp(a, b, strlen(b)) &&
            (a[strlen(b)] == '/' || a[strlen(b)] == '\\' || !a[strlen(b)])) {
            set_failure(FAIL_NOT_FOUND);
            goto done;
        }
        rt_remove_game_files(g_root.c_str());  // (an earlier or interrupted setup's; removes the folder too)
        game_files_changed();
        mkdir(g_root.c_str(), 0755);
        unsigned long long rbytes = romfs_dir_bytes(romfs.c_str());
        g_total = rbytes;
        set_job("Copying the game files...");
        if (!romfs_copy_tree(exefs.c_str(), (g_root + "/exefs").c_str(), NULL) ||
            !romfs_copy_tree(romfs.c_str(), (g_root + "/romfs").c_str(), setup_progress)) {
            set_failure(FAIL_COPY);
            goto done;
        }
        g_phase_base = rbytes, g_done = rbytes;
        // Retrying a cancelled compilation must use the copied files and their cache.
        pthread_mutex_lock(&g_lock);
        g_src.clear();
        pthread_mutex_unlock(&g_lock);
        if (!build_game_code()) goto done;
    }
check:
    {
        game_files_changed();
        std::string why = check_game_files(g_root);
        if (why.empty()) prepare_shaders();  // (the GPU device is up: the start screen draws with it)
        if (why.empty()) set_job("Game files ready.");
        else if (why.find("version") != std::string::npos) set_failure(FAIL_VERSION);
        else set_failure(FAIL_MISSING, g_romfs_count);
    }
done:
    pthread_mutex_lock(&g_lock);
    g_busy = false;
    pthread_mutex_unlock(&g_lock);
    return NULL;
}
#endif

// ------------------------------------------------------------------ folder dialog (SDL calls back on any thread)
static void SDLCALL picked(void *, const char *const *files, int) {
    if (!files || !files[0]) return;
    pthread_mutex_lock(&g_lock);
    g_src = files[0];
    pthread_mutex_unlock(&g_lock);
}
#ifdef __ANDROID__
static void picked_android(const char *name) {
    if (!name) return;
    const char *const files[] = {name, NULL};
    picked(NULL, files, 0);
    pthread_mutex_lock(&g_lock);
    bool already_busy = g_busy;
    g_busy = true;
    pthread_mutex_unlock(&g_lock);
    if (!already_busy) {
        pthread_t t;
        pthread_create(&t, NULL, extract_thread, NULL);
    }
}
#endif

// ------------------------------------------------------------------ the user's own Nintendo fonts (not shipped)
// runtime/hle/pl.c loads fonts/ first, else a close substitute of the requested language. Import copies recognized
// files only: the console's own names for the shared fonts (Standard, Chinese Simplified / its Ext, Chinese
// Traditional, Korean and NintendoExt).
static const char *FONT_STD[] = {"nintendo_udsg-r_std_003.bfttf", "nintendo_udsg-r_std_003.ttf",
                                 "nintendo_udsgr_std_003.ttf", "nintendo_udsgr_std_003.bfttf"};
static const char *FONT_LANG[] = {"nintendo_udsg-r_org_zh-cn_003.bfttf", "nintendo_udsg-r_org_zh-cn_003.ttf",
                                  "nintendo_udsg-r_ext_zh-cn_003.bfttf", "nintendo_udsg-r_ext_zh-cn_003.ttf",
                                  "nintendo_udjxh-db_zh-tw_003.bfttf", "nintendo_udjxh-db_zh-tw_003.ttf",
                                  "nintendo_udsg-r_ko_003.bfttf", "nintendo_udsg-r_ko_003.ttf"};
static const char *FONT_EXT[] = {"nintendo_ext_003.bfttf", "nintendo_ext_003.ttf"};
static std::vector<std::string> g_font_picks;
static std::string g_font_msg;

static bool have_font(const char *const *names, int n) {
    for (int i = 0; i < n; i++)
        if (file_exists(std::string("fonts/") + names[i])) return true;
    return false;
}

static void SDLCALL picked_fonts(void *, const char *const *files, int) {
    if (!files) return;
    pthread_mutex_lock(&g_lock);
    for (int i = 0; files[i]; i++) g_font_picks.push_back(files[i]);
    pthread_mutex_unlock(&g_lock);
}

// a picked file's own name: Android's picker hands over content:// URIs (their last part an id like "msf:1234")
static std::string picked_name(const std::string &src) {
#ifdef __ANDROID__
    if (!src.compare(0, 10, "content://"))
        if (const char *n = android_display_name(src.c_str())) return n;
#endif
    return src.substr(src.find_last_of("/\\") + 1);  // (Windows paths use '\\' too)
}

// The files inside a zip (font downloads come zipped, and Android has no easy way to unzip): name and contents of each
// stored / deflated entry whose name ends in one of exts. Android only (the system's zlib).
struct PickedFile { std::string name; std::vector<uint8_t> data; };
static void unzip_fonts(const uint8_t *z, size_t n, std::vector<PickedFile> &out) {
#ifdef __ANDROID__
    auto u16 = [&](size_t o) { return o + 2 <= n ? (unsigned)(z[o] | z[o + 1] << 8) : 0u; };
    auto u32 = [&](size_t o) { return o + 4 <= n ? (uint32_t)(z[o] | z[o + 1] << 8 | z[o + 2] << 16 | (uint32_t)z[o + 3] << 24) : 0u; };
    size_t eocd = SIZE_MAX;  // (the end record: in the last 64 KB + 22)
    for (size_t i = n >= 22 ? n - 22 : 0; i + 22 <= n && n - i < 65536 + 22; i--) {
        if (u32(i) == 0x06054b50) { eocd = i; break; }
        if (!i) break;
    }
    if (eocd == SIZE_MAX) return;
    size_t cd = u32(eocd + 16), count = u16(eocd + 10);
    for (size_t k = 0; k < count && cd + 46 <= n && u32(cd) == 0x02014b50; k++) {
        unsigned method = u16(cd + 10), nl = u16(cd + 28), xl = u16(cd + 30), cl = u16(cd + 32);
        uint32_t csize = u32(cd + 20), usize = u32(cd + 24), loc = u32(cd + 42);
        std::string name((const char *)z + cd + 46, cd + 46 + nl <= n ? nl : 0);
        cd += 46 + nl + xl + cl;
        std::string low = name.substr(name.find_last_of('/') + 1);
        for (auto &c : low) c = (char)tolower((unsigned char)c);
        size_t dot = low.find_last_of('.');
        std::string ext = dot == std::string::npos ? "" : low.substr(dot);
        if (ext != ".ttf" && ext != ".otf" && ext != ".bfttf") continue;
        if (usize > (64u << 20) || loc + 30 > n || u32(loc) != 0x04034b50) continue;
        size_t at = loc + 30 + u16(loc + 26) + u16(loc + 28);
        if (at + csize > n) continue;
        PickedFile f{name.substr(name.find_last_of('/') + 1), std::vector<uint8_t>(usize)};
        if (method == 0 && csize == usize) {
            memcpy(f.data.data(), z + at, usize);
        } else if (method == 8) {
            z_stream st = {};
            if (inflateInit2(&st, -MAX_WBITS) != Z_OK) continue;
            st.next_in = (Bytef *)(z + at), st.avail_in = csize;
            st.next_out = f.data.data(), st.avail_out = usize;
            int r = inflate(&st, Z_FINISH);
            inflateEnd(&st);
            if (r != Z_STREAM_END || st.total_out != usize) continue;
        } else continue;
        out.push_back(std::move(f));
    }
#else
    (void)z, (void)n, (void)out;
#endif
}

static void import_fonts() {
    pthread_mutex_lock(&g_lock);
    std::vector<std::string> picks;
    picks.swap(g_font_picks);
    pthread_mutex_unlock(&g_lock);
    if (picks.empty()) return;
    mkdir("fonts", 0755);
    int ok = 0, unknown = 0, unreadable = 0;
    std::vector<PickedFile> files;  // (the picked files, a zip's fonts in its place)
    for (auto &src : picks) {
        size_t size = 0;
        uint8_t *data = (uint8_t *)SDL_LoadFile(src.c_str(), &size);  // (SDL_IOFromFile: paths and content:// URIs)
        if (!data) { unreadable++; continue; }
        if (size > 4 && !memcmp(data, "PK\x03\x04", 4)) {
            size_t before = files.size();
            unzip_fonts(data, size, files);
            if (files.size() == before) unknown++;
        } else {
            files.push_back({picked_name(src), std::vector<uint8_t>(data, data + size)});
        }
        SDL_free(data);
    }
    for (auto &f : files) {
        std::string low = f.name;
        for (auto &c : low) c = (char)tolower((unsigned char)c);
        const char *const *group = NULL;
        int gn = 0;
        for (auto n : FONT_STD) if (low == n) group = FONT_STD, gn = 4;
        for (auto n : FONT_LANG) if (low == n) group = FONT_LANG, gn = 8;
        for (auto n : FONT_EXT) if (low == n) group = FONT_EXT, gn = 2;
        const uint8_t *d = f.data.data();
        bool font = f.data.size() > 4 && (!memcmp(d, "\x00\x01\x00\x00", 4) || !memcmp(d, "OTTO", 4) ||
                                          !memcmp(d, "true", 4) || !memcmp(d, "ttcf", 4));
        if (!group && font && files.size() == 1) {  // one font under another name: the game's text font
            group = FONT_STD, gn = 4;
            low = "nintendo_udsg-r_std_003.ttf";
        }
        if (!group) { unknown++; continue; }
        if (group != FONT_LANG)  // (one file per role: the one just picked replaces the other spellings)
            for (int i = 0; i < gn; i++) unlink((std::string("fonts/") + group[i]).c_str());
        FILE *out = fopen(("fonts/" + low).c_str(), "wb");
        if (out && fwrite(f.data.data(), 1, f.data.size(), out) == f.data.size()) ok++;
        else unreadable++;
        if (out) fclose(out);
    }
    std::string m = std::to_string(ok) + T(" font file(s) imported");
    if (unknown) m += ", " + std::to_string(unknown) + T(" not recognized (pick one font, or the files by their Switch names)");
    if (unreadable) m += ", " + std::to_string(unreadable) + T(" couldn't be read");
    g_font_msg = m + (ok ? T(". Used from the next game start.") : ".");
    fprintf(stderr, "[launcher] fonts: %s\n", g_font_msg.c_str());
}

static void remove_fonts() {
    for (auto n : FONT_STD) unlink((std::string("fonts/") + n).c_str());
    for (auto n : FONT_LANG) unlink((std::string("fonts/") + n).c_str());
    for (auto n : FONT_EXT) unlink((std::string("fonts/") + n).c_str());
    g_font_msg = "Imported fonts removed: the substitute fonts are used.";
}

// ------------------------------------------------------------------ background: a title movie frame
#ifdef __APPLE__
static id<MTLTexture> g_bg;
#define BG_TEXID ((ImTextureID)(__bridge void *)g_bg)
typedef id<MTLDevice> GpuDevice;
#else
static uint64_t g_bg;  // ImGui texture id (Vulkan descriptor set)
#define BG_TEXID ((ImTextureID)g_bg)
typedef void *GpuDevice;
#endif
static int g_bg_w, g_bg_h;

// ------------------------------------------------------------------ the game's own artwork (its control section)
// The home menu's icon and the game's real title, from <root>/control: control.nacp and icon.rgba (the icon as
// LasActivity.artworkFrom decoded it, the JPEG in the package). Taken along by the package import; for game files set
// up before that, once in the background from the package picked then (android_import_artwork).
static uint64_t g_icon;  // ImGui texture id, 0: none (Vulkan; the Metal start screen keeps the movie still)
static std::atomic<int> g_art_job{0};  // 0 not asked, 1 extracting, 2 extracted (load it), 3 done / not possible

static std::string game_dir_abs(void) {
    return g_root[0] == '/' ? g_root : std::string(rt_data_root()) + "/" + g_root;
}

static void load_artwork(void) {
    std::string dir = game_dir_abs() + "/control";
    if (FILE *f = fopen((dir + "/control.nacp").c_str(), "rb")) {  // 16 x {name[0x200], publisher[0x100]}, AmE first
        char name[0x201] = {0};
        for (int lang = 0; lang < 16 && !name[0]; lang++)
            if (fseek(f, lang * 0x300, SEEK_SET) != 0 || fread(name, 1, 0x200, f) != 0x200) name[0] = 0;
        fclose(f);
        name[0x200] = 0;
        if (name[0]) g_game_title = name;
    }
#ifndef __APPLE__
    if (g_icon) return;
    FILE *f = fopen((dir + "/icon.rgba").c_str(), "rb");
    if (!f) return;
    int32_t wh[2] = {0, 0};
    if (fread(wh, 4, 2, f) == 2 && wh[0] > 0 && wh[1] > 0 && wh[0] <= 1024 && wh[1] <= 1024) {
        std::vector<uint8_t> px((size_t)wh[0] * wh[1] * 4);
        if (fread(px.data(), 1, px.size(), f) == px.size()) g_icon = vk_imgui_texture_rgba(px.data(), wh[0], wh[1]);
    }
    fclose(f);
#endif
}

#ifdef __ANDROID__
static void *artwork_thread(void *) {
    const char *err = android_import_artwork((game_dir_abs() + "/control").c_str());
    fprintf(stderr, "[launcher] game artwork: %s\n", err ? err : "extracted");
    g_art_job = err ? 3 : 2;
    return NULL;
}
#endif

static void load_background(GpuDevice dev) {
    std::string path = g_root + "/romfs/region_common/movie/title.webm";
    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, path.c_str(), NULL, NULL) < 0) return;
    int si = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (si >= 0 && avformat_find_stream_info(fmt, NULL) >= 0) {
        AVStream *st = fmt->streams[si];
        const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
        AVCodecContext *cc = avcodec_alloc_context3(codec);
        avcodec_parameters_to_context(cc, st->codecpar);
        if (codec && avcodec_open2(cc, codec, NULL) == 0) {
            AVPacket *pkt = av_packet_alloc();
            AVFrame *fr = av_frame_alloc();
            int64_t want = (int64_t)(6.0 / av_q2d(st->time_base));  // a few seconds in: the island, not black
            av_seek_frame(fmt, si, want, AVSEEK_FLAG_BACKWARD);
            bool got = false;
            while (!got && av_read_frame(fmt, pkt) >= 0) {
                if (pkt->stream_index == si && avcodec_send_packet(cc, pkt) == 0)
                    while (avcodec_receive_frame(cc, fr) == 0)
                        if (fr->best_effort_timestamp >= want) { got = true; break; }
                av_packet_unref(pkt);
            }
            if (got) {
                int w = fr->width, h = fr->height;
                std::vector<uint8_t> rgba((size_t)w * h * 4);
                SwsContext *sws = sws_getContext(w, h, (AVPixelFormat)fr->format, w, h, AV_PIX_FMT_RGBA, SWS_BILINEAR, NULL, NULL, NULL);
                uint8_t *dst[1] = {rgba.data()};
                int dst_ls[1] = {w * 4};
                sws_scale(sws, fr->data, fr->linesize, 0, h, dst, dst_ls);
                sws_freeContext(sws);
#ifdef __APPLE__
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                              width:w height:h mipmapped:NO];
                g_bg = [dev newTextureWithDescriptor:td];
                [g_bg replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:rgba.data() bytesPerRow:w * 4];
#else
                (void)dev;
                g_bg = vk_imgui_texture_rgba(rgba.data(), w, h);
#endif
                g_bg_w = w, g_bg_h = h;
            }
            av_frame_free(&fr);
            av_packet_free(&pkt);
        }
        avcodec_free_context(&cc);
    }
    avformat_close_input(&fmt);
}

// ------------------------------------------------------------------ seeds
static std::vector<std::string> list_seeds() {
    std::vector<std::string> out;
    if (DIR *d = opendir("rando")) {
        while (struct dirent *e = readdir(d)) {
            if (e->d_name[0] == '.') continue;
            std::string dir = std::string("rando/") + e->d_name;
            if (file_exists(dir + "/settings.json") && file_exists(dir + "/romfs")) out.push_back(e->d_name);
        }
        closedir(d);
    }
    std::sort(out.begin(), out.end());
    return out;
}

// ------------------------------------------------------------------ screen
static ImFont *g_font_title, *g_font_menu, *g_font_small;
// MAIN: the home screen (game tiles). The selected game's pages, one per sidebar entry: SETTINGS (the in-game menu's
// tabs, runtime/ui/menu.mm), PLAYMODE (vanilla / a seed), SETUP (its game files), INFO. SYSTEM: System Settings.
enum Page { MAIN, SETTINGS, SETUP, PLAYMODE, INFO, SYSTEM };
static HzHomeState g_home;  // the home screen's selection (g_home.sel: index into g_library, the pages' game)

void menu_tabs_draw(float scale, ImFont *font, ImFont *font_big, bool in_game, void (*prelaunch)(float));  // menu.mm
void menu_tabs_focus(bool first_tab);
extern int g_tab_request_ext;
extern "C" void menu_apply_window_requests(void *sdl_window);
extern "C" int g_start_screen;  // runtime/hle/warp.c: the start screen is up (no game loaded: don't read its memory)
// The Randomizer tab's Play / Play Now on the start screen (rando_tab.mm): start the game with that seed
static std::string g_play_seed;
static bool g_play_seed_req;  // (g_play_pending: with the setup state above)
extern "C" void launcher_play_seed(const char *seed) {
    g_play_seed = seed ? seed : "";
    g_play_seed_req = true;
}

// The first PLAY ever (settings.menu_tip_seen): a note on opening the LAS Recomp menu in game (it isn't obvious),
// OK starts the game. Returns true once OK is pressed.
static bool g_tip_test;  // (LARECOMP_LAUNCHER_SHOT=<frame>:tip)
// First PLAY ever, before the menu note: authentic 16:9 or the unlocked (fill the window) aspect ratio.
static bool aspect_prompt(float s) {
    bool done = false;
    ImVec2 ds = ImGui::GetIO().DisplaySize;
    ImGui::SetNextWindowPos(ImVec2(ds.x * 0.5f, ds.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(fminf(ds.x * 0.8f, 760 * s), 0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(36 * s, 28 * s));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 16 * s);
    ImGui::PushStyleColor(ImGuiCol_PopupBg, ImVec4(0.03f, 0.04f, 0.05f, 0.94f));
    bool open = ImGui::BeginPopupModal("##aspect", NULL, ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                                       ImGuiWindowFlags_NoMove | ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::PopStyleColor();
    ImGui::PopStyleVar(2);
    if (open) {
        ImGui::SetWindowFontScale(1.25f);
        ImGui::PushTextWrapPos(0);
        ImGui::TextUnformatted(T("How would you like to play?"));
        ImGui::Spacing();
        ImGui::TextDisabled("%s", T("You can change this any time in Settings."));
        ImGui::PopTextWrapPos();
        ImGui::Dummy(ImVec2(0, 14 * s));
        float bw = 300 * s, gap = 20 * s;
        ImGui::SetCursorPosX((ImGui::GetWindowWidth() - 2 * bw - gap) * 0.5f);
        int pick = -1;
        ImGui::SetItemDefaultFocus();
        if (ImGui::Button(T("Authentic 16:9"), ImVec2(bw, 44 * s))) pick = ASPECT_ORIGINAL;
        ImGui::SameLine(0, gap);
        if (ImGui::Button(T("Unlocked (fill the screen)"), ImVec2(bw, 44 * s))) pick = ASPECT_UNLOCKED;
        if (pick >= 0) {
            g_settings.aspect = pick;
            g_settings.aspect_asked = true;
            settings_save();
            ImGui::CloseCurrentPopup();
            done = true;
        }
        ImGui::EndPopup();
    }
    return done;
}

static bool menu_tip(float s) {
    bool go = false;
    ImVec2 ds = ImGui::GetIO().DisplaySize;
    ImGui::SetNextWindowPos(ImVec2(ds.x * 0.5f, ds.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(fminf(ds.x * 0.8f, 760 * s), 0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(36 * s, 28 * s));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 16 * s);
    ImGui::PushStyleColor(ImGuiCol_PopupBg, ImVec4(0.03f, 0.04f, 0.05f, 0.94f));
    bool open = ImGui::BeginPopupModal("##menutip", NULL, ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                                       ImGuiWindowFlags_NoMove | ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::PopStyleColor();
    ImGui::PopStyleVar(2);
    if (open) {
        ImGui::SetWindowFontScale(1.25f);
        // the controller's home button first (what players reach for: the PS button on a DualSense), the combo second
        static const char *const home[] = {"Home button", "Xbox button", "PlayStation button"};  // (bind_label_family)
        static const char *const pad[] = {"Minus + Plus", "View + Menu", "Create + Options"};
        ImGui::PushTextWrapPos(0);
        ImGui::TextUnformatted(T("LAS Recomp has its own menu for settings, the randomizer, cosmetics and more."));
        ImGui::Spacing();
        int fam = bind_label_family() % 3;
#ifdef __ANDROID__
        ImGui::Text(T("Open it in game with the menu button at the top of the screen, or on a controller with the %s (or "
                      "%s together)."), T(home[fam]), T(pad[fam]));
#else
        ImGui::Text(T("Open it in game with F1 or Esc, or on a controller with the %s (or %s together)."), T(home[fam]), T(pad[fam]));
#endif
        ImGui::PopTextWrapPos();
        ImGui::Dummy(ImVec2(0, 14 * s));
        ImGui::SetCursorPosX((ImGui::GetWindowWidth() - 180 * s) * 0.5f);
        ImGui::SetItemDefaultFocus();
        if (ImGui::Button("OK", ImVec2(180 * s, 44 * s)) || ImGui::IsKeyPressed(ImGuiKey_Enter) ||
            ImGui::IsKeyPressed(ImGuiKey_GamepadFaceDown)) {
            g_settings.menu_tip_seen = true;
            settings_save();
            ImGui::CloseCurrentPopup();
            go = true;
        }
        ImGui::EndPopup();
    }
    return go;
}

// Controllers, as in the in-game menu (runtime/ui/menu.mm): read straight from SDL, confirm / back as the Confirm
// button setting says (pad_nav.h: the game's layout, or the controller's convention); d-pad / left stick move.
// (ImGui's own SDL gamepad handling is switched off: per the user, it didn't work on the start screen.)

static void launcher_pad_open_all(void) {
    int n = 0;
    SDL_JoystickID *ids = SDL_GetGamepads(&n);
    for (int i = 0; ids && i < n; i++) SDL_OpenGamepad(ids[i]);
    SDL_free(ids);
}

// true when the event was a controller event (handled here)
static bool launcher_pad_event(const SDL_Event &e) {
    ImGuiIO &io = ImGui::GetIO();
    switch (e.type) {
    case SDL_EVENT_GAMEPAD_ADDED:
        SDL_OpenGamepad(e.gdevice.which);
        io.BackendFlags |= ImGuiBackendFlags_HasGamepad;
        return true;
    case SDL_EVENT_GAMEPAD_BUTTON_DOWN: case SDL_EVENT_GAMEPAD_BUTTON_UP: {
        ImGuiKey k = ui_pad_key(e.gbutton.which, e.gbutton.button, e.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN);
        if (k != ImGuiKey_None) io.AddKeyEvent(k, e.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN);
        return true;
    }
    case SDL_EVENT_GAMEPAD_AXIS_MOTION: {
        float v = e.gaxis.value / 32767.0f;
        // the left stick also works as the d-pad (ImGui moves between items with the d-pad only; the stick scrolls):
        // pressed past half way, released under 0.3
        if (e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTX || e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTY) {
            static bool held[4];  // left, right, up, down
            bool x = e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTX;
            int neg = x ? 0 : 2, pos = neg + 1;
            const ImGuiKey keys[4] = {ImGuiKey_GamepadDpadLeft, ImGuiKey_GamepadDpadRight, ImGuiKey_GamepadDpadUp,
                                      ImGuiKey_GamepadDpadDown};
            for (int i : {neg, pos}) {
                float m = i == neg ? -v : v;
                bool now = held[i] ? m > 0.3f : m > 0.5f;
                if (now != held[i]) { held[i] = now; io.AddKeyEvent(keys[i], now); }
            }
        }
        if (e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTX) {
            io.AddKeyAnalogEvent(ImGuiKey_GamepadLStickLeft, v < -0.3f, v < -0.3f ? -v : 0);
            io.AddKeyAnalogEvent(ImGuiKey_GamepadLStickRight, v > 0.3f, v > 0.3f ? v : 0);
        } else if (e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTY) {
            io.AddKeyAnalogEvent(ImGuiKey_GamepadLStickUp, v < -0.3f, v < -0.3f ? -v : 0);
            io.AddKeyAnalogEvent(ImGuiKey_GamepadLStickDown, v > 0.3f, v > 0.3f ? v : 0);
        }
        return true;
    }
    default: return false;
    }
}

// Returns when PLAY is chosen (seed stored in g_settings.rando_seed); QUIT exits.
// Settings' first tab, on the start screen only: the extracted game files (size, delete) and the user's own Switch
// fonts (import / back to the substitute)
// Open a folder in Finder / Explorer (relative paths are in the data root, the working directory)
static void reveal_folder(const std::string &dir) {
    std::string path = dir;
    bool abs = !path.empty() && (path[0] == '/' || path[0] == '\\' || (path.size() > 1 && path[1] == ':'));
    if (!abs) path = std::string(rt_data_root()) + "/" + path;
    std::string url = "file://";
    if (path[0] != '/') url += "/";  // (Windows: file:///C:/...)
    for (char ch : path) {
        if (ch == '\\') ch = '/';
        if (ch == ' ') url += "%20";
        else if (ch == '%') url += "%25";
        else if (ch == '#') url += "%23";
        else url += ch;
    }
    SDL_OpenURL(url.c_str());
}

static SDL_Window *g_launcher_win;
// The progress overlay in front of the start screen (input waits): the setup, an update's build, or the shader
// preparation (with Skip) - the setup's, or the background one when PLAY was pressed before it finished
static void draw_busy_overlay(ImVec2 ds, const std::string &job, bool test_busy, bool prep_wait = false) {
    float sc = ds.y / 1080.0f;
    ImDrawList *fg = ImGui::GetForegroundDrawList();
    ImVec2 o = ImGui::GetMainViewport()->Pos;
    if (!g_auto_update) fg->AddRectFilled(o, ImVec2(o.x + ds.x, o.y + ds.y), IM_COL32(0, 0, 0, 170));  // (an update: plain)
    float f = test_busy && g_prep_frac < 0 ? 0.42f : prep_wait && g_prep_frac < 0 ? 0.99f : extract_progress();
    // (while the game code is built: what's happening, on whose files - runtime/gamebuild.c)
    bool preparing = g_prep_frac >= 0 || prep_wait, recompiling = g_build_frac >= 0 && !preparing;
    const char *title = T(preparing ? "Preparing shaders" : g_auto_update ? "Updating the game"
                          : recompiling ? "Recompiling the game" : "Setting up the game files");
#ifdef __ANDROID__  // (an hour or so on a phone: it goes on with the screen off - BuildService)
    const char *notes[] = {T("This only needs to be done once and may take a while. You can turn the screen off.")};
#else
    const char *notes[] = {T("This only needs to be done once and may take a while.")};
#endif
    int nnotes = recompiling && !g_auto_update ? 1 : 0;
    float tfs = g_font_menu->FontSize * 0.75f, sfs = g_font_small->FontSize * 0.85f;
    ImVec2 ts = g_font_menu->CalcTextSizeA(tfs, FLT_MAX, 0, title);
    float line_h = g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, "A").y;
    float pw = fminf(ds.x * 0.6f, 900 * sc), bar_y = 36 * sc + ts.y + 30 * sc;
    for (int i = 0; i < nnotes; i++)  // (wide enough for its text, within the window)
        pw = fmaxf(pw, g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, notes[i]).x + 96 * sc);
    pw = fminf(fmaxf(pw, ts.x + 96 * sc), ds.x - 32 * sc);
    float ph = bar_y + 24 * sc + 26 * sc + line_h + (nnotes ? 14 * sc + nnotes * line_h : 0) + 40 * sc +
               (preparing ? line_h + 28 * sc : recompiling ? 54 * sc : 0);  // (Skip / Cancel)
    ImVec2 a(o.x + (ds.x - pw) * 0.5f, o.y + (ds.y - ph) * 0.5f), b(a.x + pw, a.y + ph);
    fg->AddRectFilled(a, b, IM_COL32(28, 30, 36, 250), 14 * sc);
    fg->AddRect(a, b, IM_COL32(0, 200, 230, 140), 14 * sc, 0, 1.5f * sc);
    fg->AddText(g_font_menu, tfs, ImVec2((a.x + b.x - ts.x) * 0.5f, a.y + 36 * sc), IM_COL32(0, 200, 230, 255), title);
    ImVec2 ba(a.x + 48 * sc, a.y + bar_y), bb(b.x - 48 * sc, a.y + bar_y + 24 * sc);
    fg->AddRectFilled(ba, bb, IM_COL32(255, 255, 255, 25), 12 * sc);
    if (f > 0) fg->AddRectFilled(ba, ImVec2(ba.x + (bb.x - ba.x) * f, bb.y), IM_COL32(0, 200, 230, 255), 12 * sc);
    char line[200];
    if (preparing) snprintf(line, sizeof line, "%d%%", (int)(f * 100));  // (the title says it)
    else {
        std::string e = recompiling ? eta_text() : "";  // (time left: a build only)
        snprintf(line, sizeof line, "%s   %d%%%s%s", T(test_busy ? "Setting up the game files..." : job.c_str()),
                 (int)(f * 100), e.empty() ? "" : "   ", e.c_str());
    }
    ImVec2 ls = g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, line);
    fg->AddText(g_font_small, sfs, ImVec2((a.x + b.x - ls.x) * 0.5f, bb.y + 26 * sc), IM_COL32(220, 216, 205, 255), line);
    for (int i = 0; i < nnotes; i++) {
        ImVec2 ns = g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, notes[i]);
        fg->AddText(g_font_small, sfs, ImVec2((a.x + b.x - ns.x) * 0.5f, bb.y + 26 * sc + (i + 1) * line_h + 14 * sc),
                    IM_COL32(150, 148, 140, 255), notes[i]);
    }
    if (recompiling) {  // Shader preparation has its own Skip action; cancellation only stops the game-code build.
        ImVec2 ca((a.x + b.x) * 0.5f - 150 * sc, b.y - 66 * sc), cb(ca.x + 300 * sc, ca.y + 44 * sc);
        bool hover = !g_cancel_build && ImGui::IsMouseHoveringRect(ca, cb, false);
        fg->AddRectFilled(ca, cb, hover ? IM_COL32(70, 76, 86, 255) : IM_COL32(52, 56, 64, 255), 8 * sc);
        const char *cancel = g_cancel_build ? "Cancelling..." : "Cancel";  // (B / Circle and Esc too)
        ImVec2 cs = g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, cancel);
        fg->AddText(g_font_small, sfs, ImVec2((ca.x + cb.x - cs.x) * 0.5f, (ca.y + cb.y - cs.y) * 0.5f),
                    IM_COL32(0, 200, 230, 255), cancel);
        if ((hover && ImGui::IsMouseClicked(ImGuiMouseButton_Left)) ||
            ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false))
            g_cancel_build = true;
    }
    if (preparing) {  // Skip: the game then compiles what it needs as it goes (back / Esc too)
        const char *sk = g_prep_skip ? "Skipping..." : "Skip";
        ImVec2 ks = g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, sk);
        ImVec2 ka((a.x + b.x - ks.x) * 0.5f - 22 * sc, b.y - 40 * sc - line_h - 10 * sc);
        ImVec2 kb(ka.x + ks.x + 44 * sc, ka.y + line_h + 16 * sc);
        bool hover = !g_prep_skip && !g_prep_skip_ask && ImGui::IsMouseHoveringRect(ka, kb, false);
        fg->AddRect(ka, kb, IM_COL32(0, 200, 230, hover ? 255 : 140), 8 * sc, 0, 1.5f * sc);
        fg->AddText(g_font_small, sfs, ImVec2(ka.x + 22 * sc, ka.y + 8 * sc),
                    hover ? IM_COL32(0, 200, 230, 255) : IM_COL32(220, 216, 205, 255), sk);
        if (!g_prep_skip && !g_prep_skip_ask &&
            ((hover && ImGui::IsMouseClicked(ImGuiMouseButton_Left)) ||
             ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false)))
            g_prep_skip_ask = true;
    }
    if (preparing && g_prep_skip_ask && !g_prep_skip) {  // what Skip means, before it happens
        const char *q = "Shaders will compile as you play, but you may experience some pop-in.";
        const char *yes = "Yes, skip", *no = "No, wait";
        ImVec2 qs = g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, q);
        ImVec2 ys = g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, yes), ns = g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, no);
        float bw = fmaxf(ys.x, ns.x) + 64 * sc, bh = line_h + 20 * sc, gap = 24 * sc;
        float qw = fminf(fmaxf(qs.x, 2 * bw + gap) + 96 * sc, ds.x - 32 * sc), qh = 40 * sc + line_h + 32 * sc + bh + 36 * sc;
        fg->AddRectFilled(a, b, IM_COL32(0, 0, 0, 120), 14 * sc);  // (the bar behind it dimmed)
        ImVec2 qa(o.x + (ds.x - qw) * 0.5f, o.y + (ds.y - qh) * 0.5f), qb(qa.x + qw, qa.y + qh);
        fg->AddRectFilled(qa, qb, IM_COL32(28, 30, 36, 255), 14 * sc);
        fg->AddRect(qa, qb, IM_COL32(0, 200, 230, 200), 14 * sc, 0, 1.5f * sc);
        fg->AddText(g_font_small, sfs, ImVec2((qa.x + qb.x - qs.x) * 0.5f, qa.y + 40 * sc), IM_COL32(236, 232, 220, 255), q);
        float by = qb.y - 36 * sc - bh, bx = (qa.x + qb.x) * 0.5f;
        ImVec2 ya(bx - gap * 0.5f - bw, by), yb(bx - gap * 0.5f, by + bh), na(bx + gap * 0.5f, by), nb(bx + gap * 0.5f + bw, by + bh);
        bool hy = ImGui::IsMouseHoveringRect(ya, yb, false), hn = ImGui::IsMouseHoveringRect(na, nb, false);
        fg->AddRect(ya, yb, IM_COL32(0, 200, 230, hy ? 255 : 140), 8 * sc, 0, 1.5f * sc);
        fg->AddRectFilled(na, nb, IM_COL32(0, 200, 230, hn ? 255 : 210), 8 * sc);  // (waiting: the default)
        fg->AddText(g_font_small, sfs, ImVec2((ya.x + yb.x - ys.x) * 0.5f, ya.y + 10 * sc),
                    hy ? IM_COL32(0, 200, 230, 255) : IM_COL32(220, 216, 205, 255), yes);
        fg->AddText(g_font_small, sfs, ImVec2((na.x + nb.x - ns.x) * 0.5f, na.y + 10 * sc), IM_COL32(28, 30, 36, 255), no);
        bool click = ImGui::IsMouseClicked(ImGuiMouseButton_Left);
        // A / Enter: the highlighted default (wait); B / Esc: also wait; Yes only by clicking it or Y / Space
        if ((hy && click) || ImGui::IsKeyPressed(ImGuiKey_GamepadFaceUp, false) || ImGui::IsKeyPressed(ImGuiKey_Space, false))
            g_prep_skip = 1, g_prep_skip_ask = false;
        else if ((hn && click) || ImGui::IsKeyPressed(ImGuiKey_GamepadFaceDown, false) ||
                 ImGui::IsKeyPressed(ImGuiKey_Enter, false) || ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) ||
                 ImGui::IsKeyPressed(ImGuiKey_Escape, false))
            g_prep_skip_ask = false;
    }
}

static bool g_files_deleted;  // set here: the start screen goes back to setting the game files up

// ---- System Settings (the home screen's gear): what isn't one game's - keys, fonts, updates, about
static const char *const SYS_SECTIONS[] = {
#ifdef __ANDROID__
    "Decryption keys",
#endif
    "Fonts", "Updates", "About"};
enum { SYS_N = sizeof SYS_SECTIONS / sizeof SYS_SECTIONS[0] };
static int g_sys_section;

static void sys_heading(const char *t) {
    ImGui::PushFont(g_font_menu);
    ImGui::TextColored(ImVec4(1, 1, 1, 1), "%s", T(t));
    ImGui::PopFont();
    ImGui::Separator();
    ImGui::Spacing();
}

static void sys_section_draw(const char *name) {
    const ImVec4 ok(0.4f, 0.9f, 0.5f, 1), bad(1, 0.55f, 0.45f, 1);
    ImGui::PushTextWrapPos(0);
    if (!strcmp(name, "Decryption keys")) {
#ifdef __ANDROID__
        sys_heading("Decryption keys (prod.keys)");
        bool have = android_has_prod_keys();
        ImGui::TextColored(have ? ok : bad, "%s", T(have ? "prod.keys installed" : "prod.keys not found"));
        ImGui::TextDisabled("%s", T("Your console's prod.keys decrypts your own game package (.xci / .nsp) when the game "
                                    "files are set up. It stays on this phone."));
        ImGui::Spacing();
        if (ImGui::Button(T(have ? "Replace prod.keys" : "Import prod.keys"))) android_pick_prod_keys();
#endif
    } else if (!strcmp(name, "Fonts")) {
        sys_heading("Game font");
        import_fonts();
        bool fs = have_font(FONT_STD, 4), fl = have_font(FONT_LANG, 8), fe = have_font(FONT_EXT, 2);
        ImGui::Text(T("Text: %s"), T(fs ? "Nintendo font (imported)" : "substitute (this OS's, per language)"));
        ImGui::Text(T("Chinese / Korean: %s"), T(fl ? "Nintendo font (imported)" : "substitute"));
        ImGui::Text(T("Button icons: %s"), T(fe ? "imported" : "substitute"));
        ImGui::Spacing();
        ImGui::TextDisabled("%s", T("Fonts aren't included. For the original look, import your own copies of "
                                  "nintendo_udsg-r_std_003.bfttf (text), the same-named files for Chinese and Korean "
                                  "(nintendo_udsg-r_org_zh-cn_003, nintendo_udsg-r_ext_zh-cn_003, nintendo_udjxh-db_zh-tw_003, "
                                  "nintendo_udsg-r_ko_003) and nintendo_ext_003.bfttf (button icons). "
                                  ".ttf versions with the same names work too, and a single other .ttf / .otf font is used for the text."));
        if (!g_font_msg.empty()) ImGui::Text("%s", T(g_font_msg.c_str()));
        ImGui::Spacing();
#ifdef __ANDROID__  // (Android maps filters to MIME types: .bfttf has none, and the picker would grey it out)
        static const SDL_DialogFileFilter *font_f = NULL;
        const int font_nf = 0;
#else
        static const SDL_DialogFileFilter font_f[] = {{"Switch fonts", "bfttf;ttf;otf"}};
        const int font_nf = 1;
#endif
        if (ImGui::Button(T("Import fonts"))) SDL_ShowOpenFileDialog(picked_fonts, NULL, g_launcher_win, font_f, font_nf, NULL, true);
        if (fs || fl || fe) {
            ImGui::SameLine();
            if (ImGui::Button(T("Use substitute font"))) remove_fonts();
        }
    } else if (!strcmp(name, "Updates")) {
        sys_heading("Updates");
        ImGui::Text(T("This version: %s"), tag_label(LARECOMP_VERSION, false).c_str());
        pthread_mutex_lock(&g_update_lock);
        std::string upd = g_update_tag;
        pthread_mutex_unlock(&g_update_lock);
        ImGui::Spacing();
        if (getenv("LARECOMP_NO_UPDATE_CHECK")) {
            ImGui::TextDisabled("%s", T("The update check is turned off (LARECOMP_NO_UPDATE_CHECK)."));
        } else if (!upd.empty()) {
            ImGui::TextColored(ok, T("%s is available."), tag_label(upd, true).c_str());
            ImGui::Spacing();
            if (ImGui::Button(T("Open the release page"))) SDL_OpenURL((RELEASE_PAGE + upd).c_str());
        } else {
            ImGui::TextDisabled("%s", T("No newer release was found when the app started (or it couldn't check: offline)."));
        }
    } else if (!strcmp(name, "About")) {
        sys_heading("About");
        ImGui::Text("%s", tag_label(LARECOMP_VERSION, true).c_str());
        ImGui::Spacing();
        ImGui::TextDisabled("%s", T("Static recompilations of Nintendo Switch games, running natively - not emulation. "
                                  "No game files are included: every game is built on this device from your own copy."));
        ImGui::Spacing();
        ImGui::Text(T("Data folder: %s"), rt_data_root());
#if !defined(__ANDROID__)
        ImGui::Spacing();
        if (ImGui::Button(T("Open the data folder"))) reveal_folder(rt_data_root());
#endif
    }
    ImGui::PopTextWrapPos();
}

extern "C" void launcher_run(const char *root) {
    g_root = root;
#ifdef __ANDROID__
    if (g_src.empty() && check_copied_files(g_root) != "") {  // (the folder picked last time, if setup isn't done)
        const char *saved = android_saved_game_folder();
        if (saved) g_src = saved;
    }
#endif
    g_start_screen = 1;
    static bool update_checked;  // (once per launch, not again after a "Title screen" reboot)
    if (!update_checked && !getenv("LARECOMP_NO_UPDATE_CHECK")) {
        update_checked = true;
        pthread_t t;
        if (pthread_create(&t, NULL, update_thread, NULL) == 0) pthread_detach(t);
    }
    ui_window_init();
    SDL_Window *win = ui_window();
    g_launcher_win = win;
#ifdef __APPLE__
    CAMetalLayer *layer = (__bridge CAMetalLayer *)ui_metal_layer();
    id<MTLDevice> dev = (__bridge id<MTLDevice>)ui_metal_device();
    id<MTLCommandQueue> queue = [dev newCommandQueue];
#else
    GpuDevice dev = NULL;
#endif

    IMGUI_CHECKVERSION();
    ImGuiContext *prev_ctx = ImGui::GetCurrentContext();  // the in-game menu's, when back here after a reboot
    ImGuiContext *ctx = ImGui::CreateContext();
    ImGui::SetCurrentContext(ctx);
    ImGuiIO &io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard | ImGuiConfigFlags_NavEnableGamepad;
    io.IniFilename = NULL;
    // fonts belong to this context: back here via "Title screen" (in-place reboot) the previous run's are gone with
    // its context, so load them again (a stale pointer here aborted in PushFont - user, 0.1 RC)
    g_font_small = g_font_menu = g_font_title = NULL;
    // Baloo 2 SemiBold (OFL, shipped: third_party/fonts/Baloo2) - rounded, game-like; it runs small, hence the sizes
    char baloo[1024];
    std::string own = rt_resource("Baloo2-SemiBold.ttf", "third_party/fonts/Baloo2/Baloo2-SemiBold.ttf", baloo, sizeof baloo) ? baloo : "";
    const char *fonts[] = {getenv("LARECOMP_LAUNCHER_FONT") ? getenv("LARECOMP_LAUNCHER_FONT") : "",  // (test)
                           own.c_str(), "fonts/nintendo_udsgr_std_003.ttf", "/System/Library/Fonts/Avenir Next.ttc",
                           "/System/Library/Fonts/Helvetica.ttc", "C:/Windows/Fonts/segoeui.ttf"};
    static const ImWchar ranges[] = {0x20, 0xFF, 0x2018, 0x201D, 0x2039, 0x203A, 0x2122, 0x2122, 0x2192, 0x2192, 0x2713, 0x2713, 0x25B8, 0x25B8, 0};  // + ‹ › → ✓ ▸
    for (const char *p : fonts) {
        if (g_font_menu || !*p || !file_exists(p)) continue;
        bool b2 = p == own.c_str() || getenv("LARECOMP_LAUNCHER_FONT");
        g_font_small = io.Fonts->AddFontFromFileTTF(p, 30 * (b2 ? 1.75f : 1), NULL, ranges);
        g_font_menu = io.Fonts->AddFontFromFileTTF(p, 52 * (b2 ? 1.85f : 1), NULL, ranges);
        g_font_title = io.Fonts->AddFontFromFileTTF(p, 92 * (b2 ? 2.3f : 1), NULL, ranges);
    }
    if (!g_font_menu) g_font_small = g_font_menu = g_font_title = io.Fonts->AddFontDefault();
    ImGuiStyle &st = ImGui::GetStyle();
    st.Colors[ImGuiCol_Header] = ImVec4(0, 0, 0, 0);
    st.Colors[ImGuiCol_HeaderHovered] = ImVec4(1, 1, 1, 0.08f);
    st.Colors[ImGuiCol_HeaderActive] = ImVec4(1, 1, 1, 0.14f);
    st.Colors[ImGuiCol_NavCursor] = ImVec4(0, 0.78f, 0.9f, 1);  // (the home menu's cyan)
    st.FrameRounding = st.WindowRounding = 10;
#ifdef __APPLE__
    ImGui_ImplSDL3_InitForMetal(win);
    ImGui_ImplMetal_Init(dev);
#else
    ImGui_ImplSDL3_InitForVulkan(win);
    vk_imgui_backend_init();
#endif
    ImGui_ImplSDL3_SetGamepadMode(ImGui_ImplSDL3_GamepadMode_Manual, NULL, 0);  // (controllers: launcher_pad_event)
    launcher_pad_open_all();
    io.BackendFlags |= ImGuiBackendFlags_HasGamepad;

    // an older version's game data image: the game reads the romfs/ folder itself now - 5.8 GB back
    if (check_copied_files(g_root).empty() && file_exists(g_root + "/romfs.bin") &&
        rt_remove_game_file(g_root.c_str(), "romfs.bin"))
        fprintf(stderr, "[launcher] removed the old game data image (romfs.bin)\n");
    std::string status = check_game_files(g_root);
    if (check_copied_files(g_root).empty()) load_background(dev), load_artwork();  // (also behind an update of the game code)
    std::vector<std::string> seeds = list_seeds();
    std::vector<std::string> choices = {"Vanilla"};
    choices.insert(choices.end(), seeds.begin(), seeds.end());
    int choice = 0;
    for (size_t i = 0; i < seeds.size(); i++)
        if (seeds[i] == g_settings.rando_seed) choice = (int)i + 1;
    Page page = MAIN;  // (not set up yet: the game's tile says so, A opens its game files)
    bool play = false;
    // LARECOMP_LAUNCHER_SHOT=<frame>[:<page>] (test): save build/launcher.png at that frame and exit; page: settings[:<tab>] / askdelete / setup / extracting / preparing
    long shot_at = getenv("LARECOMP_LAUNCHER_SHOT") ? atol(getenv("LARECOMP_LAUNCHER_SHOT")) : 0, frame = 0;
    if (shot_at) {
#ifdef __APPLE__
        layer.framebufferOnly = NO;
#endif
        const char *pg = strchr(getenv("LARECOMP_LAUNCHER_SHOT"), ':');
        if (pg && (!strncmp(pg + 1, "settings", 8) || !strcmp(pg + 1, "askdelete"))) page = SETTINGS, menu_tabs_focus(true);
        if (pg && !strcmp(pg + 1, "setup")) page = SETUP;
        if (pg && !strcmp(pg + 1, "preparing")) page = SETUP, g_prep_frac = 0.42f, set_job("Preparing shaders");
        if (pg && !strcmp(pg + 1, "skipask")) page = SETUP, g_prep_frac = 0.42f, set_job("Preparing shaders"), g_prep_skip_ask = true;
        if (pg && !strncmp(pg + 1, "fail", 4)) page = SETUP, set_failure(atoi(pg + 5));  // (the failure messages)
        if (pg && !strncmp(pg + 1, "settings", 8) && pg[9] == ':') g_tab_request_ext = atoi(pg + 10);  // settings:<tab>
        if (pg && !strcmp(pg + 1, "delete")) page = SETUP, g_confirm_delete = true;
        if (pg && !strcmp(pg + 1, "tip")) g_settings.menu_tip_seen = false, g_tip_test = true;
        if (pg && !strcmp(pg + 1, "aspect")) g_settings.aspect_asked = g_settings.menu_tip_seen = false, g_tip_test = true;
    }

    static int runs;  // (test: =once - only the first time, so a "Title screen" reboot lands on the start screen)
    const char *ap = getenv("LARECOMP_LAUNCHER_AUTOPLAY");
    if (ap && status.empty() && !(runs && !strcmp(ap, "once"))) play = true;  // (test: PLAY at once)
    if (getenv("LARECOMP_LAUNCHER_PREPARE") && status.empty() && !runs) {  // (test) the setup's shader preparation
        g_busy = true;                                                      // alone, then PLAY with AUTOPLAY
        page = SETUP, play = false;
        pthread_t th;
        pthread_create(&th, NULL, [](void *) -> void * {
            prepare_shaders();
            set_job("Game files ready.");
            pthread_mutex_lock(&g_lock);
            g_busy = false;
            pthread_mutex_unlock(&g_lock);
            return NULL;
        }, NULL);
        pthread_detach(th);
    }
    runs++;
    if (const char *t = getenv("LARECOMP_LAUNCHER_EXTRACT")) {  // (test) <folder>: set the game files up, log, exit
        g_src = t;
        g_busy = true;
        extract_thread(NULL);
        fprintf(stderr, "[launcher] setup: %s -> %s\n", g_job.c_str(), check_game_files(g_root).empty() ? "READY" : "NOT READY");
        exit(0);
    }
    if (const char *t = getenv("LARECOMP_LAUNCHER_SETUP")) {  // (test) <folder>: Set up started on the start screen
        g_src = t;
        g_busy = true;
        page = SETUP;
        pthread_t th;
        pthread_create(&th, NULL, extract_thread, NULL);
        pthread_detach(th);
    }
    // An update: the game files are there and only the game code is out of date - rebuilt at once, by itself (only
    // the pieces that changed: runtime/gamebuild.c), with the progress bar; then the start screen as usual. A failure
    // stays on the setup page with what went wrong.
    if (!status.empty() && check_copied_files(g_root).empty() && gamebuild_available() &&
        !getenv("LARECOMP_LAUNCHER_DELETE")) {
        fprintf(stderr, "[launcher] game code out of date: updating it\n");
        g_src.clear();
        g_busy = true, g_auto_update = true;
        page = SETUP;
        pthread_t th;
        pthread_create(&th, NULL, extract_thread, NULL);
        pthread_detach(th);
    }
    if (getenv("LARECOMP_LAUNCHER_DELETE")) {  // (test) what DELETE GAME FILES does, logged; then the start screen
        double gb = rt_game_files_size(g_root.c_str()) / 1e9;
        stop_background_prep();
        bool ok = rt_remove_game_files(g_root.c_str());
        game_files_changed();
        status = check_game_files(g_root);
        fprintf(stderr, "[launcher] delete %.1f GB: %s -> %s\n", gb, ok ? "ok" : "refused", status.c_str());
        if (!status.empty()) { g_bg = 0; page = SETUP; }
    }
    // the shader preparation of every later start: in the background (first setups and updates do theirs above)
    if (status.empty() && !g_busy && !getenv("LARECOMP_LAUNCHER_PREPARE")) start_background_prep();
    // (test) LARECOMP_LAUNCHER_PLAY_AT=<s>: PLAY that many seconds in; LARECOMP_LAUNCHER_SKIP_AT=<s>: Skip then
    const char *play_at_env = getenv("LARECOMP_LAUNCHER_PLAY_AT"), *skip_at_env = getenv("LARECOMP_LAUNCHER_SKIP_AT");
    uint64_t loop_t0 = SDL_GetTicks(), last_frame = loop_t0, bg_gap = 0, bg_frames = 0;
    bool bg_logged = false;
    for (;;) {
        uint64_t now = SDL_GetTicks();
        if (g_bg_prep) bg_frames++, bg_gap = std::max(bg_gap, now - last_frame);
        else if (!bg_logged && bg_frames) {  // (how the start screen kept up meanwhile)
            bg_logged = true;
            fprintf(stderr, "[launcher] background shader preparation: %llu frames meanwhile, longest %llu ms\n",
                    (unsigned long long)bg_frames, (unsigned long long)bg_gap);
        }
        last_frame = now;
        if (play_at_env && status.empty() && now - loop_t0 >= (uint64_t)(atof(play_at_env) * 1000)) play = true, play_at_env = NULL;
        if (skip_at_env && g_prep_wait && now - loop_t0 >= (uint64_t)(atof(skip_at_env) * 1000)) g_prep_skip = 1, skip_at_env = NULL;
        // PLAY while that still runs: its bar (with Skip) until it's done
        if (play && g_bg_prep) {
            play = false, g_prep_wait = true;
            fprintf(stderr, "[launcher] PLAY: waiting for the shader preparation\n");
        }
        if (g_prep_wait && !g_bg_prep) {
            g_prep_wait = false, play = true;
            fprintf(stderr, "[launcher] shader preparation %s: playing\n", g_prep_skip ? "skipped" : "done");
        }
        if (play) break;
        menu_apply_window_requests(win);  // (the Video tab's Fullscreen)
        // the seed PLAY would start, kept current (Settings > Gameplay greys out what that seed forces)
        snprintf(g_settings.rando_seed, sizeof g_settings.rando_seed, "%s", choice ? choices[choice].c_str() : "");
        if (g_files_deleted) {  // (Settings > Prelaunch deleted them)
            g_files_deleted = false;
            status = check_game_files(g_root);
            if (!status.empty()) { g_bg = 0; bind_capture_cancel(); settings_save(); page = SETUP; }
        }
        if (g_play_seed_req) {  // the Randomizer tab's Play: that seed, then PLAY as if pressed (first-launch questions)
            g_play_seed_req = false;
            seeds = list_seeds();
            choices = {"Vanilla"};
            choices.insert(choices.end(), seeds.begin(), seeds.end());
            choice = 0;
            for (size_t i = 0; i < seeds.size(); i++)
                if (seeds[i] == g_play_seed) choice = (int)i + 1;
            bind_capture_cancel();
            settings_save();
            page = MAIN;
            g_play_pending = true;
        }
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (page == SETTINGS && bind_capture_event(&e)) continue;  // (waiting for a new binding: controls_ui.mm)
#ifdef __ANDROID__
            if (e.type == SDL_EVENT_FINGER_DOWN || e.type == SDL_EVENT_FINGER_UP || e.type == SDL_EVENT_FINGER_MOTION ||
                e.type == SDL_EVENT_FINGER_CANCELED) {
                // touch screens (touch_ui.h): taps click, drags scroll (SDL's touch-made mouse events carry no window:
                // ImGui drops them)
                ImGuiIO &tio = ImGui::GetIO();
                tio.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
                g_touch.event(&e, tio.DisplaySize.x, tio.DisplaySize.y, [&](float x, float y) { tio.AddMousePosEvent(x, y); },
                              [&](bool down) { tio.AddMouseButtonEvent(0, down); });
                continue;
            }
#endif
            if (!launcher_pad_event(e)) ImGui_ImplSDL3_ProcessEvent(&e);
            if (e.type == SDL_EVENT_QUIT) exit(0);
        }
        // extraction finished: re-check, load the background
        pthread_mutex_lock(&g_lock);
        bool busy = g_busy;
        pthread_mutex_unlock(&g_lock);
        static bool was_busy;
        if (was_busy && !busy) {
            g_build_cache_changed = true;
            status = check_game_files(g_root);
            if (status.empty()) { if (!g_bg) load_background(dev); load_artwork(); page = MAIN; }
            if (status.empty() && ap && getenv("LARECOMP_LAUNCHER_PREPARE")) play = true;
            g_auto_update = false;
        }
        was_busy = busy;
#ifdef __ANDROID__
        if (g_art_job == 0 && !busy && status.empty() && !g_icon) {  // (game files set up before the artwork was taken)
            g_art_job = 1;
            pthread_t th;
            if (pthread_create(&th, NULL, artwork_thread, NULL) == 0) pthread_detach(th);
            else g_art_job = 3;
        }
#endif
        if (g_art_job == 2) load_artwork(), g_art_job = 3;

#ifdef __APPLE__
        int w, h;
        SDL_GetWindowSizeInPixels(win, &w, &h);
        layer.drawableSize = CGSizeMake(w, h);
        @autoreleasepool {
            id<CAMetalDrawable> drawable = [layer nextDrawable];
            if (!drawable) { SDL_Delay(16); continue; }
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = drawable.texture;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0.04, 0.05, 0.06, 1);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            ImGui_ImplMetal_NewFrame(rp);
#else
        {
            // one frame per refresh of the window's display: the swapchain presents without waiting (mailbox, for the
            // game's own pacing: device.c), so the start screen alone would draw as fast as the GPU goes
            static uint64_t next_frame;
            const SDL_DisplayMode *dm = SDL_GetCurrentDisplayMode(SDL_GetDisplayForWindow(win));
            uint64_t period = (uint64_t)(1e9 / (dm && dm->refresh_rate > 1 ? dm->refresh_rate : 60.0f)), now = plat_now_ns();
            bool on_time = next_frame > now && next_frame - now <= period;  // (else late, or the rate changed: start over)
            if (on_time) plat_sleep_until_ns(next_frame);
            next_frame = (on_time ? next_frame : now) + period;
            static const float clear_col[4] = {0.04f, 0.05f, 0.06f, 1};
            if (!vk_frame_begin(clear_col)) { SDL_Delay(16); continue; }
            ImGui_ImplVulkan_NewFrame();
#endif
            ImGui_ImplSDL3_NewFrame();
            // the backend (manual mode, no gamepads of its own) clears HasGamepad every frame, and ImGui then drops the
            // controller presses launcher_pad_event fed in and turns gamepad navigation off: set it again while a
            // controller is connected
            if (SDL_HasGamepad()) io.BackendFlags |= ImGuiBackendFlags_HasGamepad;
            // a drag / flick (touch_ui.h): this frame's scroll, onto the page under the finger
            float touch_px = g_touch.frame(io.DeltaTime, [&](float x, float y) { io.AddMousePosEvent(x, y); });
            ImGui::NewFrame();
            touch_scroll_apply(touch_px);

            ImVec2 ds = io.DisplaySize;
            float s = ds.y / 720.0f;  // layout scale (fonts are built for ~2x)
            ImGui::GetIO().FontGlobalScale = s * 0.5f;
            ImDrawList *bg = ImGui::GetBackgroundDrawList();
            // an update by itself: only its bar, on the start screen's background (gray without it; a failure or
            // Cancel then shows the Game Files page)
            const bool update_only = g_auto_update && busy;
            // the wallpaper (the home menu's theme): the game's title-movie still from the player's own files once
            // they're set up, else a dark gradient; darkened along the top for the icons and the clock
            if (g_bg) {  // cover the window, keep the aspect
                float ia = (float)g_bg_w / g_bg_h, wa = ds.x / ds.y;
                ImVec2 uv0(0, 0), uv1(1, 1);
                if (wa > ia) { float v = ia / wa; uv0.y = (1 - v) / 2; uv1.y = 1 - uv0.y; }
                else { float u = wa / ia; uv0.x = (1 - u) / 2; uv1.x = 1 - uv0.x; }
                bg->AddImage(BG_TEXID, ImVec2(0, 0), ds, uv0, uv1);
            } else {
                bg->AddRectFilledMultiColor(ImVec2(0, 0), ds, IM_COL32(34, 40, 56, 255), IM_COL32(44, 52, 70, 255),
                                            IM_COL32(18, 20, 28, 255), IM_COL32(12, 14, 20, 255));
            }
            if (!update_only) {
                bg->AddRectFilled(ImVec2(0, 0), ds, IM_COL32(6, 8, 14, 60));
                bg->AddRectFilledMultiColor(ImVec2(0, 0), ImVec2(ds.x, 130 * s), IM_COL32(6, 8, 14, 150),
                                            IM_COL32(6, 8, 14, 150), IM_COL32(6, 8, 14, 0), IM_COL32(6, 8, 14, 0));
            }

            ImGui::SetNextWindowPos(ImVec2(0, 0));
            ImGui::SetNextWindowSize(ds);
            ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0, 0, 0, 0));
            ImGui::Begin("##launcher", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove |
                                                 ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBringToFrontOnFocus);
            const bool waiting = g_prep_wait;  // (the menu waits under the bar)
            ImGui::BeginDisabled(waiting);
            ImGui::SetScrollX(0);  // (the start screen never scrolls; a long seed name or a stray nav move mustn't shift it)
            ImGui::SetScrollY(0);
            static bool typed_before;
            bool typing = typed_before || ui_text_busy();
            {  // the library, kept current (an addon put into the data folder while the app runs shows up)
                static uint64_t scanned;
                uint64_t t = SDL_GetTicks();
                if (!scanned || t - scanned > 2000) scan_library(), scanned = t ? t : 1;
            }
            if (g_home.sel >= (int)g_library.size()) g_home.sel = 0;
            const LibGame &game = g_library[g_home.sel];
            const bool la = game.builtin;
            // the built-in game's tile art: the wallpaper's still, its middle square
            ImVec2 art_uv0(0, 0), art_uv1(1, 1);
            if (g_bg) {
                float u = (float)g_bg_h / g_bg_w;
                art_uv0 = ImVec2(0.5f - u * 0.5f, 0), art_uv1 = ImVec2(0.5f + u * 0.5f, 1);
            }
            const bool popup = ImGui::IsPopupOpen("", ImGuiPopupFlags_AnyPopupId);  // (before the pages run, like the menu)
            const bool pad = SDL_HasGamepad();
            ImDrawList *dl = ImGui::GetWindowDrawList();
            // back on the home screen: the seed list again (seeds made / renamed / deleted in the Randomizer tab)
            auto to_home = [&] {
                bind_capture_cancel();
                settings_save();
                g_confirm_delete = false;
                page = MAIN;
                std::string cur = choices[choice];
                seeds = list_seeds();
                choices = {"Vanilla"};
                choices.insert(choices.end(), seeds.begin(), seeds.end());
                choice = 0;
                for (size_t i = 0; i < choices.size(); i++)
                    if (choices[i] == cur) choice = (int)i;
            };
            auto b_pressed = [] {
                return ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false);
            };

            if (update_only) {
                // (an update by itself: only its bar, drawn below)
            } else if (page == MAIN) {
                std::vector<HzTile> tiles;
                for (const LibGame &g : g_library) {
                    HzTile t;
                    t.title = g.name;
                    float hue = 0;
                    for (char c : g.id) hue = fmodf(hue * 31 + (unsigned char)c, 360.0f);
                    ImVec4 c1, c2;
                    ImGui::ColorConvertHSVtoRGB(hue / 360.0f, 0.55f, 0.55f, c1.x, c1.y, c1.z);
                    ImGui::ColorConvertHSVtoRGB(hue / 360.0f, 0.65f, 0.28f, c2.x, c2.y, c2.z);
                    t.col1 = IM_COL32((int)(c1.x * 255), (int)(c1.y * 255), (int)(c1.z * 255), 255);
                    t.col2 = IM_COL32((int)(c2.x * 255), (int)(c2.y * 255), (int)(c2.z * 255), 255);
                    if (g.builtin) {
                        if (g_icon) t.art = (ImTextureID)g_icon;
                        else if (g_bg) t.art = BG_TEXID, t.uv0 = art_uv0, t.uv1 = art_uv1;
                        if (busy) t.badge = T("Setting up"), t.progress = extract_progress();
                        else if (!status.empty()) t.badge = T("Set up");
                        else if (choice) t.badge = T("Randomizer");
                    } else {
                        t.badge = T("Not supported yet"), t.dim = true;
                    }
                    tiles.push_back(t);
                }
                std::string upd;
                pthread_mutex_lock(&g_update_lock);
                upd = g_update_tag;
                pthread_mutex_unlock(&g_update_lock);
                // the icons: only what works - System Settings, a newer release when the update check found one, Quit
                std::vector<HzIcon> icons = {{HZ_GLYPH_GEAR, T("System Settings"), false}};
                if (!upd.empty()) icons.push_back({HZ_GLYPH_DOWNLOAD, T("Update available"), true});
                icons.push_back({HZ_GLYPH_POWER, T("Quit"), false});
                // the hints: what A and + do for the selected game
                std::vector<HzHint> hints;
                if (la) hints.push_back({'+', T("Options")});
                hints.push_back({'A', !la ? T("Details") : status.empty() ? T("Start") : T("Set up")});
                int bat = -1;
                SDL_PowerState ps = SDL_GetPowerInfo(NULL, &bat);
                if (ps == SDL_POWERSTATE_NO_BATTERY || ps == SDL_POWERSTATE_UNKNOWN || ps == SDL_POWERSTATE_ERROR) bat = -1;
                bool input_on = !popup && !busy && !waiting;
                HzHomeResult r = hz_home(dl, g_font_small, ds, s, g_home, tiles, icons.data(), (int)icons.size(), pad,
                                         hints.data(), (int)hints.size(), bat, ps == SDL_POWERSTATE_CHARGING, input_on);
                const LibGame &sel = g_library[g_home.sel];
                bool options = input_on && sel.builtin && ImGui::IsKeyPressed(ImGuiKey_GamepadStart, false);
                bool start = r.start_tile >= 0;
                if (r.hint >= 0) (hints[r.hint].button == '+' ? options : start) = true;
                if (r.icon >= 0) {
                    if (icons[r.icon].glyph == HZ_GLYPH_GEAR) page = SYSTEM;
                    else if (icons[r.icon].glyph == HZ_GLYPH_DOWNLOAD) SDL_OpenURL((RELEASE_PAGE + upd).c_str());
                    else if (icons[r.icon].glyph == HZ_GLYPH_POWER) exit(0);
                }
                bool pressed = false;
                if (options) page = status.empty() ? SETTINGS : SETUP, menu_tabs_focus(true);
                else if (start && !sel.builtin) page = INFO;
                else if (start) {
                    if (status.empty()) pressed = true;
                    else page = SETUP;
                }
                // first Start ever: the aspect ratio question, then how to reach our menu, then the game
                if (g_play_pending && status.empty()) pressed = true, g_play_pending = false, g_home.sel = 0;
                if (pressed) {
                    if (!g_settings.aspect_asked) ImGui::OpenPopup("##aspect");
                    else if (!g_settings.menu_tip_seen) ImGui::OpenPopup("##menutip");
                    else play = true;
                }
                if (g_tip_test) ImGui::OpenPopup(g_settings.aspect_asked ? "##menutip" : "##aspect"), g_tip_test = false;
                if (aspect_prompt(s)) {
                    if (g_settings.menu_tip_seen) play = true;
                    else ImGui::OpenPopup("##menutip");
                }
                if (menu_tip(s)) play = true;
                if (const char *f = getenv("LARECOMP_LAUNCHER_FONT")) {  // (test) which typeface this window shows
                    const char *b = strrchr(f, '/');
                    dl->AddText(ImVec2(20 * s, ds.y - 110 * s), IM_COL32(255, 255, 255, 255), b ? b + 1 : f);
                }
            } else if (page == SYSTEM) {
                HzPageRects R = hz_page_frame(dl, g_font_small, ds, s, T("System Settings"), "", 0, ImVec2(0, 0), ImVec2(1, 1));
                ImGui::SetCursorScreenPos(R.side_min);
                ImGui::BeginChild("##sysside", ImVec2(R.side_max.x - R.side_min.x, R.side_max.y - R.side_min.y),
                                  ImGuiChildFlags_None, ImGuiWindowFlags_NavFlattened);
                if (g_sys_section >= SYS_N) g_sys_section = 0;
                for (int i = 0; i < SYS_N; i++)
                    if (hz_side_item(g_font_small, s, T(SYS_SECTIONS[i]), g_sys_section == i)) g_sys_section = i;
                ImGui::EndChild();
                float sc = ds.y / 1080.0f;
#ifdef __ANDROID__
                sc *= 1.35f;
                ImGui::GetIO().FontGlobalScale *= 1.35f;
#endif
                ImGui::SetCursorScreenPos(R.body_min);
                ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(20 * sc, 16 * sc));
                ImGui::BeginChild("##sysbody", ImVec2(R.body_max.x - R.body_min.x, R.body_max.y - R.body_min.y),
                                  ImGuiChildFlags_AlwaysUseWindowPadding, ImGuiWindowFlags_NavFlattened);
                ImGui::PopStyleVar();
                ImGui::PushFont(g_font_small);
                sys_section_draw(SYS_SECTIONS[g_sys_section]);
                ImGui::PopFont();
                ImGui::EndChild();
                HzHint hints[] = {{'B', T("Back")}};
                bool back = hz_bottom_bar(dl, g_font_small, ds, s, pad, hints, 1) == 0;
                if (!popup && b_pressed()) back = true;
                if (back) settings_save(), page = MAIN;
            } else {
                // the selected game's pages: a sidebar of them, the page on the right. A game this engine can't run
                // has its details only.
                if (!la) page = INFO;
                const char *sub = !la ? T("Not supported yet") : busy ? T("Setting up...")
                                : status.empty() ? T("Ready to play") : T("Not set up");
                HzPageRects R = hz_page_frame(dl, g_font_small, ds, s, game.name.c_str(), sub,
                                              !la ? 0 : g_icon ? (ImTextureID)g_icon : g_bg ? BG_TEXID : 0,
                                              g_icon ? ImVec2(0, 0) : art_uv0, g_icon ? ImVec2(1, 1) : art_uv1);
                ImGui::SetCursorScreenPos(R.side_min);
                ImGui::BeginChild("##gameside", ImVec2(R.side_max.x - R.side_min.x, R.side_max.y - R.side_min.y),
                                  ImGuiChildFlags_None, ImGuiWindowFlags_NavFlattened);
                ImGui::BeginDisabled(busy);
                if (la) {
                    if (hz_side_item(g_font_small, s, T("Settings"), page == SETTINGS)) page = SETTINGS, menu_tabs_focus(true);
                    if (hz_side_item(g_font_small, s, T("Play mode"), page == PLAYMODE)) page = PLAYMODE;
                    if (hz_side_item(g_font_small, s, T("Game files"), page == SETUP)) page = SETUP;
                }
                if (hz_side_item(g_font_small, s, T("Information"), page == INFO)) page = INFO;
                ImGui::EndDisabled();
                ImGui::EndChild();

                // the pages' own widgets (option rows, the menu's tabs) at the sizes they're made for
                float sc = ds.y / 1080.0f;
#ifdef __ANDROID__
                sc *= 1.35f;  // (phones: a third larger, as the in-game menu there: runtime/ui/menu.mm kUi)
                ImGui::GetIO().FontGlobalScale *= 1.35f;
#endif
                ImGui::SetCursorScreenPos(R.body_min);
                ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(20 * sc, 16 * sc));
                ImGui::BeginChild("##gamebody", ImVec2(R.body_max.x - R.body_min.x, R.body_max.y - R.body_min.y),
                                  ImGuiChildFlags_AlwaysUseWindowPadding, ImGuiWindowFlags_NavFlattened);
                ImGui::PopStyleVar();
                ImGui::PushFont(g_font_small);
                if (page == SETTINGS) {
                    menu_tabs_draw(sc, g_font_small, g_font_menu, false, NULL);
                } else if (page == PLAYMODE) {
                    ImGui::PushTextWrapPos(0);
                    ImGui::TextDisabled("%s", T("What Start plays: the game as it is, or one of your randomizer seeds."));
                    ImGui::PopTextWrapPos();
                    ImGui::Spacing();
                    for (int i = 0; i < (int)choices.size(); i++) {
                        std::string lbl = i ? T("Randomizer: ") + choices[i] : std::string(T("Vanilla (the original game)"));
                        if (ImGui::Selectable((lbl + "##mode" + std::to_string(i)).c_str(), choice == i, 0,
                                              ImVec2(0, 46 * sc)))
                            choice = i;
                    }
                    ImGui::Spacing();
                    if (seeds.empty()) ImGui::TextDisabled("%s", T("No seeds yet: make one in Settings > Randomizer."));
                    if (ImGui::Button(T("Randomizer settings"))) {
                        page = SETTINGS;
                        g_tab_request_ext = 3;  // (menu.mm: the Randomizer tab's id)
                        menu_tabs_focus(false);
                    }
                } else if (page == INFO) {
                    static double gb = -1;
                    static uint64_t gb_at;
                    if (la && status.empty() && (gb < 0 || SDL_GetTicks() - gb_at > 10000))
                        gb = rt_game_files_size(g_root.c_str()) / 1e9, gb_at = SDL_GetTicks();
                    auto row = [&](const char *k, const std::string &v) {
                        ImGui::TextDisabled("%s", T(k));
                        ImGui::SameLine(260 * sc);
                        ImGui::TextUnformatted(v.c_str());
                    };
                    row("Title ID", game.id);
                    if (!game.version.empty()) row("Version", game.version);
                    if (!game.build_id.empty()) row("Build ID", game.build_id);
                    if (!game.author.empty()) row("Addon by", game.author);
                    char size[32];
                    snprintf(size, sizeof size, "%.1f GB", gb);
                    if (la) row("Status", T(busy ? "Setting up" : status.empty() ? "Ready to play" : status_text(status).c_str()));
                    if (la && status.empty() && gb >= 0) row("Game files", size);
                    ImGui::Spacing();
                    ImGui::PushTextWrapPos(0);
                    if (la) {
                        ImGui::TextDisabled("%s", T("Built on this device from your own copy of the game. Saves, seeds and "
                                                  "settings stay when the game files are deleted."));
                    } else {
                        ImGui::TextDisabled("%s", T("This game's addon is installed, but this version of the engine can't run "
                                                  "it yet. A later update that adds it makes it playable here."));
                        ImGui::Spacing();
                        ImGui::Text(T("Addon folder: %s"), (std::string(rt_data_root()) + "/addons/" + game.id).c_str());
                    }
                    ImGui::PopTextWrapPos();
                } else {  // SETUP: the game files - choose the folder with them, set up; once set up, delete
                    pthread_mutex_lock(&g_lock);
                    std::string src = g_src, job = T(g_job.c_str()), job_hint = T(g_job_hint.c_str());  // (shown: translated)
                    bool failed = g_job_failed;
                    pthread_mutex_unlock(&g_lock);
                    bool ready = status.empty() && !busy;  // (set up: the window offers to delete them)
                    static double files_gb = -1;
                    // chosen: "Selected" with a green check (long paths ran over the label); the path is in the
                    // explanation, and choosing again opens the picker again
                    std::string src_v = src.empty() ? "Choose..." : "Selected";
                    auto check_left_of_value = [&](const std::string &v) {
                        if (v != "Selected") return;
                        ImVec2 rb = ImGui::GetItemRectMax(), ra = ImGui::GetItemRectMin();
                        float fs = ImGui::GetFontSize(), vw = ImGui::CalcTextSize(T(v.c_str())).x;
                        float x = rb.x - 16 * sc - vw - fs * 0.95f, cy = (ra.y + rb.y) * 0.5f, u = fs * 0.62f;
                        ImU32 g = IM_COL32(120, 220, 120, 255);
                        ImDrawList *dl = ImGui::GetWindowDrawList();
                        dl->AddLine(ImVec2(x, cy), ImVec2(x + u * 0.35f, cy + u * 0.35f), g, fs * 0.11f);
                        dl->AddLine(ImVec2(x + u * 0.35f, cy + u * 0.35f), ImVec2(x + u, cy - u * 0.4f), g, fs * 0.11f);
                    };
                    std::string src_d = T("The folder with your own game folders (exefs/romfs) of The Legend of Zelda: Link's "
                                          "Awakening for Nintendo Switch, version 1.0.0. The game isn't included with LAS Recomp.");
#ifdef __ANDROID__
                    src_d = T("The folder with your own copy of The Legend of Zelda: Link's Awakening for Nintendo Switch, "
                              "version 1.0.0: its .xci or .nsp together with the prod.keys from your Switch (asked for if it "
                              "isn't there), or its extracted exefs and romfs folders. The game isn't included with LAS Recomp.");
                    src_d += T("\n\nOr copy exefs and romfs from a computer over USB into ") + std::string(rt_data_root()) +
                             T("/extracted and choose Set up.");
#endif
                    if (!src.empty()) src_d += T("\n\nChosen: ") + src;
                    // the step that's running / its result, under the rows and in the Set up row's explanation
                    const std::string &job_line = job;
                    std::string ex_d = T("Copies the game files LAS Recomp needs and recompiles the game from them. This only "
                                         "needs to be done once and may take a while. Your own files aren't changed.");
                    if (!job.empty()) ex_d += "\n\n" + job + (job_hint.empty() ? "" : ".\n" + job_hint);

                    // the controller's cursor starts on the first row (not the X), a few frames while the window lays out
                    static int seen_frame = -10, focus_first;  // (not drawn last frame: the window has just opened)
                    if (seen_frame != ImGui::GetFrameCount() - 1) focus_first = 4;
                    seen_frame = ImGui::GetFrameCount();
                    auto first_row = [&] {
                        if (focus_first > 0 && focus_first--) ImGui::SetFocusID(ImGui::GetItemID(), ImGui::GetCurrentWindow());
                    };
                    opt_begin("##files", sc);
                    if (!ready) {
                        opt_section("Your copy of the game");
                        if (busy) opt_disable_next();
#ifdef __ANDROID__
                        if (opt_action("Game files folder", src_v.c_str(), src_d.c_str(), true)) android_pick_game_folder(picked_android);
                        bool have_files = in_place_files(g_root);
#else
                        if (opt_action("Game files folder", src_v.c_str(), src_d.c_str(), true))
                            SDL_ShowOpenFolderDialog(picked, NULL, win, NULL, false);
                        bool have_files = false;
#endif
                        check_left_of_value(src_v);
                        first_row();
                        opt_section("Set up");
                        if (busy || (src.empty() && !have_files && !check_copied_files(g_root).empty())) opt_disable_next();
                        bool resume = !busy && src.empty() && resumable_build();
                        if (opt_action(resume ? "Resume game code" : "Set up game files", busy ? "Working..." : "", ex_d.c_str(), true)) {
                            pthread_mutex_lock(&g_lock);
                            g_busy = true;
                            pthread_mutex_unlock(&g_lock);
                            pthread_t t;
                            pthread_create(&t, NULL, extract_thread, NULL);
                            pthread_detach(t);
                        }
                        files_gb = -1;  // (re-measured after a setup)
                    } else {
                        // DELETE: frees LAS Recomp's copy (runtime/paths.c removes only what the setup made, only inside
                        // the data root). Saves, seeds, settings and the user's own files stay.
                        if (files_gb < 0) files_gb = rt_game_files_size(g_root.c_str()) / 1e9;
                        char gb[32];
                        snprintf(gb, sizeof gb, "%.1f GB", files_gb);
                        opt_section("Game files");
                        if (!g_confirm_delete) {
                            if (opt_action("Delete game files", gb, "Frees the space LAS Recomp's copy of the game files takes. "
                                           "Saves, seeds and settings are kept, and your own game files aren't touched: you can "
                                           "set the game files up again from them.", true))
                                g_confirm_delete = true;
                            first_row();
                        } else {
                            if (opt_action("Yes, delete them", gb, "Deletes the extracted game files now.", true)) {
                                stop_background_prep();
                                bool ok = rt_remove_game_files(g_root.c_str());
                                game_files_changed();
                                status = check_game_files(g_root);
                                if (ok) set_job("Game files deleted.");
                                else set_job("Couldn't delete the game files", true, "They aren't in LAS Recomp's data folder, "
                                             "so they were left alone.");
                                if (!status.empty()) g_bg = 0;
                                g_confirm_delete = false, files_gb = -1;
                            }
                            if (opt_action("Cancel", "", "Keeps the game files.", true)) g_confirm_delete = false;
                        }
                    }
                    if (!busy && has_build_cache()) {
                        opt_section("Build cache");
                        if (opt_action("Clear build cache", "", "Removes the saved game-code build files. The next setup compiles "
                                       "everything again.", true)) {
                            char why[512] = "";
                            g_build_cache_changed = true;
                            if (build_cache_clear(g_root.c_str(), why, sizeof why)) set_job("Build cache cleared.");
                            else set_job("Could not clear the build cache.", true, why);
                        }
                    }
                    if (!job_line.empty()) {  // the current step / result
                        ImGui::Dummy(ImVec2(0, 14 * sc));
                        ImGui::PushTextWrapPos(0);
                        ImGui::TextColored(failed ? ImVec4(1, 0.5f, 0.4f, 1) : busy ? ImVec4(0, 0.78f, 0.9f, 1)
                                                  : ImVec4(0.45f, 0.95f, 0.55f, 1), "%s", job_line.c_str());
                        if (failed && !job_hint.empty())  // (what to do next, in the rows' own text colour)
                            ImGui::TextColored(ImVec4(0.86f, 0.85f, 0.80f, 1), "%s", job_hint.c_str());
                        ImGui::PopTextWrapPos();
                    } else if (!busy && !status.empty() && status != "No game files yet") {
                        // (no setup run yet this session: why the game files on disk can't be played - an incomplete copy
                        // opens this window instead of crashing on Play)
                        ImGui::Dummy(ImVec2(0, 14 * sc));
                        ImGui::PushTextWrapPos(0);
                        ImGui::TextColored(ImVec4(1, 0.5f, 0.4f, 1), "%s", status_text(status).c_str());
                        ImGui::TextColored(ImVec4(0.86f, 0.85f, 0.80f, 1), "%s", status_hint(status));
                        ImGui::PopTextWrapPos();
                    }
                    opt_end();
                }
                ImGui::PopFont();
                ImGui::EndChild();

                HzHint hints[] = {{'B', T("Back")}};
                bool back = !busy && hz_bottom_bar(dl, g_font_small, ds, s, pad, hints, 1) == 0;
                int cap_dev;
                bind_capture_active(&cap_dev, NULL, NULL);
                if (g_confirm_delete && b_pressed()) g_confirm_delete = false;  // (B / Esc: back out of the question first)
                else if (!popup && !typing && !busy && cap_dev < 0 && !controls_ui_took_back() && b_pressed()) back = true;
                if (back) to_home();
            }
            // the setup's / an update's / the shader preparation's bar, in front of everything
            static bool test_busy = getenv("LARECOMP_LAUNCHER_SHOT") && (strstr(getenv("LARECOMP_LAUNCHER_SHOT"), ":extracting") ||
                                                                     strstr(getenv("LARECOMP_LAUNCHER_SHOT"), ":preparing") ||
                                                                     strstr(getenv("LARECOMP_LAUNCHER_SHOT"), ":skipask"));
            if (busy || test_busy) {
                pthread_mutex_lock(&g_lock);
                std::string job = g_job;
                pthread_mutex_unlock(&g_lock);
                draw_busy_overlay(ds, job, test_busy);
            }
            ImGui::EndDisabled();
            ImGui::End();
            ImGui::PopStyleColor();
            if (waiting) draw_busy_overlay(ds, "", false, true);
            osk_draw(g_font_menu, s * 0.7f);  // (a text field activated with the controller)
            typed_before = ui_text_busy();

            ImGui::Render();
#ifdef __APPLE__
            ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
            [enc endEncoding];
            id<MTLTexture> shot = nil;
            if (shot_at && ++frame == shot_at) {
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:drawable.texture.pixelFormat
                                             width:drawable.texture.width height:drawable.texture.height mipmapped:NO];
                td.storageMode = MTLStorageModeShared;
                shot = [dev newTextureWithDescriptor:td];
                id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
                [bl copyFromTexture:drawable.texture toTexture:shot];
                [bl endEncoding];
            }
            [cb presentDrawable:drawable];
            [cb commit];
            if (shot) {
                [cb waitUntilCompleted];
                save_png(shot, getenv("LARECOMP_SHOT_PATH") ? getenv("LARECOMP_SHOT_PATH") : "build/launcher.png");
                exit(0);
            }
#else
            ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), (VkCommandBuffer)vk_frame_cmd());
            bool shot = shot_at && ++frame == shot_at;
            vk_frame_end(shot ? getenv("LARECOMP_SHOT_PATH") ? getenv("LARECOMP_SHOT_PATH") : "build/launcher.png" : NULL);
            if (shot) exit(0);
#endif
        }
    }
    // play: remember the choice, hand the window to the game
    snprintf(g_settings.rando_seed, sizeof g_settings.rando_seed, "%s", choice ? choices[choice].c_str() : "");
    settings_save();
#ifdef __APPLE__
    ImGui_ImplMetal_Shutdown();
#else
    vk_imgui_backend_shutdown();
#endif
    ImGui_ImplSDL3_Shutdown();
    ImGui::DestroyContext(ctx);
    ImGui::SetCurrentContext(prev_ctx);
    g_bg = 0;
    g_start_screen = 0;
}
