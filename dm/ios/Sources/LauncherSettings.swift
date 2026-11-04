// Launcher settings, validation and persistence. Shared by the iOS UI, the Mac app's settings window (dm/mac/Launcher.swift) and the native storage regression test.
import Foundation
import Combine
import CoreGraphics
import DmTouchPad
#if os(iOS)
import UIKit
import Metal
#endif

struct Setting: Decodable, Identifiable {
    let env, kind, label, note: String
    var def: String
    let phoneDefault: PhoneDefault?
    struct PhoneDefault: Decodable {
        let generation: Int
        let value: String
        func matches(_ gpu: String?) -> Bool {
            let words = (gpu ?? "").split(separator: " ")
            guard words.count >= 3, words[0] == "Apple", words[1].first == "A",
                  let number = Int(words[1].dropFirst()) else { return false }
            return number > generation || (number == generation && words[2] == "Pro")
        }
    }
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
    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", phoneDefault = "phone_default", section, needs, level, base, options, min, max, step, format, on, off }
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
    static let added: [Self] = [
        .init(id: 16, key: "WEAPON", label: "Weapons"), .init(id: 17, key: "SHIELD", label: "Shields"),
        .init(id: 18, key: "FOOD", label: "Food"), .init(id: 19, key: "WHISTLE", label: "Whistle")
    ]
    static let cancel = Self(id: 20, key: "CANCEL", label: "Cancel switching")
    static let editable = all + added + [cancel]
    static let compact = all
    func option(_ field: String, portrait: Bool) -> String {
        botwTouchKey("DM_BOTW_PAD_\(key)_\(field)", portrait: portrait)
    }
    var removable: Bool { id == 12 || (16...20).contains(id) }
    func visibilityKey(portrait: Bool) -> String { option(id == 12 ? "VISIBLE" : "ENABLED", portrait: portrait) }
    func env(_ field: String, portrait: Bool = false) -> String {
        botwTouchKey("DM_BOTW_PAD_\(key)_\(field)_PT", portrait: portrait)
    }
    var keys: Set<String> { keys(portrait: false) }
    func keys(portrait: Bool) -> Set<String> {
        var keys = Set([env("X", portrait: portrait), env("Y", portrait: portrait), env("SIZE", portrait: portrait), option("ANCHOR", portrait: portrait)])
        if id == 6 || id == 16 || id == 17 { keys.insert(option("MODE", portrait: portrait)) }
        if id == 6 { keys.insert(option("ICON_MODE", portrait: portrait)) }
        if id == 8 { keys.insert(env("HIT", portrait: portrait)) }
        if id == 4 { keys.insert(option("ALPHA", portrait: portrait)) }
        if id == 7 || id == 9 { keys.insert(option("DRAG_MODE", portrait: portrait)) }
        return keys
    }

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

struct BotwTouchArea: Codable, Equatable {
    var width, height: Double
    static let normal = Self(width: 932, height: 430)
    static let compact = Self(width: 390, height: 844)
    var valid: Bool { width.isFinite && height.isFinite && width >= 20 && height >= 20 && width <= 10000 && height <= 10000 }
}

struct BotwSavedTouchLayout: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var values: [String: String]
    var normalArea = BotwTouchArea.normal
    var compactArea = BotwTouchArea.compact
}

private struct BotwTouchLibrary: Codable {
    var schemaVersion = 1
    var selected: String
    var layouts: [BotwSavedTouchLayout]
}

struct BotwPortableControl: Codable {
    enum Anchor: String, Codable { case left, right }
    var anchor: Anchor
    var side, bottom, size: Double
    enum CodingKeys: String, CodingKey { case anchor, side = "sidePt", bottom = "bottomPt", size = "sizePt" }
}

struct BotwPortableBank: Codable {
    var controls: [String: BotwPortableControl]
    var options: [String: String]
}

struct BotwPortableLayout: Codable {
    var name: String
    var normal, compact: BotwPortableBank?
}

struct BotwTouchLayoutsFile: Codable {
    var schemaVersion = 1
    var game = "01007EF00011E000"
    var layouts: [BotwPortableLayout]
}

enum BotwTouchFileError: Error, LocalizedError {
    case invalid, version, limit
    var errorDescription: String? {
        let key: String
        switch self {
        case .invalid: key = "This file does not contain valid touch layouts."
        case .version: key = "This layout file uses an unsupported schema version."
        case .limit: key = "Keep up to 256 layouts. Layout files must be smaller than 4 MB."
        }
        return NSLocalizedString(key, comment: "")
    }
}

