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
branch's BOTW profile. The NVN queue integration uses this repository's existing renderer. UI is
provided through Apple's composited-UI API; the original game draws and the
offline shader pipeline remain unchanged.

Other inherited adaptations are documented at their source locations. This
credit does not imply that MacNativeGames authors maintain or endorse this fork.
