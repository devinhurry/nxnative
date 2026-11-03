# BOTW files and shaders

## Files and shaders

- RomFS is almost all Yaz0 (`.s*` extensions) and SARC (`Pack/*.pack`); `romfs_marker` `Pack/Bootup_Graphics.pack`.
- 19,592 shaders: `Shader/*.sbfsha` (BNSH), the gsys / ksys resource packs in `Pack/Bootup_Graphics.pack` and the terrain pack in `Pack/TitleBG.pack`, particle effects in `Effect/*.sesetlist` (11,373 shaders, 101 compute), layouts (`.sblarc`) and 37 in `main`. All bind with Mario's texture handle layout; the full build had no failure and no unresolved binding.
- **Resolved: duplicate pipeline keys from disabled blend state.** A recording held 4,829 keys for 1,982 distinct pipelines from 1,818 Metal 4 bases; 2,845 keys differed only in blend factors of targets whose blending was disabled. [Pipeline keys omit unused colour state](../../../../docs/reference/shaders.md#pipeline-keys-omit-unused-colour-state) describes the shared normalization.
- `pack_ipa.py` packs its 16 GB IPA in 57 s (Info-ZIP took 2 min 50 s).

#### Shader cache validation

The [operation-specific shader caches](../../../../docs/reference/shaders.md#shader-caches-follow-each-operations-inputs)
are implemented (2026-10-30), including complete translation outputs, SPIRV-Cross
conversion, source analysis, variants and independent Mac/iOS compilation.
The reproducible harness, source hashes and reports are in
`01007EF00011E000-work/shader-cache-full-20261030/`:
`candidate_subset.py`, `candidate-report.json` and `metal-repeat-report.json`.
The workload keeps the pair closure of 11 real BOTW shaders: three vertex,
five pixel and three compute shaders. It compiles both Mac and iOS outputs.

All 87 source, reflection and library artifacts match byte for byte across
cold, warm and forced rebuilds, with zero shader failures. Cold took 20.498 s,
warm 2.854 s and forced 21.012 s; common discovery/snapshot setup took 1.305 s.
The warm run starts no translator, SPIRV-Cross or Metal compiler process,
hits all 11 analysis bundles and 37 variant entries, and restores all 21
libraries per target. These are bounded-workload measurements, not timings
for all 19,592 game shaders. The first build must populate the new caches.

The comparison also exposed a Metal input-basename dependency and concurrent
same-key compilation. The [fixed input-name convention](../../../../docs/reference/shaders.md#metal-cache-entries-require-a-fixed-compiler-input-name)
and cache format 4 make repeated and forced outputs agree; older compiled
cache entries are rebuilt once. The pre-change baseline differs in two fetch
libraries per target because of the corrected compiler filename convention,
despite identical MSL. The extra per-target analysis sources stay outside the
runtime app; packaging tests retain unrelated `.metal` game assets.

Supplemental translator coverage in `translation-cache-20261030/report.json`
compares 98 jobs, including an integer-attribute retry and a synthetic geometry
reader: all 197 raw outputs and 97 ordinary MSL sources match cold, warm and
disabled-cache runs. Unit tests additionally cover scoped invalidation,
paired source dependencies, independent target fallback, corruption and races.

Cache scheduling was then isolated in `dmsh_shader_pipeline.py`. The separate
`shader-cache-isolation-20261030/candidate-report.json` records identical
87-file cold/warm/forced outputs and agreement with the pre-refactor outputs
apart from chain metadata. Reusing the pre-refactor cache also restores all
11 analysis bundles and 42 target libraries without translation or compilation.
The builder supplies explicit callbacks and retains shader transforms and
target fallback policy.

The real compiler comparison above is explicitly experimental:
`DM_ALLOW_OTHER_METAL=1` uses local Metal `32023.883`; the unchanged lock requires
`32023.921`. The supported-toolchain regression report is
`shader-cache-full-20261030/regress/report.md`; that check stops at this compiler
mismatch. No new-chain gameplay or rendered-image comparison is claimed.
BOTW is the only locally available Mac game build; other games have no local
regression run for this change.

#### Pipelines on a cold start

- **Experimental runtime-only cache policy:** [Learn and restart measurements](../../../../docs/experiments/file-backed-memory.md#further-experiment-runtime-captured-pipeline-cache-2026-10-31) preserve archive lookup with a small cache of requested bases. First-use compilation, further cache growth and physical-iPhone acceptance remain open; defaults are unchanged.
- **Experimental, 2026-10-31:** a retained-graphics Lab-save comparison on the M2 Mac and external SSD reduced kernel footprint from 2888 to 2346 MiB by deriving GPU-only copies of the runtime archives with Apple's `metal-lipo`. Both 115-second runs retained archive hits and produced inspected gameplay screenshots. This is not a new current-graphics or physical-iPhone result. [Cause and reproduction](../../../../docs/reference/memory.md#pipeline-archives-copied-from-removable-storage); [full experiment](../../../../docs/experiments/file-backed-memory.md#follow-up-pipeline-archive-bytes-2026-10-31).
- `pso_pairs.tsv`: 3,012 shader pairs from agl's BAHS program variations (the agl / gsys / terrain resource packs), which `shader_pairs.tsv` does not hold. 109 of the 543 pairs drawn on entering Zora's Domain came from them; with the table all 543 are known. The prebuild (15,767 bases) takes 910 MB in 16 files, 187 s with 7 workers for the first 12,755 and 19 s for the 3,012 more; the files open in 2.2 s cold, 0.25 s from the file cache, and add about 850 MB of footprint.
- Mac (M2 Max), the Zora's Domain save, Metal shader cache empty (a new bundle ID per run):

| Start | Frame entering the area | Draws that waited, entering it |
|---|---|---|
| `DM_PSO_MTL4=0`, no `pso_user.tsv` | 990 ms, then 535 / 738 / 496 ms frames | 512 draws, 3,325 ms |
| Hybrid, archive prebuilt from `shader_pairs.tsv`, no `pso_user.tsv` | 830 ms, no other frame over 250 ms | 102 draws, 650 ms |
| Hybrid, archive prebuilt with `pso_pairs.tsv` too, no `pso_user.tsv` | 340 ms, no other frame over 150 ms | 50 draws, 20 ms (no pair without its pulling base) |
| Hybrid, archive and `pso_user.tsv` of an earlier run | no frame over 100 ms | 17 draws, 4.6 ms |

Every kind of cold start also shows the game's own 130–220 ms frames every 9–13 frames for a while after the load, with no pipeline work in them.

- The prepare step with the seed list `pso_manifest.tsv` (1,789 lines: New Game to the Shrine of Resurrection, then a Zora's Domain save load). Mac (M2 Max), runs started at a 1-minute load average below 4: Metal cache empty (a new bundle ID per run), the prebuilt archive, that save loaded. Frames over 25 ms with new pipelines or shader library loads, in the 60 s after the last menu press:

| Start | Before the first frame | Frames with pipelines / library loads |
|---|---|---|
| No list (the profile before its list) | – | 4 / 5 (75 libraries), 168 ms of that work, worst frame 128 ms |
| The list, background prewarm (`DM_PSO_PREPARE=0`) | – (14.6 and 16.0 s on one worker, during boot) | 0 / 0 (two runs) |
| The list, prepare step | 5.2 and 2.2 s on 12 workers, 3.3 s on 8 (872 bases compiled) | 0 / 0 (three runs) |
| Second start (Metal cache and archive warm) | 0.08 s, no screen | 0 / 0 |
| A player's list (5,783 lines with the manifest), warm | 0.23 s, no screen (2.7 s in the background) | 0 / 0 |

- **The pipeline archive made offline** ([development.md](../../../../docs/development.md#the-pipeline-archive-made-offline)): every one of the 15,767 pairs makes a base (none left to the device, none left out); `metal-tt` built the iPhone 17 Pro Max's archive (`applegpu_g18p`, iOS 27.0) in 252 s on an M2 Max: 653 MB, 219 MB zipped. On that iPhone (iOS 27.0.1) a test app found all 200 bases of a 200-pair archive, at 0.06–0.3 ms each. On the Mac the same build for the M2 Max (`applegpu_g14s`, 615 MB, 253 s) held all 15,767 bases: the prebuild tool with it opened it in 1.8 s from the external drive, found 16 of 16 probed bases in 57 ms and built nothing, where the device's own prebuild took 187 + 19 s on 7 workers. The process's footprint rose by about 615 MB with the archive open. Resolved on the iPhone 17 Pro Max (iOS 27.0.1): the app with the archive (622.8 MB) opened it in 555 ms, found 16 of 16 probed bases in 17 ms, and its prepare step took 0.53 s with no base compiled (1,722 bases from the archives), where the device's own prebuild took 7–8 minutes on a first start; footprint 1,424 MiB at frame 300 and 2,579–2,679 MiB in play to frame 2,100, with the device's own earlier prebuild (932.7 MB in 30 files of `pso_archive/`, from before the archive was shipped) still open beside it.

- **A Mac app** (`--platform mac-app`, M2 Max). Before the shader pairs went into the app: `pipeline prebuild: no …/Resources/dm/shader_pairs.tsv, nothing to build`, no hybrid draws, and first-seen pipelines compiled on the submit thread in frames of 100–546 ms ([Shader-pair tables in a Mac app](../../../../docs/reference/shaders.md#shader-pair-tables-in-a-mac-app)). With the pairs and the archive for `applegpu_g14s` in the app (586.2 MB): 16 of 16 probed bases found in 20.6 ms, prepare step 0.23 s, no base compiled, no red line. The first launch of the freshly signed app waited about 100 s while macOS checked its signature; later launches start in a few seconds. The run stayed in the title and menus, so no hybrid draw occurred in it ([PR #241](https://github.com/seedds/nxnative/pull/241)). Repeated on an M4 Pro (`applegpu_g16s`) with an empty Application Support folder: `metal-tt` built the archive in 6:12 (629.4 MB, an APFS clone in the app; ad-hoc signing of the 16.9 GB app took 4:40). The first launch waited about 4 minutes for the signature check before the host started. The archive opened in 250.5 ms from the external drive and covered every pair (16 of 16 probed bases in 34.5 ms), so no pair base was built. The prepare step still compiled 871 bases in 2.80 s on 14 workers: the prewarm list's bases with a vertex layout, which the archive never holds, and which went into the app's own `pso_archive/` (19.9 MB). No red line in the 90 s after.

On this Mac the background prewarm also ends before the save loads, so the step changes the first minute only where the prewarm is slower than the way into play: a slower device, fewer cores, a longer list, a player who skips through the title. Frames over 25 ms without pipeline work (20–71 per run) are the game's own and vary with the machine's other load.
