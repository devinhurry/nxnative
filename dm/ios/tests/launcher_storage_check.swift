// The launcher's storage (LauncherSettings.swift LauncherModel), run by test_launcher_storage.py on macOS: changed choices and explicit automatic-default overrides are
// stored, Reset to tested defaults followed by Play forgets the choices, an env file's values are kept. Arguments: the iOS and the Mac launcher.json of Breath of the Wild (settings.py, GFXAPI=nvn)
import Foundation
import CoreGraphics

@_cdecl("dm_botw_rune_icon_snapshot")
func mockRuneIconSnapshot(_ state: UnsafeMutableRawPointer?) -> Int32 { 0 }

@_cdecl("dm_launcher_grab_game_frame")
func launcherGrabGameFrame(_ callback: @convention(block) (CGImage?) -> Void) { callback(nil) }
#if DM_HOST_UI
private var nativeApplied: [String: String] = [:]
@_cdecl("dm_launcher_settings_pause")
func mockNativeSettingsPause(_ on: Int32) {}
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
        let phoneSuite = "nxnative.phone-default-test." + UUID().uuidString
        let phoneDefaults = UserDefaults(suiteName: phoneSuite)!
        defer { phoneDefaults.removePersistentDomain(forName: phoneSuite) }
        for (gpu, fast) in [(nil, false), ("Apple A19 Pro GPU", false), ("Apple A20 GPU", false),
                            ("Apple A20 Pro GPU", true), ("Apple A21 GPU", true), ("Apple M4 Pro", false)] as [(String?, Bool)] {
            let phone = LauncherModel(file.settings, defaults: phoneDefaults, phoneGPUName: gpu)
            expect(phone.values["DM_FPS_TARGET"] == (fast ? "60" : "30") && phone.values["DM_OPMODE"] == (fast ? "1" : "0"),
                   "phone defaults follow the profile's GPU threshold: \(gpu ?? "not a phone")")
            expect(phone.values["DM_FRAMEGEN"] == "0" && phone.values["DM_RENDER_SCALE"] == "1.0" && !phone.changed,
                   "device defaults do not enable interpolation or change render scale")
        }
        let phone = LauncherModel(file.settings, defaults: phoneDefaults, phoneGPUName: "Apple A20 Pro GPU")
        phone.applySaved()
        expect(String(cString: getenv("DM_FPS_TARGET")) == "60" && String(cString: getenv("DM_OPMODE")) == "1" &&
               phoneDefaults.string(forKey: "launcher.DM_FPS_TARGET") == nil, "skipping the launcher applies device defaults without saving them")
        phone.values["DM_FPS_TARGET"] = "30"; phone.values["DM_OPMODE"] = "0"; phone.apply()
        let savedPhone = LauncherModel(file.settings, defaults: phoneDefaults, phoneGPUName: "Apple A20 Pro GPU")
        expect(savedPhone.values["DM_FPS_TARGET"] == "30" && savedPhone.values["DM_OPMODE"] == "0", "saved manual choices override capable-phone defaults")
        savedPhone.reset(); savedPhone.apply()
        expect(savedPhone.values["DM_FPS_TARGET"] == "60" && savedPhone.values["DM_OPMODE"] == "1" &&
               phoneDefaults.string(forKey: "launcher.DM_FPS_TARGET") == nil, "reset restores device defaults and removes overrides")
        unsetenv("DM_FPS_TARGET"); unsetenv("DM_OPMODE")
        let customFPS = file.settings.first { $0.env == "DM_FPS_TARGET" }!.def == "30" ? "60" : "30"
        let suite = "nxnative.launcher-test." + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set("1", forKey: "launcher.DM_PRESENT_SNAP")   // stored by the old launcher, equal to the default
        d.set(customFPS, forKey: "launcher.DM_FPS_TARGET")    // a changed game setting
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
        expect(m.values["DM_FPS_TARGET"] == customFPS && m.values["DM_PSO_MTL4"] == "0" && m.values["DM_FPS_HOLD"] == "on" && m.values["DM_METAL_HUD"] == "1", "stored choices and the env file are read")
        expect(m.changed, "Reset is offered with changed settings")
        let stick = m.touchStickResponse!
        expect(stick.deadzone == 0.07 && stick.curve == 0.3 && stick.full == 0.71 && stick.size == 123.2, "touch stick starts at its point diameter and current movement defaults")
        expect(stick.strength(at: 0.07) == 0 && abs(stick.strength(at: 0.2) - pow(0.13/0.64,0.3)) < 0.001 && stick.strength(at: 0.71) == 1, "curve preview has the real deadzone, short-drag strength and endpoint")
        let curve = file.settings.first { $0.env == "DM_BOTW_MOVE_CURVE" }!
        let pointSize = file.settings.first { $0.env == "DM_BOTW_PAD_STICK_SIZE_PT" }!
        expect(curve.formattedValue("0.7") == "0.70" && scale.formattedValue("0.5") == "50 %" && pointSize.formattedValue("123.2") == "123.2 pt", "layout dimensions show points while response and render-scale units remain unchanged")
        m.values["DM_BOTW_MOVE_DEADZONE"] = "0.15"; m.values["DM_BOTW_MOVE_CURVE"] = "1.00"
        m.values["DM_BOTW_MOVE_FULL"] = "0.60"; m.values["DM_BOTW_PAD_STICK_SIZE_PT"] = "160.000"
        expect(abs(m.touchStickResponse!.strength(at: 0.375) - 0.5) < 1e-6, "adjusted curve preview responds to movement parameters")
        m.values["DM_BOTW_PAD_A_X_PT"] = "-20.000"; m.values["DM_BOTW_PAD_B_SIZE_PT"] = "72.000"
        m.values["DM_RENDER_SCALE"] = "1.00"
        m.values["DM_BOTW_PAD_BADGES"] = "0"
        let exported = m.touchSettingsExport
        expect(exported.contains("DM_BOTW_PAD_A_X_PT=-20.000") && exported.contains("DM_BOTW_PAD_B_SIZE_PT=72.000") && exported.contains("DM_BOTW_PAD_BADGES=0") && exported.contains("DM_BOTW_MOVE_CURVE=1.000") && !exported.contains("DM_FPS_TARGET") && !exported.contains("PAD_FACE_"), "touch export contains independent button point values without obsolete group settings")
        m.apply()
        expect(d.string(forKey: "launcher.DM_PRESENT_SNAP") == nil, "a value equal to the default is not stored (and an old one is dropped)")
        expect(d.string(forKey: "launcher.DM_RENDER_SCALE") == nil && d.string(forKey: "launcher.DM_OPMODE") == nil && d.string(forKey: "launcher.DM_FPS_HOLD") == nil, "defaults are not stored")
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == customFPS && d.string(forKey: "launcher.DM_PSO_MTL4") == "0", "changed choices are stored")
        expect(d.string(forKey: "launcher.DM_THERMAL_CAP") == "1" && String(cString: getenv("DM_THERMAL_CAP")) == "1", "Play saves and applies the optional thermal cap")
        expect(d.string(forKey: "launcher.DM_METAL_HUD") == nil && String(cString: getenv("DM_METAL_HUD")) == "1", "the env file's value is kept and not stored")
        expect(String(cString: getenv("DM_PSO_MTL4")) == "0" && String(cString: getenv("DM_PRESENT_SNAP")) == "1" && String(cString: getenv("DM_FPS_HOLD")) == "on", "the environment gets every value")
        let reopened = LauncherModel(file.settings, defaults: d)
        expect(reopened.values["DM_THERMAL_CAP"] == "1", "reopening restores an enabled thermal cap")
        expect(reopened.values["DM_BOTW_MOVE_DEADZONE"] == "0.15" && reopened.values["DM_BOTW_PAD_STICK_SIZE_PT"] == "160.000" && String(cString: getenv("DM_BOTW_MOVE_CURVE")) == "1.00", "Play persists and restores movement settings and point diameter")
        expect(reopened.values["DM_BOTW_PAD_A_X_PT"] == "-20.000" && reopened.values["DM_BOTW_PAD_B_SIZE_PT"] == "72.000", "independent face positions and sizes persist")
        expect(!file.settings.contains { $0.env.hasPrefix("DM_BOTW_PAD_PLUS") || $0.env.hasPrefix("DM_BOTW_PAD_MINUS") }, "plus and minus remain fixed")
        reopened.reset(keys: TouchStickResponse.keys)
        expect(!reopened.touchStickChanged && reopened.values["DM_BOTW_MOVE_DEADZONE"] == "0.070" && reopened.values["DM_BOTW_PAD_STICK_SIZE_PT"] == "123.200", "left-stick reset restores its response and point diameter")
        expect(reopened.values["DM_FPS_TARGET"] == customFPS && d.string(forKey: "launcher.DM_PSO_MTL4") == "0", "left-stick reset preserves unrelated game and performance choices")
        reopened.values["DM_BOTW_PAD_R_Y_PT"] = "40.000"
        reopened.reset(keys: BotwTouchControl.all[0].keys)
        expect(reopened.values["DM_BOTW_PAD_A_X_PT"] == "0.000" && reopened.values["DM_BOTW_PAD_B_SIZE_PT"] == "72.000" && reopened.values["DM_BOTW_PAD_R_Y_PT"] == "40.000", "restoring A leaves B and R unchanged")
        reopened.reset(keys: reopened.touchSettingsKeys)
        expect(reopened.values["DM_BOTW_PAD_R_Y_PT"] == "0.000" && reopened.values["DM_FPS_TARGET"] == customFPS, "restore all touch defaults leaves frame rate alone")
        let portraitSuite = suite + ".portrait"
        let portraitDefaults = UserDefaults(suiteName: portraitSuite)!
        defer { portraitDefaults.removePersistentDomain(forName: portraitSuite) }
        let portraitModel = LauncherModel(file.settings, defaults: portraitDefaults)
        expect(portraitModel.values["DM_BOTW_PORTRAIT"] == "0", "compact portrait rotation defaults off")
        portraitModel.values["DM_BOTW_PAD_A_X_PT"] = "12.000"
        portraitModel.values["DM_BOTW_PORTRAIT_PAD_A_X_PT"] = "-20.000"
        portraitModel.values["DM_BOTW_PORTRAIT_PAD_B_Y_PT"] = "10.000"
        portraitModel.values["DM_BOTW_PORTRAIT_PAD_X_SIZE_PT"] = "65.000"
        portraitModel.values["DM_BOTW_PORTRAIT_PAD_Y_X_PT"] = "5.000"
        portraitModel.values["DM_BOTW_PORTRAIT_MOVE_CURVE"] = "0.750"
        portraitModel.values["DM_BOTW_PORTRAIT"] = "1"; portraitModel.apply()
        let portraitRestored = LauncherModel(file.settings, defaults: portraitDefaults)
        expect(portraitRestored.values["DM_BOTW_PAD_A_X_PT"] == "12.000" && portraitRestored.values["DM_BOTW_PORTRAIT_PAD_A_X_PT"] == "-20.000" && portraitRestored.values["DM_BOTW_PORTRAIT_PAD_B_Y_PT"] == "10.000" && portraitRestored.touchStickResponse(portrait: true)?.curve == 0.75 && portraitRestored.touchStickResponse?.curve == 0.3, "normal and compact adjustments persist independently")
        let portraitExport = portraitRestored.touchSettingsExport(portrait: true)
        expect(portraitExport.contains("DM_BOTW_PORTRAIT_PAD_X_SIZE_PT=65.000") && portraitExport.contains("DM_BOTW_PORTRAIT_PAD_Y_X_PT=5.000") && !portraitExport.contains("DM_BOTW_PAD_A_X_PT="), "compact export uses independent point dimensions")
        portraitRestored.reset(keys: BotwTouchControl.compact[0].keys(portrait: true))
        expect(portraitRestored.values["DM_BOTW_PORTRAIT_PAD_A_X_PT"] == "0.000" && portraitRestored.values["DM_BOTW_PORTRAIT_PAD_B_Y_PT"] == "10.000", "restoring compact A preserves other buttons")
        portraitRestored.reset(keys: portraitRestored.touchSettingsKeys(portrait: true))
        expect(portraitRestored.values["DM_BOTW_PORTRAIT_PAD_X_SIZE_PT"] == "53.900" && portraitRestored.values["DM_BOTW_PAD_A_X_PT"] == "12.000" && portraitRestored.values["DM_BOTW_PORTRAIT"] == "1", "compact restore preserves normal settings and rotation permission")
        let editorSuite = suite + ".editor"
        let editorDefaults = UserDefaults(suiteName: editorSuite)!
        defer { editorDefaults.removePersistentDomain(forName: editorSuite) }
        editorDefaults.set("-0.100", forKey: "launcher.DM_BOTW_PAD_FACE_X")
        editorDefaults.set("0.100", forKey: "launcher.DM_BOTW_PORTRAIT_PAD_B_Y")
        let editor = LauncherModel(file.settings, defaults: editorDefaults)
        editor.values["DM_FPS_TARGET"] = "30"
        var draft = editor.values
        draft["DM_BOTW_PAD_A_X_PT"] = "15.300"
        draft["DM_BOTW_PAD_WEAPON_ENABLED"] = "1"
        draft["DM_BOTW_PAD_WEAPON_MODE"] = "2"
        draft["DM_BOTW_PAD_L_ICON_MODE"] = "1"
        draft["DM_BOTW_PAD_DPAD_VISIBLE"] = "0"
        draft["DM_BOTW_PORTRAIT_PAD_B_Y_PT"] = "100.000"
        expect(editor.values["DM_BOTW_PAD_A_X_PT"] != "15.300" && editorDefaults.string(forKey: "launcher.DM_BOTW_PAD_A_X_PT") == nil,
               "an editor draft can be discarded without changing the launcher or saved choices")
        expect(editor.touchSettingsExport(portrait: false, values: draft).contains("DM_BOTW_PAD_A_X_PT=15.300") && !editor.touchSettingsExport(portrait: false).contains("DM_BOTW_PAD_A_X_PT=15.300"),
               "copying editor parameters exports the draft rather than the applied layout")
        expect(editor.saveTouchSettings(draft, portrait: false), "Save accepts a complete valid layout draft")
        let savedEditor = LauncherModel(file.settings, defaults: editorDefaults)
        expect(savedEditor.touchLayout(portrait: false).rune_icon_mode == 1 && savedEditor.touchLayout(portrait: true).rune_icon_mode == 0 &&
               BotwTouchControl.all.first { $0.id == 6 }!.keys.contains("DM_BOTW_PAD_L_ICON_MODE"),
               "L icon choice saves independently per bank and defaults to the current rune")
        expect(savedEditor.touchSettingsExport.contains("DM_BOTW_PAD_L_ICON_MODE=1"), "layout export includes L icon display choice")
        expect(savedEditor.values["DM_BOTW_PAD_WEAPON_ENABLED"] == "1" && savedEditor.values["DM_BOTW_PAD_WEAPON_MODE"] == "2" &&
               savedEditor.values["DM_BOTW_PAD_DPAD_VISIBLE"] == "0" && savedEditor.values["DM_BOTW_PORTRAIT_PAD_WEAPON_ENABLED"] == "0",
               "added buttons, switch modes and D-pad visibility save only in the edited bank")
        expect(savedEditor.values["DM_BOTW_PAD_A_X_PT"] == "15.300" && editorDefaults.string(forKey: "launcher.DM_FPS_TARGET") == nil,
               "Save persists point offsets before Play without saving unrelated game choices")
        expect(savedEditor.values["DM_BOTW_PORTRAIT_PAD_B_Y_PT"] == "84.400" && editorDefaults.integer(forKey: "launcher.botwPointLayoutVersion") == 1,
               "saving one layout finishes the other bank's legacy migration without saving its uncommitted draft")
        draft["DM_BOTW_PAD_A_X_PT"] = "80.000"; draft["DM_BOTW_PAD_A_SIZE_PT"] = "nan"
        expect(!editor.saveTouchSettings(draft, portrait: false) && editor.values["DM_BOTW_PAD_A_X_PT"] == "15.300" && editorDefaults.string(forKey: "launcher.DM_BOTW_PAD_A_X_PT") == "15.300",
               "an invalid draft is rejected without partially applying or saving it")
        draft = editor.values
        for row in file.settings where editor.touchSettingsKeys(portrait: false).contains(row.env) { draft[row.env] = row.def }
        expect(editor.saveTouchSettings(draft, portrait: false) && LauncherModel(file.settings, defaults: editorDefaults).values["DM_BOTW_PAD_A_X_PT"] == "0.000",
               "Save after layout reset does not resurrect the legacy offsets")
        let legacySuite = suite + ".legacy"
        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        legacyDefaults.set("-0.100", forKey: "launcher.DM_BOTW_PAD_FACE_X")
        legacyDefaults.set("1.200", forKey: "launcher.DM_BOTW_PAD_FACE_GAP")
        legacyDefaults.set("0.100", forKey: "launcher.DM_BOTW_PORTRAIT_PAD_B_Y")
        let pointMigrated = LauncherModel(file.settings, defaults: legacyDefaults)
        expect(abs((Double(pointMigrated.values["DM_BOTW_PAD_A_X_PT"]!) ?? 0) + 64.158) < 0.001 && abs((Double(pointMigrated.values["DM_BOTW_PAD_B_X_PT"]!) ?? 0) + 71.858) < 0.001 && pointMigrated.values["DM_BOTW_PORTRAIT_PAD_B_Y_PT"] == "84.400", "old group offsets, spacing and compact fractions migrate to reference-phone point values")
        pointMigrated.apply()
        pointMigrated.reset(keys: pointMigrated.touchSettingsKeys); pointMigrated.apply()
        expect(LauncherModel(file.settings, defaults: legacyDefaults).values["DM_BOTW_PAD_A_X_PT"] == "0.000", "reset point defaults do not resurrect old fraction settings")
        legacyDefaults.set("25.000", forKey: "launcher.DM_BOTW_PAD_A_X_PT")
        expect(LauncherModel(file.settings, defaults: legacyDefaults).values["DM_BOTW_PAD_A_X_PT"] == "25.000", "explicit point choices take precedence over legacy migration")
        d.set("nan", forKey: "launcher.DM_BOTW_MOVE_CURVE"); d.set("241", forKey: "launcher.DM_BOTW_PAD_STICK_SIZE_PT")
        expect(LauncherModel(file.settings, defaults: d).touchStickResponse!.curve == 0.3 && LauncherModel(file.settings, defaults: d).touchStickResponse!.size == 123.2, "invalid saved response and point dimensions load defaults")
        setenv("DM_ENV_FILE_KEYS", "DM_BOTW_MOVE_DEADZONE", 1); setenv("DM_BOTW_MOVE_DEADZONE", "0.12", 1)
        let locked = LauncherModel(file.settings, defaults: d)
        locked.reset(keys: TouchStickResponse.keys); locked.apply()
        expect(locked.values["DM_BOTW_MOVE_DEADZONE"] == "0.12" && String(cString: getenv("DM_BOTW_MOVE_DEADZONE")) == "0.12", "left-stick reset and Play preserve an env-file override")
        setenv("DM_ENV_FILE_KEYS", "DM_METAL_HUD", 1)
        m.reset()
        expect(m.values["DM_PSO_MTL4"] == "1" && m.values["DM_FPS_TARGET"] == file.settings.first { $0.env == "DM_FPS_TARGET" }!.def, "Reset shows the defaults")
        expect(d.string(forKey: "launcher.DM_PSO_MTL4") == "0" && d.string(forKey: "launcher.DM_FPS_TARGET") == customFPS, "Reset alone forgets nothing: Quit after it keeps the choices")
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
        expect(String(cString: getenv("DM_FPS_TARGET")) == fps.def, "DM_SAVED_CHOICES=0: skipping the screen applies the device default")
        plain.apply()
        expect(String(cString: getenv("DM_FPS_TARGET")) == fps.def && d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "DM_SAVED_CHOICES=0: Play uses the screen's values and leaves the saved choices")
        plain.reset()
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "DM_SAVED_CHOICES=0: Reset leaves the saved choices too")
        unsetenv("DM_SAVED_CHOICES")
        // The Mac window's list (second argument): Basic first, then Advanced in the list's sections; Display mode; the render scale in pixels; values set at launch are fixed
        let mac = try! JSONDecoder().decode(SettingsFile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        setenv("DM_ENV_FILE_KEYS", "", 1); unsetenv("DM_FULLSCREEN"); unsetenv("DM_OPMODE")
        let mm = LauncherModel(mac.settings, defaults: d)
        expect(mm.sections(basic: true) == ["Game", "General", "Controls"] && mm.sections(basic: false) == ["Game", "Controls", "Touch left stick", "Touch layout", "Performance"], "Basic and Advanced keep the list's sections")
        expect(mm.rows(in: "Game", basic: true).map(\.env) == ["DM_FPS_TARGET", "DM_FRAMEGEN", "DM_RENDER_SCALE", "DM_OPMODE", "DM_FULLSCREEN"] && mm.rows(in: "General", basic: true).map(\.env) == ["DM_LANG"], "language is separated from graphics in General")
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
        runtimeModel.setValue("ja", for: runtimeModel.settings.first { $0.env == "DM_LANG" }!)
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
        failed += checkGameLanguageDefaults()
        failed += checkTouchLayoutPresets(file.settings)
        print("launcher storage: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

private func checkGameLanguageDefaults() -> Int {
    var failed = 0
    func expect(_ condition: Bool, _ what: String) { print((condition ? "PASS " : "FAIL ") + what); if !condition { failed += 1 } }
    let keys = ["DM_LANG", "DM_ENV_FILE_KEYS", "DM_ENV_LAUNCH_KEYS", "DM_SAVED_CHOICES"]
    let previous = ProcessInfo.processInfo.environment
    defer { for key in keys { if let value = previous[key] { setenv(key, value, 1) } else { unsetenv(key) } } }
    for key in keys { unsetenv(key) }
    let suite = "nxnative.language-test." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let language = try! JSONDecoder().decode(Setting.self, from: Data(#"{"env":"DM_LANG","kind":"choice","label":"Game language","note":"","default":"en-US","options":[["en-US","English"],["ja","Japanese"],["zh-Hans","Simplified Chinese"],["zh-Hant","Traditional Chinese"]]}"#.utf8))
    func model(_ preferences: [String], row: Setting? = nil) -> LauncherModel {
        LauncherModel([row ?? language], defaults: defaults, preferredLanguages: preferences)
    }
    for (preferences, expected) in [(["zh-Hans-CN"], "zh-Hans"), (["zh-TW"], "zh-Hant"), (["en-GB"], "en-US"),
                                    (["de-DE", "ja-JP"], "ja"), (["de-DE"], "en-US"), ([], "en-US")] {
        let automatic = model(preferences)
        expect(automatic.values["DM_LANG"] == expected && !automatic.changed, "game language matches device preferences: \(preferences)")
        automatic.apply()
        expect(defaults.string(forKey: "launcher.DM_LANG") == nil, "starting a game never saves the automatic language")
    }
    var fallback = language
    fallback.def = "ja"
    expect(model(["de-DE"], row: fallback).values["DM_LANG"] == "ja", "an unsupported device language falls back to the packed language")
    expect(model(["ja-JP"]).values["DM_LANG"] == "ja" && model(["zh-Hans-CN"]).values["DM_LANG"] == "zh-Hans",
           "automatic language follows changed preferences on the next launch")
    for chosen in ["en-US", "zh-Hans"] {
        defaults.removeObject(forKey: "launcher.DM_LANG")
        let manual = model([chosen])
        manual.binding(manual.settings[0]).wrappedValue = chosen
        expect(manual.changed && defaults.string(forKey: "launcher.DM_LANG") == chosen,
               "explicitly choosing the automatic language is remembered, including the packed default: \(chosen)")
        manual.apply()
        let reopened = model(["ja-JP"])
        setenv("DM_LANG", "en-US", 1)
        reopened.applySaved()
        expect(reopened.values["DM_LANG"] == chosen && String(cString: getenv("DM_LANG")) == chosen,
               "manual language survives changed system preferences and a skipped startup screen")
    }
    let reset = model(["ja-JP"])
    reset.reset(keys: ["DM_RENDER_SCALE"])
    expect(reset.values["DM_LANG"] == "zh-Hans", "an unrelated reset preserves the manual language")
    reset.reset(); reset.apply()
    expect(reset.values["DM_LANG"] == "ja" && !reset.changed && defaults.string(forKey: "launcher.DM_LANG") == nil &&
           model(["zh-TW"]).values["DM_LANG"] == "zh-Hant", "Reset restores automatic language selection for future launches")
    defaults.set("de-DE", forKey: "launcher.DM_LANG")
    let unsupported = model(["zh-TW"])
    expect(unsupported.values["DM_LANG"] == "zh-Hant", "a saved language the game no longer supports falls back to the device")
    unsupported.apply()
    expect(defaults.string(forKey: "launcher.DM_LANG") == nil, "an unsupported old language is not converted into a manual override")
    for marker in ["DM_ENV_FILE_KEYS", "DM_ENV_LAUNCH_KEYS"] {
        defaults.set("en-US", forKey: "launcher.DM_LANG")
        setenv(marker, "DM_LANG", 1); setenv("DM_LANG", "ja", 1)
        let locked = model(["zh-Hans-CN"])
        locked.setValue("zh-Hant", for: locked.settings[0]); locked.reset(); locked.apply(); locked.applySaved()
        expect(locked.values["DM_LANG"] == "ja" && String(cString: getenv("DM_LANG")) == "ja" &&
               defaults.string(forKey: "launcher.DM_LANG") == "en-US", "a temporary language override preserves the saved manual choice: \(marker)")
        unsetenv(marker)
    }
    setenv("DM_SAVED_CHOICES", "0", 1)
    let ignored = model(["zh-TW"])
    expect(ignored.values["DM_LANG"] == "zh-Hant", "ignoring saved choices resumes following device language")
    ignored.setValue("ja", for: ignored.settings[0]); ignored.apply()
    expect(defaults.string(forKey: "launcher.DM_LANG") == "en-US", "DM_SAVED_CHOICES=0 leaves the saved language untouched")
    unsetenv("DM_SAVED_CHOICES")
    defaults.removeObject(forKey: "launcher.DM_LANG")
    let runtime = model(["zh-TW"])
    runtime.applySaved()
    expect(String(cString: getenv("DM_LANG")) == "zh-Hant" && defaults.string(forKey: "launcher.DM_LANG") == nil,
           "skipping the startup screen applies automatic language without saving it")
    runtime.beginRuntime()
    runtime.setValue("zh-Hant", for: runtime.settings[0])
    expect(defaults.string(forKey: "launcher.DM_LANG") == "zh-Hant", "a runtime manual choice is saved even when equal to automatic")
    runtime.setValue("ja", for: runtime.settings[0])
    expect(defaults.string(forKey: "launcher.DM_LANG") == "ja" && String(cString: getenv("DM_LANG")) == "zh-Hant",
           "changing language while playing takes effect at the next game start")
    runtime.reset()
    expect(defaults.string(forKey: "launcher.DM_LANG") == nil && String(cString: getenv("DM_LANG")) == "zh-Hant",
           "runtime Reset removes the manual language without changing the running game")
    return failed
}

import DmTouchPad

private func checkTouchLayoutPresets(_ settings: [Setting]) -> Int {
    var failed = 0
    func expect(_ condition: Bool, _ message: String) {
        print((condition ? "PASS " : "FAIL ") + message)
        if !condition { failed += 1 }
    }
    let suite = "nxnative.touch-presets-test." + UUID().uuidString
    let sourceDefaults = UserDefaults(suiteName: suite + ".source")!
    let targetDefaults = UserDefaults(suiteName: suite + ".target")!
    let fallbackDefaults = UserDefaults(suiteName: suite + ".fallback")!
    let fixedDefaults = UserDefaults(suiteName: suite + ".fixed")!
    let exportAreaDefaults = UserDefaults(suiteName: suite + ".export-area")!
    let manySourceDefaults = UserDefaults(suiteName: suite + ".many-source")!
    let manyTargetDefaults = UserDefaults(suiteName: suite + ".many-target")!
    let shieldDefaults = UserDefaults(suiteName: suite + ".shield-range")!
    defer {
        for suffix in [".source", ".target", ".fallback", ".fixed", ".export-area", ".many-source", ".many-target", ".shield-range"] {
            UserDefaults(suiteName: suite + suffix)?.removePersistentDomain(forName: suite + suffix)
        }
    }
    shieldDefaults.set("100.000", forKey: "launcher.DM_BOTW_PAD_ZL_SIZE_PT")
    let shieldModel = LauncherModel(settings, defaults: shieldDefaults)
    expect(shieldModel.touchLayout(portrait: false).shield_hit_size == 140,
           "an older layout retains its former shield touch diameter")
    var shieldDraft = shieldModel.values
    shieldDraft["DM_BOTW_PAD_ZL_SIZE_PT"] = "180.000"
    expect(shieldModel.saveTouchSettings(shieldDraft, portrait: false) &&
           LauncherModel(settings, defaults: shieldDefaults).touchLayout(portrait: false).shield_hit_size == 140,
           "the migrated touch diameter is saved once and stays independent after resizing and reopening")
    shieldDraft["DM_BOTW_PAD_ZL_HIT_PT"] = "215.600"
    expect(shieldModel.saveTouchSettings(shieldDraft, portrait: false) &&
           abs(LauncherModel(settings, defaults: shieldDefaults).touchLayout(portrait: false).shield_hit_size - 215.6) < 0.001,
           "a touch diameter equal to its default also stays fixed after artwork resizing and reopening")
    let source = LauncherModel(settings, defaults: sourceDefaults)
    expect(source.touchLayouts.count == 1 && source.selectedTouchLayoutID == source.touchLayouts.first?.id,
           "an empty preset library starts with one selected default layout")
    expect(BotwTouchControl.cancel.removable, "Cancel can be removed and offered again in Add button")
    for portrait in [false, true] {
        let cancel = BotwTouchControl.cancel.visibilityKey(portrait: portrait)
        for (key, mode) in [("L_MODE", "2"), ("WEAPON_MODE", "2"), ("SHIELD_MODE", "2"),
                            ("R_DRAG_MODE", "1"), ("ZR_DRAG_MODE", "1")] {
            var changed = source.values
            changed[cancel] = "0"
            let setting = botwTouchKey("DM_BOTW_PAD_" + key, portrait: portrait)
            source.setTouchValue(mode, for: setting, in: &changed)
            expect(changed[cancel] == "1", "enabling \(setting) adds Cancel to the same layout bank")
            changed[cancel] = "0"
            source.setTouchValue(mode, for: setting, in: &changed)
            expect(changed[cancel] == "0", "an unchanged action does not undo manual Cancel removal")
        }
        var added = source.values
        added[cancel] = "0"
        added[BotwTouchControl.added[0].option("MODE", portrait: portrait)] = "2"
        source.setTouchValue("1", for: BotwTouchControl.added[0].visibilityKey(portrait: portrait), in: &added)
        expect(added[cancel] == "1", "adding a sticky equipment shortcut restores Cancel")
    }
    var draft = source.values
    draft["DM_BOTW_PAD_CANCEL_ENABLED"] = "0"
    draft["DM_BOTW_PAD_L_ANCHOR"] = "2"; draft["DM_BOTW_PAD_L_X_PT"] = "20.000"
    draft["DM_BOTW_PAD_L_Y_PT"] = "100.000"; draft["DM_BOTW_PAD_L_SIZE_PT"] = "60.000"
    draft["DM_BOTW_PAD_FILL_GRAY"] = "0.630"; draft["DM_BOTW_PAD_FILL_ALPHA"] = "0.470"
    draft["DM_BOTW_PAD_STROKE_GRAY"] = "0.740"; draft["DM_BOTW_PAD_STROKE_ALPHA"] = "0.580"
    draft["DM_BOTW_PAD_ICON_ALPHA"] = "0.810"
    draft["DM_BOTW_PAD_ZL_HIT_PT"] = "80.000"
    expect(source.saveTouchSettings(draft, portrait: false), "a default left control can save a right-edge anchor")
    expect(LauncherModel(settings, defaults: sourceDefaults).touchLayout(portrait: false).cancel_enabled == 0,
           "saving and reopening preserves manual Cancel removal")
    source.rememberTouchArea(.init(width: 900, height: 430), portrait: false)
    source.addTouchLayout(name: "Right hand", copyCurrent: true)
    let rightID = source.selectedTouchLayoutID
    expect(source.touchLayouts.count == 2 && source.touchLayouts.last?.normalArea.width == 900 &&
           source.values["DM_BOTW_PAD_L_ANCHOR"] == "2", "copying a preset retains its anchors and source pane")
    source.addTouchLayout(name: "Fresh", copyCurrent: false)
    expect(source.touchLayouts.count == 3 && source.values["DM_BOTW_PAD_L_ANCHOR"] == "0" &&
           source.values["DM_BOTW_PAD_L_SIZE_PT"] == "57.600", "a fresh preset uses defaults rather than the previous preset")
    source.selectTouchLayout(rightID)
    let target = LauncherModel(settings, defaults: targetDefaults)
    target.addTouchLayout(name: "Right hand", copyCurrent: false)
    let previousID = target.selectedTouchLayoutID
    var previousDraft = target.values; previousDraft["DM_BOTW_PAD_A_X_PT"] = "7.000"
    expect(target.saveTouchSettings(previousDraft, portrait: false), "the pre-import selected preset has an independent edit")
    let previousLayouts = target.touchLayouts
    let normal = BotwTouchArea(width: 430, height: 300), compact = BotwTouchArea(width: 320, height: 400)
    let encoder = JSONEncoder()
    do {
        let unopened = LauncherModel(settings, defaults: exportAreaDefaults)
        unopened.addTouchLayout(name: "Unopened", copyCurrent: false)
        let beforeAreaExport = exportAreaDefaults.data(forKey: "launcher.botwTouchLayouts")
        let beforeAreaLayouts = unopened.touchLayouts, beforeAreaSelection = unopened.selectedTouchLayoutID
        let actualAreaExport = try unopened.exportTouchLayouts(all: true, normalArea: normal, compactArea: compact)
        let actualAreaFile = try JSONDecoder().decode(BotwTouchLayoutsFile.self, from: actualAreaExport)
        expect(actualAreaFile.layouts.count == 2 && actualAreaFile.layouts.allSatisfy {
            $0.normal?.controls["L"]?.anchor == .left && $0.normal?.controls["L"]?.side == 164.56 &&
            $0.compact?.controls["WHISTLE"]?.anchor == .right && $0.compact?.controls["WHISTLE"]?.side == 72
        }, "all exported presets use the supplied source panes even before opening the editor, including normal L at 164.56pt on a 430pt pane")
        expect(exportAreaDefaults.data(forKey: "launcher.botwTouchLayouts") == beforeAreaExport &&
               unopened.selectedTouchLayoutID == beforeAreaSelection && beforeAreaLayouts.allSatisfy { before in
                   unopened.touchLayouts.contains { $0.id == before.id && $0.values == before.values &&
                       $0.normalArea == before.normalArea && $0.compactArea == before.compactArea }
               }, "exporting with actual source areas leaves saved layouts, stored areas and selection unchanged")
        let one = try source.exportTouchLayouts(all: false), all = try source.exportTouchLayouts(all: true)
        let oneFile = try JSONDecoder().decode(BotwTouchLayoutsFile.self, from: one)
        let allFile = try JSONDecoder().decode(BotwTouchLayoutsFile.self, from: all)
        expect(oneFile.schemaVersion == 1 && oneFile.game == "01007EF00011E000" &&
               oneFile.layouts.count == 1 && oneFile.layouts[0].name == "Right hand" && allFile.layouts.count == 3,
               "JSON export includes its schema and game and supports one or all presets")
        let originalL = oneFile.layouts[0].normal?.controls["L"]
        expect(oneFile.layouts[0].normal?.options["DM_BOTW_PAD_ZL_HIT_PT"] == "80.000",
               "portable JSON records the independent shield touch diameter")
        expect(oneFile.layouts[0].normal?.options["DM_BOTW_PAD_ICON_ALPHA"] == "0.810" &&
               oneFile.layouts[0].normal?.options["DM_BOTW_PAD_FILL_GRAY"] == "0.630",
               "portable JSON includes the current layout's global appearance")
        expect(originalL?.anchor == .right && originalL?.side == 20 && originalL?.size == 60,
               "export records L's chosen right anchor and actual point distances")
        expect(try target.importTouchLayouts(one, normalArea: normal, compactArea: compact) == 1,
               "a single-layout JSON imports successfully")
        expect(target.touchLayouts.count == 3 && target.selectedTouchLayoutID == previousID &&
               target.values["DM_BOTW_PAD_A_X_PT"] == "7.000" && previousLayouts.allSatisfy { old in
                   target.touchLayouts.contains { $0.id == old.id && $0.name == old.name && $0.values == old.values }
               }, "import adds a layout while preserving previous presets, edits and selection")
        let imported = target.touchLayouts.last!
        expect(imported.name == "Right hand (2)" && !previousLayouts.contains { $0.id == imported.id },
               "a colliding imported name is renamed and receives an independent ID")
        target.selectTouchLayout(imported.id)
        var sourceConfig = source.touchLayout(portrait: false), targetConfig = target.touchLayout(portrait: false)
        expect(targetConfig.cancel_enabled == 0 && target.touchLayout(portrait: true).cancel_enabled == 1,
               "layout import preserves Cancel removal independently in each bank")
        expect(targetConfig.shield_hit_size == 80 && abs(target.touchLayout(portrait: true).shield_hit_size - 195.58) < 0.001,
               "shield touch diameter survives save, duplicate, export and import independently per bank")
        var resizedShield = target.values
        resizedShield["DM_BOTW_PAD_ZL_SIZE_PT"] = "100.000"
        expect(target.touchLayout(portrait: false, values: resizedShield).shield_hit_size == 80,
               "resizing shield artwork does not change its saved touch diameter")
        expect(abs(targetConfig.fill_gray - 0.63) < 0.0001 && abs(targetConfig.fill_alpha - 0.47) < 0.0001 &&
               abs(targetConfig.stroke_gray - 0.74) < 0.0001 && abs(targetConfig.stroke_alpha - 0.58) < 0.0001 &&
               abs(targetConfig.icon_alpha - 0.81) < 0.0001 && abs(target.touchLayout(portrait: true).icon_alpha - 0.9) < 0.0001,
               "global appearance survives save, duplicate, export and import without changing the other bank")
        let sourceRect = dm_botw_layout_control(&sourceConfig, 6, 900, 430, 0, 0, 0, 0, dm_botw_layout_canvas(900, 430))
        let targetRect = dm_botw_layout_control(&targetConfig, 6, 430, 300, 0, 0, 0, 0, dm_botw_layout_canvas(430, 300))
        expect(sourceRect.x + sourceRect.width / 2 == 850 && targetRect.x + targetRect.width / 2 == 380 &&
               targetRect.width == 60 && 300 - targetRect.y - targetRect.height == 100,
               "L moves from center 850pt on a 900pt pane to 380pt on a 430pt pane with unchanged size and bottom margin")
        let selectionBeforeAll = target.selectedTouchLayoutID, idsBeforeAll = Set(target.touchLayouts.map(\.id))
        expect(try target.importTouchLayouts(all, normalArea: normal, compactArea: compact) == 3,
               "a multi-layout JSON imports all of its presets")
        expect(target.touchLayouts.count == 6 && target.selectedTouchLayoutID == selectionBeforeAll &&
               idsBeforeAll.isSubset(of: Set(target.touchLayouts.map(\.id))) &&
               Set(target.touchLayouts.map(\.name)).count == target.touchLayouts.count,
               "multi-layout import remains additive and resolves all existing name collisions")

        func rejectedAtomically(_ data: Data, _ message: String) throws {
            let before = try target.exportTouchLayouts(all: true), selection = target.selectedTouchLayoutID
            let savedBefore = targetDefaults.data(forKey: "launcher.botwTouchLayouts"), valuesBefore = target.values
            var rejected = false
            do { try target.importTouchLayouts(data, normalArea: normal, compactArea: compact) }
            catch { rejected = true }
            let after = try target.exportTouchLayouts(all: true)
            expect(rejected && before == after && target.selectedTouchLayoutID == selection && target.values == valuesBefore &&
                   targetDefaults.data(forKey: "launcher.botwTouchLayouts") == savedBefore, message)
        }
        try rejectedAtomically(Data("{malformed".utf8), "malformed JSON leaves the entire library and saved data unchanged")
        var future = oneFile; future.schemaVersion = 99
        try rejectedAtomically(encoder.encode(future), "an unsupported schema is rejected without modifying presets")
        var invalid = oneFile.layouts[0]
        invalid.normal!.options["DM_BOTW_PAD_L_MODE"] = "9"
        var invalidBatch = oneFile; invalidBatch.layouts.append(invalid)
        try rejectedAtomically(encoder.encode(invalidBatch), "a bad mode after a valid layout rejects the whole import atomically")
        var oldFile = oneFile
        oldFile.layouts[0].normal!.options.removeValue(forKey: "DM_BOTW_PAD_ZL_HIT_PT")
        oldFile.layouts[0].normal!.controls["ZL"]!.size = 100
        let oldCount = try shieldModel.importTouchLayouts(encoder.encode(oldFile), normalArea: normal, compactArea: compact)
        shieldModel.selectTouchLayout(shieldModel.touchLayouts.last!.id)
        expect(oldCount == 1 && shieldModel.touchLayout(portrait: false).shield_hit_size == 140,
               "older JSON without a touch diameter derives it from its imported shield size")

        let tinyFile = BotwTouchLayoutsFile(layouts: [.init(name: "Tiny compact", normal: nil, compact: .init(controls: [
            "L": .init(anchor: .right, side: 999, bottom: 999, size: 60),
            "A": .init(anchor: .left, side: -10, bottom: -20, size: 50)
        ], options: [:]))])
        try target.importTouchLayouts(encoder.encode(tinyFile), normalArea: normal, compactArea: .init(width: 80, height: 90))
        target.selectTouchLayout(target.touchLayouts.last!.id)
        let tiny = try JSONDecoder().decode(BotwTouchLayoutsFile.self, from: target.exportTouchLayouts(all: false)).layouts[0]
        var missingBank = target.touchLayout(portrait: false), defaultsBank = dm_botw_layout_defaults_for(0)
        let missingL = dm_botw_layout_control(&missingBank, 6, 430, 300, 0, 0, 0, 0, dm_botw_layout_canvas(430, 300))
        let defaultL = dm_botw_layout_control(&defaultsBank, 6, 430, 300, 0, 0, 0, 0, dm_botw_layout_canvas(430, 300))
        let missingBankFitted = BotwTouchControl.editable.allSatisfy { control in
            if dm_botw_layout_control_visible(&missingBank, Int32(control.id)) == 0 { return true }
            let r = dm_botw_layout_control(&missingBank, Int32(control.id), 430, 300, 0, 0, 0, 0, dm_botw_layout_canvas(430, 300))
            return r.x >= -0.001 && r.y >= -0.001 && r.x + r.width <= 430.001 && r.y + r.height <= 300.001
        }
        expect(tiny.compact?.controls["L"]?.side == 20 && tiny.compact?.controls["L"]?.bottom == 30 &&
               tiny.compact?.controls["L"]?.size == 60 && tiny.compact?.controls["A"]?.side == 0 &&
               tiny.compact?.controls["A"]?.bottom == 0 && tiny.compact?.controls["A"]?.size == 50 &&
               abs(missingL.x - defaultL.x) < 0.001 && abs(missingL.y - defaultL.y) < 0.001 && missingBankFitted,
               "a compact-only import fits tiny-pane margins without resizing and supplies a fitted default normal bank")

        let oversized = BotwTouchLayoutsFile(layouts: [.init(name: "Oversized", normal: .init(controls: [
            "L": .init(anchor: .right, side: 999, bottom: 999, size: 240)
        ], options: [:]), compact: nil)])
        try target.importTouchLayouts(encoder.encode(oversized), normalArea: .init(width: 80, height: 90), compactArea: compact)
        target.selectTouchLayout(target.touchLayouts.last!.id)
        var fittedConfig = target.touchLayout(portrait: false)
        let fitted = dm_botw_layout_control(&fittedConfig, 6, 80, 90, 0, 0, 0, 0, dm_botw_layout_canvas(80, 90))
        expect(fitted.x == 0 && fitted.y == 0 && fitted.width == 80 && fitted.height == 80,
               "import reduces a button only when its original size cannot fit the target pane")

        let longName = String(repeating: "N", count: 80)
        target.addTouchLayout(name: longName, copyCurrent: false)
        var longFile = oneFile; longFile.layouts[0].name = longName
        try target.importTouchLayouts(encoder.encode(longFile), normalArea: normal, compactArea: compact)
        let renamedLong = target.touchLayouts.last!
        let longReloaded = LauncherModel(settings, defaults: targetDefaults)
        expect(renamedLong.name.count == 80 && renamedLong.name.hasSuffix(" (2)") &&
               longReloaded.touchLayouts.contains { $0.id == renamedLong.id && $0.name == renamedLong.name },
               "an imported duplicate 80-character name is shortened for its suffix and survives reopening")

        let manySource = LauncherModel(settings, defaults: manySourceDefaults)
        let seedBank = BotwPortableBank(controls: ["L": .init(anchor: .right, side: 20, bottom: 40, size: 60)], options: [:])
        let seed = BotwTouchLayoutsFile(layouts: (0..<64).map { .init(name: "Layout \($0)", normal: seedBank, compact: nil) })
        try manySource.importTouchLayouts(encoder.encode(seed), normalArea: normal, compactArea: compact)
        let ownExport = try manySource.exportTouchLayouts(all: true)
        let manyTarget = LauncherModel(settings, defaults: manyTargetDefaults)
        let manyCount = try manyTarget.importTouchLayouts(ownExport, normalArea: normal, compactArea: compact)
        expect(manySource.touchLayouts.count == 65 && manyCount == 65 && manyTarget.touchLayouts.count == 66,
               "an app-generated 65-layout JSON can be imported within the same documented limits")

        let fixedSeed = LauncherModel(settings, defaults: fixedDefaults)
        var fixedDraft = fixedSeed.values
        fixedDraft["DM_BOTW_PAD_L_ANCHOR"] = "2"; fixedDraft["DM_BOTW_PAD_L_X_PT"] = "27.000"
        fixedDraft["DM_BOTW_PAD_L_Y_PT"] = "40.000"; fixedDraft["DM_BOTW_PAD_L_SIZE_PT"] = "60.000"
        expect(fixedSeed.saveTouchSettings(fixedDraft, portrait: false), "the env-override check starts with a saved user preset")
        let previousKeys = getenv("DM_ENV_FILE_KEYS").map { String(cString: $0) }
        let previousX = getenv("DM_BOTW_PAD_L_X_PT").map { String(cString: $0) }
        do {
            setenv("DM_ENV_FILE_KEYS", "DM_BOTW_PAD_L_X_PT", 1); setenv("DM_BOTW_PAD_L_X_PT", "99.000", 1)
            defer {
                if let previousKeys { setenv("DM_ENV_FILE_KEYS", previousKeys, 1) } else { unsetenv("DM_ENV_FILE_KEYS") }
                if let previousX { setenv("DM_BOTW_PAD_L_X_PT", previousX, 1) } else { unsetenv("DM_BOTW_PAD_L_X_PT") }
            }
            let locked = LauncherModel(settings, defaults: fixedDefaults)
            locked.addTouchLayout(name: "Pinned copy", copyCurrent: true)
            var editedLocked = locked.values; editedLocked["DM_BOTW_PAD_A_Y_PT"] = "18.000"
            expect(locked.saveTouchSettings(editedLocked, portrait: false), "unlocked controls remain editable under an env override")
            let regular = try JSONDecoder().decode(BotwTouchLayoutsFile.self, from: locked.exportTouchLayouts(all: false))
            let draftFile = try JSONDecoder().decode(BotwTouchLayoutsFile.self,
                from: locked.exportTouchLayoutDraft(locked.values, portrait: false, area: .normal))
            expect(locked.values["DM_BOTW_PAD_L_X_PT"] == "99.000" && regular.layouts[0].normal?.controls["L"]?.side == 27 &&
                   draftFile.layouts[0].normal?.controls["L"]?.side == 27 && locked.touchLayouts.allSatisfy {
                       $0.values["DM_BOTW_PAD_L_X_PT"] == "27.000"
                   }, "sync, duplicate, Save and both exports preserve user preset values beneath a temporary env override")
        }
        let unpinned = LauncherModel(settings, defaults: fixedDefaults)
        expect(unpinned.values["DM_BOTW_PAD_L_X_PT"] == "27.000" && unpinned.values["DM_BOTW_PAD_A_Y_PT"] == "18.000",
               "removing the env override restores the user's preset and preserves unrelated edits")

        target.selectTouchLayout(imported.id)
        var edited = target.values; edited["DM_BOTW_PAD_L_X_PT"] = "26.000"; edited["DM_BOTW_PAD_L_SIZE_PT"] = "64.000"
        expect(target.saveTouchSettings(edited, portrait: false), "an imported layout remains editable")
        let saved = LauncherModel(settings, defaults: targetDefaults)
        expect(saved.selectedTouchLayoutID == imported.id && saved.touchLayouts.count == target.touchLayouts.count &&
               saved.values["DM_BOTW_PAD_L_X_PT"] == "26.000" && saved.values["DM_BOTW_PAD_L_SIZE_PT"] == "64.000",
               "editor Save persists the selected preset and its edits before Play")
        saved.values["DM_BOTW_PAD_L_X_PT"] = "27.000"; saved.apply()
        let applied = LauncherModel(settings, defaults: targetDefaults)
        expect(applied.selectedTouchLayoutID == imported.id && applied.values["DM_BOTW_PAD_L_X_PT"] == "27.000",
               "Play also persists changes to the selected preset library")
        while applied.touchLayouts.count > 1 { applied.deleteTouchLayout(applied.touchLayouts[0].id) }
        let lastID = applied.touchLayouts[0].id
        applied.deleteTouchLayout(lastID)
        let last = LauncherModel(settings, defaults: targetDefaults)
        expect(last.touchLayouts.count == 1 && last.selectedTouchLayoutID == lastID,
               "deleting presets preserves one selected layout and refusing to delete the last survives reopening")
    } catch {
        expect(false, "preset regression completes without unexpected errors: \(error)")
    }
    let invalidLibraries = [Data(), Data("not JSON".utf8),
        Data(#"{"schemaVersion":1,"selected":"missing","layouts":[]}"#.utf8),
        Data(#"{"schemaVersion":99,"selected":"missing","layouts":[]}"#.utf8)]
    for data in invalidLibraries {
        fallbackDefaults.set(data, forKey: "launcher.botwTouchLayouts")
        let fallback = LauncherModel(settings, defaults: fallbackDefaults)
        expect(fallback.touchLayouts.count == 1 && fallback.selectedTouchLayoutID == fallback.touchLayouts.first?.id &&
               fallback.values["DM_BOTW_PAD_L_ANCHOR"] == "0" && fallback.values["DM_BOTW_PAD_L_X_PT"] == "0.000",
               "empty, corrupt or unsupported saved libraries recover a selected default layout")
    }
    return failed
}
