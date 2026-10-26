#!/bin/bash
# Xcode target phase: copy the active game's resources into the app before CodeSign.
# Paths come from build_ipa.sh, not from a per-game rule or a phone-visible Mac path.
set -eu
[ "${DM_COPY_GAME_RESOURCES:-YES}" != NO ] || exit 0
die() { echo "[RED] $*" >&2; exit 1; }
[ "${PLATFORM_NAME:-}" = iphoneos ] || die 'This game needs a physical iPhone or iPad; choose a device, not a simulator.'
[ -f "${SRCROOT:?}/Gen/resources.env" ] || die 'Missing game resource paths; run build_ipa_from_nsp.py --prepare-xcode first.'
source "$SRCROOT/Gen/resources.env"
APP="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
case "$APP" in /*.app) ;; *) die "Unexpected app resource destination: $APP";; esac
# Validate every source before copying or removing anything (the external drive may be disconnected).
if [ "$DM_RESOURCE_SEPARATE_ROM" = 0 ]; then
    [ -e "$DM_RESOURCE_ROMFS/$DM_RESOURCE_MARKER" ] || die "Game files unavailable: $DM_RESOURCE_ROMFS/$DM_RESOURCE_MARKER"
    [ -z "$DM_RESOURCE_AOC" ] || [ -d "$DM_RESOURCE_AOC" ] || die "Add-on content unavailable: $DM_RESOURCE_AOC"
elif [ "$DM_RESOURCE_SEPARATE_ROM" != 1 ]; then die 'DM_RESOURCE_SEPARATE_ROM must be 0 or 1'; fi
[ -d "$SRCROOT/Gen/dm" ] || die 'Missing generated game tables; prepare the game again.'
if [ "$DM_RESOURCE_SEPARATE_ROM" = 1 ]; then
    [ -f "$SRCROOT/Gen/dm/game-data.json" ] || die 'Missing external game-data descriptor; prepare the game again.'
fi
[ -d "$DM_RESOURCE_SHADERS" ] || die "Shader libraries unavailable: $DM_RESOURCE_SHADERS"
DM_RESOURCE_PSO=${DM_RESOURCE_PSO:-}   # (a project prepared before the pipeline archive has none)
[ -z "$DM_RESOURCE_PSO" ] || [ -f "$DM_RESOURCE_PSO/prebuilt.tsv" ] || die "Pipeline archive unavailable: $DM_RESOURCE_PSO"
# The host is compiled from the repository's current sources and loads only msl/b-<its chain version>: after a chain change (a pull, dmsh_chain.py --header) the prepared shaders are another chain's
case "$DM_RESOURCE_MSLDIR" in b-*)
    [ -f "$DM_RESOURCE_CHAIN_H" ] || die "No chain version header: $DM_RESOURCE_CHAIN_H (a project prepared before the chain version moved to dm/gfx/nvn: prepare the game again, build_ipa_from_nsp.py --prepare-xcode)"
    V=$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' "$DM_RESOURCE_CHAIN_H")
    [ "$DM_RESOURCE_MSLDIR" = "b-$V" ] || die "The prepared shaders are chain $DM_RESOURCE_MSLDIR, the sources are now at b-$V: prepare the game again (build_ipa_from_nsp.py --prepare-xcode)";;
esac
echo 'Copy game resources (the first build copies the complete game; later builds sync changes)'
mkdir -p "$APP/msl/$DM_RESOURCE_MSLDIR"
mkdir -p "$APP/dm"
# Remove stale descriptors when switching a prepared project back to a bundled build.
/usr/bin/rsync -a --delete -- "$SRCROOT/Gen/dm/" "$APP/dm/"
if [ "$DM_RESOURCE_SEPARATE_ROM" = 1 ]; then
    rm -rf "$APP/romfs" "$APP/aoc"
else
    mkdir -p "$APP/romfs"
    /usr/bin/rsync -a --delete -- "$DM_RESOURCE_ROMFS/" "$APP/romfs/"
fi
/usr/bin/rsync -a --delete -- "$DM_RESOURCE_SHADERS/" "$APP/msl/$DM_RESOURCE_MSLDIR/"
for old in "$APP/msl/"*; do
    [ "$old" = "$APP/msl/$DM_RESOURCE_MSLDIR" ] || rm -rf "$old"
done
if [ "$DM_RESOURCE_SEPARATE_ROM" = 0 ] && [ -n "$DM_RESOURCE_AOC" ]; then
    mkdir -p "$APP/aoc"
    /usr/bin/rsync -a --delete -- "$DM_RESOURCE_AOC/" "$APP/aoc/"
else
    rm -rf "$APP/aoc"
fi
# The pipeline archive made offline (the shader pairs' bases, build_ipa.sh): the app hands <App>/pso to the host as DM_PSO_BUNDLE
if [ -n "$DM_RESOURCE_PSO" ]; then
    mkdir -p "$APP/pso"
    /usr/bin/rsync -a --delete -- "$DM_RESOURCE_PSO/" "$APP/pso/"
else
    rm -rf "$APP/pso"
fi
