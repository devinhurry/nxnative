#!/bin/bash
# Xcode target phase: copy the active game's resources into the app before CodeSign.
# Paths come from build_ipa.sh, not from a per-game rule or a phone-visible Mac path.
set -eu
[ "${DM_COPY_GAME_RESOURCES:-YES}" != NO ] || [ -f "${SRCROOT:-}/Gen/dm/graphics-required.json" ] || exit 0
die() { echo "[RED] $*" >&2; exit 1; }
[ "${PLATFORM_NAME:-}" = iphoneos ] || die 'This game needs a physical iPhone or iPad; choose a device, not a simulator.'
[ -f "${SRCROOT:?}/Gen/resources.env" ] || die 'Missing game resource paths; run build_ipa_from_nsp.py --prepare-xcode first.'
source "$SRCROOT/Gen/resources.env"
resource_dm=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().parents[2])' "$0")
if [ -f "$SRCROOT/Gen/dm/graphics-required.json" ] && [ -n "${DM_RESOURCE_TABLES:-}" ]; then
    DM_GAMES_DIR=$(dirname "$DM_RESOURCE_TABLES") DM_GAMES_FIRST=1 python3 "$resource_dm/tools/graphics_pack.py" \
        --check "$SRCROOT/Gen/dm/graphics-required.json" --game "$DM_RESOURCE_TITLE" --build "$DM_RESOURCE_BUILD" \
        --api "${DM_RESOURCE_API:-nvn}" --library "$DM_RESOURCE_MSLDIR" --shaders "$DM_RESOURCE_SHADERS" --tables "$DM_RESOURCE_TABLES" \
        || die 'Graphics compatibility changed; prepare the game again before building.'
