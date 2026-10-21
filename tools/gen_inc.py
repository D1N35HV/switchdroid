#!/usr/bin/env python3
import sys

def gen_smaa(src_path, dst_path):
    with open(src_path, 'rb') as f:
        data = f.read()
    data = data.replace(b'\r', b'')
    cleaned = bytes([b if b < 0x80 else ord('?') for b in data])
    lines = cleaned.decode('latin-1').splitlines()
    out_lines = []
    for line in lines:
        line_escaped = line.replace('\\', '\\\\').replace('"', '\\"')
        out_lines.append(f'"{line_escaped}\\n"\n')
    with open(dst_path, 'w', encoding='utf-8', newline='\n') as f:
        f.writelines(out_lines)

def gen_variants(src_path, dst_path):
    with open(src_path, 'r', encoding='utf-8', errors='ignore') as f:
        text = f.read().replace('\r', '')
    lines = text.splitlines()
    out_lines = []
    for line in lines:
        line_escaped = line.replace('\\', '\\\\').replace('"', '\\"')
        out_lines.append(f'"{line_escaped}\\n"\n')
    out_lines.append('""\n')
    with open(dst_path, 'w', encoding='utf-8', newline='\n') as f:
        f.writelines(out_lines)

if __name__ == '__main__':
    if len(sys.argv) < 4:
        sys.exit("Usage: gen_inc.py <smaa|variants> <src> <dst>")
    mode = sys.argv[1]
    src = sys.argv[2]
    dst = sys.argv[3]
    if mode == 'smaa':
        gen_smaa(src, dst)
    elif mode == 'variants':
        gen_variants(src, dst)
    else:
        sys.exit(f"Unknown mode: {mode}")
