# File-backed guest heap experiment

Experimental branch: `experiment/file-backed-memory`, based on `e1b4196c`.
The BOTW overlay selects the preset from available memory unless the player
has made a manual choice. All experimental mechanisms remain behind its switch.
This is an experiment, not a default memory policy or a shipped iPhone result.

## Enable from the game overlay

Build from this branch, then turn on **Performance → Experimental low-memory
mode** before pressing **Play**. In Chinese the switch is **实验性低内存模式**.
Without a manual choice, the launcher enables it below 4.5 GiB of available memory
and disables it at or above that threshold. This is the selected initial cutoff,
not a demonstrated iPhone memory guarantee.
iPhone uses Apple's current per-app headroom; Mac estimates free plus inactive
memory. A zero/unavailable reading leaves it off. The query is repeated at each
launch and when Reset selects a fresh default. The iPhone overlay also refreshes
an automatic selection as its memory readout updates. A manual choice stops
these updates, and no setting change remaps a running game's heap.

Manual On and Off are saved immediately and always beat subsequent detection,
even when equal to the current automatic value. Automatic choices are never
stored. **Reset to tested defaults**, followed by **Play**, restores automatic
selection. An existing launch/env-file override remains fixed as before.
A localized notice below Play is shown whenever low-memory mode is enabled.
It applies after launcher choices and host preload, before the first guest
instruction or GPU pool. It does not remap a live heap.

`DM_LOW_MEMORY=1` selects the same preset without the overlay:

| Component | Preset value |
|---|---|
| File-backed guest heap | `DM_FILE_HEAP=$DM_TEMP` |
| Transient GPU upload sources | `DM_NVN_TRANSIENT_UPLOADS=1` |
| Whole-game pipeline prebuild | `DM_PSO_PREBUILD=0` |
| Bundled pipeline archive | `DM_PSO_BUNDLE=off` |
| Runtime pipeline archive | `DM_PSO_ARCHIVE=$DM_TEMP/pso-low-memory` |

The preset owns these component options while enabled. `DM_TEMP` must already
be an absolute existing directory; the iOS app supplies its container's
`Documents/temp`, excluded from backup. The preset creates only its own cache
directory, preserves the normal cache and `DM_SAVE`, and leaves Metal 4's
on/off choice unchanged.

The switch is the master gate: only `DM_LOW_MEMORY=1` enables experimental
behaviour. Unset, `0` or any other value preserves the original anonymous heap,
eager Metal buffer creation, CPU lookup residency and upload autorelease scope.
Older `DM_FILE_HEAP` and `DM_NVN_TRANSIENT_UPLOADS` options cannot bypass it.
With the switch off, the preset does not alter pipeline/cache settings, create
its cache folder or print experimental boot messages. Relaunch after changing
the switch; there is no live-mode transition.

The log must contain `[mem] experimental low-memory mode on`, followed by the
resolved heap and runtime-cache paths. The existing heap and GPU logs report
their actual activation. With the switch off there is no experimental boot line;
merely building this branch does not enable it. The first reported iPhone test
used default settings, so file backing and transient upload sources were not
active. CPU-only lookup changes were still unconditional at that time; the
strict off-path isolation below was added after that report.

