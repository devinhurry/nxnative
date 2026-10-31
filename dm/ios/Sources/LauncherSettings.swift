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
    static let keys: Set<String> = ["DM_BOTW_MOVE_DEADZONE", "DM_BOTW_MOVE_CURVE", "DM_BOTW_MOVE_FULL", "DM_BOTW_MOVE_SIZE"]
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
        .init(id: 0, key: "FACE", label: "XYAB"), .init(id: 4, key: "STICK", label: "Left stick"),
        .init(id: 8, key: "ZL", label: "Shield stick"), .init(id: 6, key: "L", label: "Rune (L)"),
        .init(id: 7, key: "R", label: "R"), .init(id: 9, key: "ZR", label: "ZR"),
        .init(id: 12, key: "DPAD", label: "D-pad")
    ]
    static let compact: [Self] = [
        .init(id: 0, key: "A", label: "A"), .init(id: 1, key: "B", label: "B"),
        .init(id: 2, key: "X", label: "X"), .init(id: 3, key: "Y", label: "Y")
    ] + all.filter { $0.id != 0 }
    func env(_ field: String, portrait: Bool = false) -> String {
        botwTouchKey(id == 4 && field == "SCALE" ? "DM_BOTW_MOVE_SIZE" : "DM_BOTW_PAD_\(key)_\(field)", portrait: portrait)
    }
    var keys: Set<String> { Set([env("X"), env("Y"), env("SCALE")]) }
    func keys(portrait: Bool) -> Set<String> { Set([env("X", portrait: portrait), env("Y", portrait: portrait), env("SCALE", portrait: portrait)]) }
}

final class LauncherModel: ObservableObject {
    static let lowMemoryKey = "DM_LOW_MEMORY"
    static let lowMemoryNotice = "Low-memory mode is enabled to help keep the game running. Performance may be affected."
    let settings: [Setting]
    let fixed: Set<String>      // set by an env file or by the launch environment: shown, not changed
    let fromLaunch: Set<String>   // of those, the ones the launch environment set (a front end's launch overrides, Xcode; DM_ENV_LAUNCH_KEYS from launcher.c or main.m)
    let ignoreSaved: Bool   // DM_SAVED_CHOICES=0: start from the defaults, and leave the saved choices as they are
    @Published var values: [String: String] = [:]

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
        for s in settings {
            if fixed.contains(s.env), let v = env[s.env] { values[s.env] = v; continue }
            let saved = ignoreSaved ? nil : defaults.object(forKey: "launcher." + s.env) as? String   // a string, as launcher.c reads it: not string(forKey:), which turns a number into one
            values[s.env] = saved.flatMap { s.accepts($0) ? $0 : nil } ?? defaultValue(s)
        }
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
        guard !fixed.contains(s.env), s.accepts(v) else { return }
        if s.env == Self.lowMemoryKey {
            lowMemoryOverride = v
            if !ignoreSaved { defaults.set(v, forKey: "launcher." + s.env) }
        }
        values[s.env] = v
    }

    var sections: [String] {
        settings.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    // A row with "needs" is a sub-setting of the row it names: drawn only while that setting has that value, so a
    // setting that cannot do anything is not offered (an upscaler's detail with the upscaler off, rumble strength
    // with rumble off). A row naming a setting this game does not have stays drawn, as it has nothing to hide behind
    func visible(_ s: Setting) -> Bool {
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
              let full = number("DM_BOTW_MOVE_FULL"), let size = number("DM_BOTW_MOVE_SIZE") else { return nil }
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
        for s in settings where !fixed.contains(s.env) && (keys?.contains(s.env) ?? true) { values[s.env] = defaultValue(s) }
        fputs("launcher: settings reset to the game's defaults\n", stderr)
    }

    // Before the game starts: every setting not set by an env file goes into the environment (DM_LANG replaces the packed language main.m set as a default). Only a choice that
    // differs from the game's default is stored. The memory switch instead keeps
    // only its explicit manual override; the automatic selection is never saved.
    func apply() {
        for s in settings {
            let v = values[s.env] ?? s.def
            if fixed.contains(s.env) { fputs("launcher: \(s.env) kept at \(v) (\(fromLaunch.contains(s.env) ? "launch environment" : "env file"))\n", stderr); continue }
            if !ignoreSaved {
                if s.env == Self.lowMemoryKey {
                    if let choice = lowMemoryOverride { defaults.set(choice, forKey: "launcher." + s.env) }
                    else { defaults.removeObject(forKey: "launcher." + s.env) }
                } else if s.isDefault(v) { defaults.removeObject(forKey: "launcher." + s.env) }
                else { defaults.set(v, forKey: "launcher." + s.env) }
            }
            let origin = s.env == Self.lowMemoryKey ? (lowMemoryOverride == nil ? " (automatic)" : " (manual)") : (s.isDefault(v) ? "" : " (changed)")
            setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v)\(origin)\n", stderr)
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
