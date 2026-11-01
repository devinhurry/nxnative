// Shared launcher dashboard, settings pages and rows for the iOS and native Mac wrappers.
// A row whose setting is fixed by an env file or by the launch environment is shown but disabled.
import SwiftUI

extension LauncherModel {
    func binding(_ s: Setting) -> Binding<String> { Binding(get: { self.values[s.env] ?? s.def }, set: { self.setValue($0, for: s) }) }
}

struct SettingRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel

    private var locked: Bool { m.lockingKey(s) != nil }
    private var note: String {
        let text = NSLocalizedString(s.note, comment: "Launcher setting description")
        guard locked else {
            guard m.isRunning else { return text }
            let timing = NSLocalizedString(m.appliesImmediately(s) ? "Applies immediately." : "Applies next time you start the game.", comment: "Setting application timing")
            return (text.isEmpty ? "" : text + " · ") + timing
        }
        return (text.isEmpty ? "" : text + " · ") + NSLocalizedString(m.fromLaunch.contains(m.lockingKey(s) ?? s.env) ? "Set at launch" : "Set by an env file", comment: "Locked launcher setting")
    }
    private var rangeValue: Binding<Double> {
        Binding(get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 },
                set: { m.setValue(String(format: "%.2f", $0), for: s) })
    }
    private var percentage: String { m.rangeLabel(s, rangeValue.wrappedValue) }

    private var settingLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(s.label))
            if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    var body: some View {
        Group {
            switch s.kind {
            case "choice" where s.env == "DM_FRAMEGEN":
                Toggle(isOn: Binding(get: { m.frameGenerationEnabled }, set: { enabled in
                    m.setValue(enabled ? (m.values["DM_FPS_TARGET"] ?? "60") : "0", for: s)
                })) {
                    settingLabel
                }
                .accessibilityIdentifier(s.env)
                .accessibilityLabel(Text(LocalizedStringKey(s.label)))
                .accessibilityHint(note)
            case "choice":
                if s.env == "DM_FPS_TARGET" {
                    VStack(alignment: .leading, spacing: 8) {
                        settingLabel
                        choices.pickerStyle(.segmented)
                    }
                } else {
                    choices.pickerStyle(.menu)
                }
            case "range":
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        settingLabel
                        Spacer()
                        Text(percentage).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: rangeValue, in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05)
                        .accessibilityLabel(Text(LocalizedStringKey(s.label)))
                        .accessibilityValue(percentage)
                        .accessibilityIdentifier(s.env)
                }
            default:
                Toggle(isOn: Binding(get: { (m.values[s.env] ?? s.def) == s.onValue }, set: { m.setValue($0 ? s.onValue : s.offValue, for: s) })) {
                    settingLabel
                }
            }
        }
        .disabled(locked)
    }

    private var choices: some View {
        Picker(selection: m.binding(s)) {
            ForEach(s.options ?? [], id: \.[0]) { Text(LocalizedStringKey($0[1])).tag($0[0]) }
        } label: {
            settingLabel
        }
        .accessibilityIdentifier(s.env)
    }
}