final class LauncherModel: ObservableObject {
    static let languageKey = "DM_LANG"
    static let lowMemoryKey = "DM_LOW_MEMORY"
    static let lowMemoryNotice = "Low-memory mode is enabled to help keep the game running. Performance may be affected."
    let settings: [Setting]
    let fixed: Set<String>      // set by an env file or by the launch environment: shown, not changed
    let fromLaunch: Set<String>   // of those, the ones the launch environment set (a front end's launch overrides, Xcode; DM_ENV_LAUNCH_KEYS from launcher.c or main.m)
    let ignoreSaved: Bool   // DM_SAVED_CHOICES=0: start from the defaults, and leave the saved choices as they are
    @Published var values: [String: String] = [:] {
        didSet {
            syncTouchLayout()
            if isRunning { applyRuntimeChanges(previous: oldValue); persistTouchLayouts() }
        }
    }
    @Published private(set) var touchLayouts: [BotwSavedTouchLayout] = []
    @Published private(set) var selectedTouchLayoutID = ""
    @Published private(set) var isRunning = false
    @Published private(set) var deferredSettings: Set<String> = []

    private let defaults: UserDefaults
    private let availableMemory: () -> UInt64
    private var automaticLowMemoryValue = "0"
    private var lowMemoryOverride: String?
    private var hasLanguageOverride = false

    static var phoneGPUName: String? {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone { return MTLCreateSystemDefaultDevice()?.name }
        #endif
        return nil
    }

    init(_ settings: [Setting], defaults: UserDefaults = .standard,
         availableMemory: @escaping () -> UInt64 = { dm_low_memory_available() },
         phoneGPUName: String? = LauncherModel.phoneGPUName,
         preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        self.availableMemory = availableMemory
        let settings = settings.map { row -> Setting in
            var row = row
            if let preset = row.phoneDefault, preset.matches(phoneGPUName), row.accepts(preset.value) { row.def = preset.value }
            if row.env == Self.languageKey {
                let supported = row.options?.compactMap(\.first) ?? []
                // Match the game's languages, independently of the launcher's translations.
                // The packed language is the fallback after all user preferences.
                row.def = Bundle.preferredLocalizations(from: supported, forPreferences: preferredLanguages + [row.def]).first ?? row.def
            }
            return row
        }
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
        let legacyPoints = !ignoreSaved && defaults.integer(forKey: "launcher.botwPointLayoutVersion") == 0
            ? Self.legacyTouchPoints(defaults) : [:]
        for s in settings {
            if fixed.contains(s.env), let v = env[s.env] { values[s.env] = v; continue }
            let saved = ignoreSaved ? nil : (defaults.object(forKey: "launcher." + s.env) as? String ?? legacyPoints[s.env])   // accept only strings, as launcher.c does
            let choice = saved.flatMap { s.accepts($0) ? $0 : nil }
            if s.env == Self.languageKey { hasLanguageOverride = choice != nil }
            values[s.env] = choice ?? defaultValue(s)
        }
        for portrait in [false, true] {
            let hit = botwTouchKey("DM_BOTW_PAD_ZL_HIT_PT", portrait: portrait)
            if !fixed.contains(hit), ignoreSaved || defaults.string(forKey: "launcher." + hit) == nil {
                values.removeValue(forKey: hit)
            }
        }
        values.merge(touchSnapshot(values)) { _, migrated in migrated }
        alignFrameGeneration()
        loadTouchLayouts()
    }

