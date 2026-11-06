#!/usr/bin/env python3
"""Seed placeholder narinfos for paths that opt out of caching."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def format_size(bytes_val: int) -> str:
    if bytes_val < 1024:
        return f"{bytes_val} B"
    if bytes_val < 1024 * 1024:
        return f"{bytes_val / 1024:.1f} KiB"
    if bytes_val < 1024 * 1024 * 1024:
        return f"{bytes_val / (1024 * 1024):.1f} MiB"
    return f"{bytes_val / (1024 * 1024 * 1024):.2f} GiB"


def chunked(items: list[str], chunk_size: int = 200):
    for i in range(0, len(items), chunk_size):
        yield items[i : i + chunk_size]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", type=Path, required=True, help="Push-cache stage directory")
    parser.add_argument("--cfg", type=str, default="", help="Config label for logs")
    parser.add_argument("--paths-file", type=Path, default=None, help="File holding closure paths")
    args = parser.parse_args()

    if args.paths_file:
        raw_paths = args.paths_file.read_text(errors="replace").splitlines()
    else:
        raw_paths = sys.stdin.read().splitlines()

    paths = [p.strip() for p in raw_paths if p.strip()]
    cfg = args.cfg or "unknown"
    if not paths:
        print(f"{cfg}: skipped 0 prebuilt/local paths (0 B)", file=sys.stderr)
        return 0

    path_to_drv: dict[str, str] = {}
    for batch in chunked(paths, 500):
        cmd = ["nix-store", "-q", "--deriver", *batch]
        res = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if res.returncode == 0:
            lines = res.stdout.splitlines()
            for p, d in zip(batch, lines):
                path_to_drv[p] = d.strip()

    existing_drvs = sorted({d for d in path_to_drv.values() if os.path.isabs(d) and os.path.exists(d)})
    if not existing_drvs:
        print(f"{cfg}: skipped 0 prebuilt/local paths (0 B)", file=sys.stderr)
        return 0

    def is_drv_marked(drv_info: dict) -> bool:
        env = drv_info.get("env", {})
        if env.get("icedosNoCache") in ("1", "true", True):
            return True
        if "__json" in env:
            try:
                parsed = json.loads(env["__json"])
                if parsed.get("icedosNoCache") in ("1", "true", True):
                    return True
            except Exception:
                pass
        structured = drv_info.get("structuredAttrs", {})
        if structured.get("icedosNoCache") in ("1", "true", True):
            return True
        return False

    marked_drvs: set[str] = set()
    for batch in chunked(existing_drvs, 200):
        cmd = ["nix", "derivation", "show", *batch]
        res = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if res.returncode != 0:
            continue
        try:
            data = json.loads(res.stdout)
        except json.JSONDecodeError:
            continue
        derivations = data.get("derivations", data)
        for drv_path, drv_info in derivations.items():
            if is_drv_marked(drv_info):
                marked_drvs.add(drv_path)
                drv_base = os.path.basename(drv_path)
                marked_drvs.add(drv_base)

    marked_paths = [p for p in paths if path_to_drv.get(p) in marked_drvs or os.path.basename(path_to_drv.get(p, "")) in marked_drvs]
    if not marked_paths:
        print(f"{cfg}: skipped 0 prebuilt/local paths (0 B)", file=sys.stderr)
        return 0

    stage = args.stage
    stage.mkdir(parents=True, exist_ok=True)

    path_infos: dict[str, dict] = {}
    for batch in chunked(marked_paths, 200):
        cmd = ["nix", "path-info", "--json", "--json-format", "1", *batch]
        res = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if res.returncode == 0:
            try:
                path_infos.update(json.loads(res.stdout))
            except json.JSONDecodeError:
                pass

    total_bytes = 0
    seeded_files: list[str] = []
    for p in marked_paths:
        info = path_infos.get(p)
        if not info:
            continue
        h = os.path.basename(p)[:32]
        nar_hash = info.get("narHash", "")
        nar_size = info.get("narSize", 0)
        total_bytes += nar_size
        refs = " ".join(os.path.basename(r) for r in info.get("references", []))
        narinfo_content = (
            f"StorePath: {p}\n"
            f"URL: nar/dummy.nar\n"
            f"Compression: none\n"
            f"NarHash: {nar_hash}\n"
            f"NarSize: {nar_size}\n"
            f"References: {refs}\n"
        )
        narinfo_name = f"{h}.narinfo"
        (stage / narinfo_name).write_text(narinfo_content)
        seeded_files.append(narinfo_name)
        print(narinfo_name)

    print(f"{cfg}: skipped {len(seeded_files)} prebuilt/local paths ({format_size(total_bytes)})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
