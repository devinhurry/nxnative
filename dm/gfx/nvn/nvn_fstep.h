// Frame step in whole vsyncs (pure function, shared by Mac / iOS; unit test tests/t_fstep.c). The rewriter's frame-step stubs (patch_nso.py FRAME_STEP: Tears of the Kingdom 1.4.3,
// Breath of the Wild 1.9.0) step the game by the vsyncs (1/60 s) the host hands them each frame, and the host keeps each frame on screen for k vsyncs (hle_nvn.c present_itv).
// At a steady rate the step is the time on screen: even motion, and only steps the games' own interval logic uses (60 / 30 / 20 fps). Real time the game falls behind (a late
// frame, a hitch) is a debt paid back one extra vsync per frame, so over time game time = real time. k follows the frames' cost: three late frames in a row step up to the cost
// (30 fps when 60 does not hold: no 40 fps steps on 120 Hz screens) when the frames at k also fall short of it on average (FSTEP_LATE over the last FSTEP_RUN frames); 30 frames
// in a row whose cost fits k − 1's full budget try it. Failed trials wait twice as long, independently per target: up to 30 s for the fastest normal target, 8 s for intermediate rates and fixed-target 120 fps.
// The average: a frame late by FSTEP_LATE is the rate of a hold that does not hold (53 fps is not 60), but three such frames in a row among frames on time are not. Frames whose
// cost scatters around k (Mario Kart World on an M4 Max: 20–30% of them 1–5 ms late, 57.5–61 fps and game time 0.99–1.02 of real time with no holds) met three in a row about once
// a second and spent half the time at 30 or 20, up and down 30 times a session (issue #1823); a short hitch (pipeline compiles) stepped to 30 the same way. The late frames are
// paid back by the step, so only a rate that falls short of k is worth a longer hold. Where the step cannot pay them back (120 fps, where the game steps by its target: a late
// frame is slow motion) three late frames still raise the hold. The step goes to the cheapest of the three late frames' cost: a hitch as the third no longer meant 20 fps.
// A game takes steps up to its stub's largest (smax; Mario Kart World's interval logic stops at 2): k and the paid-back step stay within it, or the frames held longer than the
// game steps play in slow motion and the debt counted as paid is lost.
// A probe is a trial at the next shorter hold that the cost does not justify. At normal variable-step rates, the hold-off alone starts one: neither a slowdown report nor
// a proven faster-rate reference is required. Costs observed while waiting at a longer hold can overestimate the shorter deadline's work, and the heuristics can miss it. Its first
// FSTEP_GRACE frames may be late without failing it, the time the controller needs to raise the clock for the shorter deadline; after them it is judged like a trial.
// A probe that holds leaves its target's hold-off as it is until its run lasts FSTEP_HOLD_MAX (8 s): a shorter run counts as a failure. Failure returns to its starting hold,
// not the ceiling of a frame at the failed deadline, and waits FSTEP_GRACE frames before judging the return hold: present snapshots / GPU times can still belong to the trial.
// A step up after a run at kmin of FSTEP_HOLD_MAX keeps the cost that held there, and a cost at the longer hold of at most FSTEP_SAME times it starts a probe too: the scene
// costs what it did, so the step up came from a hitch (Breath of the Wild on an iPhone: pipeline compiles after a cutscene). Full-budget trials recover work that fits;
// probes also cover costs inflated by waiting at a slower clock. Bounded probes run at both 20 and 30 without a slowed report, so neither lower rate can latch forever.
// A cap that falls and rises again (a movie, hle_movie.c dm_movie_playing; the iOS thermal cap in hle_nvn.c) keeps what was learned at each kmin: the cost that held it
// (cref) and the GPU reference (nvn_fgpu below); and the frames after the cap rises are a probe with its grace, as the clocks are still set for the longer hold. Before, the
// rise set k to kmin with no grace, so three frames late while the clock rose stepped up again, with cref dropped at the cap change and a GPU reference taken at the 30 fps
// cap: neither the fit trial (a GPU-bound cost near FSTEP_FIT) nor a probe brought kmin back (t_fstep: the movie and thermal cap cases). A cref kept from before the cap
// starts a probe only when the cost at the longer hold is within FSTEP_SAME of it, and a failed probe doubles the hold-off as any other does.
#pragma once
#include <math.h>
#include <stdint.h>
#include <string.h>

