#!/usr/bin/env python3
"""Print narinfos not referenced by active per-config roots or young paths.

Roots are the newest toplevel per config plus rollback toplevels, read from
per-config root files, plus every narinfo younger than the grace period.
"""

import argparse
import os
import sys
import time
from pathlib import Path


def read_narinfo(path: Path) -> tuple[str, list[str]] | None:
    fields = dict(
        line.split(": ", 1)
        for line in path.read_text(errors="replace").splitlines()
        if ": " in line
    )
    store_path = fields.get("StorePath")
    if not store_path:
        return None
    name = store_path.rsplit("/", 1)[-1]
    return name, [r for r in fields.get("References", "").split() if r != name]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("narinfo_dir", type=Path, help="Directory containing downloaded narinfos")
    parser.add_argument("roots_dir", type=Path, nargs="?", default=None, help="Directory with per-config root files")
    parser.add_argument("--roots-dir", dest="roots_dir_opt", type=Path, default=None)
    parser.add_argument("--config-dir", type=Path, default=None, help="Directory with config/*.toml")
    parser.add_argument("--keep", type=int, default=2, help="Number of toplevels to keep per config")
    parser.add_argument("--root-days", type=float, default=7.0, help="Days to keep historical roots")
    parser.add_argument("--orphan-days", type=float, default=30.0, help="Days before an unrefreshed non-checked-in root file is ignored")
    parser.add_argument("--grace-hours", type=float, default=48, help="Grace period in hours for young paths")
    default_ratio = float(os.environ.get("ICEDOS_MIN_LIVE_RATIO", "0.5")) if os.environ.get("ICEDOS_MIN_LIVE_RATIO") else 0.5
    parser.add_argument("--min-live-ratio", type=float, default=default_ratio, help="Minimum ratio of live paths to total narinfos")
    args = parser.parse_args()

    roots_dir = args.roots_dir_opt or args.roots_dir
    if roots_dir is None:
        candidate = args.narinfo_dir.parent / "roots"
        if candidate.is_dir():
            roots_dir = candidate
        else:
            print("roots directory required", file=sys.stderr)
            return 1

    config_dir = args.config_dir or (Path(__file__).resolve().parent.parent / "config")
    if not config_dir.is_dir():
        print(f"config directory not found: {config_dir}", file=sys.stderr)
        return 1

    expected_configs = sorted(p.stem for p in config_dir.glob("*.toml"))
    if not expected_configs:
        print(f"no configs found in {config_dir}", file=sys.stderr)
        return 1

    if not roots_dir.is_dir():
        print(f"roots directory not found: {roots_dir}", file=sys.stderr)
        return 1

    for cfg in expected_configs:
        if not (roots_dir / cfg).is_file():
            print(f"missing root file for config: {cfg}", file=sys.stderr)
            return 1

    # 90-ext-* configs are staged from module repos at build time, so only their root files list them.
    # One not rebuilt for --orphan-days belongs to a build.toml that was removed.
    orphan_cutoff = time.time() - args.orphan_days * 86400
    root_configs = sorted(p.name for p in roots_dir.iterdir() if p.is_file())
    kept_roots: list[str] = []
    root_cutoff = time.time() - args.root_days * 86400
    for cfg in root_configs:
        root_file = roots_dir / cfg
        lines = [
            line.strip()
            for line in root_file.read_text(errors="replace").splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
        if not lines:
            print(f"empty roots for config: {cfg}", file=sys.stderr)
            return 1
        entries = []
        for line in lines:
            parts = line.split()
            ts = float(parts[0]) if len(parts) > 1 and parts[0].replace(".", "", 1).isdigit() else None
            entries.append((ts, parts[-1].rsplit("/", 1)[-1]))
        # Every build rewrites the newest line's timestamp, so a stale one means nothing builds this config.
        newest = max((ts for ts, _ in entries if ts is not None), default=None)
        if cfg not in expected_configs and newest is not None and newest < orphan_cutoff:
            print(f"ignoring roots of retired config: {cfg}", file=sys.stderr)
            continue
        for idx, (ts, name) in enumerate(entries):
            if idx < args.keep or (ts is not None and ts >= root_cutoff):
                kept_roots.append(name)

    if not kept_roots:
        print("no roots found across configs", file=sys.stderr)
        return 1

    newer_than = time.time() - args.grace_hours * 3600
    files: dict[str, Path] = {}
    refs: dict[str, list[str]] = {}
    young: list[str] = []
    for path in args.narinfo_dir.rglob("*.narinfo"):
        parsed = read_narinfo(path)
        if parsed is None:
            print(f"keeping unparsable {path}", file=sys.stderr)
            continue
        name, references = parsed
        files[name], refs[name] = path, references
        # An open PR pushes before merging, so its paths have no root file yet.
        if path.stat().st_mtime >= newer_than:
            young.append(name)

    # Every retained root toplevel must have a narinfo in the cache.
    for root in kept_roots:
        if root not in files:
            print(f"root toplevel has no narinfo in cache: {root}", file=sys.stderr)
            return 1

    live: set[str] = set()
    stack = young + kept_roots
    while stack:
        name = stack.pop()
        if name not in live and name in refs:
            live.add(name)
            stack.extend(refs[name])

    # A suspiciously small live set indicates broken traversal or missing narinfos.
    if len(files) >= 10 and (len(live) / len(files)) < args.min_live_ratio:
        ratio = len(live) / len(files)
        print(
            f"suspiciously small live set: {len(live)} live of {len(files)} total "
            f"({ratio:.1%} < {args.min_live_ratio:.0%}); aborting prune to prevent data loss",
            file=sys.stderr,
        )
        return 1

    print(
        f"keeping {len(kept_roots)} roots across {len(root_configs)} configs, "
        f"{len(young)} young paths, {len(live)} live paths",
        file=sys.stderr,
    )
    for name in sorted(files.keys() - live):
        print(files[name])
    return 0


if __name__ == "__main__":
    sys.exit(main())
