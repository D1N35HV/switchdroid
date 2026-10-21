#!/usr/bin/env python3
"""Creates addons/<title_id>/ from addons/template.

    python tools/new_addon.py 01008cf01baac000 "The Legend of Zelda: Echoes of Wisdom" --build-id 0123456789abcdef \
        --author "Your Name"

The build ID is read from exefs/main offset 0x40 on the player's own dump; see docs/ADDON_GUIDE.md.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HEX16 = re.compile(r"^[0-9a-f]{16}$")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("title_id", help="16 hex digits, the base game's title ID")
    ap.add_argument("name", help="game name as shown in the Hub")
    ap.add_argument("--build-id", action="append", required=True, help="16 hex digits (repeat for several)")
    ap.add_argument("--author", default="Community Developer")
    ap.add_argument("--version", default="1.0.0", help="game version the addon targets")
    args = ap.parse_args()

    tid = args.title_id.lower()
    if not HEX16.match(tid):
        sys.exit("title_id must be 16 hex digits")
    bids = [b.lower() for b in args.build_id]
    if not all(HEX16.match(b) for b in bids):
        sys.exit("build ids must be 16 hex digits")

    dest = os.path.join(ROOT, "addons", tid)
    if os.path.exists(dest):
        sys.exit(f"{dest} already exists")
    shutil.copytree(os.path.join(ROOT, "addons", "template"), dest)

    mf = os.path.join(dest, "manifest.json")
    with open(mf, encoding="utf-8") as f:
        m = json.load(f)
    m.update(game_id=tid, name=args.name, version=args.version, build_ids=bids, author=args.author)
    with open(mf, "w", encoding="utf-8", newline="\n") as f:
        json.dump(m, f, indent=2)
        f.write("\n")

    print(f"created {dest}")
    print("next: set romfs_validator.critical_files / min_file_count from your own dump, add `upstream` credits and a")
    print("`license` if you reuse a community project, then run: python tools/validate_addon.py addons/" + tid)
    subprocess.call([sys.executable, os.path.join(ROOT, "tools", "validate_addon.py"), dest])


if __name__ == "__main__":
    main()