#define FSTEP_MAX 3           // the largest step: both games' own interval logic uses 1–3 (BotW clamps to [2, 3], TOTK picks 2 or 3), so their integer readers never see 4
#define FSTEP_LATE 0.1        // a frame is late when it or its GPU work took this many vsyncs (1.7 ms) more than k: 53 fps is not 60 (start-to-start jitter on time is well below)
#define FSTEP_SHORT_MAX 2.0  // a frame counts at most this many vsyncs past its hold toward the average (a load's stall is one long frame, not a rate)
#define FSTEP_FIT 1.0         // use the target's full work budget; judge the actual deadline during the trial instead of reserving 15% headroom
#define FSTEP_RUN 30          // frames in a row that fit k − 1 before a trial, and frames a trial must hold
#define FSTEP_DEBT_MAX 15.0   // debt kept at most (0.25 s): the rest of a long stall (a load) is dropped, not replayed
#define FSTEP_HOLD0 60.0      // vsyncs since the last step up before a trial: 1 s, doubled after each failed trial up to 8 s
#define FSTEP_HOLD_MAX 480.0
#define FSTEP_RETRY_MAX 1800.0   // 30 s between repeated failed trials at the fastest target; intermediate-rate recovery keeps the 8 s limit
#define FSTEP_GRACE 30        // a probe's first frames, whose lateness neither fails it nor counts toward a step up (the controller lowered the clock within 10 frames of a step to 30)
#define FSTEP_SAME 1.1        // the cost at the longer hold against the cost that held kmin: at most this much is the same scene (BotW at hold 2: 1.0–1.07 times its hold-1 GPU time)
// The grace is renewed (nvn_fstep.ramp) while the probe's frames keep getting cheaper: a controller that raises the clock slowly is still raising it. macOS raises the GPU clock
// of a game that misses its deadline at 85–100% GPU occupancy by about 100 MHz a second (Breath of the Wild on an M5 Pro: 338 → 432 MHz over a 33-frame probe, GPU 24.8 → 18.5 ms,
// then the probe failed at 22 ms frames; hold 1 needs about 560 MHz there), where the iPhone's controller settles within the 30 frames. A window of FSTEP_GRACE frames whose
// second half cost at most 1 − FSTEP_RAMP of its first half, and had a late frame (a window on time is judged as a trial), starts another, up to FSTEP_PROBE_MAX frames in all
#define FSTEP_RAMP 0.05       // the fall in cost from one half of a grace window to the next that shows the clock still rising (the per-frame noise of a 25 ms frame is 4%, of 15 frames 1%)
#define FSTEP_PROBE_MAX 180   // grace frames a probe may take in all (3 s at 60 fps): a clock that keeps rising without reaching the hold is not waited for longer

