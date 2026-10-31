# The Legend of Zelda: Breath of the Wild (01007EF00011E000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
import struct
from nso_asm import ADRP, B, LDRX
CUTS = {
  # The Legend of Zelda: Breath of the Wild 1.9.0 (v1114112) main: 60 fps. The main loop of sead::GameFrameworkNx (main+0x112660c) runs a dynamic interval (framework +0x267 = 1):
  # every frame it computes how many vsyncs the last frame needed (rounded up), clamped to [2, max 3] (the max comes from the interval controller +0xc, constructed at main+0x1126c04); it steps up after 3 overrunning frames in a row,
  # steps down one level every 6 frames until 2, and hands the result through setWaitVsyncInterval (vtable +0x130, main+0x11269b8) to presentation (nvnWindowSetPresentInterval).
  # The game logic time step follows it: ksys::VFR is initialized with a base interval of 2 (constant 2 at main+0x127e740 → VFR::init main+0x151d2d0), and every frame VFR::updateInterval (main+0x151d3d0,
  # called at main+0xcf9ad4 / main+0x1281044) takes the framework's current interval (vtable +0x138); the frame ratio = current interval / 2 -- at interval 1 each frame advances half a 30 fps tick and the game speed stays the same;
  # when it struggles and steps back to 2 / 3 the ratio is 1 / 1.5, again at the same speed. So only the floor changes from 2 to 1: the lower bound of the candidate interval (two places), the step-down target recorded when stepping up, max(candidate, 3) - 1 → max(candidate, 2) - 1,
  # and stepping down stops at < 3 → < 2. On hardware the same logic starting from 1 would also be 60 fps; it falls back to 30 by itself only when its input shows a slow frame (the last two cuts make that input include the GPU time).
  # With the frame step (FRAME_STEP below) the host's step replaces the controller's interval, except while the game's own VFR override is set (and at fps_target 0): the framework then keeps the controller's
  'cd57b23fa4bbad65803d9788c01821ee': [
    (0x112670c, '6041201e', '4041201e', 'lower bound of the candidate interval: fmov s0,s11 (2.0) → fmov s0,s10 (1.0)'),
    (0x1126710, '7f0b0071', '7f070071', 'lower bound of the candidate interval: cmp w27,#2 → cmp w27,#1'),
    (0x112665c, '78008052', '58008052', 'step-down target recorded when stepping up, max(candidate, w24) − 1: mov w24,#3 → mov w24,#2'),
    (0x1126748, '1f0d0071', '1f090071', 'step-down target recorded when stepping up: cmp w8,#3 → cmp w8,#2'),
    (0x1126794, '3f0d0071', '3f090071', 'stepping down stops at < 3 → at < 2: cmp w9,#3 → cmp w9,#2'),
    # The controller's input (framework +0x250, controller main+0x1126cec..) is the main thread's CPU span up to the draw step (about 2.7 ms in the first shrine), so GPU-bound frames stayed at interval 1 and the game ran slow
    # (iPhone 16 Pro Max: 25 ms frames, two thirds of the speed). The game has a GPU-time path that uses max(CPU span, GPU time between the frame's two timestamp reports, framework +0x220, read after the fence wait)
    # but takes it only while [main+0x1e3a638]+0x1d2b8 is set (64 of 6,046 shrine frames); both of its checks become branches into it. The GPU time needs the profile's gpu_timestamps segment
    (0x112691c, 'c00000b4', '03000014', 'interval controller always takes the GPU time path (CPU span timing): cbz x0,#0x1126934 → b #0x1126928'),
    (0x1126974, 'c00000b4', '03000014', 'interval controller always takes the GPU time path (takes max(CPU span, GPU time)): cbz x0,#0x112698c → b #0x1126980'),
  ],
}

