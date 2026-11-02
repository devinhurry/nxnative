// Launcher settings, validation and persistence. Shared by the iOS UI, the Mac app's settings window (dm/mac/Launcher.swift) and the native storage regression test.
import Foundation
import Combine
import DmTouchPad

struct Setting: Decodable, Identifiable {
    let env, kind, label, note, def: String
    let section: String?   // heading on the settings screen; absent in older bundles
    let needs: String?     // "<VAR>=<value>": a sub-setting, drawn only while that setting has that value
    let level: String?     // "basic": shown first (the Mac window's Basic settings); any other or none: Advanced settings. The iPhone keeps one list
    let base: Base?        // render scale: the 3D views' size at 1.0, docked and handheld, for the size in pixels (the Mac window)
    struct Base: Decodable { let docked, handheld: [Int] }
    let options: [[String]]?   // choice: [value, label]
    let min, max, step: Double?   // range
    let format: String?   // range: percent (default) or number
    let on, off: String?   // toggle: the values the variable takes (1 / 0 when not given)
    var id: String { env }
    var sectionTitle: String { section ?? "Game" }
    var basic: Bool { level == "basic" }
    var onValue: String { on ?? "1" }
    var offValue: String { off ?? "0" }
    func formattedValue(_ value: String) -> String {
        let n = Double(value) ?? Double(def) ?? 0
        guard n.isFinite else { return "Invalid" }
        if env.hasSuffix("_PT") { return String(format: "%.1f pt", n) }
        return format == "number" ? String(format: "%.2f", n) : "\(Int((n * 100).rounded())) %"
    }
    func isDefault(_ v: String) -> Bool {   // a range compares as numbers (a slider writes 1.00 for 1.0)
        kind == "range" ? abs((Double(v) ?? .nan) - (Double(def) ?? .nan)) < 1e-6 : v == def
    }
    func accepts(_ v: String) -> Bool {   // a saved choice the game still offers
        switch kind {
        case "choice": return options?.contains { $0[0] == v } ?? false
        case "range":
            guard !v.contains(where: { $0 == "x" || $0 == "X" }), let n = Double(v), n.isFinite, let lo = min, let hi = max else { return false }   // no hex: launcher.c's check agrees
            return n >= lo && n <= hi
        case "toggle": return v == onValue || v == offValue
        default: return true
        }
    }
    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", section, needs, level, base, options, min, max, step, format, on, off }
}
struct SettingsFile: Decodable { let settings: [Setting] }

struct TouchStickResponse {
    static let section = "Touch left stick"
    static let keys: Set<String> = ["DM_BOTW_MOVE_DEADZONE", "DM_BOTW_MOVE_CURVE", "DM_BOTW_MOVE_FULL", "DM_BOTW_PAD_STICK_SIZE_PT"]
    let deadzone, curve, full, size: Double

    func strength(at travel: Double) -> Double {
        guard travel > deadzone, full > deadzone else { return 0 }
        return pow(min((travel - deadzone) / (full - deadzone), 1), curve)
    }
}

func botwTouchKey(_ key: String, portrait: Bool) -> String {
    portrait ? "DM_BOTW_PORTRAIT_" + String(key.dropFirst("DM_BOTW_".count)) : key
}

struct BotwTouchControl: Identifiable, Hashable {
    let id: Int
    let key, label: String
    static let all: [Self] = [
        .init(id: 0, key: "A", label: "A"), .init(id: 1, key: "B", label: "B"),
        .init(id: 2, key: "X", label: "X"), .init(id: 3, key: "Y", label: "Y"),
        .init(id: 4, key: "STICK", label: "Left stick"), .init(id: 8, key: "ZL", label: "Shield stick"),
        .init(id: 6, key: "L", label: "Rune (L)"), .init(id: 7, key: "R", label: "R"),
        .init(id: 9, key: "ZR", label: "ZR"), .init(id: 12, key: "DPAD", label: "D-pad")
    ]
    static let compact = all
    func env(_ field: String, portrait: Bool = false) -> String {
        botwTouchKey("DM_BOTW_PAD_\(key)_\(field)_PT", portrait: portrait)
    }
    var keys: Set<String> { keys(portrait: false) }
    func keys(portrait: Bool) -> Set<String> { Set([env("X", portrait: portrait), env("Y", portrait: portrait), env("SIZE", portrait: portrait)]) }

