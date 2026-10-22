#!/bin/bash
# Start Breath of the Wild in the Mac host from an existing build folder.
# Usage: scripts/run_botw_mac.sh [--windowed]
# Environment:
#   BOTW_BUILD=<id>_build folder   default: $HOME/Games/ZeldaWild/01007EF00011E000_build
#   BOTW_VERSION=<version>         default: v1114112
#   DM_SAVE=<save folder>          default: <build>/run/save
#   DM_TEMP=<temporary folder>     default: <build>/run/tmp
#   DM_ASPECT=0                    compare with the old 16:9 display
#   DM_ASPECT_RATIO=20:9           render and letterbox a custom aspect
#   DM_WINDOW_SIZE=1600x720        windowed size (with --windowed and DM_ASPECT_RATIO, sized to the ratio if unset)
#   DM_KEYS=...                    scripted input (see docs/development.md)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${BOTW_BUILD:-$HOME/Games/ZeldaWild/01007EF00011E000_build}"
VERSION="${BOTW_VERSION:-v1114112}"
WINDOWED=0

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi
if [ "${1:-}" = "--windowed" ]; then
    WINDOWED=1
elif [ "$#" -gt 0 ]; then
    printf 'unknown argument: %s (try --help)\n' "$1" >&2
    exit 2
fi

PATCHED="$BUILD/patched_$VERSION"
ROMFS="${DM_ROMFS:-$BUILD/extract/$VERSION/RomFS}"
MSL="${DM_MSL_DIR:-$BUILD/shader/cache}"
SAVE="${DM_SAVE:-$BUILD/run/save}"
TEMP="${DM_TEMP:-$BUILD/run/tmp}"

if [ ! -d "$BUILD" ]; then
    printf 'no build folder: %s\nset BOTW_BUILD to the game work folder.\n' "$BUILD" >&2
    exit 1
fi
if [ ! -d "$PATCHED" ]; then
    printf 'no patched modules: %s\nset BOTW_VERSION to a version under %s.\n' "$PATCHED" "$BUILD" >&2
    exit 1
fi
if [ ! -d "$ROMFS" ]; then
    printf 'no RomFS: %s\n' "$ROMFS" >&2
    exit 1
fi
if [ ! -d "$MSL" ]; then
    printf 'no shader cache: %s\n' "$MSL" >&2
    exit 1
fi

make -s -C "$ROOT/dm/host" GAME=01007EF00011E000 dmhost

mkdir -p "$SAVE" "$TEMP"
export DM_ROOT="$BUILD" DM_ROMFS="$ROMFS" DM_SAVE="$SAVE" DM_TEMP="$TEMP" DM_MSL_DIR="$MSL"
export DM_WINDOW="${DM_WINDOW:-1}"
export DM_FULLSCREEN="${DM_FULLSCREEN:-1}"
if [ "$WINDOWED" = 1 ]; then
    export DM_FULLSCREEN=0
    if [ -z "${DM_WINDOW_SIZE:-}" ] && [ -n "${DM_ASPECT_RATIO:-}" ]; then
        H=$(python3 - "$DM_ASPECT_RATIO" <<'PY'
import re, sys
s = sys.argv[1]
try:
    m = re.fullmatch(r'\s*([0-9.]+)\s*[:/x]\s*([0-9.]+)\s*', s)
    r = float(m.group(1)) / float(m.group(2)) if m else float(s)
    if not 0.1 <= r <= 10: raise ValueError('ratio out of range')
    print(round(1600 / r))
except (ValueError, ZeroDivisionError):
    sys.exit('invalid DM_ASPECT_RATIO: ' + s)
PY
)
        export DM_WINDOW_SIZE="1600x$H"
    fi
fi

printf 'Breath of the Wild: %s\n' "$PATCHED"
printf 'save: %s\n' "$SAVE"
exec "$ROOT/dm/host/dmhost" "$PATCHED"