fi
[ "${DM_COPY_GAME_RESOURCES:-YES}" != NO ] || exit 0
APP="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
case "$APP" in /*.app) ;; *) die "Unexpected app resource destination: $APP";; esac
# Validate every source before copying or removing anything (the external drive may be disconnected).
python3 "$resource_dm/tools/romfs.py" "$DM_RESOURCE_ROMFS" "$DM_RESOURCE_MARKER" || die "Game files unavailable: $DM_RESOURCE_ROMFS/$DM_RESOURCE_MARKER"
[ -z "$DM_RESOURCE_AOC" ] || [ -d "$DM_RESOURCE_AOC" ] || die "Add-on content unavailable: $DM_RESOURCE_AOC"
[ -d "$SRCROOT/Gen/dm" ] || die 'Missing generated game tables; prepare the game again.'
DM_RESOURCE_PSO=${DM_RESOURCE_PSO:-}   # (a project prepared before the pipeline archive has none)
DM_COPY_GRAPHICS=${DM_COPY_GRAPHICS:-${DM_RESOURCE_COPY_GRAPHICS:-YES}}
if [ "${DM_SKIP_ROMFS:-NO}" = YES ] && [ "${DM_COPY_ROMFS:-YES}" != NO ]; then die 'DM_SKIP_ROMFS=YES requires DM_COPY_ROMFS=NO'; fi
if [ "$DM_COPY_GRAPHICS" != NO ]; then
    [ -d "$DM_RESOURCE_SHADERS" ] || die "Shader libraries unavailable: $DM_RESOURCE_SHADERS"
    [ -z "$DM_RESOURCE_PSO" ] || [ -f "$DM_RESOURCE_PSO/prebuilt.tsv" ] || die "Pipeline archive unavailable: $DM_RESOURCE_PSO"
fi
# The host is compiled from the repository's current sources and loads only msl/b-<its chain version>: after a chain change (a pull, dmsh_chain.py --header) the prepared shaders are another chain's
case "$DM_RESOURCE_MSLDIR" in b-*)
    [ -f "$DM_RESOURCE_CHAIN_H" ] || die "No chain version header: $DM_RESOURCE_CHAIN_H (a project prepared before the chain version moved to dm/gfx/nvn: prepare the game again, build_ipa_from_nsp.py --prepare-xcode)"
    V=$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' "$DM_RESOURCE_CHAIN_H")
    [ "$DM_RESOURCE_MSLDIR" = "b-$V" ] || die "The prepared shaders are chain $DM_RESOURCE_MSLDIR, the sources are now at b-$V: prepare the game again (build_ipa_from_nsp.py --prepare-xcode)";;
esac
if [ "${DM_COPY_ROMFS:-YES}" = NO ] && [ "${DM_SKIP_ROMFS:-NO}" != YES ] && [ -n "$DM_RESOURCE_AOC" ]; then
    mkdir -p "$SRCROOT/Gen/game-data"
    python3 "$resource_dm/tools/game_image.py" --reuse "$DM_RESOURCE_ROMFS" "$DM_RESOURCE_AOC" "$SRCROOT/Gen/game-data/RomFS.img" || die 'Combine game files and DLC'
    DM_RESOURCE_ROMFS=$SRCROOT/Gen/game-data/RomFS.img; DM_RESOURCE_AOC=
fi
echo 'Synchronize game resources (DM_COPY_ROMFS=NO keeps game data and DLC external)'
# A first copy into an empty place is an APFS clone (cp -c, clonefile): the game's files take no more disk space until either side changes, where rsync wrote all of them again
# (BotW's app is 16.5 GB; a full copy filled a Mac that had 13 GB free). cp falls back to a plain copy on a volume without clones. Later builds sync with rsync as before
sync_dir() {   # source folder, destination folder
    if [ ! -d "$2" ] || [ -z "$(ls -A "$2" 2>/dev/null)" ]; then mkdir -p "$2"; /bin/cp -cRp -- "$1/." "$2/" || die "copy $1 to $2"
    else /usr/bin/rsync -a --delete -- "$1/" "$2/" || die "sync $1 to $2"; fi
}
mkdir -p "$APP/msl/$DM_RESOURCE_MSLDIR"
mkdir -p "$APP/dm"
# Keep generated tables synchronized with the current build.
/usr/bin/rsync -a --delete -- "$SRCROOT/Gen/dm/" "$APP/dm/"
# DM_COPY_ROMFS=NO: base game and DLC stay in one external image, read directly from Documents/romfs.img.
if [ "${DM_COPY_ROMFS:-YES}" = NO ]; then
    rm -rf "$APP/romfs" "$APP/romfs.img" "$APP/romfs.id" "$APP/romfs.base.id"
    # the image's identity (dm/host/romfs_identity.h): main.m uses only a Documents/romfs.img that matches it; a RomFS folder has none yet (push_romfs.sh packs it), so no identity is written for it
    if [ "${DM_SKIP_ROMFS:-NO}" = YES ] && [ -n "$DM_RESOURCE_AOC" ]; then
        python3 -I "$resource_dm/tools/game_image.py" --source-identities "$DM_RESOURCE_ROMFS" "$DM_RESOURCE_AOC" "$APP" "${DM_RESOURCE_TITLE:-}" "${DM_RESOURCE_VERSION:-}" "${DM_RESOURCE_BUILD:-}" || die 'Identity of game files and DLC'
    elif [ -f "$DM_RESOURCE_ROMFS" ]; then
        python3 -I "$resource_dm/tools/game_image.py" --identities "$DM_RESOURCE_ROMFS" "$APP" "${DM_RESOURCE_TITLE:-}" "${DM_RESOURCE_VERSION:-}" "${DM_RESOURCE_BUILD:-}" || die "identity of $DM_RESOURCE_ROMFS"
    elif [ "${DM_SKIP_ROMFS:-NO}" = YES ]; then die 'DM_SKIP_ROMFS=YES requires a RomFS image for version checks'
    fi
elif [ -f "$DM_RESOURCE_ROMFS" ]; then
    if [ -f "$APP/romfs.img" ]; then /usr/bin/rsync -a -- "$DM_RESOURCE_ROMFS" "$APP/romfs.img"; else /bin/cp -cp -- "$DM_RESOURCE_ROMFS" "$APP/romfs.img" || die "copy $DM_RESOURCE_ROMFS"; fi
    rm -rf "$APP/romfs"; rm -f "$APP/romfs.id" "$APP/romfs.base.id"
else
    sync_dir "$DM_RESOURCE_ROMFS" "$APP/romfs"
    rm -f "$APP/romfs.img" "$APP/romfs.id" "$APP/romfs.base.id"
fi
# Analysis MSL is an external cache/prefill input, not a runtime resource; remove old copies only from this shader folder.
if [ "$DM_COPY_GRAPHICS" = NO ]; then
    rm -rf "$APP/msl" "$APP/pso"
else
/usr/bin/rsync -a --delete --delete-excluded --exclude '*.metal' -- "$DM_RESOURCE_SHADERS/" "$APP/msl/$DM_RESOURCE_MSLDIR/"
for old in "$APP/msl/"*; do
    [ "$old" = "$APP/msl/$DM_RESOURCE_MSLDIR" ] || rm -rf "$old"
done
fi
if [ "${DM_COPY_ROMFS:-YES}" != NO ] && [ -n "$DM_RESOURCE_AOC" ]; then
    sync_dir "$DM_RESOURCE_AOC" "$APP/aoc"
else
    rm -rf "$APP/aoc"
fi
# The pipeline archive made offline (the shader pairs' bases, build_ipa.sh): the app hands <App>/pso to the host as DM_PSO_BUNDLE
if [ "$DM_COPY_GRAPHICS" != NO ] && [ -n "$DM_RESOURCE_PSO" ]; then
    sync_dir "$DM_RESOURCE_PSO" "$APP/pso"
else
    rm -rf "$APP/pso"
fi
