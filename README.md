# Touch the Wild

A fork of [nxnative](https://github.com/seedds/nxnative), focused on bringing touch controls to **The Legend of Zelda: Breath of the Wild**.

Play your own Nintendo Switch games natively on iPhone and iPad. Bring your game (its NSP files) and your `prod.keys`; one script turns them into an IPA that you sideload.

It is not an emulator: the game's own code runs directly on the Apple chip, with Switch graphics rebuilt on Metal. Nothing from any game is in this repository, and the project is not affiliated with Nintendo or any game publisher.

Ask your AI agent how to build the project.

## Experimental frame generation (`expriment`)

BOTW has an opt-in MetalFX experiment for the validated Docked rendering path: `DM_FRAMEGEN=30` requests 30 real game frames plus one generated picture between each pair. Leave it unset, or use `0`, for the normal renderer. The Game Overlay home page exposes an off-by-default **Experimental frame generation** switch under **Performance** when Docked mode is selected. A supported Metal 4 GPU is required.

This is a prototype with extra GPU cost and latency. It uses Apple's composited-UI mode, supplying the scene before UI and the completed canvas. It does not guarantee 60 displayed frames per second. See the [BOTW experiment and validation notes](dm/games/01007EF00011E000/README.md#experimental-metalfx-frame-generation).

## Credits

- [seedds](https://github.com/seedds) for [nxnative](https://github.com/seedds/nxnative), the native runtime, graphics translation and build tools this fork is based on (MIT; see [LICENSE](LICENSE)).
- [ly05010419](https://github.com/ly05010419) and the [MacNativeGames contributors](https://github.com/ly05010419/MacNativeGames) for their BOTW/TOTK research and MetalFX frame interpolation implementation. The experimental frame-generation work adapts their camera reprojection, motion vectors and MetalFX setup; see the [source attribution](dm/third_party/macnativegames/README.md) and [MIT license](dm/third_party/macnativegames/LICENSE).
- The Ryujinx contributors for the shader translator used by the inherited graphics pipeline; its [license](dm/third_party/ryujinx/LICENSE.txt) is retained with the source.

## 触摸旷野

这是 [nxnative](https://github.com/seedds/nxnative) 的一个分支，专注于为 **《塞尔达传说：旷野之息》** 添加触屏操作支持。

在 iPhone 和 iPad 上原生运行你自己的 Nintendo Switch 游戏。准备好游戏的 NSP 文件和你的 `prod.keys`，通过一个脚本即可生成 IPA，再自行侧载到设备上。

这不是模拟器：游戏自身的代码直接运行在 Apple 芯片上，Switch 图形则通过 Metal 重新实现。本仓库不包含任何游戏内容，本项目与任天堂或任何游戏发行商均无关联。

你可以向 AI 助手询问如何构建本项目。
