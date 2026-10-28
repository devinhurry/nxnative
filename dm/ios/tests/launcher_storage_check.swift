// The launcher's storage (LauncherSettings.swift LauncherModel), run by test_launcher_storage.py on macOS: only choices that differ from the game's default are
// stored, Reset to tested defaults clears all choices, an env file's values are kept. Argument: a launcher.json of Breath of the Wild (settings.py, GFXAPI=nvn)
import Foundation
@main struct Check {
    static func main() {
        var failed = 0
        func expect(_ c: Bool, _ what: String) { print((c ? "PASS " : "FAIL ") + what); if !c { failed += 1 } }
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
        let scale = file.settings.first { $0.env == "DM_RENDER_SCALE" }!
        expect(["nan", "inf", "-inf", "0.49", "1.01", "invalid"].allSatisfy { !scale.accepts($0) } && scale.accepts("0.5") && scale.accepts("1.00"), "saved ranges reject nonfinite and out-of-range values")
        d.set("nan", forKey: "launcher.DM_RENDER_SCALE")
        expect(LauncherModel(file.settings, defaults: d).values["DM_RENDER_SCALE"] == scale.def, "an invalid saved range loads the default")
        expect(m.values["DM_FPS_TARGET"] == "30" && m.values["DM_PSO_MTL4"] == "0" && m.values["DM_FPS_HOLD"] == "on" && m.values["DM_METAL_HUD"] == "1", "stored choices and the env file are read")
        expect(m.changed, "Reset is offered with changed settings")
        let stick = m.touchStickResponse!
        expect(stick.deadzone == 0.07 && stick.curve == 0.7 && stick.full == 0.8 && stick.size == 1, "touch stick starts at the current movement defaults")
        expect(stick.strength(at: 0.07) == 0 && abs(stick.strength(at: 0.2) - 0.298803) < 0.001 && stick.strength(at: 0.8) == 1, "curve preview has the real deadzone, short-drag strength and endpoint")
        let curve = file.settings.first { $0.env == "DM_BOTW_MOVE_CURVE" }!
        expect(curve.formattedValue("0.7") == "0.70" && scale.formattedValue("0.5") == "50 %", "curve values are numbers and existing ranges remain percentages")
        m.values["DM_BOTW_MOVE_DEADZONE"] = "0.15"; m.values["DM_BOTW_MOVE_CURVE"] = "1.00"
        m.values["DM_BOTW_MOVE_FULL"] = "0.60"; m.values["DM_BOTW_MOVE_SIZE"] = "1.25"
        expect(abs(m.touchStickResponse!.strength(at: 0.375) - 0.5) < 1e-6, "adjusted curve preview responds to all movement parameters")
        m.values["DM_RENDER_SCALE"] = "1.00"   // the slider's format of the default
        m.apply()
        expect(d.string(forKey: "launcher.DM_PRESENT_SNAP") == nil, "a value equal to the default is not stored (and an old one is dropped)")
        expect(d.string(forKey: "launcher.DM_RENDER_SCALE") == nil && d.string(forKey: "launcher.DM_OPMODE") == nil && d.string(forKey: "launcher.DM_FPS_HOLD") == nil, "defaults are not stored")
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == "30" && d.string(forKey: "launcher.DM_PSO_MTL4") == "0", "changed choices are stored")
        expect(d.string(forKey: "launcher.DM_METAL_HUD") == nil && String(cString: getenv("DM_METAL_HUD")) == "1", "the env file's value is kept and not stored")
        expect(String(cString: getenv("DM_PSO_MTL4")) == "0" && String(cString: getenv("DM_PRESENT_SNAP")) == "1" && String(cString: getenv("DM_FPS_HOLD")) == "on", "the environment gets every value")
        let reopened = LauncherModel(file.settings, defaults: d)
        expect(reopened.values["DM_BOTW_MOVE_DEADZONE"] == "0.15" && reopened.values["DM_BOTW_MOVE_SIZE"] == "1.25" && String(cString: getenv("DM_BOTW_MOVE_CURVE")) == "1.00", "Play persists stick settings, reopening restores them, and runtime receives them")
        reopened.reset(keys: TouchStickResponse.keys)
        expect(!reopened.touchStickChanged && reopened.values["DM_BOTW_MOVE_DEADZONE"] == "0.07" && reopened.values["DM_BOTW_MOVE_SIZE"] == "1.0", "left-stick reset restores the entire group")
        expect(reopened.values["DM_FPS_TARGET"] == "30" && d.string(forKey: "launcher.DM_PSO_MTL4") == "0", "left-stick reset preserves unrelated game and performance choices")
        d.set("nan", forKey: "launcher.DM_BOTW_MOVE_CURVE"); d.set("2.00", forKey: "launcher.DM_BOTW_MOVE_SIZE")
        expect(LauncherModel(file.settings, defaults: d).touchStickResponse!.curve == 0.7 && LauncherModel(file.settings, defaults: d).touchStickResponse!.size == 1, "invalid saved tuning values load defaults")
        setenv("DM_ENV_FILE_KEYS", "DM_BOTW_MOVE_DEADZONE", 1); setenv("DM_BOTW_MOVE_DEADZONE", "0.12", 1)
        let locked = LauncherModel(file.settings, defaults: d)
        locked.reset(keys: TouchStickResponse.keys); locked.apply()
        expect(locked.values["DM_BOTW_MOVE_DEADZONE"] == "0.12" && String(cString: getenv("DM_BOTW_MOVE_DEADZONE")) == "0.12", "left-stick reset and Play preserve an env-file override")
        setenv("DM_ENV_FILE_KEYS", "DM_METAL_HUD", 1)
        m.reset()
        expect(d.string(forKey: "launcher.DM_PSO_MTL4") == nil && m.values["DM_PSO_MTL4"] == "1", "Reset clears performance choices and shows the defaults")
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == nil && m.values["DM_FPS_TARGET"] == file.settings.first { $0.env == "DM_FPS_TARGET" }!.def, "Reset also clears game choices")
        expect(m.values["DM_METAL_HUD"] == "1" && !m.changed, "Reset leaves the env file's value; nothing left to reset")
        print("launcher storage: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
