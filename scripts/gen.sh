#!/bin/sh
set -eu
. "$(dirname -- "$0")/config.sh"
cd "$root"
xcodegen generate
