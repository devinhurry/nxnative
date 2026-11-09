// The launcher's storage (LauncherSettings.swift LauncherModel), run by test_launcher_storage.py on macOS: only choices that differ from the game's default are
// stored, Reset to tested defaults followed by Play forgets the choices, an env file's values are kept. Arguments: the iOS and the Mac launcher.json of Breath of the Wild (settings.py, GFXAPI=nvn)
import Foundation
@main struct Check {
    static func main() {
        var failed = 0
        func expect(_ c: Bool, _ what: String) { print((c ? "PASS " : "FAIL ") + what); if !c { failed += 1 } }
        let file = try! JSONDecoder().decode(SettingsFile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        // Exercise linked frame-rate and frame-generation choices independently
        // of the fixture's game-build capability list.
        let frameJSON = """
        {"settings":[
          {"env":"DM_FPS_TARGET","kind":"choice","label":"Rate","note":"","default":"30","options":[["30","30"],["40","40"],["60","60"],["120","120"]]},
          {"env":"DM_FRAMEGEN","kind":"choice","label":"Frame generation","note":"","default":"0","options":[["0","Off"],["30","30"],["40","40"],["60","60"],["max","Uncapped"]]}
        ]}
        """.data(using: .utf8)!
        let frameSettings = try! JSONDecoder().decode(SettingsFile.self, from: frameJSON).settings
        let frameSuite = "nxnative.frame-rate-test." + UUID().uuidString
        let frameDefaults = UserDefaults(suiteName: frameSuite)!
        defer { frameDefaults.removePersistentDomain(forName: frameSuite) }
        let fpsRow = frameSettings[0], fgRow = frameSettings[1]
        let fm = LauncherModel(frameSettings, defaults: frameDefaults)
        fm.setValue("40", for: fgRow)
        expect(fm.values["DM_FPS_TARGET"] == "40" && fm.values["DM_FRAMEGEN"] == "40", "frame generation selects its source rate")
        fm.setValue("60", for: fpsRow)
        expect(fm.values["DM_FRAMEGEN"] == "60", "changing the rate updates frame generation")
        fm.setValue("120", for: fpsRow)
        expect(fm.values["DM_FRAMEGEN"] == "0", "rates above 60 switch frame generation off")
        fm.choose(fgRow, "40")
        expect(frameDefaults.string(forKey: "launcher.DM_FPS_TARGET") == "40" && frameDefaults.string(forKey: "launcher.DM_FRAMEGEN") == "40", "live frame generation persists both rates")
        setenv("DM_ENV_FILE_KEYS", "DM_FRAMEGEN", 1); setenv("DM_FRAMEGEN", "40", 1)
        let fixedFG = LauncherModel(frameSettings, defaults: frameDefaults)
        fixedFG.setValue("60", for: fpsRow)
        expect(fixedFG.values["DM_FPS_TARGET"] == "40" && fixedFG.lockingKey(fpsRow) == "DM_FRAMEGEN", "fixed frame generation also fixes its source rate")
        setenv("DM_ENV_FILE_KEYS", "DM_FPS_TARGET", 1); setenv("DM_FPS_TARGET", "120", 1)
        let fixedRate = LauncherModel(frameSettings, defaults: frameDefaults)
        fixedRate.setValue("40", for: fgRow)
        expect(fixedRate.values["DM_FPS_TARGET"] == "120" && fixedRate.values["DM_FRAMEGEN"] == "0", "fixed rate above 60 keeps frame generation off")
        unsetenv("DM_ENV_FILE_KEYS"); unsetenv("DM_FRAMEGEN"); unsetenv("DM_FPS_TARGET")
        let phoneSuite = "nxnative.phone-default-test." + UUID().uuidString
        let phoneDefaults = UserDefaults(suiteName: phoneSuite)!
        defer { phoneDefaults.removePersistentDomain(forName: phoneSuite) }
        for (model, fast) in [(nil, false), ("iPhone18,1", false), ("iPhone19,1", false),
                              ("iPhone19,2", true), ("iPhone19,3", true), ("iPhone19,4", true),
                              ("iPhone19,7", true), ("iPad19,2", false)] as [(String?, Bool)] {
            let phone = LauncherModel(file.settings, defaults: phoneDefaults, phoneModel: model)
            expect(phone.values["DM_FPS_TARGET"] == (fast ? "60" : "30") && phone.values["DM_OPMODE"] == (fast ? "1" : "0"),
                   "phone defaults follow the recognized model: \(model ?? "none")")
            expect(!phone.changed, "phone defaults are not saved choices")
        }
        let phone = LauncherModel(file.settings, defaults: phoneDefaults, phoneModel: "iPhone19,2")
        phone.applySaved()
        expect(getenv("DM_FPS_TARGET").map { String(cString: $0) } == "60" && getenv("DM_OPMODE").map { String(cString: $0) } == "1" &&
               phoneDefaults.string(forKey: "launcher.DM_FPS_TARGET") == nil, "skipping the screen applies device defaults without saving them")
        phone.values["DM_FPS_TARGET"] = "30"; phone.values["DM_OPMODE"] = "0"; phone.apply()
        let savedPhone = LauncherModel(file.settings, defaults: phoneDefaults, phoneModel: "iPhone19,2")
        expect(savedPhone.values["DM_FPS_TARGET"] == "30" && savedPhone.values["DM_OPMODE"] == "0", "saved choices override phone defaults")
        savedPhone.reset(); savedPhone.apply()
        expect(savedPhone.values["DM_FPS_TARGET"] == "60" && savedPhone.values["DM_OPMODE"] == "1" &&
               phoneDefaults.string(forKey: "launcher.DM_FPS_TARGET") == nil, "reset restores phone defaults")
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
        let scale = file.settings.first { $0.env == "DM_RENDER_SCALE" }!
        expect(["nan", "inf", "-inf", "0.49", "1.01", "invalid", "0x1p-1", "0X1", " 0.75"].allSatisfy { !scale.accepts($0) } && scale.accepts("0.5") && scale.accepts("1.00"), "saved ranges reject nonfinite, out-of-range, hex and padded values, as launcher.c does")
        d.set("nan", forKey: "launcher.DM_RENDER_SCALE")
        expect(LauncherModel(file.settings, defaults: d).values["DM_RENDER_SCALE"] == scale.def, "an invalid saved range loads the default")
        expect(m.values["DM_FPS_TARGET"] == customFPS && m.values["DM_PSO_MTL4"] == "0" && m.values["DM_FPS_HOLD"] == "on" && m.values["DM_METAL_HUD"] == "1", "stored choices and the env file are read")
        expect(m.changed, "Reset is offered with changed settings")
        m.values["DM_RENDER_SCALE"] = "1.00"   // the slider's format of the default
        m.apply()
        expect(d.string(forKey: "launcher.DM_PRESENT_SNAP") == nil, "a value equal to the default is not stored (and an old one is dropped)")
        expect(d.string(forKey: "launcher.DM_RENDER_SCALE") == nil && d.string(forKey: "launcher.DM_OPMODE") == nil && d.string(forKey: "launcher.DM_FPS_HOLD") == nil, "defaults are not stored")
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == customFPS && d.string(forKey: "launcher.DM_PSO_MTL4") == "0", "changed choices are stored")
        expect(d.string(forKey: "launcher.DM_METAL_HUD") == nil && String(cString: getenv("DM_METAL_HUD")) == "1", "the env file's value is kept and not stored")
        expect(String(cString: getenv("DM_PSO_MTL4")) == "0" && String(cString: getenv("DM_PRESENT_SNAP")) == "1" && String(cString: getenv("DM_FPS_HOLD")) == "on", "the environment gets every value")
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
        d.set(customFPS, forKey: "launcher.DM_FPS_TARGET"); unsetenv("DM_FPS_TARGET")
        LauncherModel(file.settings, defaults: d).applySaved()
        expect(String(cString: getenv("DM_FPS_TARGET")) == customFPS && d.string(forKey: "launcher.DM_FPS_TARGET") == customFPS, "without the screen, a saved choice goes into the environment and stays saved")
        setenv("DM_SAVED_CHOICES", "0", 1); unsetenv("DM_FPS_TARGET")
        let plain = LauncherModel(file.settings, defaults: d)
        expect(plain.values["DM_FPS_TARGET"] == fps.def, "DM_SAVED_CHOICES=0 starts from the defaults")
        plain.applySaved()
        expect(getenv("DM_FPS_TARGET").map { String(cString: $0) } == fps.def, "DM_SAVED_CHOICES=0: skipping the screen applies the device default")
        plain.apply()
        expect(String(cString: getenv("DM_FPS_TARGET")) == fps.def && d.string(forKey: "launcher.DM_FPS_TARGET") == customFPS, "DM_SAVED_CHOICES=0: Play uses the screen's values and leaves the saved choices")
        plain.reset()
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == customFPS, "DM_SAVED_CHOICES=0: Reset leaves the saved choices too")
        unsetenv("DM_SAVED_CHOICES")
        // The Mac window's list (second argument): Basic first, then Advanced in the list's sections; Display mode; the render scale in pixels; values set at launch are fixed
        let mac = try! JSONDecoder().decode(SettingsFile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        setenv("DM_ENV_FILE_KEYS", "", 1); unsetenv("DM_FULLSCREEN"); unsetenv("DM_OPMODE")
        let mm = LauncherModel(mac.settings, defaults: d)
        expect(mm.sections(basic: true) == ["Game", "Controls"] && mm.sections(basic: false) == ["Game", "Controls", "Performance"], "Basic and Advanced keep the list's sections")
        expect(mm.rows(in: "Game", basic: true).map(\.env) == ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_OPMODE", "DM_LANG", "DM_FULLSCREEN"], "Basic rows in the list's order")
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
        failed += checkLauncherLayout(LauncherModel(mac.settings, defaults: d), defaults: d)
        print("launcher storage: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