    // Old offsets were fractions of a reference phone canvas. Project saved
    // customizations once into the new point keys; never reinterpret a fraction
    // as points, and never replace an explicit choice under a new key.
    func legacyPointValues(portrait: Bool, read: (String) -> String?) -> [String: String] {
        let prefix = portrait ? "DM_BOTW_PORTRAIT_" : "DM_BOTW_"
        let name = !portrait && id < 4 ? "FACE" : key
        func number(_ key: String, _ fallback: Double, _ low: Double, _ high: Double) -> Double {
            guard let text = read(key), let n = Double(text), n.isFinite, n >= low, n <= high else { return fallback }
            return n
        }
        let oldX = prefix + "PAD_\(name)_X", oldY = prefix + "PAD_\(name)_Y"
        let oldSize = prefix + (id == 4 ? "MOVE_SIZE" : "PAD_\(name)_SCALE")
        let oldGap = prefix + "PAD_FACE_GAP"
        var sourceKeys = [oldX, oldY, oldSize]
        if !portrait && id < 4 { sourceKeys.append(oldGap) }
        if portrait && id == 12 { sourceKeys.append(prefix + "PAD_L_SCALE") }
        guard sourceKeys.contains(where: { read($0) != nil }) else { return [:] }
        let u = portrait ? 390.0 / 430 : 1
        let oldDefaultX: Double = portrait ? 0 : id < 4 ? -0.006 : id == 6 ? 0.021 : id == 7 ? 0.025 : id == 9 ? -0.022 : id == 12 ? 0.042 : 0
        let oldDefaultY: Double = portrait ? 0 : id < 4 ? -0.068 : id == 4 ? 0.023 : id == 7 ? -0.097 : id == 9 ? -0.098 : 0
        let oldDefaultScale: Double = id < 4 || id == 7 || id == 9 ? 1.1 : id == 6 ? 1.2 : id == 4 ? 0.8 : 1
        var baseSize: Double = id < 4 ? 54 : id == 4 || id == 8 ? 154 : id == 6 ? 48 : id == 12 ? 96 : 52
        baseSize *= u
        if portrait {
            if id < 2 { baseSize -= 10 / 1.1 }
            if id == 3 { baseSize += 10 / 1.1 }
            if id == 6 { baseSize -= 6 / 1.2 }
            if id == 12 { baseSize -= 6 }
        }
        let scale = number(oldSize, oldDefaultScale, id == 4 ? 0.6 : 0.5, 1.5)
        let diameter = baseSize * scale
        let deltaSize = diameter - baseSize * oldDefaultScale
        var x = (number(oldX, oldDefaultX, -0.5, 0.5) - oldDefaultX) * (portrait ? 390 : 430 * 16 / 9)
        var y = (number(oldY, oldDefaultY, -0.5, 0.5) - oldDefaultY) * (portrait ? 844 : 430)
        if !portrait && id < 4 {
            let deltaGap = 50 * number(oldGap, 1.06, 0.5, 1.5) * scale - 58.3
            x += id == 0 ? deltaGap : id == 3 ? -deltaGap : 0
            y += id == 1 ? deltaGap : id == 2 ? -deltaGap : 0
        }
        if portrait && id == 12 {
            let runeDelta = (48 * u - 6 / 1.2) * (number(prefix + "PAD_L_SCALE", 1.2, 0.5, 1.5) - 1.2)
            x += runeDelta
            y += (deltaSize - runeDelta) / 2
        } else if !portrait || id != 6 {
            // The old compact rune already anchored its left/bottom edges.
            x += (id < 4 || id == 7 || id == 9 ? 1 : -1) * deltaSize / 2
            y += deltaSize / 2
        }
        return [env("X", portrait: portrait): String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), x),
                env("Y", portrait: portrait): String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), y),
                env("SIZE", portrait: portrait): String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), diameter)]
    }
}

