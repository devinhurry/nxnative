# Separate graphics packages

iOS builds now produce an IPA and a sibling `<app>.graphics.zip` by default.
Use `--graphics bundle` to embed graphics instead. ROM deployment is independent:
`--romfs separate` keeps the combined game/DLC image outside the IPA. Mac builds
and `run_mac.py --test` retain their existing shader paths.

On the launch page, use **Import ROM** and **Import shaders** below **Play** to
choose the image and graphics ZIP in Files. Import each once. Play is enabled
when both are usable. Updates keep compatible imports. An incompatible or failed
import reports the reason and preserves the selected package.

## Compatibility and updates

The app's `dm/graphics-required.json` records an exact compatibility series and a
minimum integer version. Import and every launch require the same series and a
package version at least that minimum. A UI-only IPA update keeps the series.

`dm/tools/graphics_pack.py` derives the series from the game/build, graphics API,
current shader chain, renderer sources, profile constants and shader-input tables.
Renderer changes conservatively start another series, even if a specific edit
might be compatible. Launcher/touch UI, local source paths and the app commit are
excluded. The existing strict `DMSH_CHAIN` check is unchanged.

Within one series, identical contents reuse the ZIP; changed contents increment
the version. `VERSION` and `MINIMUM_VERSION` set the release floor and app
requirement. Raise `MINIMUM_VERSION` when a fix must replace earlier packages in
that series. New series start at the floor. A content SHA-256 identifies each
distinct package separately from its version.

The manifest records actual compiler identities/flags from reflection and Metal
versions/iOS targets from binaries. It does not attribute reused shaders to the
machine building the IPA. Different compilers can share a compatibility series
but produce distinct package IDs. Import enforces the minimum iOS target; this
metadata cannot guarantee an untested compiler's rendering correctness.

A separate NVN iOS build checks the sibling published ZIP before compiling
shaders. A compatible ZIP restores runtime resources to
`<id>_build/graphics-cache/<package ID>/`, even when local shader caches are gone;
no Metal compiler is needed. Explicit GPU archive settings use the normal build
path. Changed contracts report `UPDATE REQUIRED` and build a new package. Prepared
Xcode projects recheck requirements at build time and ask to prepare again after
relevant source changes.

## Archive and installed layout

The format is standard **ZIP_STORED**, with ZIP64 for large files/counts, no
encryption or custom wrapper. `manifest.json` is first. It records `schema`,
`kind`, `series`, `version`, `compatibility`, `compilers`, `compiler_id`, `id`,
and sorted `files` entries containing `path`, `size` and `sha256`.

```text
manifest.json
msl/b-<chain>/*.metallib
msl/b-<chain>/*.json
msl/b-<chain>/inputs.tsv
tables/shader_map.tsv
tables/{pso_manifest,c1_full,cb_extent,shader_pairs,pso_pairs}.tsv (when present)
pso/*.{mtl4a,tsv}                                              (when present)
```

Vulkan/OpenGL use their backend library directory instead of `b-*`. Metal source,
game code, ROM and saves are excluded. The system ZIP reader streams to a private
staging directory, checks inventory, paths, file sizes, ZIP integrity and SHA-256,
and rejects duplicate/unlisted entries and links before publishing.

```text
Documents/
  romfs.img
  graphics/
    current.json
    v<version>-<package ID>/
      manifest.json
      msl/...
      tables/...
      pso/...              (optional)
```

Only a complete import atomically updates `current.json`. Installed sizes and
compatibility are checked before Play. Graphics are excluded from iCloud backup;
saves are unchanged. Older package directories remain available after updates.

## Validation

`test_graphics_pack.py` exercises the production Foundation/libarchive importer
with stored ZIP/ZIP64 fixtures, version/series rejection, corruption, unsafe
entries, truncated imports, reimport repair, package reuse and cache restoration.
Packaging tests cover both ROM modes and both graphics modes. The full production
iOS smoke app compiles/links; a simulator launcher uses real Files pickers and
importers with synthetic resources. Complete game graphics on a physical iPhone
remain a separate acceptance check.

The game regression harness was attempted for BOTW, the only local prepared
title. Its baseline stopped before shader comparison because installed Metal
`32023.883` differs from locked `32023.921.6`. No compatibility build or older
shader/host pair was substituted. This change does not modify shader-chain or
graphics execution code.
