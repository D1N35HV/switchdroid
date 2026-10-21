# SwitchDroid Hub - Addon Creation & Multi-Game Architecture Guide

This guide explains how to add new Nintendo Switch game recompilations to **SwitchDroid Hub** using the `.recomp` addon format or through app updates.

---

## 1. Overview of the Architecture

SwitchDroid Hub transforms standalone Switch static recompilations into a modular, multi-game Android environment.

When a user supplies:
1. A dumped Switch game package (`.xci` or `.nsp`)
2. Their console's `prod.keys`

The Hub:
1. **Inspects Title ID & Version**: Reads the NCA headers in pure Java via `NxPackage.java`.
2. **Matches Game Profile**: Queries `AddonManager` for registered built-in profiles or installed `.recomp` addons.
3. **Decrypts & Extracts**: Extracts the application's `exefs/` (including `main` and `subsdk`) and `romfs/` to `Android/data/com.lasrecomp.android/files/games/<title_id>/extracted/`.
4. **On-Device AOT Recompilation**: Executes `tools/gen.py` via embedded Python to lift ARM64 machine code to C, then compiles it via the bundled on-device Clang/Zig toolchain into `games/<title_id>/libgame.so`.
5. **Native Execution**: Launches the native Horizon OS / NVN-to-Vulkan runtime with per-game custom Turnip GPU drivers and touch overlay.

---

## 2. Structure of a `.recomp` Addon Package

A `.recomp` addon is a zip file named `<game_slug>.recomp` with the following structure:

```
zelda_la_v100.recomp
├── manifest.json              # Mandatory: Game metadata, title ID, and configuration
├── lifter/
│   ├── patches.py             # Optional: Game-specific lifter hooks & instruction patches
│   ├── hot_functions.txt      # Optional: Function offsets optimized at -O1 vs -O0
│   └── game_addresses.json    # Optional: Named guest addresses
├── overlay/
│   ├── touch_layout.json      # Custom on-screen touch layout
│   └── icons/                 # Dynamic action button icons
└── assets/
    ├── icon.png               # 256x256 game boxart for Hub grid
    └── banner.jpg             # Hub detail screen background
```

---

## 3. `manifest.json` Specification

```json
{
  "format_version": 1,
  "game_id": "01006bb00c6f0000",
  "name": "The Legend of Zelda: Link's Awakening",
  "version": "1.0.0",
  "build_ids": [
    "ae16f71e002af8cb"
  ],
  "author": "Community Developer",
  "min_hub_version": "1.0.0",
  "requirements": {
    "storage_mb": 7500,
    "recommended_ram_gb": 6,
    "supported_architectures": ["arm64-v8a"]
  },
  "runtime_config": {
    "base_resolution": [1920, 1080],
    "default_orientation": "landscape_sensor",
    "frame_rate_target": 60,
    "frame_generation_supported": true,
    "recommended_gpu_driver": "turnip",
    "memory_pool_mb": 4096
  },
  "romfs_validator": {
    "critical_files": [
      "region_common/movie/movie_000.mp4"
    ],
    "min_file_count": 200
  }
}
```

### Manifest Fields:
* `game_id`: The 16-character hexadecimal Title ID of the base game (lowercase).
* `build_ids`: Array of 16-character hexadecimal module build IDs (found at offset `0x40` of `exefs/main`).
* `romfs_validator`:
  * `critical_files`: Relative paths in RomFS that must exist to verify complete extraction.
  * `min_file_count`: Minimum number of extracted RomFS files required.

---

## 4. How to Install an Addon on Android

1. Download or transfer your `<name>.recomp` file to the phone (e.g. `Download/`).
2. In SwitchDroid Hub, tap **Install Addon (.recomp)** and pick the file.
3. The Hub validates the manifest and extracts the addon into `Android/data/com.lasrecomp.android/files/addons/<game_id>/`.
4. The game immediately appears in the Hub library as a supported title!
5. Select the game, provide your game dump (`.xci` / `.nsp`) and `prod.keys`, and tap **Build & Play**.