    private static func legacyTouchPoints(_ defaults: UserDefaults) -> [String: String] {
        var points: [String: String] = [:]
        for portrait in [false, true] {
            for control in BotwTouchControl.all {
                points.merge(control.legacyPointValues(portrait: portrait) { defaults.object(forKey: "launcher." + $0) as? String }) { current, _ in current }
            }
        }
        return points
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

    // Automatic defaults are never saved. Explicit memory and language choices
    // are remembered even when they equal this launch's automatic value.
    func setValue(_ v: String, for s: Setting) {
        guard lockingKey(s) == nil, s.accepts(v) else { return }
        if s.env == Self.lowMemoryKey {
            lowMemoryOverride = v
            if !ignoreSaved { defaults.set(v, forKey: "launcher." + s.env) }
        }
        if s.env == Self.languageKey {
            hasLanguageOverride = true
            if !ignoreSaved { defaults.set(v, forKey: "launcher." + s.env) }
        }
        var next = values
        setTouchValue(v, for: s.env, in: &next)
        if s.env == "DM_FPS_TARGET", frameGenerationEnabled { next["DM_FRAMEGEN"] = v }
        if s.env == "DM_FRAMEGEN", v != "0" {
            if fixed.contains("DM_FPS_TARGET") { next[s.env] = values["DM_FPS_TARGET"] ?? v }
            else { next["DM_FPS_TARGET"] = v }
        }
        values = next
    }

    // Add Cancel only on a user configuration change, never while loading or
    // rendering a layout: an explicit removal must survive saving and import.
    func setTouchValue(_ value: String, for key: String, in draft: inout [String: String]) {
        let previous = draft[key] ?? settings.first(where: { $0.env == key })?.def
        draft[key] = value
        guard previous != value else { return }
        for portrait in [false, true] {
            let cancel = BotwTouchControl.cancel.visibilityKey(portrait: portrait)
            guard !fixed.contains(cancel) else { continue }
            let sticky = ["L", "WEAPON", "SHIELD"].contains {
                key == botwTouchKey("DM_BOTW_PAD_\($0)_MODE", portrait: portrait)
            } && value == "2"
            let camera = ["R", "ZR"].contains {
                key == botwTouchKey("DM_BOTW_PAD_\($0)_DRAG_MODE", portrait: portrait)
            } && value == "1"
            let addedSticky = BotwTouchControl.added.prefix(2).contains {
                key == $0.visibilityKey(portrait: portrait) && value == "1" &&
                    draft[$0.option("MODE", portrait: portrait)] == "2"
            }
            if sticky || camera || addedSticky { draft[cancel] = "1" }
        }
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
        } else if s.env == Self.languageKey && hasLanguageOverride {
            defaults.set(value, forKey: "launcher." + s.env)
        } else if s.env.hasSuffix("_ZL_HIT_PT") {
            // Keep the migrated reach even at its default; artwork can resize later.
            defaults.set(value, forKey: "launcher." + s.env)
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
    private var touchLayoutKeys: Set<String> { touchSettingsKeys.subtracting(["DM_BOTW_PORTRAIT"]) }
    private var defaultTouchValues: [String: String] {
        let keys = touchLayoutKeys
        return Dictionary(uniqueKeysWithValues: settings.filter { keys.contains($0.env) }.map { ($0.env, $0.def) })
    }
    private func touchSnapshot(_ source: [String: String]) -> [String: String] {
        var snapshot = defaultTouchValues
        let keys = touchLayoutKeys
        for row in settings where keys.contains(row.env) {
            if let value = source[row.env], row.accepts(value) { snapshot[row.env] = value }
        }
        for portrait in [false, true] {
            let hit = botwTouchKey("DM_BOTW_PAD_ZL_HIT_PT", portrait: portrait)
            let size = botwTouchKey("DM_BOTW_PAD_ZL_SIZE_PT", portrait: portrait)
            if source[hit] == nil, snapshot[hit] != nil, let diameter = Double(snapshot[size] ?? "") {
                snapshot[hit] = Self.touchPoint(diameter * Double(DM_TP_STICK_GRAB))
            }
        }
        return snapshot
    }
    private func syncTouchLayout() {
        guard let index = touchLayouts.firstIndex(where: { $0.id == selectedTouchLayoutID }) else { return }
        var snapshot = touchSnapshot(values)
        for key in fixed {
            if let saved = touchLayouts[index].values[key] { snapshot[key] = saved }
        }
        if touchLayouts[index].values != snapshot { touchLayouts[index].values = snapshot }
    }
    private func loadTouchLayouts() {
        guard !touchLayoutKeys.isEmpty else { return }
        if !ignoreSaved, let data = defaults.data(forKey: "launcher.botwTouchLayouts"),
           let library = try? JSONDecoder().decode(BotwTouchLibrary.self, from: data), library.schemaVersion == 1,
           !library.layouts.isEmpty, library.layouts.count <= 256 {
            var ids = Set<String>()
            touchLayouts = library.layouts.filter {
                !$0.id.isEmpty && ids.insert($0.id).inserted && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                $0.name.count <= 80 && $0.normalArea.valid && $0.compactArea.valid && validTouchAnchors($0.values)
            }.map { var layout = $0; layout.values = touchSnapshot(layout.values); return layout }
            selectedTouchLayoutID = touchLayouts.contains { $0.id == library.selected } ? library.selected : touchLayouts.first?.id ?? ""
        }
        if touchLayouts.isEmpty {
            var source = values
            for row in settings where fixed.contains(row.env) {
                let saved = ignoreSaved ? nil : defaults.string(forKey: "launcher." + row.env)
                source[row.env] = saved.flatMap { row.accepts($0) ? $0 : nil } ?? row.def
            }
            let layout = BotwSavedTouchLayout(name: "Default layout", values: touchSnapshot(source))
            touchLayouts = [layout]; selectedTouchLayoutID = layout.id
        }
        // The ordinary scalar choices are the active layout's compatibility
        // record. Older app versions can update them without knowing about the
        // library; retain their validated values instead of reviving a stale
        // active snapshot. Inactive layouts remain independent in the library.
        syncTouchLayout()
    }
    private func persistTouchLayouts() {
        guard !ignoreSaved, !touchLayouts.isEmpty else { return }
        let library = BotwTouchLibrary(selected: selectedTouchLayoutID, layouts: touchLayouts)
        if let data = try? JSONEncoder().encode(library) { defaults.set(data, forKey: "launcher.botwTouchLayouts") }
    }
    private func persistCurrentTouchChoices() {
        let keys = touchLayoutKeys
        for row in settings where keys.contains(row.env) && !fixed.contains(row.env) {
            if let value = values[row.env], row.accepts(value) { storeChoice(row, value) }
        }
        persistTouchLayouts()
    }
    func selectTouchLayout(_ id: String) {
        guard let layout = touchLayouts.first(where: { $0.id == id }) else { return }
        syncTouchLayout()
        selectedTouchLayoutID = id
        var next = values
        for (key, value) in layout.values where !fixed.contains(key) { next[key] = value }
        values = next
        persistCurrentTouchChoices()
    }
    func addTouchLayout(name: String, copyCurrent: Bool) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, touchLayouts.count < 256 else { return }
        syncTouchLayout()
        let current = touchLayouts.first(where: { $0.id == selectedTouchLayoutID })
        var layout = BotwSavedTouchLayout(name: name, values: copyCurrent ? current?.values ?? touchSnapshot(values) : defaultTouchValues)
        if copyCurrent, let current = touchLayouts.first(where: { $0.id == selectedTouchLayoutID }) {
            layout.normalArea = current.normalArea; layout.compactArea = current.compactArea
        }
        touchLayouts.append(layout)
        selectTouchLayout(layout.id)
    }
    func renameTouchLayout(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, let index = touchLayouts.firstIndex(where: { $0.id == selectedTouchLayoutID }) else { return }
        touchLayouts[index].name = name
        persistTouchLayouts()
    }
    func deleteTouchLayout(_ id: String) {
        guard touchLayouts.count > 1, let index = touchLayouts.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTouchLayoutID == id
        touchLayouts.remove(at: index)
        if wasSelected { selectTouchLayout(touchLayouts[min(index, touchLayouts.count - 1)].id) }
        else { persistTouchLayouts() }
    }
    func rememberTouchArea(_ area: BotwTouchArea, portrait: Bool) {
        guard area.valid, let index = touchLayouts.firstIndex(where: { $0.id == selectedTouchLayoutID }) else { return }
        if portrait { if touchLayouts[index].compactArea != area { touchLayouts[index].compactArea = area } }
        else { if touchLayouts[index].normalArea != area { touchLayouts[index].normalArea = area } }
    }
    private func validTouchAnchors(_ source: [String: String]) -> Bool {
        for portrait in [false, true] {
            for control in BotwTouchControl.editable {
                let anchor = source[control.option("ANCHOR", portrait: portrait)] ?? "0"
                guard ["0", "1", "2"].contains(anchor) else { return false }
                if anchor != "0" {
                    guard let x = Double(source[control.env("X", portrait: portrait)] ?? "0"), x.isFinite, x >= 0, x <= 10000,
                          let y = Double(source[control.env("Y", portrait: portrait)] ?? "0"), y.isFinite, y >= 0, y <= 10000 else { return false }
                }
            }
        }
        return true
    }
    func touchLayout(portrait: Bool, values source: [String: String]? = nil) -> dm_botw_touch_layout {
        let source = source ?? values
        var result = dm_botw_layout_defaults_for(portrait ? 1 : 0)
        func number(_ key: String, _ fallback: Double = 0) -> Double {
            guard let row = settings.first(where: { $0.env == key }) else { return fallback }
            let text = source[key] ?? row.def
            return Double(row.accepts(text) ? text : row.def) ?? fallback
        }
        withUnsafeMutableBytes(of: &result.control) { bytes in
            let controls = bytes.bindMemory(to: dm_botw_control_transform.self)
            for control in BotwTouchControl.editable {
                controls[control.id] = .init(x: Float(number(control.env("X", portrait: portrait))),
                    y: Float(number(control.env("Y", portrait: portrait))),
                    size: Float(number(control.env("SIZE", portrait: portrait), Double(controls[control.id].size))),
                    anchor: Int32(number(control.option("ANCHOR", portrait: portrait))))
            }
        }
        result.badges = Int32(number(botwTouchKey("DM_BOTW_PAD_BADGES", portrait: portrait)))
        result.dpad_visible = Int32(number(botwTouchKey("DM_BOTW_PAD_DPAD_VISIBLE", portrait: portrait), 1))
        result.cancel_enabled = Int32(number(BotwTouchControl.cancel.visibilityKey(portrait: portrait), 1))
        withUnsafeMutableBytes(of: &result.added) { bytes in
            let flags = bytes.bindMemory(to: Int32.self)
            for (i, control) in BotwTouchControl.added.enumerated() { flags[i] = Int32(number(control.visibilityKey(portrait: portrait))) }
        }
        withUnsafeMutableBytes(of: &result.switch_mode) { bytes in
            let modes = bytes.bindMemory(to: Int32.self)
            for i in 0..<2 { modes[i] = Int32(number(BotwTouchControl.added[i].option("MODE", portrait: portrait))) }
        }
        result.rune_mode = Int32(number(botwTouchKey("DM_BOTW_PAD_L_MODE", portrait: portrait)))
        result.rune_icon_mode = Int32(number(botwTouchKey("DM_BOTW_PAD_L_ICON_MODE", portrait: portrait)))
        result.trigger_drag = (Int32(number(botwTouchKey("DM_BOTW_PAD_R_DRAG_MODE", portrait: portrait))),
            Int32(number(botwTouchKey("DM_BOTW_PAD_ZR_DRAG_MODE", portrait: portrait))))
        result.shield_hit_size = Float(number(botwTouchKey("DM_BOTW_PAD_ZL_HIT_PT", portrait: portrait), Double(result.shield_hit_size)))
        result.fill_gray = Float(number(botwTouchKey("DM_BOTW_PAD_FILL_GRAY", portrait: portrait), Double(result.fill_gray)))
        result.fill_alpha = Float(number(botwTouchKey("DM_BOTW_PAD_FILL_ALPHA", portrait: portrait), Double(result.fill_alpha)))
        result.stroke_gray = Float(number(botwTouchKey("DM_BOTW_PAD_STROKE_GRAY", portrait: portrait), Double(result.stroke_gray)))
        result.stroke_alpha = Float(number(botwTouchKey("DM_BOTW_PAD_STROKE_ALPHA", portrait: portrait), Double(result.stroke_alpha)))
        result.icon_alpha = Float(number(botwTouchKey("DM_BOTW_PAD_ICON_ALPHA", portrait: portrait), Double(result.icon_alpha)))
        result.stick_alpha = Float(number(botwTouchKey("DM_BOTW_PAD_STICK_ALPHA", portrait: portrait), Double(result.stick_alpha)))
        return result
    }
    private func portableBank(_ saved: BotwSavedTouchLayout, portrait: Bool) -> BotwPortableBank {
        let area = portrait ? saved.compactArea : saved.normalArea
        var config = touchLayout(portrait: portrait, values: saved.values)
        var controls: [String: BotwPortableControl] = [:]
        var positionKeys = Set<String>()
        for control in BotwTouchControl.editable {
            let r = dm_botw_layout_control(&config, Int32(control.id), Float(area.width), Float(area.height), 0, 0, 0, 0,
                dm_botw_layout_canvas(Float(area.width), Float(area.height)))
            let right = Double(r.x + r.width / 2) > area.width / 2
            let storedAnchor = saved.values[control.option("ANCHOR", portrait: portrait)] ?? "0"
            let anchor: BotwPortableControl.Anchor = storedAnchor == "1" ? .left : storedAnchor == "2" ? .right : right ? .right : .left
            controls[control.key] = .init(anchor: anchor,
                side: (max(0, anchor == .right ? area.width - Double(r.x + r.width) : Double(r.x)) * 1000).rounded() / 1000,
                bottom: (max(0, area.height - Double(r.y + r.height)) * 1000).rounded() / 1000,
                size: (Double(r.width) * 1000).rounded() / 1000)
            positionKeys.formUnion([control.env("X", portrait: portrait), control.env("Y", portrait: portrait),
                control.env("SIZE", portrait: portrait), control.option("ANCHOR", portrait: portrait)])
        }
        let optionKeys = touchSettingsKeys(portrait: portrait).subtracting(positionKeys)
        return .init(controls: controls, options: saved.values.filter { optionKeys.contains($0.key) })
    }
    func exportTouchLayouts(all: Bool, normalArea: BotwTouchArea? = nil, compactArea: BotwTouchArea? = nil) throws -> Data {
        syncTouchLayout()
        let layouts = touchLayouts.filter { all || $0.id == selectedTouchLayoutID }.map {
            var saved = $0
            if let normalArea, normalArea.valid { saved.normalArea = normalArea }
            if let compactArea, compactArea.valid { saved.compactArea = compactArea }
            return BotwPortableLayout(name: saved.name, normal: portableBank(saved, portrait: false), compact: portableBank(saved, portrait: true))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(BotwTouchLayoutsFile(layouts: layouts))
    }
    func exportTouchLayoutDraft(_ draft: [String: String], portrait: Bool, area: BotwTouchArea) throws -> Data {
        guard var layout = touchLayouts.first(where: { $0.id == selectedTouchLayoutID }), area.valid else { throw BotwTouchFileError.invalid }
        for key in touchSettingsKeys(portrait: portrait) where !fixed.contains(key) { if let value = draft[key] { layout.values[key] = value } }
        if portrait { layout.compactArea = area } else { layout.normalArea = area }
        let file = BotwTouchLayoutsFile(layouts: [.init(name: layout.name, normal: portableBank(layout, portrait: false), compact: portableBank(layout, portrait: true))])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }
    @discardableResult func importTouchLayouts(_ data: Data, normalArea: BotwTouchArea, compactArea: BotwTouchArea) throws -> Int {
        guard data.count <= 4_194_304 else { throw BotwTouchFileError.limit }
        guard normalArea.valid, compactArea.valid else { throw BotwTouchFileError.invalid }
        let file: BotwTouchLayoutsFile
        do { file = try JSONDecoder().decode(BotwTouchLayoutsFile.self, from: data) }
        catch { throw BotwTouchFileError.invalid }
        guard file.schemaVersion == 1 else { throw BotwTouchFileError.version }
        guard file.game == "01007EF00011E000", !file.layouts.isEmpty else { throw BotwTouchFileError.invalid }
        guard file.layouts.count <= 256, touchLayouts.count + file.layouts.count <= 256 else { throw BotwTouchFileError.limit }
        var added: [BotwSavedTouchLayout] = []
        for incoming in file.layouts {
            let name = incoming.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80, incoming.normal != nil || incoming.compact != nil else { throw BotwTouchFileError.invalid }
            var next = defaultTouchValues
            for portrait in [false, true] {
                guard let bank = portrait ? incoming.compact : incoming.normal else { continue }
                let area = portrait ? compactArea : normalArea
                var geometryKeys = Set<String>()
                for control in BotwTouchControl.editable {
                    geometryKeys.formUnion([control.env("X", portrait: portrait), control.env("Y", portrait: portrait),
                        control.env("SIZE", portrait: portrait), control.option("ANCHOR", portrait: portrait)])
                }
                let optionKeys = touchSettingsKeys(portrait: portrait).subtracting(geometryKeys)
                for (key, value) in bank.options {
                    guard optionKeys.contains(key), let row = settings.first(where: { $0.env == key }), row.accepts(value) else { throw BotwTouchFileError.invalid }
                    next[key] = value
                }
                guard !bank.controls.isEmpty else { throw BotwTouchFileError.invalid }
                for (name, position) in bank.controls {
                    guard let control = BotwTouchControl.editable.first(where: { $0.key == name }),
                          position.side.isFinite, position.bottom.isFinite, position.size.isFinite,
                          abs(position.side) <= 10000, abs(position.bottom) <= 10000,
                          position.size >= 20, position.size <= 240 else { throw BotwTouchFileError.invalid }
                    let size = min(position.size, min(area.width, area.height))
                    next[control.option("ANCHOR", portrait: portrait)] = position.anchor == .left ? "1" : "2"
                    next[control.env("X", portrait: portrait)] = Self.touchPoint(min(max(0, position.side), max(0, area.width - size)))
                    next[control.env("Y", portrait: portrait)] = Self.touchPoint(min(max(0, position.bottom), max(0, area.height - size)))
                    next[control.env("SIZE", portrait: portrait)] = Self.touchPoint(size)
                }
                let hit = botwTouchKey("DM_BOTW_PAD_ZL_HIT_PT", portrait: portrait)
                if bank.options[hit] == nil {
                    next.removeValue(forKey: hit)
                    next = touchSnapshot(next)
                }
            }
            // Missing banks and controls use defaults, fitted to this device
            // too. A sparse imported file must not leave fallback controls out
            // of a narrow or short pane.
            for portrait in [false, true] {
                let area = portrait ? compactArea : normalArea
                var config = touchLayout(portrait: portrait, values: next)
                for control in BotwTouchControl.editable {
                    let r = dm_botw_layout_control(&config, Int32(control.id), Float(area.width), Float(area.height), 0, 0, 0, 0,
                        dm_botw_layout_canvas(Float(area.width), Float(area.height)))
                    let storedAnchor = next[control.option("ANCHOR", portrait: portrait)] ?? "0"
                    let right = storedAnchor == "2" || (storedAnchor == "0" && Double(r.x + r.width / 2) > area.width / 2)
                    let size = min(Double(r.width), min(area.width, area.height))
                    let side = right ? area.width - Double(r.x + r.width) : Double(r.x)
                    let bottom = area.height - Double(r.y + r.height)
                    next[control.option("ANCHOR", portrait: portrait)] = right ? "2" : "1"
                    next[control.env("X", portrait: portrait)] = Self.touchPoint(min(max(0, side), max(0, area.width - size)))
                    next[control.env("Y", portrait: portrait)] = Self.touchPoint(min(max(0, bottom), max(0, area.height - size)))
                    next[control.env("SIZE", portrait: portrait)] = Self.touchPoint(size)
                }
            }
            guard validTouchAnchors(next) else { throw BotwTouchFileError.invalid }
            var uniqueName = name, suffix = 2
            while (touchLayouts + added).contains(where: { $0.name == uniqueName }) {
                let ending = " (\(suffix))"
                uniqueName = String(name.prefix(80 - ending.count)) + ending
                suffix += 1
            }
            added.append(.init(name: uniqueName, values: next, normalArea: normalArea, compactArea: compactArea))
        }
        syncTouchLayout()
        touchLayouts.append(contentsOf: added)
        // Import is additive. The currently selected layout keeps running until
        // the player selects one of the newly imported layouts.
        persistTouchLayouts()
        return added.count
    }
    static func touchPoint(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    // Export the same normalized values consumed by both gamepads, including
    // defaults and locked values. No device-specific preview pixels are saved.
    var touchSettingsExport: String {
        touchSettingsExport(keys: touchSettingsKeys, values: values)
    }
    func touchSettingsExport(portrait: Bool, values: [String: String]? = nil) -> String {
        touchSettingsExport(keys: touchSettingsKeys(portrait: portrait), values: values ?? self.values)
    }
    private func touchSettingsExport(keys: Set<String>, values: [String: String]) -> String {
        settings.filter { keys.contains($0.env) }.map { row in
            let current = values[row.env] ?? row.def
            let value = row.accepts(current) ? current : row.def
            let text = row.kind == "range" ? String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(value) ?? 0) : value
            return "\(row.env)=\(text)"
        }.joined(separator: "\n")
    }

    // The full-screen editor keeps a draft until Save. Persist only this bank;
    // unrelated launcher choices still wait for Play.
    @discardableResult func saveTouchSettings(_ draft: [String: String], portrait: Bool) -> Bool {
        let keys = touchSettingsKeys(portrait: portrait)
        let rows = settings.filter { keys.contains($0.env) && !fixed.contains($0.env) }
        guard rows.allSatisfy({ row in draft[row.env].map(row.accepts) ?? false }), validTouchAnchors(draft) else { return false }
        if !ignoreSaved && defaults.integer(forKey: "launcher.botwPointLayoutVersion") == 0 {
            // Finish both banks' stored legacy conversion before retiring it.
            // Do not save unrelated, uncommitted values from the current UI.
            let migrated = Self.legacyTouchPoints(defaults)
            for row in settings where defaults.object(forKey: "launcher." + row.env) == nil {
                if let value = migrated[row.env], row.accepts(value) { storeChoice(row, value) }
            }
            defaults.set(1, forKey: "launcher.botwPointLayoutVersion")
        }
        var next = values
        for row in rows { next[row.env] = draft[row.env] }
        values = next
        for row in rows { storeChoice(row, next[row.env]!) }
        persistTouchLayouts()
        return true
    }

    var changed: Bool {
        settings.contains { s in
            guard !fixed.contains(s.env) else { return false }
            if s.env == Self.lowMemoryKey { return lowMemoryOverride != nil || values[s.env] != automaticLowMemoryValue }
            return (s.env == Self.languageKey && hasLanguageOverride) || !s.isDefault(values[s.env] ?? s.def)
        }
    }

    // Reset every launcher choice to the game's defaults on the screen; values fixed by an env file or at launch stay. The saved choices are forgotten when Play applies
    // the defaults (apply() keeps no default), so Quit after Reset keeps them, and a choice a launch override hides is kept
    func reset(keys: Set<String>? = nil) {
        if settings.contains(where: { $0.env == Self.lowMemoryKey }), !fixed.contains(Self.lowMemoryKey),
           keys?.contains(Self.lowMemoryKey) ?? true {
            automaticLowMemoryValue = memoryDefault(); lowMemoryOverride = nil
        }
        if !fixed.contains(Self.languageKey), keys?.contains(Self.languageKey) ?? true { hasLanguageOverride = false }
        var next = values
        for s in settings where !fixed.contains(s.env) && (keys?.contains(s.env) ?? true) {
            next[s.env] = defaultValue(s)
            if isRunning { storeChoice(s, defaultValue(s)) }
        }
        values = next
        alignFrameGeneration()
        fputs("launcher: settings reset to the game's defaults\n", stderr)
    }

    // Before the game starts: every setting not set by an env file goes into the environment (DM_LANG replaces the packed language main.m set as a default). Only a choice that
    // differs from the game's default is stored. Memory and language keep explicit
    // manual overrides even at the automatic value; automatic choices are never saved.
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
        syncTouchLayout()
        persistTouchLayouts()
    }
    private func store(_ s: Setting, _ v: String) {
        if !ignoreSaved { if s.isDefault(v) { defaults.removeObject(forKey: "launcher." + s.env) } else { defaults.set(v, forKey: "launcher." + s.env) } }
    }

    // A choice made while the game runs (the iOS in-game menu, GameMenu.swift): saved as Play saves it, so the settings screen shows it at the next start, and put in the environment.
    // A value an env file or the launch fixed stays
    func choose(_ s: Setting, _ v: String) {
        guard !fixed.contains(s.env), s.accepts(v) else { return }
        values[s.env] = v; store(s, v); setenv(s.env, v, 1)
        fputs("launcher: \(s.env)=\(v) (in-game menu)\n", stderr)
    }

    // DM_LAUNCHER=0: no screen, but the saved choices still apply (only DM_SAVED_CHOICES=0 ignores them); nothing is written
    func applySaved() {
        for s in settings where !fixed.contains(s.env) {
            let v = values[s.env] ?? s.def
            // Device defaults can differ from the compiled profile even when no
            // choices were saved and the startup screen is skipped.
            if s.env == Self.languageKey || s.env == Self.lowMemoryKey || s.phoneDefault != nil || !s.isDefault(v) {
                let origin = s.env == Self.lowMemoryKey ? (lowMemoryOverride == nil ? "automatic" : "manual") : (s.isDefault(v) ? "default" : "saved choice")
                setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v) (\(origin))\n", stderr)
            }
        }
    }
}
