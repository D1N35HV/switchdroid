#!/usr/bin/env python3
"""Checks addon folders (addons/<title_id>/) and keeps game files out of the repo.

    python tools/validate_addon.py                 # every folder under addons/
    python tools/validate_addon.py addons/0100...  # one addon
    git diff --name-only --diff-filter=A BASE...HEAD | python tools/validate_addon.py --scan-names

No game files are needed: it checks the manifest against addons/manifest.schema.json's rules (hand-checked, standard
library only), the folder layout, and refuses anything that looks like Nintendo data or keys.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDONS = os.path.join(ROOT, "addons")

HEX16 = re.compile(r"^[0-9a-f]{16}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")

ALLOWED_TOP = {"manifest.json", "README.md", "LICENSE", "lifter", "overlay", "assets"}
ALLOWED_EXT = {".json", ".py", ".txt", ".md", ".png", ".jpg", ".jpeg", ".webp", ".svg", ""}
MAX_FILE = 5 * 1024 * 1024

# Never allowed anywhere in the repo, by name or extension.
FORBIDDEN_EXT = {".nso", ".nro", ".nca", ".nsp", ".xci", ".nsz", ".xcz", ".keys", ".bfttf", ".bfotf", ".szs",
                 ".elf", ".so", ".dll", ".exe", ".apk", ".ncz", ".tik", ".cert"}
FORBIDDEN_NAMES = {"prod.keys", "title.keys", "console.keys", "main", "subsdk0", "rtld", "sdk"}
FORBIDDEN_DIRS = {"extracted", "generated", "exefs", "romfs", "rando"}
MAGICS = (b"NSO0", b"NRO0", b"NCA3", b"NCA2", b"PFS0", b"HFS0", b"\x7fELF", b"MOD0", b"Yaz0")


def check_names(paths):
    errs = []
    for p in paths:
        p = p.strip().replace("\\", "/")
        if not p:
            continue
        parts = p.split("/")
        base = parts[-1].lower()
        ext = os.path.splitext(base)[1]
        if base in FORBIDDEN_NAMES and not p.startswith(("tools/", "docs/", "runtime/", "android/")):
            errs.append(f"{p}: file name looks like game/key data")
        if ext in FORBIDDEN_EXT:
            errs.append(f"{p}: extension {ext} is not allowed (game, key or binary data)")
        if any(d in FORBIDDEN_DIRS for d in parts[:-1]) and parts[0] == "addons":
            errs.append(f"{p}: folder name suggests extracted game data")
    return errs


def check_manifest(path, folder):
    errs = []
    try:
        with open(path, encoding="utf-8") as f:
            m = json.load(f)
    except (OSError, ValueError) as e:
        return [f"{path}: cannot read manifest: {e}"]

    def need(key, cond, msg):
        if key not in m:
            errs.append(f"manifest: missing '{key}'")
        elif not cond(m[key]):
            errs.append(f"manifest: '{key}' {msg}")

    need("format_version", lambda v: v == 1, "must be 1")
    need("game_id", lambda v: isinstance(v, str) and HEX16.match(v), "must be 16 lowercase hex digits")
    need("name", lambda v: isinstance(v, str) and 0 < len(v) <= 120, "must be a non-empty string (max 120)")
    need("version", lambda v: isinstance(v, str) and SEMVER.match(v), "must look like 1.0.0")
    need("author", lambda v: isinstance(v, str) and v.strip(), "must be a non-empty string")
    need("build_ids", lambda v: isinstance(v, list) and v and all(isinstance(x, str) and HEX16.match(x) for x in v),
         "must be a non-empty list of 16 lowercase hex digits")
    if "min_hub_version" in m and not (isinstance(m["min_hub_version"], str) and SEMVER.match(m["min_hub_version"])):
        errs.append("manifest: 'min_hub_version' must look like 1.0.0")

    rv = m.get("romfs_validator")
    if not isinstance(rv, dict):
        errs.append("manifest: missing 'romfs_validator' object")
    else:
        cf = rv.get("critical_files")
        if not isinstance(cf, list) or not all(isinstance(x, str) for x in cf):
            errs.append("manifest: romfs_validator.critical_files must be a list of strings")
        else:
            for x in cf:
                if x.startswith(("/", "\\")) or ".." in x.replace("\\", "/").split("/") or re.match(r"^[A-Za-z]:", x):
                    errs.append(f"manifest: critical file path must be relative: {x}")
        n = rv.get("min_file_count")
        if not isinstance(n, int) or isinstance(n, bool) or n < 1:
            errs.append("manifest: romfs_validator.min_file_count must be an integer >= 1")

    rc = m.get("runtime_config", {})
    if rc:
        br = rc.get("base_resolution")
        if br is not None and not (isinstance(br, list) and len(br) == 2 and all(isinstance(x, int) and x > 0 for x in br)):
            errs.append("manifest: runtime_config.base_resolution must be [width, height]")
        fr = rc.get("frame_rate_target")
        if fr is not None and not (isinstance(fr, int) and 1 <= fr <= 240):
            errs.append("manifest: runtime_config.frame_rate_target must be 1..240")

    for i, u in enumerate(m.get("upstream", [])):
        if not (isinstance(u, dict) and all(isinstance(u.get(k), str) and u[k] for k in ("name", "url", "license"))):
            errs.append(f"manifest: upstream[{i}] needs name, url and license")

    if folder != "template" and isinstance(m.get("game_id"), str) and m["game_id"] != folder:
        errs.append(f"manifest: game_id {m['game_id']} does not match folder name {folder}")
    if folder != "template" and m.get("game_id") == "0100000000000000":
        errs.append("manifest: game_id is still the template placeholder")
    return errs


def check_addon(d):
    folder = os.path.basename(os.path.normpath(d))
    errs = []
    mf = os.path.join(d, "manifest.json")
    if not os.path.isfile(mf):
        return [f"{d}: no manifest.json"]
    errs += check_manifest(mf, folder)

    for dirpath, dirnames, filenames in os.walk(d):
        rel_dir = os.path.relpath(dirpath, d)
        if rel_dir == ".":
            for entry in dirnames + filenames:
                if entry not in ALLOWED_TOP:
                    errs.append(f"{folder}/{entry}: not an allowed top-level entry (allowed: {', '.join(sorted(ALLOWED_TOP))})")
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            rel = f"{folder}/" + os.path.relpath(full, d).replace("\\", "/")
            errs += check_names(["addons/" + rel])
            ext = os.path.splitext(fn)[1].lower()
            if ext not in ALLOWED_EXT:
                errs.append(f"{rel}: file type {ext or '(none)'} is not allowed in an addon")
            size = os.path.getsize(full)
            if size > MAX_FILE:
                errs.append(f"{rel}: {size // 1024} KiB is over the {MAX_FILE // 1024 // 1024} MiB limit")
            try:
                with open(full, "rb") as f:
                    head = f.read(4)
                if head in MAGICS:
                    errs.append(f"{rel}: content looks like game or executable data ({head!r})")
            except OSError as e:
                errs.append(f"{rel}: unreadable: {e}")
        if os.path.islink(dirpath):
            errs.append(f"{folder}: symlinked folders are not allowed")
    return errs


def main(argv):
    if "--scan-names" in argv:
        errs = check_names(sys.stdin.read().splitlines())
        for e in errs:
            print("ERROR", e)
        print(f"scan-names: {len(errs)} problem(s)")
        return 1 if errs else 0

    targets = [a for a in argv if not a.startswith("-")]
    if not targets:
        targets = [os.path.join(ADDONS, n) for n in sorted(os.listdir(ADDONS))
                   if os.path.isdir(os.path.join(ADDONS, n))]
    seen = {}
    total = 0
    for t in targets:
        errs = check_addon(t)
        folder = os.path.basename(os.path.normpath(t))
        try:
            gid = json.load(open(os.path.join(t, "manifest.json"), encoding="utf-8")).get("game_id")
            if folder != "template" and gid in seen:
                errs.append(f"duplicate game_id {gid} (also {seen[gid]})")
            seen[gid] = folder
        except (OSError, ValueError):
            pass
        status = "FAIL" if errs else "ok"
        print(f"{status}  {folder}")
        for e in errs:
            print("   ", e)
        total += len(errs)
    print(f"{len(targets)} addon(s) checked, {total} problem(s)")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
