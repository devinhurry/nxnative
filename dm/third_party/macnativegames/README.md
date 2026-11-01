# MacNativeGames attribution

[MacNativeGames](https://github.com/ly05010419/MacNativeGames), by
[ly05010419](https://github.com/ly05010419) and its contributors, is licensed
under the [MIT license](LICENSE), retained here.

The experimental MetalFX frame generator in `dm/gfx/nvn/framegen_metal.m`
adapts its texture setup, camera reprojection, motion-vector compute shader,
camera-cut detection and MetalFX encoding from
[`games/totk/third_party/d2r_gfx/gfx/nvn/totk_mfx.m`](https://github.com/ly05010419/MacNativeGames/blob/933b6a0d1438de160208a0a13eb5e8d7a2cb8094/games/totk/third_party/d2r_gfx/gfx/nvn/totk_mfx.m).
The source revision is `933b6a0d1438de160208a0a13eb5e8d7a2cb8094`.
Its BOTW scene-completion shader and camera-uniform notes also inform this
branch's BOTW profile. The completion work additionally follows its separate
premultiplied HUD output and BOTW real-time VFR/fade/UI/physics step at revision
`92ec79bd10c006e1cb7ca32d7ac1d8f66c758a15`, including
[`game_patches_botw.c`](https://github.com/ly05010419/MacNativeGames/blob/92ec79bd10c006e1cb7ca32d7ac1d8f66c758a15/games/totk/runtime/game_patches_botw.c).
This repository generates the HUD fragment variants offline; it does not
compile or patch game shaders at runtime. Original game draws execute once.
The NVN queue integration uses this repository's existing renderer.

Other inherited adaptations are documented at their source locations. This
credit does not imply that MacNativeGames authors maintain or endorse this fork.
