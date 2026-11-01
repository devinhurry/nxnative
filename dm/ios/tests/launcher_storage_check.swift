// The launcher's storage (LauncherSettings.swift LauncherModel), run by test_launcher_storage.py on macOS: only choices that differ from the game's default are
// stored, Reset to tested defaults followed by Play forgets the choices, an env file's values are kept. Arguments: the iOS and the Mac launcher.json of Breath of the Wild (settings.py, GFXAPI=nvn)
import Foundation
#if DM_HOST_UI
private var nativeApplied: [String: String] = [:]
@_cdecl("dm_launcher_setting_is_live")
func mockNativeSettingIsLive(_ key: UnsafePointer<CChar>) -> Int32 {
    ["DM_BOTW_MOVE_CURVE", "DM_RUMBLE", "DM_FPS_TARGET", "DM_FRAMEGEN"].contains(String(cString: key)) ? 1 : 0
}
@_cdecl("dm_launcher_setting_apply")
func mockNativeSettingApply(_ key: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) -> Int32 {
    guard mockNativeSettingIsLive(key) == 1 else { return 0 }
    nativeApplied[String(cString: key)] = String(cString: value)
    return setenv(key, value, 1) == 0 ? 1 : -1
}
#endif
@main struct Check {
    static func main() {
        var failed = 0
        func expect(_ c: Bool, _ what: String) { print((c ? "PASS " : "FAIL ") + what); if !c { failed += 1 } }
        expect(AboutSection.shortCommit("abcdef012345") == "abcdef", "About shows a six-character commit")
        expect(AboutSection.shortCommit("abcdef012345+dirty") == "abcdef+dirty", "About preserves the local-changes marker")
        expect(AboutSection.shortCommit("unknown") == "unknown", "About handles missing source metadata")
        let utc = TimeZone(secondsFromGMT: 0)!
        expect(AboutSection.localBuildTime("2026-10-31T20:00:00Z", timeZone: TimeZone(identifier: "Asia/Shanghai")!) ==
               AboutSection.localBuildTime("2026-11-01T04:00:00Z", timeZone: utc), "About converts UTC into local time across a date boundary")
        expect(AboutSection.localBuildTime("2026-07-01T12:00:00Z", timeZone: TimeZone(identifier: "America/Los_Angeles")!) ==
               AboutSection.localBuildTime("2026-07-01T05:00:00Z", timeZone: utc), "About respects daylight saving time")
        expect(AboutSection.localBuildTime("unknown") == "unknown", "About preserves missing build-time metadata")
        let file = try! JSONDecoder().decode(SettingsFile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let suite = "nxnative.launcher-test." + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set("1", forKey: "launcher.DM_PRESENT_SNAP")   // stored by the old launcher, equal to the default
        d.set("30", forKey: "launcher.DM_FPS_TARGET")    // a changed game setting
        d.set("0", forKey: "launcher.DM_PSO_MTL4")       // a changed performance setting
        d.set("1", forKey: "launcher.DM_FPS_HOLD")       // a value the toggle does not take (on / off): the default
        setenv("DM_ENV_FILE_KEYS", "DM_METAL_HUD", 1); setenv("DM_METAL_HUD", "1", 1)   // set by Documents/env.txt
        let m = LauncherModel(file.settings, defaults: d)
        expect(m.values["DM_THERMAL_CAP"] == "0", "the optional thermal cap defaults off")
        m.values["DM_THERMAL_CAP"] = "1"
        expect(m.needsTouchFallbackNotice && LauncherModel(file.settings, defaults: d).needsTouchFallbackNotice,
               "the first BOTW touch start needs a notice until acknowledged")
        expect(!LauncherModel([], defaults: d).needsTouchFallbackNotice, "other games do not show the BOTW touch notice")
        m.acknowledgeTouchFallbackNotice()
        let acknowledged = LauncherModel(file.settings, defaults: d)
        acknowledged.reset()
        expect(!acknowledged.needsTouchFallbackNotice, "acknowledgment survives a new launcher and settings reset")
        let scale = file.settings.first { $0.env == "DM_RENDER_SCALE" }!
        expect(["nan", "inf", "-inf", "0.49", "1.01", "invalid", "0x1p-1", "0X1", " 0.75"].allSatisfy { !scale.accepts($0) } && scale.accepts("0.5") && scale.accepts("1.00"), "saved ranges reject nonfinite, out-of-range, hex and padded values, as launcher.c does")
        d.set("nan", forKey: "launcher.DM_RENDER_SCALE")
        expect(LauncherModel(file.settings, defaults: d).values["DM_RENDER_SCALE"] == scale.def, "an invalid saved range loads the default")
        expect(m.values["DM_FPS_TARGET"] == "30" && m.values["DM_PSO_MTL4"] == "0" && m.values["DM_FPS_HOLD"] == "on" && m.values["DM_METAL_HUD"] == "1", "stored choices and the env file are read")
        expect(m.changed, "Reset is offered with changed settings")
        let stick = m.touchStickResponse!
        expect(stick.deadzone == 0.07 && stick.curve == 0.3 && stick.full == 0.71 && stick.size == 0.8, "touch stick starts at the current movement defaults")
        expect(stick.strength(at: 0.07) == 0 && abs(stick.strength(at: 0.2) - pow(0.13/0.64,0.3)) < 0.001 && stick.strength(at: 0.71) == 1, "curve preview has the real deadzone, short-drag strength and endpoint")
        let curve = file.settings.first { $0.env == "DM_BOTW_MOVE_CURVE" }!
        expect(curve.formattedValue("0.7") == "0.70" && scale.formattedValue("0.5") == "50 %", "curve values are numbers and existing ranges remain percentages")
        m.values["DM_BOTW_MOVE_DEADZONE"] = "0.15"; m.values["DM_BOTW_MOVE_CURVE"] = "1.00"
        m.values["DM_BOTW_MOVE_FULL"] = "0.60"; m.values["DM_BOTW_MOVE_SIZE"] = "1.25"
        expect(abs(m.touchStickResponse!.strength(at: 0.375) - 0.5) < 1e-6, "adjusted curve preview responds to all movement parameters")
        m.values["DM_BOTW_PAD_FACE_X"] = "-0.100"; m.values["DM_BOTW_PAD_FACE_GAP"] = "1.200"
        m.values["DM_RENDER_SCALE"] = "1.00"   // the slider's format of the default
        m.values["DM_BOTW_PAD_BADGES"] = "0"
        let exported = m.touchSettingsExport
        expect(exported.contains("DM_BOTW_PAD_FACE_X=-0.100") && exported.contains("DM_BOTW_PAD_FACE_GAP=1.200") && exported.contains("DM_BOTW_PAD_BADGES=0") && exported.contains("DM_BOTW_MOVE_CURVE=1.000") && !exported.contains("DM_FPS_TARGET"), "touch export contains exact adjusted runtime values without unrelated settings")
        m.apply()
        expect(d.string(forKey: "launcher.DM_PRESENT_SNAP") == nil, "a value equal to the default is not stored (and an old one is dropped)")
        expect(d.string(forKey: "launcher.DM_RENDER_SCALE") == nil && d.string(forKey: "launcher.DM_OPMODE") == nil && d.string(forKey: "launcher.DM_FPS_HOLD") == nil, "defaults are not stored")
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == "30" && d.string(forKey: "launcher.DM_PSO_MTL4") == "0", "changed choices are stored")
        expect(d.string(forKey: "launcher.DM_THERMAL_CAP") == "1" && String(cString: getenv("DM_THERMAL_CAP")) == "1", "Play saves and applies the optional thermal cap")
        expect(d.string(forKey: "launcher.DM_METAL_HUD") == nil && String(cString: getenv("DM_METAL_HUD")) == "1", "the env file's value is kept and not stored")
        expect(String(cString: getenv("DM_PSO_MTL4")) == "0" && String(cString: getenv("DM_PRESENT_SNAP")) == "1" && String(cString: getenv("DM_FPS_HOLD")) == "on", "the environment gets every value")
        let reopened = LauncherModel(file.settings, defaults: d)
        expect(reopened.values["DM_THERMAL_CAP"] == "1", "reopening restores an enabled thermal cap")
        expect(reopened.values["DM_BOTW_MOVE_DEADZONE"] == "0.15" && reopened.values["DM_BOTW_MOVE_SIZE"] == "1.25" && String(cString: getenv("DM_BOTW_MOVE_CURVE")) == "1.00", "Play persists stick settings, reopening restores them, and runtime receives them")
        expect(reopened.values["DM_BOTW_PAD_FACE_X"] == "-0.100" && reopened.values["DM_BOTW_PAD_FACE_GAP"] == "1.200", "layout group offset and spacing persist alongside response settings")
        expect(reopened.values["DM_BOTW_PAD_BADGES"] == "0", "corner badge switch persists")
        expect(!file.settings.contains { $0.env.hasPrefix("DM_BOTW_PAD_PLUS") || $0.env.hasPrefix("DM_BOTW_PAD_MINUS") }, "plus and minus remain fixed")
        reopened.reset(keys: TouchStickResponse.keys)
        expect(!reopened.touchStickChanged && reopened.values["DM_BOTW_MOVE_DEADZONE"] == "0.070" && reopened.values["DM_BOTW_MOVE_SIZE"] == "0.800", "left-stick reset restores the entire group")
        expect(reopened.values["DM_FPS_TARGET"] == "30" && d.string(forKey: "launcher.DM_PSO_MTL4") == "0", "left-stick reset preserves unrelated game and performance choices")
        reopened.values["DM_BOTW_PAD_R_Y"] = "0.100"
        reopened.reset(keys: BotwTouchControl.all[0].keys.union(["DM_BOTW_PAD_FACE_GAP"]))
        expect(reopened.values["DM_BOTW_PAD_FACE_X"] == "-0.006" && reopened.values["DM_BOTW_PAD_FACE_GAP"] == "1.060" && reopened.values["DM_BOTW_PAD_R_Y"] == "0.100", "per-control restore resets XYAB spacing and position without changing R")
        reopened.reset(keys: reopened.touchSettingsKeys)
        expect(reopened.values["DM_BOTW_PAD_R_Y"] == "-0.097" && reopened.values["DM_FPS_TARGET"] == "30", "restore all touch defaults leaves frame rate alone")
        let portraitSuite = suite + ".portrait"
        let portraitDefaults = UserDefaults(suiteName: portraitSuite)!
        defer { portraitDefaults.removePersistentDomain(forName: portraitSuite) }
        let portraitModel = LauncherModel(file.settings, defaults: portraitDefaults)
        expect(portraitModel.values["DM_BOTW_PORTRAIT"] == "0", "portrait mode starts disabled")
        portraitModel.values["DM_BOTW_PORTRAIT"] = "1"
        portraitModel.values["DM_BOTW_PAD_FACE_X"] = "0.123"
        portraitModel.values["DM_BOTW_PORTRAIT_PAD_A_X"] = "-0.200"
        portraitModel.values["DM_BOTW_PORTRAIT_PAD_B_Y"] = "0.100"
        portraitModel.values["DM_BOTW_PORTRAIT_PAD_X_SCALE"] = "1.250"
        portraitModel.values["DM_BOTW_PORTRAIT_PAD_Y_X"] = "0.050"
        portraitModel.values["DM_BOTW_PORTRAIT_MOVE_CURVE"] = "0.750"
        portraitModel.apply()
        let portraitRestored = LauncherModel(file.settings, defaults: portraitDefaults)
        expect(portraitRestored.values["DM_BOTW_PAD_FACE_X"] == "0.123" && portraitRestored.values["DM_BOTW_PORTRAIT_PAD_A_X"] == "-0.200" &&
               portraitRestored.values["DM_BOTW_PORTRAIT_PAD_B_Y"] == "0.100" && portraitRestored.values["DM_BOTW_PORTRAIT_PAD_X_SCALE"] == "1.250" &&
               portraitRestored.values["DM_BOTW_PORTRAIT_PAD_Y_X"] == "0.050" &&
               portraitRestored.touchStickResponse(portrait: true)?.curve == 0.75 && portraitRestored.touchStickResponse?.curve == 0.3,
               "portrait and landscape positions and movement responses persist independently")
        let portraitExport = portraitRestored.touchSettingsExport(portrait: true)
        expect(portraitExport.contains("DM_BOTW_PORTRAIT_PAD_A_X=-0.200") && portraitExport.contains("DM_BOTW_PORTRAIT_PAD_B_Y=0.100") &&
               portraitExport.contains("DM_BOTW_PORTRAIT_PAD_X_SCALE=1.250") && portraitExport.contains("DM_BOTW_PORTRAIT_PAD_Y_X=0.050") &&
               !portraitExport.contains("DM_BOTW_PAD_FACE_X=") && !portraitExport.contains("DM_BOTW_PORTRAIT_PAD_FACE_"),
               "portrait parameter export contains independent buttons and only the portrait profile")
        portraitRestored.reset(keys: BotwTouchControl.compact[0].keys(portrait: true))
        expect(portraitRestored.values["DM_BOTW_PORTRAIT_PAD_A_X"] == "0.000" && portraitRestored.values["DM_BOTW_PORTRAIT_PAD_B_Y"] == "0.100",
               "restoring compact A preserves the other compact button adjustments")
        portraitRestored.reset(keys: portraitRestored.touchSettingsKeys(portrait: true))
        expect(portraitRestored.values["DM_BOTW_PORTRAIT_PAD_B_Y"] == "0.000" && portraitRestored.values["DM_BOTW_PORTRAIT_PAD_X_SCALE"] == "1.100" &&
               portraitRestored.values["DM_BOTW_PORTRAIT_PAD_Y_X"] == "0.000" && portraitRestored.values["DM_BOTW_PAD_FACE_X"] == "0.123" && portraitRestored.values["DM_BOTW_PORTRAIT"] == "1",
               "restoring portrait defaults preserves landscape settings and the portrait toggle")
        d.set("nan", forKey: "launcher.DM_BOTW_MOVE_CURVE"); d.set("2.00", forKey: "launcher.DM_BOTW_MOVE_SIZE")
        expect(LauncherModel(file.settings, defaults: d).touchStickResponse!.curve == 0.3 && LauncherModel(file.settings, defaults: d).touchStickResponse!.size == 0.8, "invalid saved tuning values load defaults")
        setenv("DM_ENV_FILE_KEYS", "DM_BOTW_MOVE_DEADZONE", 1); setenv("DM_BOTW_MOVE_DEADZONE", "0.12", 1)
        let locked = LauncherModel(file.settings, defaults: d)
        locked.reset(keys: TouchStickResponse.keys); locked.apply()
        expect(locked.values["DM_BOTW_MOVE_DEADZONE"] == "0.12" && String(cString: getenv("DM_BOTW_MOVE_DEADZONE")) == "0.12", "left-stick reset and Play preserve an env-file override")
        setenv("DM_ENV_FILE_KEYS", "DM_METAL_HUD", 1)
        m.reset()
        expect(m.values["DM_PSO_MTL4"] == "1" && m.values["DM_FPS_TARGET"] == file.settings.first { $0.env == "DM_FPS_TARGET" }!.def, "Reset shows the defaults")
        expect(d.string(forKey: "launcher.DM_PSO_MTL4") == "0" && d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "Reset alone forgets nothing: Quit after it keeps the choices")
        expect(m.values["DM_METAL_HUD"] == "1" && !m.changed, "Reset leaves the env file's value; nothing left to reset")
        m.apply()
        expect(d.string(forKey: "launcher.DM_PSO_MTL4") == nil && d.string(forKey: "launcher.DM_FPS_TARGET") == nil, "Play after Reset forgets the choices")
        d.set(30, forKey: "launcher.DM_FPS_TARGET"); d.set(false, forKey: "launcher.DM_RUMBLE")   // a number and a boolean, as defaults write -int / -bool stores them
        let typed = LauncherModel(file.settings, defaults: d)
        expect(typed.values["DM_FPS_TARGET"] == file.settings.first { $0.env == "DM_FPS_TARGET" }!.def && typed.values["DM_RUMBLE"] == "1", "a saved value that is not a string is ignored, as launcher.c ignores it")
        d.removeObject(forKey: "launcher.DM_FPS_TARGET"); d.removeObject(forKey: "launcher.DM_RUMBLE")
        // Sub-settings: a row with "needs" is drawn only while the setting it names has that value
        m.values["DM_RUMBLE"] = "1"
        expect(m.rows(in: "Controls").contains { $0.env == "DM_RUMBLE_GAIN" }, "a sub-setting is drawn while its setting is on")
        m.values["DM_RUMBLE"] = "0"
        expect(!m.rows(in: "Controls").contains { $0.env == "DM_RUMBLE_GAIN" }, "a sub-setting is hidden while its setting is off")
        expect(m.rows(in: "Controls").contains { $0.env == "DM_RUMBLE" }, "the setting it depends on stays drawn")
        m.values["DM_RUMBLE"] = "1"
        // DM_LAUNCHER=0 skips the screen, not the saved choices; DM_SAVED_CHOICES=0 ignores them and leaves them stored
        let fps = file.settings.first { $0.env == "DM_FPS_TARGET" }!
        d.set("30", forKey: "launcher.DM_FPS_TARGET"); unsetenv("DM_FPS_TARGET")
        LauncherModel(file.settings, defaults: d).applySaved()
        expect(String(cString: getenv("DM_FPS_TARGET")) == "30" && d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "without the screen, a saved choice goes into the environment and stays saved")
        setenv("DM_SAVED_CHOICES", "0", 1); unsetenv("DM_FPS_TARGET")
        let plain = LauncherModel(file.settings, defaults: d)
        expect(plain.values["DM_FPS_TARGET"] == fps.def, "DM_SAVED_CHOICES=0 starts from the defaults")
        plain.applySaved()
        expect(getenv("DM_FPS_TARGET") == nil, "DM_SAVED_CHOICES=0: nothing saved goes into the environment")
        plain.apply()
        expect(String(cString: getenv("DM_FPS_TARGET")) == fps.def && d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "DM_SAVED_CHOICES=0: Play uses the screen's values and leaves the saved choices")
        plain.reset()
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "DM_SAVED_CHOICES=0: Reset leaves the saved choices too")
        unsetenv("DM_SAVED_CHOICES")
        // The Mac window's list (second argument): Basic first, then Advanced in the list's sections; Display mode; the render scale in pixels; values set at launch are fixed
        let mac = try! JSONDecoder().decode(SettingsFile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        setenv("DM_ENV_FILE_KEYS", "", 1); unsetenv("DM_FULLSCREEN"); unsetenv("DM_OPMODE")
        let mm = LauncherModel(mac.settings, defaults: d)
        expect(mm.sections(basic: true) == ["Game", "Controls"] && mm.sections(basic: false) == ["Game", "Controls", "Touch left stick", "Touch layout", "Performance"], "Basic and Advanced keep the list's sections")
        expect(mm.rows(in: "Game", basic: true).map(\.env) == ["DM_FPS_TARGET", "DM_FRAMEGEN", "DM_RENDER_SCALE", "DM_OPMODE", "DM_LANG", "DM_FULLSCREEN"], "Basic rows in the list's order")
        expect(!file.settings.contains { $0.env == "DM_FULLSCREEN" } && mm.values["DM_FULLSCREEN"] == "0", "Display mode is the Mac's, Window by default")
        mm.values["DM_FULLSCREEN"] = "1"; mm.apply()
        expect(String(cString: getenv("DM_FULLSCREEN")) == "1" && d.string(forKey: "launcher.DM_FULLSCREEN") == "1", "Fullscreen goes into the environment and is saved")
        mm.values["DM_FULLSCREEN"] = "0"; mm.apply()
        expect(String(cString: getenv("DM_FULLSCREEN")) == "0" && d.string(forKey: "launcher.DM_FULLSCREEN") == nil, "Window is the default: set to 0, not saved")
        let macScale = mac.settings.first { $0.env == "DM_RENDER_SCALE" }!
        mm.values["DM_OPMODE"] = "1"
        expect(mm.rangeLabel(macScale, 1) == "1600 × 900 (100 %)" && mm.rangeLabel(macScale, 0.5) == "800 × 450 (50 %)", "docked size in pixels at 1.0 and 0.5")
        mm.values["DM_OPMODE"] = "0"
        expect(mm.rangeLabel(macScale, 0.75) == "960 × 540 (75 %)", "handheld size in pixels")
        let plainScale = try! JSONDecoder().decode(Setting.self, from: Data(#"{"env":"DM_X","kind":"range","label":"X","note":"","default":"1.0","min":0.5,"max":1.0,"step":0.05,"level":"expert"}"#.utf8))
        expect(mm.rangeLabel(plainScale, 0.5) == "50 %" && !plainScale.basic, "no base size: the percentage; an unknown level decodes as Advanced")
        d.set("1", forKey: "launcher.DM_OPMODE"); setenv("DM_ENV_LAUNCH_KEYS", "DM_OPMODE", 1); setenv("DM_OPMODE", "0", 1)   // a front end's launch override over a saved choice
        let launched = LauncherModel(mac.settings, defaults: d)
        expect(launched.values["DM_OPMODE"] == "0" && launched.fixed.contains("DM_OPMODE") && launched.fromLaunch.contains("DM_OPMODE"), "a variable set at launch is shown fixed, over the saved choice")
        launched.apply()
        expect(String(cString: getenv("DM_OPMODE")) == "0" && d.string(forKey: "launcher.DM_OPMODE") == "1", "Play keeps the launch value and leaves the saved choice")
        launched.reset(); launched.apply()
        expect(launched.values["DM_OPMODE"] == "0" && d.string(forKey: "launcher.DM_OPMODE") == "1", "Reset then Play keeps the saved choice of a setting fixed at launch")
        unsetenv("DM_OPMODE"); setenv("DM_ENV_LAUNCH_KEYS", "", 1); d.removeObject(forKey: "launcher.DM_OPMODE")
        // The shared toggle follows the independently selected real-game rate.
        let fgDomain = "nxnative.launcher-framegen-test.\(UUID().uuidString)"
        let fgDefaults = UserDefaults(suiteName: fgDomain)!
        defer { fgDefaults.removePersistentDomain(forName: fgDomain) }
        unsetenv("DM_FRAMEGEN"); unsetenv("DM_FPS_TARGET")
        let fgRow = file.settings.first { $0.env == "DM_FRAMEGEN" }!
        let fpsRow = file.settings.first { $0.env == "DM_FPS_TARGET" }!
        let fg = LauncherModel(file.settings, defaults: fgDefaults)
        expect(fgRow.kind == "choice" && fgRow.options!.map { $0[0] } == ["0", "30", "60"] && !fg.frameGenerationEnabled,
               "frame generation starts off and exposes only the two supported source rates")
        expect(fg.rows(in: "Game", basic: true).contains { $0.env == fgRow.env }, "frame generation is beside the game frame rate")
        for rate in ["30", "60"] { for enabled in [false, true] {
            fg.setValue("0", for: fgRow)
            fg.binding(fpsRow).wrappedValue = rate
            fg.setValue(enabled ? rate : "0", for: fgRow)
            fg.apply()
            let expected = enabled ? rate : "0"
            expect(String(cString: getenv("DM_FPS_TARGET")) == rate && String(cString: getenv("DM_FRAMEGEN")) == expected,
                   "all four frame-rate and interpolation combinations reach the game")
            let reopened = LauncherModel(file.settings, defaults: fgDefaults)
            expect(reopened.values[fpsRow.env] == rate && reopened.values[fgRow.env] == expected,
                   "each of the four modes survives reopening")
            reopened.beginRuntime()
            let other = rate == "30" ? "60" : "30"
            reopened.binding(fpsRow).wrappedValue = other
            expect(reopened.values[fgRow.env] == (enabled ? other : "0") &&
                   String(cString: getenv("DM_FPS_TARGET")) == other &&
                   String(cString: getenv("DM_FRAMEGEN")) == (enabled ? other : "0"),
                   "live frame-rate changes preserve the independent interpolation switch")
        } }
        fgDefaults.set("30", forKey: "launcher.DM_FRAMEGEN")
        fgDefaults.removeObject(forKey: "launcher.DM_FPS_TARGET")
        let migrated = LauncherModel(file.settings, defaults: fgDefaults)
        expect(migrated.values[fpsRow.env] == "30", "an existing interpolation choice restores its matching source rate")
        setenv("DM_ENV_FILE_KEYS", "DM_FRAMEGEN", 1); setenv("DM_FRAMEGEN", "30", 1)
        let fgLocked = LauncherModel(file.settings, defaults: fgDefaults)
        fgLocked.binding(fpsRow).wrappedValue = "60"
        fgLocked.reset(); fgLocked.apply()
        expect(fgLocked.lockingKey(fpsRow) == "DM_FRAMEGEN" && fgLocked.values[fpsRow.env] == "30" &&
               String(cString: getenv("DM_FRAMEGEN")) == "30", "a pinned interpolation rate remains consistent through edits and Reset")
        setenv("DM_ENV_FILE_KEYS", "DM_FPS_TARGET", 1); setenv("DM_FPS_TARGET", "60", 1)
        fgDefaults.set("30", forKey: "launcher.DM_FRAMEGEN")
        let fpsLocked = LauncherModel(file.settings, defaults: fgDefaults)
        expect(fpsLocked.values[fgRow.env] == "60", "a pinned frame rate takes precedence over a saved interpolation rate")
        fpsLocked.setValue("0", for: fgRow)
        expect(!fpsLocked.frameGenerationEnabled && fpsLocked.values[fpsRow.env] == "60", "interpolation can be disabled without changing a pinned frame rate")
        setenv("DM_ENV_FILE_KEYS", "", 1); unsetenv("DM_FRAMEGEN"); unsetenv("DM_FPS_TARGET")
        // Automatic memory defaults are recalculated; only explicit On/Off is
        // saved, including choices equal to the current automatic default.
        let memoryDomain = "org.nxnative.launcher-memory-test.\(UUID().uuidString)"
        let memoryDefaults = UserDefaults(suiteName: memoryDomain)!
        defer { memoryDefaults.removePersistentDomain(forName: memoryDomain) }
        let gib: UInt64 = 1 << 30
        let memoryRow = file.settings.first { $0.env == LauncherModel.lowMemoryKey }!
        func model(_ bytes: UInt64) -> LauncherModel {
            LauncherModel(file.settings, defaults: memoryDefaults, availableMemory: { bytes })
        }
        let memory = model(8 * gib)
        expect(!memory.lowMemoryEnabled && !memory.changed, "enough memory defaults off without a user override")
        memory.setValue("1", for: memoryRow)
        expect(!memory.rows(in: "Performance").contains { $0.env == "DM_PSO_PREBUILD" }, "memory preset hides whole-game prebuild")
        expect(memory.lowMemoryEnabled && memoryDefaults.string(forKey: "launcher.DM_LOW_MEMORY") == "1", "manual On immediately persists and shows the notice")
        memory.apply()
        expect(String(cString: getenv("DM_LOW_MEMORY")) == "1" && memoryDefaults.string(forKey: "launcher.DM_LOW_MEMORY") == "1", "Play applies and saves the memory preset")
        let memoryReloaded = model(8 * gib)
        expect(memoryReloaded.lowMemoryEnabled && model(4 * gib).lowMemoryEnabled, "manual On overrides both low and high detected memory")
        memoryReloaded.reset(); memoryReloaded.apply()
        expect(String(cString: getenv("DM_LOW_MEMORY")) == "0" && memoryDefaults.string(forKey: "launcher.DM_LOW_MEMORY") == nil, "Reset and Play disable the memory preset")
        expect(memoryReloaded.rows(in: "Performance").contains { $0.env == "DM_PSO_PREBUILD" }, "normal prebuild choice returns when memory preset is off")
        let low = model(4 * gib)
        expect(low.lowMemoryEnabled && !low.changed, "low memory automatically enables the preset without marking it as a manual change")
        low.refreshMemoryDefault(available: 8 * gib)
        expect(!low.lowMemoryEnabled && !low.changed, "automatic selection follows updated headroom while the overlay is open")
        low.refreshMemoryDefault(available: 4 * gib)
        low.apply()
        expect(memoryDefaults.string(forKey: "launcher.DM_LOW_MEMORY") == nil && !model(8 * gib).lowMemoryEnabled, "automatic On is not stored and recalculates to Off on a later high-memory launch")
        low.setValue("0", for: memoryRow)
        low.refreshMemoryDefault(available: 3 * gib)
        expect(!low.lowMemoryEnabled && memoryDefaults.string(forKey: "launcher.DM_LOW_MEMORY") == "0", "manual Off immediately persists and hides the notice")
        low.apply()
        expect(!model(4 * gib).lowMemoryEnabled && !model(8 * gib).lowMemoryEnabled, "manual Off overrides low memory and is retained even though it matches the packed default")
        model(4 * gib).applySaved()
        expect(String(cString: getenv("DM_LOW_MEMORY")) == "0", "skipping the overlay preserves explicit Off")
        let equalDefault = model(8 * gib)
        equalDefault.setValue("0", for: memoryRow)
        expect(!model(4 * gib).lowMemoryEnabled && equalDefault.changed, "manual Off equal to the automatic value stays explicit and can be reset")
        equalDefault.reset(keys: TouchStickResponse.keys); equalDefault.apply()
        expect(memoryDefaults.string(forKey: "launcher.DM_LOW_MEMORY") == "0", "resetting touch settings preserves the memory override")
        let restoreAuto = model(4 * gib)
        restoreAuto.reset()
        expect(restoreAuto.lowMemoryEnabled && memoryDefaults.string(forKey: "launcher.DM_LOW_MEMORY") == "0", "Reset selects fresh automatic On without forgetting the previous choice until Play")
        restoreAuto.apply()
        expect(memoryDefaults.string(forKey: "launcher.DM_LOW_MEMORY") == nil, "Play after Reset returns the memory setting to automatic")
        unsetenv("DM_LOW_MEMORY"); model(4 * gib).applySaved()
        expect(String(cString: getenv("DM_LOW_MEMORY")) == "1" && memoryDefaults.string(forKey: "launcher.DM_LOW_MEMORY") == nil, "skipping the overlay applies automatic On without saving it")
        expect(model(4 * gib + gib / 2 - 1).lowMemoryEnabled && !model(4 * gib + gib / 2).lowMemoryEnabled && !model(0).lowMemoryEnabled, "4.5 GiB boundary and unavailable memory follow the policy")
        memoryDefaults.set("invalid", forKey: "launcher.DM_LOW_MEMORY")
        expect(model(4 * gib).lowMemoryEnabled, "invalid saved memory choice falls back to detection")
        memoryDefaults.set("1", forKey: "launcher.DM_LOW_MEMORY")
        setenv("DM_ENV_FILE_KEYS", "DM_LOW_MEMORY", 1); setenv("DM_LOW_MEMORY", "0", 1)
        let memoryLocked = model(4 * gib)
        memoryLocked.setValue("1", for: memoryRow); memoryLocked.reset(); memoryLocked.apply()
        expect(!memoryLocked.lowMemoryEnabled && memoryDefaults.string(forKey: "launcher.DM_LOW_MEMORY") == "1", "explicit env override stays locked and preserves the saved user choice")
        setenv("DM_ENV_FILE_KEYS", "", 1)
        memoryDefaults.set("0", forKey: "launcher.DM_LOW_MEMORY"); setenv("DM_SAVED_CHOICES", "0", 1)
        let memoryIgnored = model(4 * gib); memoryIgnored.apply()
        expect(memoryIgnored.lowMemoryEnabled && memoryDefaults.string(forKey: "launcher.DM_LOW_MEMORY") == "0", "diagnostic saved-choice bypass uses detection without erasing the manual choice")
        unsetenv("DM_SAVED_CHOICES")
        let otherSettings = file.settings.filter { $0.env != LauncherModel.lowMemoryKey }
        let otherGame = LauncherModel(otherSettings, defaults: memoryDefaults, availableMemory: { fatalError("unrelated game must not query the memory policy") })
        expect(!otherGame.lowMemoryEnabled && otherGame.values[LauncherModel.lowMemoryKey] == nil, "games without the memory setting do not detect or enable it")
        failed += checkLauncherLayout(LauncherModel(mac.settings, defaults: d, availableMemory: { 4 * gib }), defaults: d)
        for list in [file.settings, mac.settings] {
            let rows = list.filter { $0.env == "DM_PRESENT_UPSCALE" }
            expect(rows.count == 1 && !list.contains { $0.env == "DM_SCENE_UPSCALE" }, "one upscaling choice replaces the independent switches")
            expect(rows[0].options?.map { $0[0] } == ["off", "scene", "metalfx"], "the three upscaling modes are available")
            let model = LauncherModel(list, defaults: d)
            for mode in ["scene", "metalfx", "off"] {
                model.values["DM_PRESENT_UPSCALE"] = mode; model.apply()
                expect(String(cString: getenv("DM_PRESENT_UPSCALE")) == mode, "the selected upscaling mode reaches the game")
                expect(LauncherModel(list, defaults: d).values["DM_PRESENT_UPSCALE"] == mode, "the upscaling choice survives reopening")
            }
        }
        setenv("DM_ENV_FILE_KEYS", "", 1); setenv("DM_ENV_LAUNCH_KEYS", "", 1)
        memoryDefaults.set("0", forKey: "launcher.DM_LOW_MEMORY")
        let runtimeModel = model(8 * gib)
        runtimeModel.beginRuntime()
        runtimeModel.reset(keys: [LauncherModel.lowMemoryKey])
        expect(memoryDefaults.string(forKey: "launcher.DM_LOW_MEMORY") == nil,
               "runtime reset removes an explicit memory override even when its value already equals automatic")
        setenv("DM_LANG", "en-US", 1)
        runtimeModel.values["DM_LANG"] = "ja"
        expect(memoryDefaults.string(forKey: "launcher.DM_LANG") == "ja" && String(cString: getenv("DM_LANG")) == "en-US",
               "runtime restart-only edits persist without altering the running language")
        #if DM_HOST_UI
        let runtimeCurve = runtimeModel.settings.first { $0.env == "DM_BOTW_MOVE_CURVE" }!
        runtimeModel.binding(runtimeCurve).wrappedValue = "0.65"
        expect(nativeApplied[runtimeCurve.env] == "0.65" && String(cString: getenv(runtimeCurve.env)) == "0.65" &&
               memoryDefaults.string(forKey: "launcher." + runtimeCurve.env) == "0.65" && runtimeModel.appliesImmediately(runtimeCurve),
               "Mac settings bindings apply live values and save the choice")
        #endif
        for list in [file.settings, mac.settings] {
            let reuse = list.first { $0.env == "DM_NVN_PASS_REUSE" }!
            let snapshots = list.first { $0.env == "DM_NVN_FB_SNAP" }!
            let effective: (String) -> String = { key in getenv(key).map { String(cString: $0) } ?? "1" }
            setenv("DM_ENV_FILE_KEYS", "", 1)
            for reuseValue in ["0", "1"] { for snapshotValue in ["0", "1"] {
                for row in [reuse, snapshots] { d.removeObject(forKey: "launcher." + row.env) }
                let model = LauncherModel(list, defaults: d)
                expect(model.values[reuse.env] == "1" && model.values[snapshots.env] == "1", "memory transfer optimization starts on and snapshot bypass starts off")
                model.setValue(reuseValue, for: reuse); model.setValue(snapshotValue, for: snapshots); model.apply()
                expect(effective(reuse.env) == reuseValue && effective(snapshots.env) == snapshotValue, "all four memory/snapshot combinations reach the game independently")
                let restored = LauncherModel(list, defaults: d)
                unsetenv(reuse.env); unsetenv(snapshots.env); restored.applySaved()
                expect(restored.values[reuse.env] == reuseValue && restored.values[snapshots.env] == snapshotValue &&
                       effective(reuse.env) == reuseValue && effective(snapshots.env) == snapshotValue, "both choices survive reopening and skipping the overlay")
                let changedReuse = reuseValue == "1" ? "0" : "1"
                restored.setValue(changedReuse, for: reuse); restored.apply()
                expect(effective(reuse.env) == changedReuse && effective(snapshots.env) == snapshotValue, "changing memory transfers leaves snapshot bypass alone")
                restored.setValue(snapshotValue == "1" ? "0" : "1", for: snapshots); restored.apply()
                expect(effective(reuse.env) == changedReuse, "changing snapshot bypass leaves memory transfers alone")
                restored.reset(); restored.apply()
                expect(effective(reuse.env) == "1" && effective(snapshots.env) == "1" &&
                       d.string(forKey: "launcher." + reuse.env) == nil && d.string(forKey: "launcher." + snapshots.env) == nil,
                       "Reset restores memory optimization on and snapshot bypass off")
            } }
            setenv("DM_ENV_FILE_KEYS", reuse.env, 1); setenv(reuse.env, "0", 1)
            let locked = LauncherModel(list, defaults: d)
            locked.setValue("1", for: reuse); locked.reset(); locked.apply()
            expect(locked.fixed.contains(reuse.env) && effective(reuse.env) == "0", "memory transfer optimization preserves an explicit env-file override")
            unsetenv(reuse.env)
        }
        // The experiment is an inverted toggle: On sends 0; Off restores automatic snapshots (1).
        for list in [file.settings, mac.settings] {
            d.removeObject(forKey: "launcher.DM_NVN_FB_SNAP")
            setenv("DM_ENV_FILE_KEYS", "", 1); unsetenv("DM_NVN_FB_SNAP")
            let row = list.first { $0.env == "DM_NVN_FB_SNAP" }!
            let model = LauncherModel(list, defaults: d)
            expect(model.values[row.env] == row.offValue, "skipping feedback snapshots starts disabled")
            model.setValue(row.onValue, for: row); model.apply()
            expect(String(cString: getenv(row.env)) == "0" && d.string(forKey: "launcher." + row.env) == "0", "enabling the experiment disables snapshots and saves the choice")
            let restored = LauncherModel(list, defaults: d)
            unsetenv(row.env); restored.applySaved()
            expect(restored.values[row.env] == row.onValue && String(cString: getenv(row.env)) == "0", "the experiment survives reopening and skipping the launcher")
            restored.setValue(row.offValue, for: row); restored.apply()
            expect(String(cString: getenv(row.env)) == "1" && d.string(forKey: "launcher." + row.env) == nil, "turning the experiment off restores automatic snapshots")
            restored.setValue(row.onValue, for: row); restored.apply()
            restored.reset(); restored.apply()
            expect(String(cString: getenv(row.env)) == "1" && d.string(forKey: "launcher." + row.env) == nil, "Reset and Play restore automatic snapshots")
            for value in ["0", "1", "all"] {
                setenv("DM_ENV_FILE_KEYS", row.env, 1); setenv(row.env, value, 1)
                let locked = LauncherModel(list, defaults: d)
                locked.setValue(row.onValue, for: row); locked.reset(); locked.apply()
                expect(locked.fixed.contains(row.env) && locked.values[row.env] == value && String(cString: getenv(row.env)) == value,
                       "the feedback experiment preserves an explicit env-file override: \(value)")
            }
        }
        unsetenv("DM_ENV_FILE_KEYS"); unsetenv("DM_NVN_FB_SNAP")
        print("launcher storage: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