# Breath of the Wild: the framework's interval controller (the 60 fps cuts above) hands its interval to setWaitVsyncInterval (main+0x11269b8), which the main loop calls once a frame
# (main+0x11267c0); the framework keeps it at fw+0x244 (getter vtable +0x138, read by both callers of VFR::updateInterval and directly in 43 places) and passes it on to
# nvnWindowSetPresentInterval. The stub at the setter's entry replaces it with the host's step, read once a frame: ksys::VFR::updateInterval (main+0x151d3d0, x0 = the VFR at
# [main+0x1e93890]; called from GameScene::calc and the per-frame delegate main+0x1280f80) takes the framework's interval in the next frame (ratio = step / 2, base interval 2, and the
# int interval that 16 pieces of logic read), so the time step and everything else that reads the interval agree. The step is not written into the VFR call itself: the game presents
# on its own thread, so the host's step can change between the two VFR calls of a frame. The VFR's own override (+0x29 flag, +0x2c interval: 2 at main+0xc3b588 and main+0xc5ebf8,
# 1 at main+0xc609d8, set and cleared by game scenes) wins in the VFR:
# a stub there publishes it at state +0x24 so the host holds frames that long, and the setter stub leaves the framework's interval to the game while it is set. x16 / x17 are free
# at both entries
def frame_step(ctx):
    here, emit, fs_site, fs_put, FS_STATE_OFF = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    fs_site(0x11269b8, 'fd7bbea9'); fs_site(0x151d3d0, 'fd7bbea9')
    start = here(); emit(ADRP(16, here(), FS_STATE_OFF))
    for w in (0xb9400211,   # ldr w17,[x16]          target fps (0 = off)
              0x34000191):  # cbz w17,orig (+12)
        emit(w)
    emit(ADRP(17, here(), 0x1e93890)); emit(LDRX(17, 17, 0x890 // 8))   # the VFR
    for w in (0xb4000131,   # cbz x17,orig (+9)
              0x3940a631,   # ldrb w17,[x17,#0x29]   the VFR's override
              0x350000f1,   # cbnz w17,orig (+7)     the framework keeps the game's interval
              0xb9402211,   # ldr w17,[x16,#0x20]    step in vsyncs
              0x340000b1,   # cbz w17,orig (+5)      not decided yet
              0x2a1103e1,   # mov w1,w17
              0xf9401a11,   # ldr x17,[x16,#0x30]
              0x8b214231,   # add x17,x17,w1,uxtw
              0xf9001a11,   # str x17,[x16,#0x30]    vsyncs stepped
              0xa9be7bfd):  # orig: stp x29,x30,[sp,#-0x20]!
        emit(w)
    emit(B(here(), 0x11269bc))
    fs_put(0x11269b8, [B(0x11269b8, start)], 'setWaitVsyncInterval: the host\'s step unless the VFR override is set (state page target fps; 0 = the game\'s interval)')
    start = here(); emit(ADRP(16, here(), FS_STATE_OFF))
    for w in (0xb9400211,   # ldr w17,[x16]          target fps (0 = off)
              0x340000b1,   # cbz w17,orig (+5)
              0x3940a411,   # ldrb w17,[x0,#0x29]    the VFR's override
              0x34000051,   # cbz w17,pub (+2)       none: 0
              0xb9402c11,   # ldr w17,[x0,#0x2c]
              0xb9002611,   # pub: str w17,[x16,#0x24]  the game's own step: the host holds frames that long
              0xa9be7bfd):  # orig: stp x29,x30,[sp,#-0x20]!
        emit(w)
    emit(B(here(), 0x151d3d4))
    fs_put(0x151d3d0, [B(0x151d3d0, start)], 'VFR::updateInterval: its own override published for the host (state page target fps; 0 = original)')
    # Held buttons: sead::ControllerBase::updateDerivativeParams_ (main+0xeb0ef0) adds s8 to each held button's count, a constant 1.0 (main+0xeb0f78..88), and raises the repeat bit
    # when fmod(count - delay, pulse) < s8: delays and pulses are counted in frames, so at 60 fps menus repeated twice as fast as at 30 (MacNativeGames 866beb9). s8 is now the VFR's
    # ratio (+0x3c: interval / base interval 2), 0.5 at a one-vsync step, 1.0 at two as shipped; the constant stays when there is no VFR yet or the ratio is not positive.
    # x8 is loaded again after the site, s0 before its first read
    fs_site(0xeb0f80, '08f144f9'); fs_site(0xeb0f88, '080140bd')
    start = here(); emit(0xbd400108)   # ldr s8,[x8]            the constant 1.0
    emit(ADRP(8, here(), 0x1e93890)); emit(LDRX(8, 8, 0x890 // 8))   # the VFR
    for w in (0xb40000a8,   # cbz x8,back (+5)
              0xbd403d00,   # ldr s0,[x8,#0x3c]      its ratio
              0x1e202008,   # fcmp s0,#0.0
              0x5400004d,   # b.le back (+2)
              0x1e204008):  # fmov s8,s0
        emit(w)
    emit(B(here(), 0xeb0f8c))   # back
    fs_put(0xeb0f88, [B(0xeb0f88, start)], 'held-button counts step by the VFR ratio (menu repeat in game time at any frame step)')
    # Render scale (state +0x10, float written by the loader: DM_RENDER_SCALE, 1.0 by default; independent of the frame step). The dynamic-resolution method (main+0x12666e4) keeps a
    # scale in 0.8–1.0 rounded to 0.05 steps (+0x1218, main+0x1266818), or the game's forced 0.75 / 0.5 (+0x284 & 0x1800), in s8; from main+0x1266880 it applies s8: each view's
    # scale (+0x28a0 / +0x28a4 = s8 × base width (+0x1214: 1600 docked, 1280 handheld) / output width), from which the scene buffers are sized each frame (main+0x106340c), the
    # shader ratio uking_dynamic_resolution_ratio and the other readers (main+0xc3c3f4, an LOD check at main+0x14126b4). Setting s8 there keeps them all consistent (a multiply in the
    # size function, TOTK's way, would leave the ratio and those readers at the old scale). The apply block runs only when the dynamic path has just recomputed the scale (+0x280 bit 4,
    # set at main+0x1266830) or in a forced mode, else main+0x126686c skips it; with a factor it is taken every frame, as in the dynamic mode, so the factor holds with dynamic
    # resolution off too. Factors above 1.0 are refused by the loader: the per-frame texture pool's size is unknown. x8, s0, s1 and the flags are dead at both sites
    fs_site(0x1266880, '88ae40f9'); fs_site(0x126686c, struct.pack('<I', B(0x126686c, 0x1266950)).hex())
    apply = here(); emit(ADRP(8, here(), FS_STATE_OFF))
    for w in (0xbd401100,   # ldr s0,[x8,#0x10]      render scale
              0x1e202008,   # fcmp s0,#0.0
              0x540000ad,   # b.le orig (+5)         not set
              0x1e2e1001,   # fmov s1,#1.0
              0x1e212000,   # fcmp s0,s1
              0x54000040,   # b.eq orig (+2)         1.0: the game's own scale
              0x1e204008,   # fmov s8,s0             the host's scale
              0xf940ae88):  # orig: ldr x8,[x20,#0x158]
        emit(w)
    emit(B(here(), 0x1266884))
    fs_put(0x1266880, [B(0x1266880, apply)], '3D view scale = the host render scale (1.0 = the game\'s dynamic resolution)'); ctx.render_scale = 1
    start = here(); emit(ADRP(8, here(), FS_STATE_OFF))
    for w in (0xb9401108,   # ldr w8,[x8,#0x10]      render scale (float bits)
              0x34000088,   # cbz w8,skip (+4)       not set
              0x52091908,   # eor w8,w8,#0x3f800000
              0x34000048):  # cbz w8,skip (+2)       1.0
        emit(w)
    emit(B(here(), 0x1266880)); emit(B(here(), 0x1266950))   # apply the host's scale; skip: the original branch
    fs_put(0x126686c, [B(0x126686c, start)], 'scale apply block taken every frame when the host render scale is not 1.0')

    # The native controller averages GPU time as a percentage of 1/60 s, lowers
    # scale above 175 and raises it below 150. Retarget its existing smoothing,
    # 0.05 steps and 0.8 floor by normalizing to the host cap: 200 at 60 fps,
    # 100 at 30 fps. Zero keeps the original 100 (opt-in, state +0x38).
    # x8 and s4 are dead here: the following instructions overwrite both before
    # reading them. s0/s3 hold the measured GPU time and remain unchanged.
    fs_site(0x12670ac, '0101271e')
    start = here(); emit(0x1e270101)   # fmov s1,w8: original 100, before x8 is reused
    emit(ADRP(8, here(), FS_STATE_OFF))
    for w in (0xbd403904,   # ldr s4,[x8,#0x38]     host normalization, 0 = original
              0x1e202088,   # fcmp s4,#0.0
              0x1e21cc81):  # fcsel s1,s4,s1,gt
        emit(w)
    emit(B(here(), 0x12670b0))
    fs_put(0x12670ac, [B(0x12670ac, start)], 'native dynamic-resolution GPU budget follows the host frame-rate cap')

FRAME_STEP = {'cd57b23fa4bbad65803d9788c01821ee': frame_step}
CAPABILITIES = {'cd57b23fa4bbad65803d9788c01821ee': ('DYNAMIC_RESOLUTION',)}

# Main's input-vector probes are fixed to the exact 1.9.0 build. Keep the original instructions
# checked here with the per-game rewrite rules, rather than embedding BOTW addresses in patch_nso.py.
def validate_main(ctx):
    word = lambda off: struct.unpack_from('<I', ctx.image, off)[0]
    assert tuple(word(o) for o in range(0xf71490, 0xf714d8, 4)) == (
        0x12001c39, 0x3877cb08, 0x6b19011f, 0x54000141, 0xb9402a88, 0xaa1303e1,
        0x6b16011f, 0xf9401a89, 0x1a9f82c8, 0xf868d920, 0xf9400008, 0xf9402d08,
        0xd63f0100, 0x910006e8, 0x110006d6, 0x92407d17, 0x6b0802bf, 0x54fffe01,
    ), 'BOTW ScreenMgr draw loop changed; revalidate OBS41 receiver and layer/index registers'
    assert tuple(word(o) for o in range(0xe1a61c, 0xe1a62c, 4)) == (
        0x97fd1459, 0x97fd1470, 0xb40002c0, 0xf960de68,
    ), 'BOTW MainScreen3D camera copy / successful-result branch changed'
    assert tuple(word(o) for o in range(0xe1a628, 0xe1a674, 4)) == (
        0xf960de68, 0xb4000288, 0xbd401000, 0x52885008, 0x8b080268, 0xbd400801,
        0x1e213800, 0x1e2c1001, 0x1e210800, 0xbd000100, 0xbd401400, 0xbd400c02,
        0x1e223800, 0x1e210803, 0xbd000503, 0xb0007fc8, 0x913b4108, 0xf9400100,
        0xb4000060,
    ), 'BOTW MainScreen3D post-copy point or x19 owner liveness changed'
    assert tuple(word(o) for o in range(0xe1a67c, 0xe1a688, 4)) == (
        0xa9414ff4, 0xa8c27bfd, 0xd65f03c0,
    ), 'BOTW MainScreen3D early return scratch-register liveness changed'
    assert tuple(word(o) for o in range(0xd58008, 0xd58018, 4)) == (
        0xf9409408, 0x910023e0, 0xf90007e8, 0x941fbe5f,
    ), 'BOTW raw stick source sequence changed; recheck OBS33 child pointer and raw pair location'
    assert tuple(word(o) for o in range(0xd5801c, 0xd58030, 4)) == (
        0xfd400be8, 0xf94017f3, 0xa941fbfd, 0x9100c3ff, 0xd65f03c0,
    ), 'BOTW shared getter epilogue changed; recheck OBS32 scratch-register liveness'
    # Pane::Draw saves this in x21 and invokes DrawSelf at vtable +0xb0.
    # The begin gate precedes that call with x9-x17 dead; the end gate follows it.
    assert tuple(word(o) for o in range(0x27d50, 0x27d8c, 4)) == (
        0x3941700a, 0xaa0203f3, 0xaa0103f4, 0x39416809, 0xaa0003f5,
        0x3620014a, 0x34000129, 0xf94002a8, 0xaa1503e0, 0xaa1403e1,
        0xaa1303e2, 0xf9405908, 0xd63f0100, 0x394162a8, 0x39416aa9,
    ), 'BOTW Pane::DrawSelf scope changed; revalidate OBS39/40 and x21 pane owner'
    assert tuple(word(o) for o in range(0x276a0, 0x276d8, 4)) == (
        0xd10243ff, 0xfd0023e8, 0xf9002ff9, 0xa904fbfd, 0xa9065ff8, 0xa90757f6,
        0xa9084ff4, 0x910123fd, 0x39416008, 0xaa0003f3, 0x12000109, 0x3940744a,
        0x2a0a0129, 0x72001d3f,
    ), 'BOTW Pane::Calculate entry changed; recheck OBS34 pane and dirty-flag semantics'
    assert tuple(word(o) for o in range(0x27ae0, 0x27aec, 4)) == (
        0x39416268, 0x52800036, 0x360805a8,
    ), 'BOTW Pane::Calculate post-matrix point changed; recheck OBS35 x19 pane and translation lanes'
    # OBS35 is interior, so its stub may use x9-x17. Both its direct exit and
    # the child-recursion path below use x8 and x19-x25 until the first blr;
    # keep the verified tail bytes here as its register-liveness proof.
    assert tuple(word(o) for o in range(0x27ae8, 0x27bd0, 4)) == (
        0x360805a8, 0x39416668, 0x7103fd1f, 0x54000540, 0x1e230100, 0x52901028,
        0x72a77008, 0xbd401a88, 0x91008279, 0x1e270101, 0x52800028, 0x1e200900,
        0x39407e98, 0x39007e88, 0x1e210803, 0xbd001a83, 0xf9401677, 0xeb1902ff,
        0x54000160, 0xf85f8ee8, 0xaa1503e1, 0xaa1703e0, 0xaa1403e2, 0xf9405108,
        0x2a1603e3, 0xd63f0100, 0xf9400af7, 0xeb1902ff, 0x54fffee1, 0xbd001a88,
        0x39007e98, 0x39416268, 0x32190108, 0x39016268, 0x39417268, 0x321c0108,
        0x39017268, 0xfd4023e8, 0xa9484ff4, 0xa94757f6, 0xf9402ff9, 0xa9465ff8,
        0xa944fbfd, 0x910243ff, 0xd65f03c0, 0xf9401677, 0x91008278, 0xeb1802ff,
        0x54fffde0, 0xd503201f, 0xf85f8ee8, 0xaa1503e1, 0xaa1703e0, 0xaa1403e2,
        0xf9405108, 0x2a1603e3, 0xd63f0100, 0xf9400af7,
    ), 'BOTW Pane::Calculate OBS35 scratch-register liveness changed'
    assert tuple(word(o) for o in range(0xf57ba0, 0xf57bb8, 4)) == (
        0xd10143ff, 0xa9027bfd, 0xa90357f6, 0xa9044ff4, 0x910083fd, 0xf9401008,
    ), 'BOTW native BoxCursorControl update entry changed; revalidate requested-entry hook and x0 manager'
    # A new save skips Title and may not update a cursor until after gameplay
    # begins. Observe the completed constructor too. Its base constructor
    # preserves x0, all manager fields are initialized, and the remaining
    # epilogue reads no x9-x17 before ret.
    assert tuple(word(o) for o in range(0xf54678, 0xf54694, 4)) == (
        0x90006dc8, 0x91126108, 0xf900101f, 0x91002009, 0xa9002408, 0xa9017c09, 0xd65f03c0,
    ), 'BOTW cursor base constructor changed; revalidate preserved x0 at construction observer'
    assert tuple(word(o) for o in range(0xf579d8, 0xf57a14, 4)) == (
        0xa9be7bfd, 0xf9000bf3, 0x910003fd, 0xaa0003f3, 0x97fff324,
        0xb0006da8, 0x9137e108, 0xf9002e7f, 0xa902fe7f, 0xf9000268,
        0xa903fe7f, 0xa904fe7f, 0xf9400bf3, 0xa8c27bfd, 0xd65f03c0,
    ), 'BOTW cursor constructor changed; revalidate initialized manager and epilogue scratch liveness'
    assert tuple(word(o) for o in range(0xe39c08, 0xe39c20, 4)) == (
        0xa9bd7bfd, 0xf9000bf5, 0xa9024ff4, 0x910003fd, 0xaa0003f4, 0x9105e000,
    ), 'BOTW inventory transition-flag setter changed; revalidate native category request staging'
    assert tuple(word(o) for o in range(0xe3b9f0, 0xe3b9fc, 4)) == (
        0xb9768c08, 0x35000048, 0xd65f03c0,
    ), 'BOTW inventory page-commit entry changed; revalidate native category commit sequence'
    assert tuple(word(o) for o in range(0xe3ddcc, 0xe3ddcc + 0x20, 4)) == (
        0xa9be7bfd, 0xa9014ff4, 0x910003fd, 0xb9763808,
        0x2a0103f4, 0xaa0003f3, 0x3100051f, 0x54000220,
    ), 'BOTW native inventory navigation/update entry changed; revalidate zero-delta category refresh'
    # Touch refreshes with the pending-page flag set, then commits last.
    # Navigation reads that pending page, its zero delta does not enter the
    # page-distance loop, and commit clears the transition after native focus.
    assert tuple(word(o) for o in range(0xe3ddec, 0xe3de10, 4)) == (
        0xb9768e69, 0x5286cb88, 0x5286cc0a, 0x8b080268, 0x8b0a026a, 0x7100013f,
        0x9a8a0108, 0xb9400108, 0x0b348100,
    ), 'BOTW inventory navigation pending-page choice changed; revalidate refresh before commit'
    assert tuple(word(o) for o in range(0xe3d430, 0xe3d444, 4)) == (
        0x6b1502ff, 0x52800028, 0x5a88c519, 0x54000161, 0xb9366277,
    ), 'BOTW inventory zero-delta staging changed; revalidate immediate category completion'
    assert tuple(word(o) for o in range(0xe3e228, 0xe3e240, 4)) == (
        0xaa1303e0, 0x52800021, 0x97ffee73, 0xb9766260, 0xb97a1274, 0x9400cb91,
    ), 'BOTW inventory refresh transition request changed; commit must finish after refresh'
    assert tuple(word(o) for o in range(0xe3ba80, 0xe3bacc, 4)) == (
        0x52800028, 0xaa1303e0, 0x390ee288, 0xb9766268, 0xb9365e68, 0x97fffd38,
        0xb9765e61, 0xaa1303e0, 0xb9766662, 0x940009f8, 0x5286cc88, 0x12800009,
        0x7900029f, 0xf8286a69, 0xaa1303e0, 0xa9414ff4, 0x2a1f03e1, 0xa8c27bfd,
        0x17fff84d,
    ), 'BOTW inventory commit focus/transition completion changed; revalidate direct category taps'
    assert tuple(word(o) for o in range(0xd6f034, 0xd6f054, 4)) == (
        0xd101c3ff, 0x6d0123e9, 0xa9027bfd, 0xa90367fa,
        0xa9045ff8, 0xa90557f6, 0xa9064ff4, 0x910083fd,
    ), 'BOTW shared list-widget update entry changed; revalidate passive OBS38 receiver and x0 ABI'
    assert tuple(word(o) for o in range(0xd6d710, 0xd6d728, 4)) == (
        0xb9829808, 0x34000808, 0xf941500a, 0x8b080d4b,
        0xf9414808, 0xb9428809,
    ), 'BOTW read-only list-entry index resolver changed; revalidate OBS38 model query'
    assert tuple(word(o) for o in range(0xd6fe80, 0xd6fe98, 4)) == (
        0x37f80221, 0xf941480a, 0xaa0003e8, 0xb40001ca,
        0xb9828909, 0x34000189,
    ), 'BOTW read-only list descriptor resolver changed; revalidate OBS38 round-trip query'
    assert tuple(word(o) for o in range(0xd6c870, 0xd6c888, 4)) == (
        0xa9be7bfd, 0xa9014ff4, 0x910003fd, 0xaa0003f3,
        0x3100043f, 0x540000e1,
    ), 'BOTW native list selection entry changed; revalidate screen-owned row selection'
    assert tuple(word(o) for o in range(0xd6c244, 0xd6c25c, 4)) == (
        0xd10103ff, 0xa9017bfd, 0xf90013f5, 0xa9034ff4,
        0x910043fd, 0xb942a808,
    ), 'BOTW native list page setter changed; revalidate category taps and list scrolling'
    assert tuple(word(o) for o in range(0xd6bfa0, 0xd6bfb8, 4)) == (
        0xd101c3ff, 0x6d012beb, 0x6d0223e9, 0xa9037bfd, 0xa9045ff8, 0xa90557f6,
    ), 'BOTW native list transition entry changed; revalidate immediate Compendium categories'
    assert tuple(word(o) for o in range(0xd6c128, 0xd6c18c, 4)) == (
        0x510006a8, 0xb9033a75, 0x7100051f, 0x540000a9, 0x52800020, 0x17ffffae,
        0x2a1f03e0, 0x17ffffac, 0x71000abf, 0xaa1303e0, 0x1a9f07e1, 0x94000b02,
        0x12800008, 0x910033e5, 0xb9000fe8, 0xaa1303e0, 0x2a1403e1, 0x2a1603e2,
        0x2a1f03e3, 0x2a1f03e4, 0x940000c5, 0xb9400fe1, 0xaa1303e0, 0x940001bb,
        0x17ffffec,
    ), 'BOTW list mode-1 completion/first-item selection changed; revalidate Compendium category jumps'
    assert tuple(word(o) for o in range(0xd6ed94, 0xd6edcc, 4)) == (
        0xb942e808, 0xb942f009, 0xb902ec09, 0xbd02c000, 0xbd02c401, 0xb902e408,
        0xb942dc08, 0xb902d808, 0x9400040f, 0xb9033660, 0x52800048, 0xaa1303e0,
        0x52800021, 0xb9033268,
    ), 'BOTW native list current/target synchronization changed; revalidate immediate category position'
    assert tuple(word(o) for o in range(0xd8caac, 0xd8cac0, 4)) == (
        0xbd400020, 0xbd088000, 0xbd400420, 0xbd088400, 0xd65f03c0,
    ), 'BOTW current map origin setter changed; revalidate direct touch dragging'
    assert tuple(word(o) for o in range(0xd7a938, 0xd7a94c, 4)) == (
        0xbd400020, 0xbd004000, 0xbd400420, 0xbd004400, 0xd65f03c0,
    ), 'BOTW target map origin setter changed; revalidate direct touch dragging'
    assert tuple(struct.unpack_from('<Q', ctx.image, 0x1cdb958 + off)[0] for off in (0, 8, 0x20, 0x40)) == (
        0xf5466c, 0xd66bb0, 0xd6f034, 0xd66bd4,
    ), 'BOTW inventory list-widget vtable address point changed; revalidate OBS38 receiver class'
    assert tuple(struct.unpack_from('<Q', ctx.image, 0x1cdbb58 + off)[0] for off in (0, 8, 0x20, 0x40)) == (
        0xf5466c, 0xd71710, 0xd6f034, 0xd66bd4,
    ), 'BOTW Quest list-widget vtable address point changed; revalidate OBS38 receiver class'
    assert tuple(struct.unpack_from('<Q', ctx.image, 0x1cfcf78 + off)[0] for off in (0, 8, 0x20, 0x40)) == (
        0xf5466c, 0xe4a2e4, 0xd6f034, 0xd66bd4,
    ), 'BOTW shop list-widget vtable address point changed; revalidate direct purchase-row selection'

VALIDATE = {'cd57b23fa4bbad65803d9788c01821ee': validate_main}

# BOTW 1.9.0 main: aspect adjustments and the selected raw / filtered right-stick observations.
OBS = {
  'cd57b23fa4bbad65803d9788c01821ee': [
    (0x276a0, 34, 'd10243ff', 'Pane::Calculate entry: locate N_MainAll_00 and mark its global matrix dirty on touch HUD changes'),
    (0x27ae4, 35, '52800036', 'Pane::Calculate after global matrix composition and before child recursion: offset N_MainAll_00 translation'),
    (0x27d7c, 39, 'f9405908', 'Pane::Draw before virtual DrawSelf: x21 owns the native background pane'),
    (0x27d84, 40, '394162a8', 'Pane::Draw after virtual DrawSelf: end the native background draw scope'),
    (0xf714b8, 41, 'f9400008', 'ScreenMgr draw dispatch: result filter moves the collapsed touch map before foreground screens in its layer'),
    (0xeb4468, 29, 'a9be7bfd', 'projection update: apply the display aspect to the main camera before checking dirty flags'),
    (0xd44a2c, 30, 'a94a2269', 'UI 3D camera update: x19 owns the source lens at +0xa0 and projection at +0xa8; apply aspect before copying lens parameters'),
    (0xe1a628, 31, 'f960de68', 'MainScreen3D update: correct its copied projection before rebuilding the world-label view'),
    (0xd58008, 33, 'f9409408', 'shared stick getter: snapshot the selected raw child pair before the native dead-zone/filter branches'),
    (0xd5801c, 32, 'fd400be8', 'shared normalized stick getter: inject one frame of relative input after native filtering and before return'),
    (0xf57ba0, 37, 'd10143ff', 'BoxCursorControl update entry: x0 is the native manager; observe focused/requested item before native validation and focus callbacks'),
    (0xf57a08, 37, 'f9400bf3', 'BoxCursorControl constructor exit: x0 is the initialized manager, including first boot without a Title cursor update'),
    (0xd6f034, 38, 'd101c3ff', 'native list-widget update entry: x0 is the shared list widget; cache receiver metadata only'),
  ],
}

# OBS_SAFE sites are interior instructions whose scratch-register liveness is established below:
# 0xe1a628 follows MainScreen3D's successful camera check and the profile verifies x9-x17 stay unread
# through the world-view setup until the next call; the getter / pane sites have their own proofs.
# 0x27d7c reaches the validated C++ DrawSelf virtual call with only x0-x2
# as arguments; x8 retains its target and x9-x17 are caller-clobbered. The
# general straight-line checker deliberately refuses unknown indirect calls.
# 0xf714b8 loads only x8 before the Draw virtual call. Its receiver x0 and
# render info x1 are live; x9-x17 are unread until that call, as checked above.
OBS_SAFE = {'cd57b23fa4bbad65803d9788c01821ee': {0xd5801c, 0x27ae4, 0xe1a628, 0x27d7c, 0xf714b8}}
# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': 'interval controller: the lower bound and the GPU-time path', 'now': 'build', 'goal': 'game', 'purpose': 'frame rate',
     'why': "sead::GameFrameworkNx's interval controller in this build; Tears of the Kingdom shares sead but not this code"},
    {'what': '60 fps frame step and render scale (ksys::VFR)', 'now': 'build', 'goal': 'game', 'purpose': 'frame rate',
     'why': "the game's own frame code; the frame-step state page is general",
     'blocked': 'frame-step stubs have no function-matched form yet'},
]
