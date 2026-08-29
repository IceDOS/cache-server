#!/usr/bin/env python3
"""Resolve tracked-input revisions from generated sub-flake locks.

A tracked input is the bare LEAF node (`nodes.<name>`) inside its module's
sub-flake. Exact key match wins; `endswith("-" + name)` handles prefixed keys.
A `follows` input (array target) has no resolvable revision and is skipped.
"""

import argparse
import json
import sys
import tomllib
from pathlib import Path


def lookup(lock: dict, name: str):
    nodes = lock.get("nodes", {})
    key = name if name in nodes else next((k for k in nodes if k.endswith("-" + name)), None)
    if key is None:
        return None

    entry = nodes[key].get("inputs", {}).get(name)
    if isinstance(entry, list):
        return None  # follows: no resolvable revision
    if isinstance(entry, str):
        key = entry  # reference to another node

    node = nodes.get(key) or {}
    rev = (node.get("locked") or {}).get("rev") or (node.get("original") or {}).get("rev")
    return {"key": key, "rev": rev} if rev else None


def tracked_names(toml_path: str) -> list[str]:
    data = tomllib.load(open(toml_path, "rb"))
    return [entry["name"] for entry in data["trackedInputs"]]


def cmd_extract(args):
    names = args.names.split(",") if args.names else tracked_names(args.toml)
    lock = json.load(open(args.lock))
    out = {}
    for name in names:
        found = lookup(lock, name)
        if found:
            out[name] = found
        else:
            print(f"warning: could not resolve a revision for tracked input '{name}'", file=sys.stderr)
    print(json.dumps(out))


def cmd_diff(args):
    names = tracked_names(args.toml)
    base = json.load(open(args.base)) if Path(args.base).exists() else {}
    locks_dir = Path(args.locks_dir)
    out = {}
    for name in names:
        # Last config wins, mirroring the detector.
        found = None
        for cfg in (locks_dir / f"{Path(cfg).stem}.lock" for cfg in configs_for(args.toml, name)):
            if not cfg.exists():
                continue
            found = lookup(json.load(open(cfg)), name)
        if not found:
            continue
        old = base.get(found["key"], "")
        if old != found["rev"]:
            out[name] = {"name": name, "key": found["key"], "rev": found["rev"], "old": old or None}
    print(json.dumps(out))


def configs_for(toml_path: str, name: str) -> list[str]:
    data = tomllib.load(open(toml_path, "rb"))
    for entry in data["trackedInputs"]:
        if entry["name"] == name:
            return entry["configs"]
    return []


parser = argparse.ArgumentParser(description=__doc__)
sub = parser.add_subparsers(dest="cmd", required=True)

p_extract = sub.add_parser("extract", help="resolve revs from one lock")
p_extract.add_argument("--lock", required=True)
p_extract.add_argument("--names", help="comma-separated; defaults to every tracked input")
p_extract.add_argument("--toml", default="tracked-inputs.toml")

p_diff = sub.add_parser("diff", help="revs that differ from a base mapping")
p_diff.add_argument("--toml", default="tracked-inputs.toml")
p_diff.add_argument("--locks-dir", required=True)
p_diff.add_argument("--base", default="state/tracked-inputs.json")

args = parser.parse_args()
{"extract": cmd_extract, "diff": cmd_diff}[args.cmd](args)
