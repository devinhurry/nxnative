# Metroid Dread (010093801237C000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
OBS = {
  # Metroid Dread 2.1.0 main: the movie player posts "link / unlink holders" requests into the dispatcher thread's request ring (main+0x222cc8) and goes on without waiting for them (after an unlink it frees the wrapper object and builds a new one in place).
  # On hardware the dispatcher thread (priority 30, core 0 only) preempts the main thread (priority 44, core 0) at once and finishes first; the host waits for the ring to empty after each post (hle_movie.c movie_ring_wait). The gates sit on the add x22, x22, #8 after the bl
  '646761f643afebb379edd5e6a5151af2': [
    (0x2247a4, 19, '910022d6', 'link request posted (loop at main+0x224728, x19 = request ring): wait for the dispatcher; orig add x22, x22, #8'),
    (0x2248e4, 20, '910022d6', 'unlink request posted (loop at main+0x224868, x19 = request ring): wait for the dispatcher before the object is freed; orig add x22, x22, #8'),
  ],
}
