#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CLIPMOAR_DIR="${CLIPMOAR_DIR:-$root/../clipmoar}"
cd "$root"
xcodegen generate
