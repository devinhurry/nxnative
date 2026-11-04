// Shared launcher dashboard, settings pages and rows for the iOS and native Mac wrappers.
// A row whose setting is fixed by an env file or by the launch environment is shown but disabled.
import SwiftUI
import DmTouchPad

let launcherTint = Color(red: 66.0 / 255, green: 102.0 / 255, blue: 134.0 / 255)

// Only the game process links the frame-capture adapter; the standalone Mac launcher does not.
#if os(iOS) || DM_HOST_UI
func withGameSettingsBackground(_ complete: @escaping (Image?) -> Void) {
    var delivered = false
    let finish: (Image?) -> Void = { image in
        guard !delivered else { return }
        delivered = true
        complete(image)
    }
    dm_launcher_grab_game_frame { image in
        let background = image.map { Image(decorative: $0, scale: 1) }
        DispatchQueue.main.async { finish(background) }
    }
    // A game that has stopped presenting must still allow settings to open.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finish(nil) }
}
#endif

extension LauncherModel {
    func binding(_ s: Setting) -> Binding<String> { Binding(get: { self.values[s.env] ?? s.def }, set: { self.setValue($0, for: s) }) }
}

struct SettingRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel
    @State private var moreFrameRates: Bool? = nil

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
                .disabled(!m.canEnableFrameGeneration)
            case "choice" where s.env == "DM_FPS_TARGET":
                frameRateRow
            case "choice":
                choices.pickerStyle(.menu)
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

    private var frameRateRow: some View {
        let value = m.values[s.env] ?? s.def
        let extended = (s.options?.count ?? 0) > 2
        let expanded = moreFrameRates ?? !["30", "60"].contains(value)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                settingLabel
                Spacer(minLength: 4)
                if extended {
                    HStack(spacing: 4) {
                        ForEach(["30", "60"], id: \.self) { rate in
                            Button { m.setValue(rate, for: s) } label: {
                                Text(rate).monospacedDigit().frame(minWidth: 24)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .tint(value == rate ? launcherTint : .secondary)
                            .accessibilityLabel("\(rate) fps")
                            .accessibilityIdentifier("DM_FPS_TARGET.\(rate)")
                        }
                        Button {
                            withAnimation { moreFrameRates = !expanded }
                        } label: {
                            HStack(spacing: 3) {
                                Text("More frame rates")
                                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            }.font(.caption).fixedSize()
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("DM_FPS_TARGET.more")
                    }
                } else {
                    choices.labelsHidden().pickerStyle(.segmented).frame(width: 180)
                }
            }
            if extended && expanded {
                HStack {
                    Slider(value: Binding(get: { Double(m.values[s.env] ?? s.def) ?? 30 },
                                          set: { m.setValue(String(Int($0.rounded())), for: s) }),
                           in: 20...120, step: 5)
                        .accessibilityLabel(Text("Frame rate"))
                        .accessibilityValue("\(value) fps")
                        .accessibilityIdentifier("DM_FPS_TARGET.slider")
                    Text("\(value) fps").monospacedDigit().font(.subheadline).frame(minWidth: 58, alignment: .trailing)
                }
                Text("Frame generation is unavailable above 60 fps.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(s.env)
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
                        if !model.touchSettingsKeys.isEmpty {
                            Text("BOTW creator notice").font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4), lineWidth: 1))
                            .accessibilityIdentifier("startup.botw.creator")
                        }
                        playButton.disabled(importBusy || checkingResources || model.saveOperationBusy || !romReady || !shadersReady)
                        if !romReady || !shadersReady {
                            HStack(spacing: 8) {
                                if !romReady, let onImportROM {
                                    Button("Import ROM", action: onImportROM)
                                        .accessibilityIdentifier("startup.import.rom")
                                        .buttonStyle(.bordered).disabled(importBusy || checkingResources)
                                }
                                if !shadersReady, let onImportShaders {
                                    Button("Import graphics", action: onImportShaders)
                                        .accessibilityIdentifier("startup.import.shaders")
                                        .buttonStyle(.bordered).disabled(importBusy || checkingResources)
                                }
                            }
                            if importBusy {
                                ProgressView(value: importProgress)
                                Text("Importing…").font(.caption).foregroundStyle(.secondary)
                            } else if checkingResources && onRefresh == nil {
                                ProgressView().controlSize(.small)
                            }
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
                        if let language = model.settings.first(where: { $0.env == "DM_LANG" }) {
                            Picker("Game language", selection: model.binding(language)) {
                                ForEach(language.options ?? [], id: \.[0]) { Text(LocalizedStringKey($0[1])).tag($0[0]) }
                            }.pickerStyle(.menu).labelsHidden()
                                .disabled(model.lockingKey(language) != nil)
                                .accessibilityLabel("Game language")
                                .accessibilityIdentifier("launcher.language")
                        }
                        Spacer()
                        Button(action: onSettings) { Label("Settings", systemImage: "gearshape") }
                            .accessibilityIdentifier("launcher.settings")
                    }.padding(.horizontal, 16).padding(.vertical, 10)
                    List {
                        Section {
                            LabeledContent("ROMFS") { readiness(romReady) }
                                .accessibilityIdentifier("startup.status.romfs")
                            LabeledContent("DLC") {
                                HStack {
                                    Text(dlcCount > 0 ? String(format: NSLocalizedString("%d available", comment: "DLC count"), dlcCount) : NSLocalizedString("Not present", comment: "DLC status"))
                                    readiness(dlcCount > 0)
                                }
                            }
                                .accessibilityIdentifier("startup.status.dlc")
                            LabeledContent("Graphics package") { readiness(shadersReady) }
                                .accessibilityIdentifier("startup.status.graphics")
                        } header: {
                            HStack {
                                Text("Resources")
                                Spacer()
                                if let onRefresh {
                                    Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                                        .buttonStyle(.borderless).disabled(importBusy || checkingResources)
                                        .accessibilityLabel("Refresh").accessibilityIdentifier("startup.resources.refresh")
                                }
                                if checkingResources { ProgressView().controlSize(.mini) }
                            }
                        } footer: {
                            if let resourceStatus {
                                Text(resourceStatus).font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("startup.resources.status")
                            }
                        }
                        Section {
                            LabeledContent("Memory available") {
                                HStack {
                                    if memoryBytes > 0 && memoryBytes < dm_low_memory_threshold() {
                                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                                            .accessibilityLabel("Low available memory")
                                    }
                                    Text(memoryBytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory) : NSLocalizedString("Unavailable", comment: "Resource status"))
                                }
                            }
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
        .tint(launcherTint).accentColor(launcherTint)
    }

    private func readiness(_ ready: Bool) -> some View {
        Image(systemName: ready ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(ready ? Color.green : Color.red)
            .accessibilityLabel(Text(LocalizedStringKey(ready ? "Ready" : "Not imported")))
    }

    @ViewBuilder
    private var playButton: some View {
        let button = Button(action: startPlay) {
            Text("Play").font(.title3.weight(.semibold)).frame(maxWidth: 220)
        }.controlSize(.large).keyboardShortcut(.defaultAction)
            .tint(launcherTint).foregroundStyle(.white)
        if #available(iOS 26.0, macOS 26.0, *) { button.buttonStyle(.glassProminent) }
        else { button.buttonStyle(.borderedProminent) }
    }

    private func startPlay() {
        guard !model.saveOperationBusy else { return }
        if model.needsTouchFallbackNotice && shouldShowTouchNotice() { showTouchNotice = true }
        else { onPlay() }
    }
}

// Keep both columns visible on compact phones as well as larger displays.
struct LauncherSettingsPage: View {
    @ObservedObject var m: LauncherModel
    var gameBackground: Image? = nil
    var onPlay: (() -> Void)? = nil
    let close: () -> Void
    @State private var selection: String = "Game"
    @State private var touchPage: BotwTouchPage?
    #if os(macOS)
    @AppStorage("window.show") private var showLauncherAtLaunch = true
    #endif

    private var sections: [String] {
        var result = m.sections.filter { !LauncherModel.isTouchSection($0) && $0 != "General" }
        if m.touchStickResponse != nil && !result.contains("Controls") { result.insert("Controls", at: min(2, result.count)) }
        result.append("Saves")
        result.append("General")
        return result
    }

    private func sectionTitle(_ section: String) -> String { section == "Game" ? "Graphics" : section }

    private var sectionList: some View {
        #if os(macOS)
        List(sections, id: \.self, selection: Binding<String?>(get: { selection }, set: { if let section = $0 { selection = section } })) { section in
            HStack {
                Text(LocalizedStringKey(sectionTitle(section)))
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
                    Text(LocalizedStringKey(sectionTitle(section)))
                    Spacer(minLength: 0)
                    if section == selection { Image(systemName: "chevron.right").font(.caption) }
                }
                .foregroundStyle(section == selection ? launcherTint : Color.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.section." + section)
            .listRowBackground(section == selection ? launcherTint.opacity(0.12) : Color.clear)
        }
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            if let touchPage, touchPage != .stick {
                BotwTouchSettingsView(m: m, portrait: touchPage == .compact, background: gameBackground,
                                      play: m.isRunning ? close : onPlay) { self.touchPage = nil }
                    .id(touchPage)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings.touch.page." + touchPage.identifier)
            } else {
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
                    BotwStickSettingsView(m: m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("settings.touch.page." + touchPage.identifier)
                } else {
                    HStack(spacing: 0) {
                        sectionList
                            .listStyle(.sidebar)
                            .frame(width: min(220, max(140, geometry.size.width * 0.24)))
                            .accessibilityIdentifier("settings.sections")
                        Divider()
                        Group {
                            if selection == "Saves" {
                                SaveManagementPage(launcher: m)
                            } else { Form {
                                if selection == "Controls" && m.touchStickResponse != nil {
                                    BotwTouchSettingsMenu(m: m) { touchPage = $0 }
                                }
                                Section(LocalizedStringKey(sectionTitle(selection))) {
                                    let rows = m.rows(in: selection)
                                    ForEach(rows.filter { $0.env == "DM_SHOW_FPS" } + rows.filter { $0.env != "DM_SHOW_FPS" }) { SettingRow(s: $0, m: m) }
                                    #if os(macOS)
                                    if selection == "Game" && ProcessInfo.processInfo.environment["DM_TOUCH_PREVIEW"] != "1" {
                                        Toggle("Show this window at launch", isOn: $showLauncherAtLaunch).toggleStyle(.checkbox)
                                    }
                                    #endif
                                }
                            Section {
                                Button("Reset to tested defaults") { m.reset() }.disabled(!m.changed)
                            }
                            } }
                        }
                        .formStyle(.grouped)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("settings.options")
                    }
                }
            }
            }
        }
        .onAppear { if !sections.contains(selection) { selection = sections.first ?? "Game" } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("launcher.settings.page")
        .preferredColorScheme(.dark)
        .tint(launcherTint).accentColor(launcherTint)
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
            LabeledContent("Commit", value: Self.shortCommit(info("DMCommit")))
            LabeledContent("Built", value: Self.localBuildTime(info("DMBuildTime")))
            if let version = graphicsVersion { LabeledContent("Graphics package", value: "v" + version) }
            if let metal = graphicsMetal { LabeledContent("Metal compiler", value: metal) }
        }
        .accessibilityIdentifier("nxnative.about")
    }
}
