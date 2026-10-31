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
resource_dm=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().parents[2])' "$0")
python3 "$resource_dm/tools/romfs.py" "$DM_RESOURCE_ROMFS" "$DM_RESOURCE_MARKER" || die "Game files unavailable: $DM_RESOURCE_ROMFS/$DM_RESOURCE_MARKER"
[ -z "$DM_RESOURCE_AOC" ] || [ -d "$DM_RESOURCE_AOC" ] || die "Add-on content unavailable: $DM_RESOURCE_AOC"
[ -d "$SRCROOT/Gen/dm" ] || die 'Missing generated game tables; prepare the game again.'
[ -d "$DM_RESOURCE_SHADERS" ] || die "Shader libraries unavailable: $DM_RESOURCE_SHADERS"
DM_RESOURCE_PSO=${DM_RESOURCE_PSO:-}   # (a project prepared before the pipeline archive has none)
[ -z "$DM_RESOURCE_PSO" ] || [ -f "$DM_RESOURCE_PSO/prebuilt.tsv" ] || die "Pipeline archive unavailable: $DM_RESOURCE_PSO"
# The host is compiled from the repository's current sources and loads only msl/b-<its chain version>: after a chain change (a pull, dmsh_chain.py --header) the prepared shaders are another chain's
case "$DM_RESOURCE_MSLDIR" in b-*)
    [ -f "$DM_RESOURCE_CHAIN_H" ] || die "No chain version header: $DM_RESOURCE_CHAIN_H (a project prepared before the chain version moved to dm/gfx/nvn: prepare the game again, build_ipa_from_nsp.py --prepare-xcode)"
    V=$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' "$DM_RESOURCE_CHAIN_H")
    [ "$DM_RESOURCE_MSLDIR" = "b-$V" ] || die "The prepared shaders are chain $DM_RESOURCE_MSLDIR, the sources are now at b-$V: prepare the game again (build_ipa_from_nsp.py --prepare-xcode)";;
esac
if [ "${DM_COPY_ROMFS:-YES}" = NO ] && [ -n "$DM_RESOURCE_AOC" ]; then
    mkdir -p "$SRCROOT/Gen/game-data"
    python3 "$resource_dm/tools/game_image.py" --reuse "$DM_RESOURCE_ROMFS" "$DM_RESOURCE_AOC" "$SRCROOT/Gen/game-data/RomFS.img" || die 'Combine game files and DLC'
    DM_RESOURCE_ROMFS=$SRCROOT/Gen/game-data/RomFS.img; DM_RESOURCE_AOC=
fi
echo 'Synchronize game resources (DM_COPY_ROMFS=NO keeps game data and DLC external)'
mkdir -p "$APP/msl/$DM_RESOURCE_MSLDIR"
mkdir -p "$APP/dm"
# Keep generated tables synchronized with the current build.
/usr/bin/rsync -a --delete -- "$SRCROOT/Gen/dm/" "$APP/dm/"
# DM_COPY_ROMFS=NO: base game and DLC stay in one external image, read directly from Documents/romfs.img.
if [ "${DM_COPY_ROMFS:-YES}" = NO ]; then
    rm -rf "$APP/romfs" "$APP/romfs.img" "$APP/romfs.id" "$APP/romfs.base.id"
    # the image's identity (dm/host/romfs_identity.h): main.m uses only a Documents/romfs.img that matches it; a RomFS folder has none yet (push_romfs.sh packs it), so no identity is written for it
    if [ -f "$DM_RESOURCE_ROMFS" ]; then
        python3 -I "$resource_dm/tools/game_image.py" --identities "$DM_RESOURCE_ROMFS" "$APP" "${DM_RESOURCE_TITLE:-}" "${DM_RESOURCE_VERSION:-}" "${DM_RESOURCE_BUILD:-}" || die "identity of $DM_RESOURCE_ROMFS"
    fi
elif [ -f "$DM_RESOURCE_ROMFS" ]; then
    /usr/bin/rsync -a -- "$DM_RESOURCE_ROMFS" "$APP/romfs.img"
    rm -rf "$APP/romfs"; rm -f "$APP/romfs.id" "$APP/romfs.base.id"
else
    mkdir -p "$APP/romfs"; /usr/bin/rsync -a --delete -- "$DM_RESOURCE_ROMFS/" "$APP/romfs/"
    rm -f "$APP/romfs.img" "$APP/romfs.id" "$APP/romfs.base.id"
fi
# Analysis MSL is an external cache/prefill input, not a runtime resource; remove old copies only from this shader folder.
/usr/bin/rsync -a --delete --delete-excluded --exclude '*.metal' -- "$DM_RESOURCE_SHADERS/" "$APP/msl/$DM_RESOURCE_MSLDIR/"
for old in "$APP/msl/"*; do
    [ "$old" = "$APP/msl/$DM_RESOURCE_MSLDIR" ] || rm -rf "$old"
done
if [ "${DM_COPY_ROMFS:-YES}" != NO ] && [ -n "$DM_RESOURCE_AOC" ]; then
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