typedef struct {
    int k, step;              // vsyncs each frame stays on screen; the step handed to the game for the next frame (k, or k + 1 while paying back)
    int resume;               // set by the present thread after a real foreground transition; discard paused samples and retry now
    int kmin;                 // the last call's kmin (a lower one takes effect at once)
    double debt;              // real time the game is behind, in vsyncs
    int late_run, fit_run, trial;   // late frames in a row; frames in a row whose cost fits k − 1; frames left of a trial at k − 1 (0 = none)
    int probe, grace;         // 1: a probe trial is running; 2: it held; frames left of its clock-ramp grace
    int target, fallback, settle;   // trial's hold and return hold; feedback / clock settling frames after returning from a failed trial
    int ramp;                 // set by the caller (kept): 1 = a probe's grace is renewed while its frames keep getting cheaper (FSTEP_RAMP; the host's DM_FSTEP_PROBE_RAMP)
    double pa, pb; int plate, ptotal;   // the current grace window: the cost of its first and second halves (sums), its late frames; grace frames this probe has taken in all
    double hold, since;       // next target's retry backoff (for diagnostics); vsyncs at this hold / since a completed trial
    double retry_hold[FSTEP_MAX + 1], retry_since[FSTEP_MAX + 1];   // backoff and elapsed vsyncs for each trial target, independent of failures at another rate
    int per_vsync;            // set by the caller: the ticks a 1/60 s vsync is (0 = 1). At 120 fps the unit is 1/120 s (hle_nvn.c fps_high), and the waits between trials stay the same real time
    double shown_slack;       // vsyncs a frame on time may show longer than k (set by the caller): one refresh on screens whose rate is not a multiple of 60; the cost keeps FSTEP_LATE
    int screen;               // set by the caller before each call, then cleared: 0 = judge lateness by shown and cost; 1 = the screen showed a recent frame on time, 2 = late. With present
                              // snapshots (nvn_mtl.m) the game runs ahead of the screen and a frame that runs long is absorbed, so only what the screen shows counts
    double run, crun, cref;   // vsyncs at kmin in a row; the cost of its frames on time (running mean; not during a probe's trial, whose frames run while the clock rises);
                              // crun when the last run of FSTEP_HOLD_MAX or more ended in a step up or a cap change (0 = none yet)
    double ccur; int ck, cn;  // the cost of the frames on time at the longer hold ck (running mean) and their count
    int ckmin;                // the kmin run, crun and cref belong to
    double cref_at[FSTEP_MAX + 1];   // cref of each kmin, kept while another kmin is in force
    double over[FSTEP_RUN], over_sum; int over_i, over_k;   // the last FSTEP_RUN frames at the hold over_k: shown − k of each (clamped), their sum; the next slot
    double last_cost[3];      // the last three frames' costs, oldest first
    int smax;                 // set by the caller: the largest step the game takes (its stub's STEP_MAX; 0 = FSTEP_MAX)
    int no_payback;           // set by the caller: 1 = the game does not take the step (120 fps: it steps by its target), so three late frames raise the hold whatever the average
    uint64_t late, paid, ups, downs, failed, probes; double dropped;   // statistics for the log
} nvn_fstep;

// Whether the cost at the longer hold is the cost that held kmin (a probe without a slowed report)
static inline int nvn_fstep_same(const nvn_fstep *s) { return s->cref > 0 && s->cn >= FSTEP_RUN && s->ccur <= FSTEP_SAME * s->cref; }

// A trial always tests the next shorter hold. A failed faster trial must return here before judging the sustainable rate again.
static inline void nvn_fstep_trial(nvn_fstep *s, int probe) {
    s->fallback = s->k; s->target = --s->k; s->downs++; s->trial = FSTEP_RUN;
    s->probe = probe; s->grace = probe ? FSTEP_GRACE : 0; s->settle = 0;
    s->fit_run = s->late_run = 0; s->since = 0; s->pa = s->pb = 0; s->plate = s->ptotal = 0;
}

