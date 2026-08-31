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
from typing import TypeAlias, cast

# Recursive JSON value, so lock/toml data stays typed without Any.
JSON: TypeAlias = str | int | float | bool | None | list["JSON"] | dict[str, "JSON"]


def _sub_dict(value: JSON) -> dict[str, JSON]:
    return value if isinstance(value, dict) else {}


def repo_of(node: dict[str, JSON]) -> str:
    # "scheme:owner/repo" identity of the leaf, so consumers can guard a name
    # match against the repo it actually points at.
    orig = _sub_dict(node.get("original"))
    kind = orig.get("type")
    if kind in ("github", "gitlab", "sourcehut"):
        return f"{kind}:{orig.get('owner')}/{orig.get('repo')}"
    if kind == "git":
        url = orig.get("url", "")
        return url if isinstance(url, str) else ""
    return ""


def lookup(lock: dict[str, JSON], name: str) -> dict[str, str] | None:
    nodes = _sub_dict(lock.get("nodes"))
    key = name if name in nodes else next(
        (k for k in nodes if k.endswith("-" + name)), None
    )
    if key is None:
        return None

    node = _sub_dict(nodes.get(key))
    entry = _sub_dict(node.get("inputs")).get(name)
    if isinstance(entry, list):
        return None  # follows: no resolvable revision
    if isinstance(entry, str):
        key = entry  # reference to another node

    node = _sub_dict(nodes.get(key))
    locked = _sub_dict(node.get("locked"))
    original = _sub_dict(node.get("original"))
    rev = locked.get("rev") or original.get("rev")
    if not isinstance(rev, str):
        return None
    return {"key": key, "rev": rev, "repo": repo_of(node)}


def _tracked_inputs(toml_path: str) -> list[dict[str, JSON]]:
    with open(toml_path, "rb") as fh:
        data = _sub_dict(cast(JSON, tomllib.load(fh)))
    return [cast("dict[str, JSON]", e) for e in cast("list[JSON]", data["trackedInputs"])]


def tracked_names(toml_path: str) -> list[str]:
    return [cast("str", e["name"]) for e in _tracked_inputs(toml_path)]


def configs_for(toml_path: str, name: str) -> list[str]:
    for e in _tracked_inputs(toml_path):
        if e.get("name") == name:
            return [cast("str", c) for c in cast("list[JSON]", e.get("configs", []))]
    return []


def cmd_extract(args: argparse.Namespace) -> None:
    names_arg = cast(str, args.names)
    toml_path = cast(str, args.toml)
    lock_path = cast(str, args.lock)
    names = names_arg.split(",") if names_arg else tracked_names(toml_path)
    lock = cast("dict[str, JSON]", json.load(open(lock_path)))
    out: dict[str, JSON] = {}
    for name in names:
        found = lookup(lock, name)
        if found:
            out[name] = cast(JSON, found)
        else:
            print(f"warning: could not resolve a revision for tracked input '{name}'", file=sys.stderr)
    print(json.dumps(out))


def cmd_diff(args: argparse.Namespace) -> None:
    toml_path = cast(str, args.toml)
    base_path = cast(str, args.base)
    locks_dir_path = cast(str, args.locks_dir)
    names = tracked_names(toml_path)
    base = cast("dict[str, JSON]", json.load(open(base_path))) if Path(base_path).exists() else {}
    locks_dir = Path(locks_dir_path)
    out: dict[str, JSON] = {}
    for name in names:
        # Last config wins, mirroring the detector.
        found = None
        for cfg in (locks_dir / f"{Path(cfg).stem}.lock" for cfg in configs_for(toml_path, name)):
            if not cfg.exists():
                continue
            found = lookup(cast("dict[str, JSON]", json.load(open(cfg))), name)
        if not found:
            continue
        old = base.get(found["key"], "")
        if old != found["rev"]:
            out[name] = {"name": name, "key": found["key"], "rev": found["rev"], "old": old or None}
    print(json.dumps(out))


parser = argparse.ArgumentParser(description=__doc__)
sub = parser.add_subparsers(dest="cmd", required=True)

p_extract = sub.add_parser("extract", help="resolve revs from one lock")
_ = p_extract.add_argument("--lock", required=True)
_ = p_extract.add_argument("--names", help="comma-separated; defaults to every tracked input")
_ = p_extract.add_argument("--toml", default="tracked-inputs.toml")

p_diff = sub.add_parser("diff", help="revs that differ from a base mapping")
_ = p_diff.add_argument("--toml", default="tracked-inputs.toml")
_ = p_diff.add_argument("--locks-dir", required=True)
_ = p_diff.add_argument("--base", default="state/tracked-inputs.json")

args = parser.parse_args()
cmd = cast(str, args.cmd)
{"extract": cmd_extract, "diff": cmd_diff}[cmd](args)
