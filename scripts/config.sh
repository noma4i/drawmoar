#!/bin/sh
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
team_override=${DRAWMOAR_TEAM_ID-}
bundle_override=${DRAWMOAR_BUNDLE_ID-}
if [ -f "$root/scripts/local.env" ]; then
    set -a
    . "$root/scripts/local.env"
    set +a
fi
export DRAWMOAR_TEAM_ID="${team_override:-${DRAWMOAR_TEAM_ID:-89QF7X66FR}}"
export DRAWMOAR_BUNDLE_ID="${bundle_override:-${DRAWMOAR_BUNDLE_ID:-com.noma4i.DrawMoar}}"