For an iPhone comparison, fully close and relaunch the app between modes, use
the same save and scene, and keep the render settings unchanged. Keep both
`Documents/log.txt` files. Cold runtime-cache runs can compile more pipelines;
measure a second run as well. This switch does not establish a physical iPhone
memory reduction or protection from Jetsam. [Mac results and their boundary](#overall-charged-memory-including-gpu-2026-10-31).

Preset validation: the native check covers disabled defaults, invalid paths,
cache preservation and actual file-backed writes. The Swift model check covers
saved choices, reset and the prebuild row's visibility; the iPhone SDK source
compile and current Mac host build pass. The Simulator fixture verifies the
English and Chinese switch, hidden prebuild row, `DM_LOW_MEMORY=1` after Play
and the enabled choice surviving a process relaunch. The full BOTW regression remains
blocked before gameplay by this Mac's pinned Metal compiler mismatch
(installed 32023.883, required 32023.921). The report is under
`file-heap-toggle-20261031/regress/` in the external game work folder.

Automatic-default verification covers the 4.5 GiB boundary, absent memory data,
both manual overrides across changing budgets, automatic choices not being
stored, reset, fixed env values and the skipped-launcher path. Native Mac
preference tests also verify explicit On/Off without the window. The real
Simulator launcher shows the English/Chinese notice below Play, hides it when
switched off and retains manual Off after a process relaunch without Play.
The Mac Form layout check includes the enabled notice. Current Mac and iPhone
SDK source builds pass; full gameplay remains blocked by the toolchain above.
Artifacts are under `file-heap-auto-default-20261031/` in the game work folder.

### Strict off-path isolation verification

An audit found that CPU-only pool queries and upload-local autorelease pools
were not gated by the original component option. Both now require the master
switch. Off uses the original `mtl_addr` residency/cache side effects and upload
autorelease scope. Heap replacement also checks the master switch at its use
site, so stale component environment values cannot activate it.

The native heap probe succeeds with the switch absent or off even when
`DM_FILE_HEAP` points inside `/dev/null`; on successfully creates real file
backing. GPU tests explicitly check absent/off with the old transient flag set:
the original CPU lookup keeps the controlled 64 MiB pool resident, whereas on
allows all 64 MiB to be evicted, with identical data. Upload-budget (261 checks)
and vertex-buffer (103 checks) tests pass in both modes; temporary upload owners
also retire correctly. These are controlled resource tests, not whole-game
iPhone memory measurements.

The current Mac build and all 188 iOS source compile checks pass. The BOTW
regression against original main `1056dc9e` is still blocked by the same pinned
Metal compiler mismatch. Artifacts are under `file-heap-isolation-20261031/` in
the external game work folder. Earlier measurements predate this strict
off-path guarantee; future A/B runs should compare the switch on and off on the
same revision.

## Mechanism

`hle_svc.c` first reserves the usual guest address space. Before publishing the
heap, `file_backed_heap.h` replaces just that owned heap reservation with a
`MAP_SHARED` regular-file mapping at the same address, initially `PROT_NONE`.
Existing `SetHeapSize` protections and game pointers continue to work. Modules,
alias memory, stacks, host allocations and Metal-owned textures are unchanged.

The file is created with `mkstemp` (0600), unlinked immediately, sized sparsely,
mapped and closed. The kernel keeps the backing alive for the mapping's lifetime;
there is no named game-memory file to clean up after a crash. Setup failures stop
the opt-in run with the actual error instead of silently using anonymous memory.
Only an address range already reserved by this process may be passed to the helper.

The host does **not** flush or invalidate a live heap on a timer. The standalone
probe does so at explicit checkpoints to measure whether backing is reclaimable.
The experiment needs no donor process or changes to rewritten game code.

This follows the platform's existing mechanisms:

- [Apple mmap manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/mmap.2.html): shared mappings preserve modifications in the file object; private modifications use copy-on-write.
- [Apple msync manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/msync.2.html): explicit writeback and invalidation.
- [Apple game-memory guidance](https://developer.apple.com/videos/play/wwdc2022/10106/): clean file pages are recoverable; allocation, residency and footprint are different measurements.

## Reproduce the standalone experiment

Use an output directory on the game drive. Do not put the backing on the home
volume. The example assumes the directory already exists:

```sh
FILE_HEAP_WORK=/absolute/path/on/game/drive/file-heap-experiment
make -C dm/host/tests B="$FILE_HEAP_WORK/tools" "$FILE_HEAP_WORK/tools/bench_file_heap"
"$FILE_HEAP_WORK/tools/bench_file_heap" anon "$FILE_HEAP_WORK" 256
"$FILE_HEAP_WORK/tools/bench_file_heap" file "$FILE_HEAP_WORK" 256
```

The probe uses the production helper. It fills every word with deterministic,
nonzero, high-entropy data, checks every word on the CPU, has a real Metal compute
shader check and modify every word through a no-copy buffer, and verifies the GPU
writes on the CPU before and after eviction. Invalid directories and unaligned
replacement addresses must fail. An assertion, shader error or GPU error is a
nonzero exit. It also uses surrounding address guards and releases all GPU
references before unmapping the backing.

Each JSON line contains kernel `phys_footprint`, process resident/internal/
compressed bytes, mapping-specific resident pages from `mincore`, page faults,
page-ins, operation duration and its return/errno. A lower footprint alone is not
proof of lower physical RAM. Successful `msync` alone is not proof of eviction.

## Mac measurements, 2026-10-30

Apple M2, 24 GiB RAM, macOS 26.5.2, APFS backing on the external game SSD.
Three independent processes per mode and size; all twelve runs passed the full
CPU/GPU data checks. Numbers below are medians. These are exploratory timings;
host compilation overlapped part of the measurement, so they are not FPS or
uncontended storage benchmarks.

| Phase | 256 MiB anonymous | 256 MiB file-backed | 1024 MiB file-backed |
|---|---:|---:|---:|
| Footprint after CPU fill | 257.50 MiB | 1.53 MiB | 1.97 MiB |
| Mapping resident after CPU fill | 256 MiB | 256 MiB | 1024 MiB |
| Mapping resident after explicit flush/invalidate | not applicable | 0 MiB | 0 MiB |
| Flush/invalidate duration | not applicable | 624 ms | 1876 ms |
| Full read/verification after eviction | not applicable | 827 ms | 4825 ms |
| Mapping resident after flush with live Metal buffer | not applicable | 256 MiB | 1024 MiB |
| Mapping resident after GPU objects released and flush | not applicable | 0 MiB | 0 MiB |

The file mapping substantially lowers the process's bill even while all its data
is in RAM. Real physical savings require eviction. A live no-copy Metal buffer
prevented eviction in this probe, even though `msync` returned success. Releasing
the buffer and command objects, then allowing asynchronous driver teardown,
made the same mapping reclaimable. The probe's short teardown observation delay
is a measurement checkpoint, not a proposed host synchronization mechanism.

## Game opt-in and verification

To opt in a current-source host built from this worktree:

```sh
DM_LOW_MEMORY=1 python3 scripts/run_mac.py --test --game /path/to/game
```

Use a disposable save copy and `DM_MEMSTAT=<output.tsv>` for comparisons. The
launcher still requires a matching shader chain and toolchain. Enabling this
switch does not bypass those checks.

The existing memory SVC tests passed both with the feature off and with it on,
including map budgets, stack copyback, simulated protection failures, concurrent
operations, 16 KiB/ASan coverage and the real graphics dirty-tracking path. The
current Mac host builds, and the iPhone source compile check passed 188 files.

The standard BOTW quick regression could not prepare its baseline: installed
Metal compiler `32023.883` differs from required `32023.921`. No compiler or shader
version guard was bypassed. Current-graphics gameplay and physical iPhone memory
accounting remain unverified. A separate retained-graphics BOTW A/B run is recorded
in the external experiment artifacts; it tests this allocation mechanism only.

### Retained-graphics BOTW comparison

Two sequential 115-second runs used the same executable (SHA-256
`6ab6f8dcd867dc20769926bdba8e520b50dd32e0e688c87ed33ac6e52bad3f3c`),
separate copies of the same initial save, the same scripted inputs, and identical
graphics/assets. Only the file arm enabled `DM_FILE_HEAP`. Both loaded Hateno
Ancient Tech Lab, produced gameplay screenshots and exited gracefully without a
fatal error. The retained host received only the opt-in allocation block and the
exact current backing helper; its source provenance is saved with the results.
It is not the newly built current-graphics host.

Medians over seconds 75 through 110:

| Measurement | Anonymous heap | File-backed heap |
|---|---:|---:|
| Process footprint | 4470 MiB | 2880 MiB |
| Resident pages in guest mappings | 915 MiB | 981 MiB |
| Process compressed memory | 3183.5 MiB | 1987 MiB |
| Metal allocated resources | 1765 MiB | 1764 MiB |

The footprint dropped by 1590 MiB (35.6%). Guest mapping residency did not drop.
This demonstrates an accounting benefit, not a reduction of the game's physical
working set. These per-region resident and compressed figures must not be summed
as a total RAM estimate: Metal aliases, filesystem cache and accounting categories
overlap. The Mac was already under memory pressure, and these short sequential
runs do not establish a frame-time improvement or a long-session stability claim.
The result supports investigating cold CPU data and GPU pool lifetimes rather
than enabling a whole-heap eviction timer.

## Follow-up: cold upload sources and GPU lifetime, 2026-10-31

Two places were keeping source memory GPU-accessible longer than its use required:

1. CPU-only uniform/vertex inspection, texture-storage liveness checks and
   diagnostic reads called `mtl_addr`, which also requests residency for the
   entire pool. Those paths now use a bounds-checked CPU pointer without changing
   residency. CPU-only hits never populate the GPU lookup cache, so a later GPU
   lookup still performs the required registration. GPU vertex-copy fallbacks
   retain their GPU lookup and ordering.
2. A GPU deswizzle only needs the original packaged texture bytes during upload.
   Previously its lookup promoted the full source pool into the persistent
   residency set. `DM_NVN_TRANSIENT_UPLOADS=1` instead creates a page-aligned
   no-copy view of that texture's source span. Each upload batch retains a source
   owner, and the last completed batch retires the view. One owner can span
   multiple batches safely. GPU addresses of persistent buffers are unchanged.

The temporary view aliases the original pool. Explicit alias visibility barriers
cover that relationship. Upload begin/flush also have local autorelease pools:
temporary Metal encoders must not retain source buffers in the still-open main
rendering submission's autorelease pool. The new source owner uses retained-return
ownership and removes residency only after all batch and caller references end.

With transient uploads enabled, source-only pools now defer creating their
persistent Metal buffer until a real GPU binding needs it. CPU inspection and
upload-only use need only the registered address bounds. This avoids keeping an
original whole-pool Metal registration alongside temporary source views. Once a
persistent GPU address is published, its buffer stays stable until pool finalization.
Finalizing a never-bound pool does not try to remove a nil buffer from the tables.

The first transient-view game comparison, before this lazy registration change,
reduced guest mapping residency (median 951 to 475 MiB) but increased footprint
(2846.5 to 3045 MiB) and Metal allocated bytes (1752 to 1941.5 MiB). It is retained
under `stage1-*` with its source snapshot, rather than presented as a net memory
win. The subsequent lazy-registration comparison is recorded separately.

The [overlay preset](#enable-from-the-game-overlay) now enables the combined
experiment. Historical measurements below used separately selected component
flags; these flags alone no longer enable experimental behaviour.

The shader/toolchain requirements above still apply. Transient uploads and lazy
persistent buffer creation require the enabled preset. Creating a persistent buffer on
its first GPU binding can shift work to that binding, so long-session frame-time
and device acceptance remain required before considering a default change.

This uses existing completion callbacks, not a timer, guessed frame age or a
sleep in the host. The backing file and all source bytes remain valid after view
retirement. No automatic whole-heap eviction policy has been added.

### Focused verification

- `t_pool_cpu_read` exercises production CPU uniform/liveness queries, then a
  real unrelated GPU commit. It checks residency, file-page eviction, preserved
  data, subsequent GPU lookup and cache invalidation after pool removal. The
  unchanged `e1b4196c` implementation fails three checks and leaves all 64 MiB
  resident after attempted eviction; the experimental implementation passes and
  leaves 0 MiB resident. The fixture, backing and GPU commit are identical.
- `t_upload_source_lifetime` uses the production upload path with two batches,
  checks every copied word, verifies owner retirement before the main rendering
  fence, and observes actual page eviction. A shared-event gate keeps batches in
  flight while the caller drops its reference, exercising batch ownership. All
  64 MiB become nonresident before the main rendering fence. It passes with
  `DM_NVN_ENC_THREAD=0` and `=1`, both with Metal API validation enabled.
- The existing upload budget test continues to verify 261 conditions, including
  pixels and a rendering pass that stays open while uploads complete.
- The existing readback test passed all 83 cases with transient uploads enabled.
  The initial uniform and vertex tests also passed (vertex: 103 checks).
- The iPhone source compile check passed 188 files. Physical iPhone behaviour
  remains unverified.

The explicit `msync` in these tests demonstrates reclaimability and real eviction
of controlled source data. The host does not run that forced eviction step after
every texture. Actual game residency still depends on filesystem writeback,
memory pressure, CPU reuse and other GPU resources aliasing the same pages.

### Retained-graphics result with lazy registration

Both 115-second arms used one executable (SHA-256
`f513a920af5b65fd8d1b67583863935250d69a2d92d3a2f11431b56ff6bc0a95`),
the same original save copied independently, file backing enabled, and the same
scripted input. The transient/lazy switch was the only arm difference. Both
reached Hateno Ancient Tech Lab and exited gracefully, with no fatal or GPU
execution error. Gameplay screenshots were inspected in both arms.

Medians over seconds 75 through 110:

| Measurement | Persistent source pools | Transient sources + lazy buffers |
|---|---:|---:|
| Resident pages in guest mappings | 953 MiB | 424.5 MiB |
| Process footprint | 2855 MiB | 2871 MiB |
| Metal allocated resources | 1751 MiB | 857 MiB |

Guest mapping residency decreased by 528.5 MiB (55.5%). Combined with the
controlled page-eviction tests, this demonstrates more than a footprint-only
accounting change. It does **not** establish a 528.5 MiB reduction of all physical
memory in the process or machine: private GPU allocations, file-cache effects,
aliases and compression need separate interpretation. The footprint stayed
approximately flat (+16 MiB), so this follow-up did not demonstrate extra
per-process Jetsam headroom beyond the earlier file-backing change.

This is one short pair under the Mac's existing memory pressure, not a sustained
gameplay or FPS benchmark. It uses the retained graphics backend; current-source
native Metal tests and Mac/iOS compilation validate the implementation separately.
Current-graphics game regression remains blocked by the Metal compiler mismatch.
Raw per-second data, stage-one results, source snapshots and manifests are retained
in the external artifacts so the unsuccessful intermediate variant stays visible.

The earlier probe now accepts `file-residency` too. It shows that, on this Mac,
merely calling `endResidency` and removing an allocation did not reclaim a
previously resident no-copy buffer's pages while the object remained alive.
This is why upload-only views have a bounded object lifetime; persistent GPU
buffers are not arbitrarily destroyed or assigned new addresses.

### What this means for Jetsam

XNU's [per-process-limit documentation](https://github.com/apple-oss-distributions/xnu/blob/main/doc/vm/memorystatus_kills.md#jetsam_reason_memory_perprocesslimit)
states that the hard process limit is enforced on the kernel's `phys_footprint`
ledger. Therefore a genuine reduction of that ledger on iOS would help avoid
that particular termination reason; it is not merely changing a UI counter.
The separate [system pressure policy](https://github.com/apple-oss-distributions/xnu/blob/main/doc/vm/memorystatus.md#memory-monitoring)
can still terminate processes when reclaimable physical pages are scarce, and
excessive file paging can itself trigger file-cache thrashing kills.

**Not established:** that this unsigned game's final iPhone installation has the
same accounting benefit, survives its per-process limit, or reduces total physical
RAM in a long gameplay session. Those claims require on-device footprint,
`os_proc_available_memory`/headroom and termination-log evidence. Mac residency
and footprint measurements are reported separately.

The follow-up artifacts are under `file-heap-experiment-20261031/` in the game's
external work directory. They include the baseline/current native regression,
GPU ownership tests, residency probe, compile logs and retained-graphics game
comparison.

## Follow-up: pipeline archive bytes, 2026-10-31

The next investigation targets the kernel footprint, since the upload-lifetime
change above did not improve that ledger. `MallocStackLogging=lite`, `heap` and
`malloc_history` on an owned, Mac-debug-signed test host attributed 1,833,336,832
live bytes to Foundation reading files for Metal's `newArchiveWithURL`, called
by `pso4_init`. This was host memory, separate from the guest heap and the
private textures. The loader opens every pipeline archive at initialization.

An LLDB trace of that read shows `NSDataReadingMappedIfSafe` (options = 1).
Apple documents that this option avoids mapping files on removable volumes;
these archives are on the external game SSD. This explains the large malloc
copies in this Mac experiment. It does not establish the same cost on an
iPhone's internal storage. See [Apple's mapping guidance](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemAdvancedPT/MappingFilesIntoMemory/MappingFilesIntoMemory.html).

A separate probe opened the archives without creating pipelines, then dropped
all archive references. A weak reference confirmed the first archive object
died, but footprint did not fall. A local autorelease pool and allocator
pressure relief did not change that result. Therefore merely clearing
`g_arch4`/`g_arch4p` after prewarm is not a demonstrated fix on this system.
The test does not identify the internal owner that retains the file bytes.

### Keep only the current GPU binary

Apple's existing `metal-lipo -thin` extracts the GPU-specific binary without
the intermediate-language slice. No custom archive parser, framework patch or
new host switch was needed. The originals were preserved. A frozen snapshot
of 110 archives occupied 1749.23 MiB; the GPU-only copies occupied 1230.84 MiB,
518.39 MiB less. The same non-archive metadata accompanied both snapshots.

The command for one archive is:

```sh
xcrun metal-lipo /external/path/original.mtl4a -archs
xcrun metal-lipo /external/path/original.mtl4a -thin applegpu_g14g -output /external/path/gpu-only/original.mtl4a
```

Use the GPU architecture listed for the test device, not this Mac's name on
every machine. Point `DM_PSO_ARCHIVE` at a **separate** directory containing
the derived files. Do not overwrite a portable source archive with one GPU's
slice. The [Apple archive-manipulation documentation](https://developer.apple.com/documentation/metal/manipulating-metal-binary-archives)
describes the tool; ordinary pipeline compilation remains the fallback when an
archive does not match a system or GPU.

Two independent 115-second game runs used executable SHA-256
`f513a920af5b65fd8d1b67583863935250d69a2d92d3a2f11431b56ff6bc0a95`,
fresh copies of the same Lab save, file backing and transient uploads enabled,
and the same inputs. Only the archive directory differed. Medians over seconds
75 through 110:

| Measurement | Full archives | GPU-only archives |
|---|---:|---:|
| Kernel process footprint | 2888 MiB | 2346 MiB |
| Metal allocated resources | 856 MiB | 857 MiB |
| Process compressed memory | 1958.5 MiB | 1360 MiB |

Footprint decreased 542 MiB (18.8%). Both reached the same Lab scene, produced
inspected gameplay screenshots, used archived bases without compiling new ones
on this route, and exited gracefully. No GPU execution error or crash was
reported. This demonstrates lower memory-limit accounting on this Mac, rather
than the upload experiment's approximately flat footprint. It does not measure
542 MiB less physical RAM across the machine.

Both runs logged the same missing prewarm seed; this route therefore tests
draw-time archive lookup, not a complete manifest prewarm. An initial scripted
screenshot setting had the wrong separator in both arms; the later control-file
screenshot succeeded in each. The harness was corrected for subsequent runs.
Two unrelated game processes were also running, so these are not controlled FPS
or storage-performance measurements. Metal's system shader cache was not
cleared; later configurations can benefit from work done by earlier runs.

### Existing lower-memory configurations

Two more independent 115-second runs used the same executable, save copies,
inputs, file backing and transient-upload setting. They exercised existing
switches rather than changing the renderer. Both reached the Lab, produced
inspected screenshots, reported no crash/GPU execution error, and exited
gracefully.

| Configuration | Median kernel footprint, seconds 75-110 | Pipeline work logged on the submit thread |
|---|---:|---:|
| Metal 4, full archives | 2888 MiB | 4198 ms |
| Metal 4, GPU-only archives | 2346 MiB | 3914 ms |
| Metal 4, `DM_PSO_ARCHIVE=off` | 1097 MiB | 9102 ms |
| `DM_PSO_MTL4=0`, archive off | 1056 MiB | 4104 ms |

Archive-off still uses the Metal 4 base compiler. It compiled 835 bases during
the logged intervals (47.2 seconds summed across compiler threads), and its
submit-thread pipeline work increased substantially. The MTLDevice path has
neither Metal 4 bases nor hybrid pipelines and was much cheaper in this warm
system-cache run. Neither result proves acceptable first-run behaviour: the
system shader cache was not cleared, later runs may reuse earlier compiler
work, other game processes were active, and the log totals cover the complete
reported intervals rather than an identical fixed-frame segment.

These configurations quantify a memory/compilation tradeoff. They are not a
default change or a recommendation to disable the pipeline cache on every
device. In particular, internal iPhone storage may already let Metal map the
archives, so the Mac's large malloc-copy saving cannot be assumed there. A
production decision needs device footprint and cold-cache transition tests.

Artifacts live under `file-heap-footprint-20261031/` in the external game work
directory: allocation stacks, LLDB loader flags, thinning hashes and sizes,
frozen archive snapshots, runtime environments, per-second memory samples,
logs, screenshots and `game-comparison.json`. The test uses the retained
graphics backend described above; current-graphics and physical-iPhone
validation remain open. No default archive policy was changed.

## Overall charged memory including GPU, 2026-10-31

After checkpoint `4787d6ee` was pushed, the requested comparison was narrowed
from total physical RAM to the whole process's charged memory, including GPU.
The metric is `ri_phys_footprint`, sampled through the existing
`scripts/regress.py` `footprint(pid)` helper (`proc_pid_rusage`,
`RUSAGE_INFO_V4`). `ri_lifetime_max_phys_footprint` records the kernel's peak,
including spikes between samples. Apple's [game-memory guidance](https://developer.apple.com/videos/play/wwdc2022/10106/)
explicitly includes CPU and GPU objects in footprint on Apple silicon.
Metal's `currentAllocatedSize` is a separate allocation diagnostic and is
**not added** to this total.

Each run lasted 130 seconds, with a fresh copy of the same Lab save, the same
rewritten modules, shaders, input, window size and archive snapshot. The total
was sampled every 250 ms; the table uses the same 85-125 second window in every
run (157 samples each). The signed apps used one bundle identifier. The before
and candidate retained source snapshots differ only in `nvn_mtl.m`; the before
binary includes the dormant file-heap opt-in but leaves it unset. Original
source executable hashes are retained in the runtime manifests.

| Configuration | Whole-process footprint, median | Kernel lifetime peak |
|---|---:|---:|
| Before: anonymous heap, original pool/upload lifetime, full archives | 4515.68 MiB | 4577.11 MiB |
| File-backed heap, CPU-only lookups, transient uploads/lazy buffers, full archives | 2845.64 MiB | 2912.50 MiB |
| Same changes plus GPU-only archives | 2308.88 MiB | 2562.32 MiB |

The combined configuration saved 2206.80 MiB (48.87%) of total charged memory
in this scene. Its kernel peak decreased by 44.02%. These are whole-process
totals, including GPU charges, rather than shader-cache sizes or CPU-only
malloc figures. The earlier 18.8% result isolated archive thinning; this new
comparison also includes the file-backed heap and GPU-lifetime changes.

At about 110 seconds, the system `footprint` command independently read each
owned process. Its byte-valued `phys_footprint` matched a nearby rusage sample
exactly in all three accepted runs. The host's one-second `TASK_VM_INFO`
medians were within 5 MiB of the higher-frequency totals. For context, the
graphics-ledger medians were 814.5 / 752 / 729.5 MiB respectively; they are
already part of the totals above. Metal allocation medians were 1784 / 825 /
800 MiB and must not be treated as an additional bill or as all-physical RAM.

All accepted runs reached the same Lab scene, had their native screenshots
inspected, and exited gracefully. They logged the same missing prewarm seed
and no crash. One first attempt of the GPU-only configuration did not produce
either requested screenshot. It remains under `after-gpu-only-no-shot`, with
2541.05 MiB median and 2795.00 MiB peak, excluded from the scene-verified table
for that reason. The retry's Lab window was also inspected through computer
use and raised to remain visible. The capture failure's cause is open; this
single retry is not evidence that it is fixed, and the higher reading remains
part of the experiment record.

These short sequential runs are not an FPS comparison or an iPhone result.
The system shader cache was not emptied and another game process was active.
The test still uses the retained graphics backend; current-graphics gameplay
remains blocked by the toolchain mismatch described above. No default policy
or production build was changed. A lower Mac ledger is not evidence of the
same iPhone Jetsam headroom or a measurement of total physical RAM.

Artifacts are under `file-heap-total-footprint-20261031/` in the external game
work directory: `measurement.json`, `run_totals.py`, `retry_gpu_only.py`,
`analyze_totals.py`, `total-comparison.json`, `unverified-trial.json`, source
and signed-executable hashes, raw quarter-second counters, host counters,
system-tool JSON, screenshots, logs and independent save copies.

## Further experiment: runtime-captured pipeline cache, 2026-10-31

The next target was the 1.2 GiB of GPU-only archives still opened at startup.
Those files cover many shader pairs the measured scene never requests. Rather
than add a new index or modify Metal's file loader, this experiment uses the
existing runtime capture/flush path with a separate, initially empty archive
directory and `DM_PSO_PREBUILD=0`. Metal 4, hybrid pipelines and persistent
pipeline caching stay enabled. Only requested pipeline bases populate the cache.
Apple discusses [pipeline prewarming, streaming and archive lookup](https://developer.apple.com/videos/play/wwdc2025/254/);
this experiment changes which pipelines are prepared, not the archive API.

Three sequential 130-second runs used the same executable as the preceding
comparison, independently copied Lab saves, the same game/shaders, scripted
input and memory sampler. The first run started with an empty cache. The first
restart copied its resulting cache; the second restart copied the first
restart's updated cache. Every run retained file backing and transient uploads.
`DM_PSO_MANIFEST=off` matched the earlier comparisons' effective lack of
prewarm (their seed file was missing). A production policy should retain a
useful bounded prewarm list; this experiment does not justify disabling every
kind of prewarming.

The whole-process charged memory includes GPU, using the same 85-125 second
window and kernel lifetime-peak measurement as above:

| Run | Median total | Kernel peak | Archive size after run | Logged archive hits / new base compilations |
|---|---:|---:|---:|---:|
| Learn from an empty cache | 1111.82 MiB | 1264.50 MiB | 24.76 MiB | 0 / 727 |
| First restart | 1147.60 MiB | 1334.35 MiB | 25.71 MiB | 658 / 16 |
| Second restart | 1124.92 MiB | 1194.27 MiB | 26.68 MiB | 678 / 14 |

The two restart medians are 50.30-51.28% below the prior GPU-only result of
2308.88 MiB, and 74.59-75.09% below the original 4515.68 MiB comparison.
No host implementation or default changed in this follow-up. The existing
configuration and a smaller cache produced this result; it is not a new
constant-memory cache implementation or a whole-game upper bound.

All three runs reached the Lab, produced inspected native screenshots, reported
no `[RED]` or crash, and exited gracefully. System `footprint` snapshots matched
nearby rusage samples exactly. The archive bytes increased on both restarts:
the remaining 14-16 compilations did not disappear. Shader/pipeline state can
differ between runs, so the result does not establish complete cache coverage.

There is a real preparation cost. The first learning run logged 21.90 seconds
of submit-thread pipeline work, versus 0.63 and 0.67 seconds on the restarts.
These totals cover reported frame intervals, not identical fixed-frame ranges;
they diagnose compilation work rather than prove an FPS improvement. System
shader caches were already warm, and this is not a fresh-device install test.
New areas or states can compile additional pipelines and grow the cache. The
whole-game prebuild avoids many such misses at the cost of a much larger
startup cache. A shipping memory option needs a deliberate choice between
preparation coverage, compilation pauses and memory, plus device validation.

To reproduce the **cache policy**, choose a new, separate cache directory and
set these existing switches alongside the earlier heap/upload options:

```sh
DM_PSO_ARCHIVE=/absolute/path/on/game/drive/runtime-only-cache
DM_PSO_PREBUILD=0
```

Do not remove or overwrite the original full archives. No archive thinning was
needed for the small captured cache. Artifacts are in
`file-heap-runtime-cache-20261031/`: the learn/restart cache snapshots, runtime
environments, source/signed hashes, quarter-second totals, system-tool JSON,
screenshots, logs and `comparison.json`. This remains a retained-graphics Mac
experiment on external storage. Lower physical RAM, current-graphics gameplay,
long-session growth and iPhone Jetsam benefit are not established by it.

## Remaining boundaries

- The useful metric is the active working set and actual resident pages, together
  with footprint. The game's original virtual heap size is not physical usage.
- Frequently written data may create substantial SSD traffic. Paging active data
  in and out can stall gameplay, as the probe's cold reads demonstrate.
- A sparse file does not reserve free storage; disk exhaustion on a mapped write
  can terminate the run. Keep ample space during experiments.
- The host's no-copy Metal pool lifetime can pin broad parts of the guest heap.
  Do not invalidate/remap those addresses behind live Metal buffers. Investigate
  pool residency/lifetime before adding an eviction policy.
- Shared mapping semantics, sandbox permissions, filesystem behaviour, memory
  accounting and performance need physical iPhone testing. Mac results do not
  establish Jetsam survival on iOS.

The next production decision should follow a same-save game memory profile:
which guest pages are CPU-only/cold, which remain pinned by GPU pools, and how much
can be reclaimed without increasing frame stalls. Donor processes remain a
separate option for per-process limits; they do not by themselves reduce the
physical working set.

Raw results for this run live in the game's external work directory under
`file-heap-experiment-20261030/`: probe JSONL, source proofs, test logs, iOS compile
log, regression report and disposable game save copies.