final class LauncherModel: ObservableObject {
    static let lowMemoryKey = "DM_LOW_MEMORY"
    static let lowMemoryNotice = "Low-memory mode is enabled to help keep the game running. Performance may be affected."
    let settings: [Setting]
    let fixed: Set<String>      // set by an env file or by the launch environment: shown, not changed
    let fromLaunch: Set<String>   // of those, the ones the launch environment set (a front end's launch overrides, Xcode; DM_ENV_LAUNCH_KEYS from launcher.c or main.m)
    let ignoreSaved: Bool   // DM_SAVED_CHOICES=0: start from the defaults, and leave the saved choices as they are
    @Published var values: [String: String] = [:] {
        didSet { if isRunning { applyRuntimeChanges(previous: oldValue) } }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var deferredSettings: Set<String> = []

    private let defaults: UserDefaults
    private let availableMemory: () -> UInt64
    private var automaticLowMemoryValue = "0"
    private var lowMemoryOverride: String?

    init(_ settings: [Setting], defaults: UserDefaults = .standard,
         availableMemory: @escaping () -> UInt64 = { dm_low_memory_available() }) {
        self.defaults = defaults
        self.availableMemory = availableMemory
        self.settings = settings
        let env = ProcessInfo.processInfo.environment
        fromLaunch = Set((env["DM_ENV_LAUNCH_KEYS"] ?? "").split(separator: " ").map(String.init))
        fixed = fromLaunch.union((env["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        ignoreSaved = env["DM_SAVED_CHOICES"] == "0"
        if ignoreSaved { fputs("launcher: saved choices ignored (DM_SAVED_CHOICES=0)\n", stderr) }
        if let s = settings.first(where: { $0.env == Self.lowMemoryKey }) {
            automaticLowMemoryValue = memoryDefault()
            if !ignoreSaved, let saved = defaults.object(forKey: "launcher." + s.env) as? String, s.accepts(saved) {
                lowMemoryOverride = saved
            }
        }
        var legacyPoints: [String: String] = [:]
        if !ignoreSaved && defaults.integer(forKey: "launcher.botwPointLayoutVersion") == 0 {
            for portrait in [false, true] {
                for control in BotwTouchControl.all {
                    legacyPoints.merge(control.legacyPointValues(portrait: portrait) { defaults.object(forKey: "launcher." + $0) as? String }) { current, _ in current }
                }
            }
        }
        for s in settings {
            if fixed.contains(s.env), let v = env[s.env] { values[s.env] = v; continue }
            let saved = ignoreSaved ? nil : (defaults.object(forKey: "launcher." + s.env) as? String ?? legacyPoints[s.env])   // accept only strings, as launcher.c does
            values[s.env] = saved.flatMap { s.accepts($0) ? $0 : nil } ?? defaultValue(s)
        }
        alignFrameGeneration()
    }

    private func memoryDefault() -> String {
        let bytes = availableMemory(), value = dm_low_memory_default(bytes) != 0 ? "1" : "0"
        fputs("launcher: low-memory automatic default \(value) (\(bytes) bytes available; threshold \(dm_low_memory_threshold()))\n", stderr)
        return value
    }
    private func defaultValue(_ s: Setting) -> String { s.env == Self.lowMemoryKey ? automaticLowMemoryValue : s.def }
    var lowMemoryEnabled: Bool { values[Self.lowMemoryKey] == "1" }
    func refreshMemoryDefault(available bytes: UInt64) {
        guard lowMemoryOverride == nil, !fixed.contains(Self.lowMemoryKey),
              settings.contains(where: { $0.env == Self.lowMemoryKey }) else { return }
        let value = dm_low_memory_default(bytes) != 0 ? "1" : "0"
        guard automaticLowMemoryValue != value else { return }
        automaticLowMemoryValue = value; values[Self.lowMemoryKey] = value
    }

    // Automatic defaults are never saved. An explicit On or Off is remembered
    // immediately, including a choice equal to this launch's automatic value.
    func setValue(_ v: String, for s: Setting) {
        guard lockingKey(s) == nil, s.accepts(v) else { return }
        if s.env == Self.lowMemoryKey {
            lowMemoryOverride = v
            if !ignoreSaved { defaults.set(v, forKey: "launcher." + s.env) }
        }
        var next = values
        next[s.env] = v
        if s.env == "DM_FPS_TARGET", frameGenerationEnabled { next["DM_FRAMEGEN"] = v }
        if s.env == "DM_FRAMEGEN", v != "0" {
            if fixed.contains("DM_FPS_TARGET") { next[s.env] = values["DM_FPS_TARGET"] ?? v }
            else { next["DM_FPS_TARGET"] = v }
        }
        values = next
    }

    var frameGenerationEnabled: Bool {
        guard let value = values["DM_FRAMEGEN"] else { return false }
        return value != "0"
    }

    func lockingKey(_ s: Setting) -> String? {
        if fixed.contains(s.env) { return s.env }
        // A launch override that pins interpolation to a source rate also pins
        // the rate selector; otherwise changing it would have no visible effect.
        if s.env == "DM_FPS_TARGET", fixed.contains("DM_FRAMEGEN"), frameGenerationEnabled { return "DM_FRAMEGEN" }
        return nil
    }

    private func alignFrameGeneration() {
        guard let rate = values["DM_FRAMEGEN"], ["30", "60"].contains(rate), values["DM_FPS_TARGET"] != nil else { return }
        if fixed.contains("DM_FPS_TARGET") && !fixed.contains("DM_FRAMEGEN") {
            values["DM_FRAMEGEN"] = values["DM_FPS_TARGET"]
        } else if !fixed.contains("DM_FPS_TARGET") {
            values["DM_FPS_TARGET"] = rate
        }
    }

    func beginRuntime() { isRunning = true }

    func appliesImmediately(_ s: Setting) -> Bool {
        #if os(iOS) || DM_HOST_UI
        return dm_launcher_setting_is_live(s.env) == 1 && !deferredSettings.contains(s.env)
        #else
        return false
        #endif
    }

    private func storeChoice(_ s: Setting, _ value: String) {
        guard !ignoreSaved else { return }
        if s.env == Self.lowMemoryKey {
            if let choice = lowMemoryOverride { defaults.set(choice, forKey: "launcher." + s.env) }
            else { defaults.removeObject(forKey: "launcher." + s.env) }
        } else if s.isDefault(value) { defaults.removeObject(forKey: "launcher." + s.env) }
        else { defaults.set(value, forKey: "launcher." + s.env) }
    }

    private func applyRuntimeChanges(previous: [String: String]) {
        for s in settings where !fixed.contains(s.env) {
            guard let value = values[s.env], value != previous[s.env], s.accepts(value) else { continue }
            #if os(iOS) || DM_HOST_UI
            if dm_launcher_setting_is_live(s.env) == 1 && dm_launcher_setting_apply(s.env, value) != 1 {
                deferredSettings.insert(s.env)
            }
            #endif
            storeChoice(s, value)
        }
    }

    var sections: [String] {
        settings.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    // A row with "needs" is a sub-setting of the row it names: drawn only while that setting has that value, so a
    // setting that cannot do anything is not offered (an upscaler's detail with the upscaler off, rumble strength
    // with rumble off). A row naming a setting this game does not have stays drawn, as it has nothing to hide behind
    func visible(_ s: Setting) -> Bool {
        if s.env == "DM_PSO_PREBUILD", values[Self.lowMemoryKey] == "1" { return false }
        guard let n = s.needs, let eq = n.firstIndex(of: "=") else { return true }
        let key = String(n[n.startIndex..<eq]), want = String(n[n.index(after: eq)...])
        guard let v = values[key] else { return true }
        return v == want
    }
    func rows(in section: String) -> [Setting] { settings.filter { $0.sectionTitle == section && visible($0) } }
    // The Mac window: Basic settings first, then Advanced settings, each in the list's sections and order
    func sections(basic: Bool) -> [String] {
        settings.filter { $0.basic == basic }.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    func rows(in section: String, basic: Bool) -> [Setting] { rows(in: section).filter { $0.basic == basic } }
    // A range's label: its percentage, with the size in pixels for the chosen console mode when the list has the base size (the render scale)
    func rangeLabel(_ s: Setting, _ v: Double) -> String {
        if s.env.hasSuffix("_PT") { return String(format: "%.1f pt", v) }
        if s.format == "number" { return String(format: "%.2f", v) }
        let p = "\(Int((v * 100).rounded())) %"
        guard let b = s.base else { return p }
        let size = (values["DM_OPMODE"] ?? "1") == "0" ? b.handheld : b.docked
        guard size.count == 2 else { return p }
        return "\(Int((Double(size[0]) * v).rounded())) × \(Int((Double(size[1]) * v).rounded())) (\(p))"
    }
    var touchStickChanged: Bool {
        settings.contains { TouchStickResponse.keys.contains($0.env) && !fixed.contains($0.env) && !$0.isDefault(values[$0.env] ?? $0.def) }
    }
    var needsTouchFallbackNotice: Bool {
        touchStickResponse != nil && !defaults.bool(forKey: "botw.touchFallbackNoticeAcknowledged")
    }
    func acknowledgeTouchFallbackNotice() {
        defaults.set(true, forKey: "botw.touchFallbackNoticeAcknowledged")
    }
    var touchStickResponse: TouchStickResponse? {
        touchStickResponse(portrait: false)
    }
    func touchStickResponse(portrait: Bool) -> TouchStickResponse? {
        guard Set(TouchStickResponse.keys.map { botwTouchKey($0, portrait: portrait) }).isSubset(of: Set(settings.map(\.env))) else { return nil }
        func number(_ key: String) -> Double? {
            let key = botwTouchKey(key, portrait: portrait)
            guard let s = settings.first(where: { $0.env == key }) else { return nil }
            let v = values[key] ?? s.def
            return Double(s.accepts(v) ? v : s.def)
        }
        guard let deadzone = number("DM_BOTW_MOVE_DEADZONE"), let curve = number("DM_BOTW_MOVE_CURVE"),
              let full = number("DM_BOTW_MOVE_FULL"), let size = number("DM_BOTW_PAD_STICK_SIZE_PT") else { return nil }
        return TouchStickResponse(deadzone: deadzone, curve: curve, full: full, size: size)
    }
    static func isTouchSection(_ section: String) -> Bool {
        section == TouchStickResponse.section || section == "Touch layout"
    }
    var touchSettingsKeys: Set<String> {
        Set(settings.filter { Self.isTouchSection($0.sectionTitle) }.map(\.env))
    }
    func touchSettingsKeys(portrait: Bool) -> Set<String> {
        Set(touchSettingsKeys.filter { $0 != "DM_BOTW_PORTRAIT" && $0.hasPrefix("DM_BOTW_PORTRAIT_") == portrait })
    }
    // Export the same normalized values consumed by both gamepads, including
    // defaults and locked values. No device-specific preview pixels are saved.
    var touchSettingsExport: String {
        touchSettingsExport(keys: touchSettingsKeys)
    }
    func touchSettingsExport(portrait: Bool) -> String {
        touchSettingsExport(keys: touchSettingsKeys(portrait: portrait))
    }
    private func touchSettingsExport(keys: Set<String>) -> String {
        settings.filter { keys.contains($0.env) }.map { row in
            let current = values[row.env] ?? row.def
            let value = row.accepts(current) ? current : row.def
            let text = row.kind == "range" ? String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(value) ?? 0) : value
            return "\(row.env)=\(text)"
        }.joined(separator: "\n")
    }

    var changed: Bool {
        settings.contains { s in
            !fixed.contains(s.env) && (s.env == Self.lowMemoryKey
                ? lowMemoryOverride != nil || values[s.env] != automaticLowMemoryValue
                : !s.isDefault(values[s.env] ?? s.def))
        }
    }

    // Reset every launcher choice to the game's defaults on the screen; values fixed by an env file or at launch stay. The saved choices are forgotten when Play applies
    // the defaults (apply() keeps no default), so Quit after Reset keeps them, and a choice a launch override hides is kept
    func reset(keys: Set<String>? = nil) {
        if settings.contains(where: { $0.env == Self.lowMemoryKey }), !fixed.contains(Self.lowMemoryKey),
           keys?.contains(Self.lowMemoryKey) ?? true {
            automaticLowMemoryValue = memoryDefault(); lowMemoryOverride = nil
        }
        for s in settings where !fixed.contains(s.env) && (keys?.contains(s.env) ?? true) {
            values[s.env] = defaultValue(s)
            if isRunning { storeChoice(s, defaultValue(s)) }
        }
        alignFrameGeneration()
        fputs("launcher: settings reset to the game's defaults\n", stderr)
    }

    // Before the game starts: every setting not set by an env file goes into the environment (DM_LANG replaces the packed language main.m set as a default). Only a choice that
    // differs from the game's default is stored. The memory switch instead keeps
    // only its explicit manual override; the automatic selection is never saved.
    func apply() {
        for s in settings {
            let v = values[s.env] ?? s.def
            if fixed.contains(s.env) { fputs("launcher: \(s.env) kept at \(v) (\(fromLaunch.contains(s.env) ? "launch environment" : "env file"))\n", stderr); continue }
            storeChoice(s, v)
            let origin = s.env == Self.lowMemoryKey ? (lowMemoryOverride == nil ? " (automatic)" : " (manual)") : (s.isDefault(v) ? "" : " (changed)")
            setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v)\(origin)\n", stderr)
        }
        if !ignoreSaved && settings.contains(where: { $0.env == "DM_BOTW_PAD_A_X_PT" }) {
            defaults.set(1, forKey: "launcher.botwPointLayoutVersion")
        }
    }

    // DM_LAUNCHER=0: no screen, but the saved choices still apply (only DM_SAVED_CHOICES=0 ignores them); nothing is written
    func applySaved() {
        for s in settings where !fixed.contains(s.env) {
            let v = values[s.env] ?? s.def
            if s.env == Self.lowMemoryKey || !s.isDefault(v) {
                let origin = s.env == Self.lowMemoryKey ? (lowMemoryOverride == nil ? "automatic" : "manual") : "saved choice"
                setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v) (\(origin))\n", stderr)
            }
        }
    }
}