// Once per frame. shown: real time since the previous frame's start, in vsyncs; cost: the frame's work, max(CPU, GPU), in vsyncs (a GPU that cannot keep up makes frames late too); kmin: 1 at a 60 fps cap, 2 at 30;
// kmax: the longest hold (FSTEP_MAX; 2 at a 30 fps cap, where the display link runs at 30 Hz and holds only even counts); fixed: a step the game has set itself (BotW's
// VFR override; 0 = none), which the host then holds as it is; slow: the caller reports a CPU/GPU slowdown, so cost at the longer hold need not rule out an adjacent probe.
// Returns the step for the next frame; s->k is how long that frame stays on screen
static inline int nvn_fstep_next(nvn_fstep *s, double shown, double cost, int kmin, int kmax, int fixed, int slow) {
    const double hold0 = FSTEP_HOLD0 * (s->per_vsync ? s->per_vsync : 1), hold_max = FSTEP_HOLD_MAX * (s->per_vsync ? s->per_vsync : 1),
                 retry_max = FSTEP_RETRY_MAX * (s->per_vsync ? s->per_vsync : 1);
    if (kmin < 1) kmin = 1;
    const int smax = s->smax > 0 && s->smax < FSTEP_MAX ? s->smax : FSTEP_MAX;
    if (kmax > smax) kmax = smax;
    if (kmin > smax) kmin = smax;
    if (kmax < kmin) kmax = kmin;
    int resume = s->resume;
    if (resume) {
        nvn_fstep old = *s;
        int k = old.probe == 1 && old.fallback ? old.fallback : old.k;
        if (k < kmin) k = kmin;
        if (k > kmax) k = kmax;
        // A pause is not game time or evidence about today's deadline. Keep caller configuration and cumulative diagnostics only.
        *s = (nvn_fstep){.k = k, .step = k, .kmin = kmin, .ramp = old.ramp, .per_vsync = old.per_vsync,
            .shown_slack = old.shown_slack, .smax = old.smax, .no_payback = old.no_payback,
            .late = old.late, .paid = old.paid, .ups = old.ups, .downs = old.downs,
            .failed = old.failed, .probes = old.probes, .dropped = old.dropped};
    }
    for (int k = 1; k <= FSTEP_MAX; k++) {
        if (!s->retry_hold[k]) s->retry_hold[k] = hold0;
        s->retry_since[k] = fmin(retry_max, s->retry_since[k] + (resume ? 0 : shown));
    }
    if (!s->hold) s->hold = hold0;
    if (fixed > 0) {   // the game's own step: speed is right by construction, nothing to pay back
        s->k = s->step = fixed < smax ? fixed : smax;
        s->debt = 0; s->late_run = s->fit_run = s->trial = s->probe = s->grace = 0; s->run = 0;
        s->target = s->fallback = s->settle = 0;
        s->kmin = FSTEP_MAX + 1;   // when it ends, k starts again from kmin
        return s->step;
    }
    if (resume) {
        if (s->k > kmin) { nvn_fstep_trial(s, 1); s->probes++; }
        else s->grace = FSTEP_GRACE;   // already at the target: let its clock and presentation feedback settle, without forcing a lower rate
        return s->step = s->k;
    }
    if (!s->k) { s->k = s->step = s->kmin = kmin; return s->step; }   // first frame: nothing measured yet
    int held = s->k;   // the frame that just ended stayed on screen this long
    if (held != s->over_k) { s->over_k = held; s->over_sum = 0; s->over_i = 0; memset(s->over, 0, sizeof s->over); }   // judged against the hold in force, not the frames before a step
    double over = shown - held; if (over < -1) over = -1; if (over > FSTEP_SHORT_MAX) over = FSTEP_SHORT_MAX;
    s->over_sum += over - s->over[s->over_i]; s->over[s->over_i] = over; s->over_i = (s->over_i + 1) % FSTEP_RUN;
    s->last_cost[0] = s->last_cost[1]; s->last_cost[1] = s->last_cost[2]; s->last_cost[2] = cost;
    s->debt += shown - s->step;
    if (s->debt > FSTEP_DEBT_MAX) { s->dropped += s->debt - FSTEP_DEBT_MAX; s->debt = FSTEP_DEBT_MAX; }
    if (s->debt < -1) s->debt = -1;   // ahead (a frame shorter than its step): nothing slows the game down, so at most one vsync is remembered
    s->since += shown;
    if (s->probe == 2 && s->since >= hold_max) s->retry_hold[s->target] = hold0;
    int cap_probe = kmin < s->kmin && s->kmin <= FSTEP_MAX && s->k > kmin;
    if (cap_probe) {   // release a cap one level at a time; the old cap's frame does not consume the new trial's grace
        nvn_fstep_trial(s, 1); s->probes++;
    } else if (kmin < s->kmin || s->k < kmin || s->k > kmax) {
        s->k = kmin; s->trial = s->probe = s->grace = s->settle = s->late_run = s->fit_run = 0;
        s->target = s->fallback = 0; s->since = 0;
    }
    s->kmin = kmin;
    int scr = s->screen; s->screen = 0;
    int settling = s->settle > 0;
    if (settling) s->settle--;
    int late = scr ? scr == 2 : shown > held + FSTEP_LATE + s->shown_slack || cost > held + FSTEP_LATE, grace = s->grace > 0 || settling;
    if (s->grace && !cap_probe) {   // the completed frame at the old cap does not consume the new hold's grace
        if (s->grace > FSTEP_GRACE / 2) s->pa += cost; else s->pb += cost;
        s->plate += late; s->ptotal++;
        if (!--s->grace && s->ramp && s->plate && s->ptotal + FSTEP_GRACE <= FSTEP_PROBE_MAX && s->pb <= (1 - FSTEP_RAMP) * s->pa) { s->grace = FSTEP_GRACE; s->pa = s->pb = 0; s->plate = 0; }   // still getting cheaper: another window
    }
    if (late) { s->late++; s->late_run = grace ? 0 : s->late_run + 1; s->fit_run = 0; } else s->late_run = 0;
    // The cost of the frames on time (a hitch is not what the scene costs): at kmin, and at the longer hold
    if (kmin != s->ckmin) {   // another cap: its run starts over, and what held it before comes back
        if (s->ckmin >= 1 && s->ckmin <= FSTEP_MAX) {
            // A cap can end a sustained run before any hitch saved its cost. Short runs keep the earlier proven reference.
            if (s->run >= hold_max && s->crun > 0) s->cref = s->crun;
            s->cref_at[s->ckmin] = s->cref;
        }
        s->ckmin = kmin; s->run = s->crun = 0; s->cref = kmin <= FSTEP_MAX ? s->cref_at[kmin] : 0;
    }
    // A frame the screen showed on time while its cost did not fit (absorbed by present snapshots) is not what the hold costs: the probes would take it for the scene that held kmin
    int fits = !scr || cost <= held;
    if (held <= kmin) { s->run += shown; s->cn = 0; if (!late && fits && s->probe != 1) s->crun = s->crun > 0 ? s->crun + (cost - s->crun) / 32 : cost; }
    else {
        s->run = 0;
        if (held != s->ck) { s->ck = held; s->cn = 0; }
        if (!late && fits) { s->ccur = s->cn ? s->ccur + (cost - s->ccur) / 8 : cost; s->cn++; }
    }
    // A rate below k over the last FSTEP_RUN frames (the slots not filled yet since the hold changed count as on time); the screen's verdict (present snapshots) is its own
    int short_of_k = scr || s->no_payback || s->over_sum > FSTEP_LATE * FSTEP_RUN;
    if (s->late_run >= 3 && s->k < kmax && short_of_k) {   // step up to the cost of the cheapest of the three late frames, at least one vsync
        double c3 = s->last_cost[0] < s->last_cost[1] ? s->last_cost[0] : s->last_cost[1]; if (s->last_cost[2] < c3) c3 = s->last_cost[2];
        int want = (int)ceil(c3 - 0.05);
        if (want < s->k + 1) want = s->k + 1;
        if (want > kmax) want = kmax;
        if (s->trial || (s->probe == 2 && s->since < hold_max)) {
            int target = s->target;
            s->failed++; s->trial = 0;
            s->retry_hold[target] = fmin(target == kmin && !s->no_payback ? retry_max : hold_max, s->retry_hold[target] * 2);
            s->retry_since[target] = 0;
            want = s->fallback < kmax ? s->fallback : kmax;
            s->settle = FSTEP_GRACE;   // old GPU timings / present snapshots belong to the failed trial, not to this returned hold
        } else if (s->probe == 2) s->retry_hold[s->target] = hold0;   // the probe's run lasted
        if (held == kmin && s->run >= hold_max) s->cref = s->crun;   // kmin held 8 s at this cost
        s->k = want; s->ups++; s->late_run = s->fit_run = 0; s->since = 0; s->probe = 0;
        s->retry_since[want - 1] = 0;
        s->over_k = 0;   // discard the failed deadline's lateness history before evaluating the return hold
    } else if (s->trial && !grace && !--s->trial) {
        if (s->probe) s->probe = 2; else s->retry_hold[s->target] = hold0;
        s->since = 0;
    }
    // Use each target's whole budget; the trial then tests actual presentation rather than demanding unused performance in advance.
    int next = s->k > kmin ? s->k - 1 : kmin;
    s->hold = s->retry_hold[next];
    if (!late && !settling) s->fit_run = s->k > kmin && cost <= FSTEP_FIT * next ? s->fit_run + 1 : 0;
    if (s->k > kmin && s->since >= hold0 && s->retry_since[next] >= s->hold && !s->trial && !s->settle && !settling) {
        if (s->fit_run >= FSTEP_RUN) nvn_fstep_trial(s, 0);
        else if (!s->no_payback || slow || nvn_fstep_same(s)) {   // both 20 -> 30 and 30 -> 60 recover without a clock signal; retain 120 fps fixed-target semantics
            nvn_fstep_trial(s, 1); s->probes++;
        }
    }
    s->step = s->k + (s->debt >= 1 && s->k < smax);
    s->paid += s->step > s->k;
    return s->step;
}

