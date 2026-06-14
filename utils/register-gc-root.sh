#!/usr/bin/env bash

set -e

new_path="$HOME/gc-roots/$(date '+%Y%m%d%H%M%S')"
mkdir -p "$new_path"
cd "$new_path"

nix build "$1"
