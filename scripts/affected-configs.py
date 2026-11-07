#!/usr/bin/env python3
"""Print, as a JSON list, the configs the given tracked inputs can change.

"*" means every config: core, nixpkgs and any input tracked-inputs.toml does not
list. A module repo also changes its staged 90-ext-<repo>-* package configs.
"""

import json
import sys
import tomllib

GLOBAL = {"icedos", "nixpkgs", "home-manager", "cache-server"}
REPO_PREFIX = "icedos-github_icedos_"


def main() -> int:
    with open("tracked-inputs.toml", "rb") as fh:
        tracked = {t["name"]: t.get("configs", []) for t in tomllib.load(fh).get("trackedInputs", [])}

    out: set[str] = set()
    for key in sys.argv[1:]:
        # state/tracked-inputs.json may key an input by its lock node, e.g. "<prefix>-<name>".
        name = key if key in tracked else next((n for n in tracked if key.endswith("-" + n)), None)
        if name is None or name in GLOBAL:
            print(json.dumps(["*"]))
            return 0
        out.update(tracked[name])
        if name.startswith(REPO_PREFIX):
            out.add(f"90-ext-{name[len(REPO_PREFIX):]}-*")
    print(json.dumps(sorted(out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