// The GPU clock follows the hold too: Breath of the Wild on an iPhone went from 14.4 to about 25 ms of GPU time a frame at hold 2 with the same 4,900 draws, the CPU still on its
// performance cores, so its cost never fitted hold 1 again. The GPU counts as slowed (another reason for nvn_fstep_next's slow) when its time at a hold above kmin is at least
// FSTEP_GPU_SLOW times its time at kmin and it alone does not fit k − 1 (a GPU at 3 ms of 17, 6 times its time on a loading screen, is not what holds a frame back).
// The reference is not updated during a probe's trial (its frames run while the clock is still rising), so a failed probe leaves it as it was. It is kept for each kmin: one
// learned at a 30 fps cap is the GPU time at the clock that cap left (lowered for 30 fps, and under the thermal cap for the heat), and taken as hold 1's after the cap rose it
// made the same work at hold 2 look not slowed
#define FSTEP_GPU_SLOW 1.3    // GPU time at the longer hold against its time at kmin
#define FSTEP_GPU_N 30        // frames at the longer hold before the comparison counts
typedef struct { double ref, cur; int n, k; double ref_at[FSTEP_MAX + 1]; } nvn_fgpu;   // GPU time at kmin (running mean; of every kmin in ref_at); at the current hold k and its frame count
static inline int nvn_fgpu_slow(const nvn_fgpu *g) { return g->n >= FSTEP_GPU_N && g->ref > 0 && g->cur >= FSTEP_GPU_SLOW * g->ref && g->cur > FSTEP_FIT * (g->k - 1); }
// Once per frame, with the frame's GPU time (vsyncs; 0 = none finished yet) and the hold and probe state (nvn_fstep.probe) it ran under
static inline int nvn_fstep_gpu_slowed(nvn_fgpu *g, double gpu, int k, int kmin, int probe) {
    if (kmin < 1 || kmin > FSTEP_MAX) return 0;   // no reference slot for it (hle_nvn.c passes 1 or 2)
    g->ref = g->ref_at[kmin];
    if (gpu <= 0) return nvn_fgpu_slow(g);
    if (k <= kmin) { if (probe != 1) g->ref = g->ref_at[kmin] = g->ref > 0 ? g->ref + (gpu - g->ref) / 32 : gpu; g->n = 0; g->k = k; return 0; }
    if (k != g->k) { g->k = k; g->n = 0; }
    g->cur = g->n ? g->cur + (gpu - g->cur) / 8 : gpu; g->n++;
    return nvn_fgpu_slow(g);
}