struct LauncherDashboard: View {
    @ObservedObject var model: LauncherModel
    let title: String
    let version: String
    let icon: Image?
    let romReady: Bool
    let shadersReady: Bool
    let dlcCount: Int
    let memoryBytes: UInt64
    let importBusy: Bool
    let checkingResources: Bool
    let resourceStatus: String?
    let importProgress: Double
    let graphicsVersion: String?
    let graphicsCompiler: String?
    let buildInfo: [String: String]
    let shouldShowTouchNotice: () -> Bool
    let onPlay: () -> Void
    let onSettings: () -> Void
    let onImportROM: (() -> Void)?
    let onImportShaders: (() -> Void)?
    var onRefresh: (() -> Void)? = nil
    @State private var showTouchNotice = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 8) {
                        if let icon {
                            let size: CGFloat = model.lowMemoryEnabled ? 52 : 64
                            icon.resizable().frame(width: size, height: size)
                                .clipShape(RoundedRectangle(cornerRadius: 15))
                                .accessibilityHidden(true)
                        }
                        Text(title)
                            .font(.title3.weight(.bold)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                        Text(String(format: NSLocalizedString("Version %@", comment: "Game version"), version))
                            .font(.caption).foregroundStyle(.secondary)
                        playButton.disabled(importBusy || checkingResources || !romReady || !shadersReady)
                        HStack(spacing: 8) {
                            if let onImportROM {
                                if romReady {
                                    Label("ROM imported", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .accessibilityIdentifier("startup.import.rom.ready")
                                } else {
                                    Button("Import ROM", action: onImportROM)
                                        .accessibilityIdentifier("startup.import.rom")
                                        .buttonStyle(.bordered).disabled(importBusy || checkingResources)
                                }
                            }
                            if let onImportShaders {
                                if shadersReady {
                                    Label("Shaders imported", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .accessibilityIdentifier("startup.import.shaders.ready")
                                } else {
                                    Button("Import shaders", action: onImportShaders)
                                        .accessibilityIdentifier("startup.import.shaders")
                                        .buttonStyle(.bordered).disabled(importBusy || checkingResources)
                                }
                            }
                        }
                        if let onRefresh {
                            Button(action: onRefresh) {
                                Label {
                                    Text("Refresh")
                                } icon: {
                                    Image(systemName: "arrow.clockwise")
                                        .opacity(checkingResources ? 0 : 1)
                                        .overlay {
                                            if checkingResources { ProgressView().controlSize(.mini) }
                                        }
                                        .accessibilityHidden(true)
                                }
                            }
                            .accessibilityIdentifier("startup.resources.refresh")
                            .buttonStyle(.bordered).disabled(importBusy || checkingResources)
                        }
                        if importBusy {
                            ProgressView(value: importProgress)
                            Text("Importing…").font(.caption).foregroundStyle(.secondary)
                        } else if checkingResources && onRefresh == nil {
                            ProgressView().controlSize(.small)
                        } else if let resourceStatus {
                            Text(resourceStatus).font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("startup.resources.status")
                        }
                        if model.lowMemoryEnabled {
                            Text(LocalizedStringKey(LauncherModel.lowMemoryNotice))
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("botw.low-memory.notice")
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .frame(width: geometry.size.width * 0.38, height: geometry.size.height)
                VStack(spacing: 0) {
                    HStack {
                        Text("Status").font(.headline)
                        Spacer()
                        Button(action: onSettings) { Label("Settings", systemImage: "gearshape") }
                            .accessibilityIdentifier("launcher.settings")
                    }.padding(.horizontal, 16).padding(.vertical, 10)
                    List {
                        Section("Resources") {
                            LabeledContent("ROMFS", value: romReady ? NSLocalizedString("Ready", comment: "Resource status") : NSLocalizedString("Not imported", comment: "Resource status"))
                                .accessibilityIdentifier("startup.status.romfs")
                            LabeledContent("DLC", value: dlcCount > 0 ? String(format: NSLocalizedString("%d available", comment: "DLC count"), dlcCount) : NSLocalizedString("Not present", comment: "DLC status"))
                                .accessibilityIdentifier("startup.status.dlc")
                            LabeledContent("Graphics package", value: shadersReady ? NSLocalizedString("Ready", comment: "Resource status") : NSLocalizedString("Not imported", comment: "Resource status"))
                                .accessibilityIdentifier("startup.status.graphics")
                        }
                        Section {
                            LabeledContent("Memory available", value: memoryBytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory) : NSLocalizedString("Unavailable", comment: "Resource status"))
                        }
                        AboutSection(graphicsVersion: graphicsVersion, graphicsMetal: graphicsCompiler, buildInfo: buildInfo)
                    }
                    #if os(macOS)
                    .listStyle(.inset)
                    #else
                    .listStyle(.insetGrouped)
                    .contentMargins(.horizontal, 12, for: .scrollContent)
                    #endif
                }
                .frame(width: geometry.size.width * 0.62)
            }
        }
        .alert("Touch controls", isPresented: $showTouchNotice) {
            Button("I know I can double-tap with three fingers") {
                model.acknowledgeTouchFallbackNotice()
                onPlay()
            }
        } message: {
            Text("Touch UI cannot cover every game screen. If a button does not respond, double-tap with three fingers to temporarily show the virtual gamepad and continue. Please report the issue to the developer.")
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var playButton: some View {
        let button = Button(action: startPlay) {
            Text("Play").font(.title3.weight(.semibold)).frame(maxWidth: 220)
        }.controlSize(.large).keyboardShortcut(.defaultAction)
        if #available(iOS 26.0, macOS 26.0, *) { button.buttonStyle(.glassProminent) }
        else { button.buttonStyle(.borderedProminent) }
    }

    private func startPlay() {
        if model.needsTouchFallbackNotice && shouldShowTouchNotice() { showTouchNotice = true }
        else { onPlay() }
    }
}

// Keep both columns visible on compact phones as well as larger displays.
struct LauncherSettingsPage: View {
    @ObservedObject var m: LauncherModel
    let close: () -> Void
    @State private var selection: String = "Game"
    @State private var touchPage: BotwTouchPage?
    #if os(macOS)
    @AppStorage("window.show") private var showLauncherAtLaunch = true
    #endif

    private var sections: [String] {
        var result = m.sections.filter { !LauncherModel.isTouchSection($0) }
        if m.touchStickResponse != nil { result.insert("Touch", at: min(2, result.count)) }
        result.append("Cloud saves")
        return result
    }

    private var sectionList: some View {
        #if os(macOS)
        List(sections, id: \.self, selection: Binding<String?>(get: { selection }, set: { if let section = $0 { selection = section } })) { section in
            HStack {
                Text(LocalizedStringKey(section))
                Spacer(minLength: 0)
                if section == selection { Image(systemName: "chevron.right").font(.caption) }
            }
            .contentShape(Rectangle())
            .tag(section)
            .accessibilityIdentifier("settings.section." + section)
        }
        #else
        List(sections, id: \.self) { section in
            Button { selection = section } label: {
                HStack {
                    Text(LocalizedStringKey(section))
                    Spacer(minLength: 0)
                    if section == selection { Image(systemName: "chevron.right").font(.caption) }
                }
                .foregroundStyle(section == selection ? Color.accentColor : Color.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.section." + section)
            .listRowBackground(section == selection ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    if touchPage != nil {
                        Button { touchPage = nil } label: { Label("Back", systemImage: "chevron.left") }
                            .accessibilityIdentifier("settings.back")
                    }
                    Text(LocalizedStringKey(touchPage?.rawValue ?? "Settings")).font(.headline)
                    Spacer()
                    Button("Done", action: close).accessibilityIdentifier("settings.done")
                }.padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                if let touchPage {
                    Group {
                        switch touchPage {
                        case .normal, .compact:
                            BotwTouchSettingsView(m: m, viewport: geometry.size, safeInsets: geometry.safeAreaInsets, portrait: touchPage == .compact)
                        case .stick:
                            BotwStickSettingsView(m: m)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("settings.touch.page." + touchPage.identifier)
                } else {
                    HStack(spacing: 0) {
                        sectionList
                            .listStyle(.sidebar)
                            .frame(width: min(220, max(140, geometry.size.width * 0.24)))
                            .accessibilityIdentifier("settings.sections")
                        Divider()
                        Form {
                            if selection == "Touch" {
                                BotwTouchSettingsMenu(m: m) { touchPage = $0 }
                            } else if selection == "Cloud saves" {
                                CloudSavesSection().disabled(m.isRunning)
                                if m.isRunning { Text("Applies next time you start the game.").font(.footnote).foregroundStyle(.secondary) }
                            } else {
                                Section(LocalizedStringKey(selection)) {
                                    ForEach(m.rows(in: selection)) { SettingRow(s: $0, m: m) }
                                    #if os(macOS)
                                    if selection == "Game" && ProcessInfo.processInfo.environment["DM_TOUCH_PREVIEW"] != "1" {
                                        Toggle("Show this window at launch", isOn: $showLauncherAtLaunch).toggleStyle(.checkbox)
                                    }
                                    #endif
                                }
                            }
                            if selection != "Touch" {
                                Section {
                                    Button("Reset to tested defaults") { m.reset() }.disabled(!m.changed)
                                }
                            }
                        }
                        .formStyle(.grouped)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("settings.options")
                    }
                }
            }
        }
        .onAppear { if !sections.contains(selection) { selection = sections.first ?? "Game" } }
        .accessibilityIdentifier("launcher.settings.page")
        .preferredColorScheme(.dark)
    }
}

// Build identity is shown at the bottom of both startup menus.
struct AboutSection: View {
    var graphicsVersion: String? = nil
    var graphicsMetal: String? = nil
    var buildInfo: [String: String] = [:]
    private func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? buildInfo[key] ?? "unknown"
    }

    static func shortCommit(_ commit: String) -> String {
        guard commit.range(of: "^[0-9a-fA-F]{6}", options: .regularExpression) != nil else { return "unknown" }
        return String(commit.prefix(6)) + (commit.hasSuffix("+dirty") ? "+dirty" : "")
    }

    static func localBuildTime(_ timestamp: String, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        guard let date = ISO8601DateFormatter().date(from: timestamp) else { return timestamp }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    var body: some View {
        Section("About") {
            LabeledContent("Repository", value: info("DMRepository"))
            LabeledContent("Commit", value: Self.shortCommit(info("DMCommit")))
            LabeledContent("Built", value: Self.localBuildTime(info("DMBuildTime")))
            if let version = graphicsVersion { LabeledContent("Graphics package", value: "v" + version) }
            if let metal = graphicsMetal { LabeledContent("Metal compiler", value: metal) }
        }
        .accessibilityIdentifier("nxnative.about")
    }
}
