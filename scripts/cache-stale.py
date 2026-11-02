#!/usr/bin/env python3
"""Print the narinfos no retained nixpkgs revision needs.

Roots are the NixOS toplevels of the newest merged revisions that are in the
bucket, plus every narinfo younger than the grace period. Reads `git log`
subjects (newest first) on stdin and walks each root's References.
"""

import argparse
import re
import sys
import time
from pathlib import Path

SUBJECT = re.compile(r"^update\(nixpkgs\): \S+ -> ([0-9a-f]{7,})")
TOPLEVEL = re.compile(r"-nixos-system-.*\.([0-9a-f]{7,})$")


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
    parser.add_argument("narinfo_dir", type=Path)
    parser.add_argument("--keep", type=int, default=3)
    parser.add_argument("--grace-hours", type=float, default=48)
    args = parser.parse_args()

    newer_than = time.time() - args.grace_hours * 3600
    files: dict[str, Path] = {}
    refs: dict[str, list[str]] = {}
    toplevels: dict[str, list[str]] = {}
    young: list[str] = []
    for path in args.narinfo_dir.rglob("*.narinfo"):
        parsed = read_narinfo(path)
        if parsed is None:
            print(f"keeping unparsable {path}", file=sys.stderr)
            continue
        name, references = parsed
        files[name], refs[name] = path, references
        if match := TOPLEVEL.search(name):
            toplevels.setdefault(match.group(1), []).append(name)
        # An open update PR pushes before it merges, so its paths have no merged revision yet.
        if path.stat().st_mtime >= newer_than:
            young.append(name)

    kept: list[str] = []
    for line in sys.stdin:
        match = SUBJECT.match(line)
        if not match:
            continue
        rev = next((r for r in toplevels if match.group(1).startswith(r)), None)
        if rev and rev not in kept:
            kept.append(rev)
        if len(kept) == args.keep:
            break
    # An empty list would mark the whole bucket stale.
    if not kept:
        print("no merged nixpkgs revision has a toplevel in the bucket", file=sys.stderr)
        return 1

    live: set[str] = set()
    stack = young + [name for rev in kept for name in toplevels[rev]]
    while stack:
        name = stack.pop()
        if name not in live and name in refs:
            live.add(name)
            stack.extend(refs[name])

    print(f"keeping revisions: {' '.join(kept)}", file=sys.stderr)
    for name in files.keys() - live:
        print(files[name])
    return 0


if __name__ == "__main__":
    sys.exit(main())
