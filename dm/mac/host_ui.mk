# Compile the shared SwiftUI launcher once, then link it into the native host.
MAC_UI_SOURCES = ../mac/Launcher.swift ../ios/Sources/LauncherSettings.swift ../ios/Sources/LauncherRow.swift ../ios/Sources/BotwTouchSettings.swift
MAC_UI_OBJECT = gen/mac-ui.o
MAC_UI_SDK = $(shell xcrun --sdk macosx --show-sdk-path)
MAC_UI_LINK = -L"$(MAC_UI_SDK)/usr/lib/swift" -Wl,-rpath,/usr/lib/swift -framework SwiftUI

gen/mac-ui-toolchain: FORCE
	@mkdir -p gen
	@mac_ui_stamp=$@.$$$$.tmp; \
	(xcrun swiftc --version; xcrun --sdk macosx --show-sdk-build-version) > "$$mac_ui_stamp"; \
	if cmp -s "$$mac_ui_stamp" $@; then rm "$$mac_ui_stamp"; else mv "$$mac_ui_stamp" $@; fi

$(MAC_UI_OBJECT): $(MAC_UI_SOURCES) ../mac/host_ui.mk ../mac/min_os.mk module.modulemap launcher_settings.h memory_mode.h aoc_files.h romfs_image.h botw_touch_layout.h botw_stick_settings.h touchpad_geometry.h dm_input.h gen/mac-ui-toolchain
	xcrun swiftc -sdk "$(MAC_UI_SDK)" -target arm64-apple-macos$(MACOS_MIN) -O -swift-version 5 -D DM_HOST_UI -parse-as-library -whole-module-optimization -emit-object -module-name DmMacLauncher -module-cache-path gen/mac-ui-module-cache -I. -o $@ $(MAC_UI_SOURCES)
