// Launcher settings, validation and persistence. Shared by the iOS UI and the native storage regression test.
import Foundation
import Combine

struct Setting: Decodable, Identifiable {
    let env, kind, label, note, def: String
    let section: String?   // heading on the settings screen; absent in older bundles
    let options: [[String]]?   // choice: [value, label]
    let min, max, step: Double?   // range
    let format: String?   // range: percent (default) or number
    let on, off: String?   // toggle: the values the variable takes (1 / 0 when not given)
    var id: String { env }
    var sectionTitle: String { section ?? "Game" }
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
            guard let n = Double(v), n.isFinite, let lo = min, let hi = max else { return false }
            return n >= lo && n <= hi
        case "toggle": return v == onValue || v == offValue
        default: return true
        }
    }
    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", section, options, min, max, step, format, on, off }
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

final class LauncherModel: ObservableObject {
    let settings: [Setting]
    let fromFile: Set<String>   // set by an env file: shown, not changed
    @Published var values: [String: String] = [:]

    private let defaults: UserDefaults

    init(_ settings: [Setting], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = settings
        fromFile = Set((ProcessInfo.processInfo.environment["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        for s in settings {
            if fromFile.contains(s.env), let v = ProcessInfo.processInfo.environment[s.env] { values[s.env] = v; continue }
            let saved = defaults.string(forKey: "launcher." + s.env)
            values[s.env] = saved.flatMap { s.accepts($0) ? $0 : nil } ?? s.def   // a saved choice the game no longer offers: its default
        }
    }

    var sections: [String] {
        settings.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    var changed: Bool { settings.contains { !fromFile.contains($0.env) && !$0.isDefault(values[$0.env] ?? $0.def) } }
    var touchStickChanged: Bool {
        settings.contains { TouchStickResponse.keys.contains($0.env) && !fromFile.contains($0.env) && !$0.isDefault(values[$0.env] ?? $0.def) }
    }
    var touchStickResponse: TouchStickResponse? {
        guard TouchStickResponse.keys.isSubset(of: Set(settings.map(\.env))) else { return nil }
        func number(_ key: String) -> Double? {
            guard let s = settings.first(where: { $0.env == key }) else { return nil }
            let v = values[key] ?? s.def
            return Double(s.accepts(v) ? v : s.def)
        }
        guard let deadzone = number("DM_BOTW_MOVE_DEADZONE"), let curve = number("DM_BOTW_MOVE_CURVE"),
              let full = number("DM_BOTW_MOVE_FULL"), let size = number("DM_BOTW_MOVE_SIZE") else { return nil }
        return TouchStickResponse(deadzone: deadzone, curve: curve, full: full, size: size)
    }

    // Reset every launcher choice to the game's defaults; an env file's values stay.
    func reset(keys: Set<String>? = nil) {
        for s in settings where keys?.contains(s.env) ?? true {
            defaults.removeObject(forKey: "launcher." + s.env)
            if !fromFile.contains(s.env) { values[s.env] = s.def }
        }
        fputs("launcher: \(keys == nil ? "settings" : "touch left stick") reset to the game's defaults\n", stderr)
    }

    // Before the game starts: every setting not set by an env file goes into the environment (DM_LANG replaces the packed language main.m set as a default). Only a choice that
    // differs from the game's default is stored: a setting the player left at its default follows the defaults of a later build (the settings it was tested with)
    func apply() {
        for s in settings {
            let v = values[s.env] ?? s.def
            if fromFile.contains(s.env) { fputs("launcher: \(s.env) kept at \(v) (env file)\n", stderr); continue }
            if s.isDefault(v) { defaults.removeObject(forKey: "launcher." + s.env) } else { defaults.set(v, forKey: "launcher." + s.env) }
            setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v)\(s.isDefault(v) ? "" : " (changed)")\n", stderr)
        }
    }
}
