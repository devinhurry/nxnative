// Shared launcher dashboard, settings pages and rows for the iOS and native Mac wrappers.
// A row whose setting is fixed by an env file or by the launch environment is shown but disabled.
import SwiftUI
import Darwin
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import DmTouchPad
import UniformTypeIdentifiers

private func launcherColor(light: UInt32, dark: UInt32) -> Color {
    #if os(macOS)
    return Color(nsColor: NSColor(name: nil) { appearance in
        let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    })
    #else
    return Color(uiColor: UIColor { traits in
        let rgb = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    })
    #endif
}

let launcherTint = launcherColor(light: 0x5365c5, dark: 0x8995ed)
let launcherSettingsBackground = launcherColor(light: 0xf2f2f7, dark: 0x090a0f)
let launcherSettingsSidebar = launcherColor(light: 0xf2f2f7, dark: 0x0d0e14)
let launcherSettingsGroup = launcherColor(light: 0xffffff, dark: 0x1b1c22)

struct SettingsInfoButton: View {
    let title: String
    let message: String
    let id: String
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }.buttonStyle(.borderless).accessibilityLabel("Show explanation")
            .accessibilityHint(Text(LocalizedStringKey(title))).accessibilityIdentifier(id + ".help")
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(LocalizedStringKey(title)).font(.headline)
                    Text(message).font(.callout).textSelection(.enabled).accessibilityIdentifier(id + ".help.text")
                }.padding(20).frame(idealWidth: 280, maxWidth: 340, alignment: .leading)
                    .presentationCompactAdaptation(.popover)
            }
    }
}

#if os(macOS)
private struct SettingsSidebarHighlight: NSViewRepresentable {
    final class AttachmentView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyStyle() }
        func applyStyle() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    // The row draws its tint; native selection still handles keyboard navigation.
                    table.selectionHighlightStyle = .none
                    return
                }
                ancestor = view.superview
            }
        }
    }
    func makeNSView(context: Context) -> AttachmentView { AttachmentView() }
    func updateNSView(_ view: AttachmentView, context: Context) { view.applyStyle() }
}
#endif

// Only the game process links the frame-capture adapter; the standalone Mac launcher does not.
#if os(iOS) || DM_HOST_UI
func withGameSettingsBackground(_ model: LauncherModel, _ complete: @escaping (Image?) -> Void) {
    var delivered = false
    model.picturePreviewFrame = nil
    let finish: (Image?) -> Void = { image in
        guard !delivered else { return }
        delivered = true
        complete(image)
    }
    dm_launcher_grab_filter_frame { image in
        DispatchQueue.main.async {
            guard !delivered else { return }
            model.picturePreviewFrame = image
            guard let image else { finish(nil); return }
            let mode = model.values["DM_PRESENT_FILTER"] ?? "off"
            let strength = Float(model.values["DM_PRESENT_FILTER_STRENGTH"] ?? "1") ?? 1
            DispatchQueue.global(qos: .userInitiated).async {
                let filtered = dm_launcher_filter_preview(image, mode, strength, 1280) ?? image
                DispatchQueue.main.async { finish(Image(decorative: filtered, scale: 1)) }
            }
        }
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
        var text = NSLocalizedString(s.note, comment: "Launcher setting description")
        if s.env == "DM_FPS_TARGET" {
            text += (text.isEmpty ? "" : "\n\n") + NSLocalizedString("Frame generation is unavailable above 60 fps.", comment: "Frame rate limit")
        }
        guard locked else { return text }
        return (text.isEmpty ? "" : text + " · ") + NSLocalizedString(m.fromLaunch.contains(m.lockingKey(s) ?? s.env) ? "Set at launch" : "Set by an env file", comment: "Locked launcher setting")
    }
    private var rangeValue: Binding<Double> {
        Binding(get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 },
                set: { m.setValue(String(format: "%.2f", $0), for: s) })
    }
    private var percentage: String { m.rangeLabel(s, rangeValue.wrappedValue) }

    @ViewBuilder private var timingLabel: some View {
        if m.isRunning && !locked {
            Text(LocalizedStringKey(m.appliesImmediately(s) ? "Applies immediately" : "After restart"))
                .font(.caption).foregroundStyle(.secondary).fixedSize()
                .accessibilityIdentifier(s.env + ".timing")
        }
    }

    private var settingLabel: some View {
        HStack(spacing: 6) {
            Text(LocalizedStringKey(s.label))
            if !note.isEmpty {
                SettingsInfoButton(title: s.label, message: note, id: s.env)
            }
        }
    }

    var body: some View {
        Group {
            switch s.kind {
            case "choice" where s.env == "DM_FRAMEGEN":
                HStack {
                    settingLabel
                    Spacer()
                    timingLabel
                    Toggle(LocalizedStringKey(s.label), isOn: Binding(get: { m.frameGenerationEnabled }, set: { enabled in
                        m.setValue(enabled ? (m.values["DM_FPS_TARGET"] ?? "60") : "0", for: s)
                    })).labelsHidden()
                        .accessibilityIdentifier(s.env)
                        .accessibilityLabel(Text(LocalizedStringKey(s.label)))
                        .accessibilityHint(note)
                        .disabled(locked || !m.canEnableFrameGeneration)
                }
            case "choice" where s.env == "DM_FPS_TARGET":
                frameRateRow
            case "choice":
                choiceRow
            case "range":
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        settingLabel
                        Spacer()
                        timingLabel
                        Text(percentage).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: rangeValue, in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05)
                        .disabled(locked)
                        .accessibilityLabel(Text(LocalizedStringKey(s.label)))
                        .accessibilityValue(percentage)
                        .accessibilityIdentifier(s.env)
                }
            default:
                HStack {
                    settingLabel
                    Spacer()
                    timingLabel
                    Toggle(LocalizedStringKey(s.label), isOn: Binding(get: { (m.values[s.env] ?? s.def) == s.onValue }, set: { m.setValue($0 ? s.onValue : s.offValue, for: s) }))
                        .labelsHidden().disabled(locked)
                        .accessibilityLabel(Text(LocalizedStringKey(s.label)))
                        .accessibilityHint(note).accessibilityIdentifier(s.env)
                }
            }
        }
    }

    @ViewBuilder private var choiceRow: some View {
        if (2...4).contains(s.options?.count ?? 0) {
            ViewThatFits(in: .horizontal) {
                HStack { settingLabel; Spacer(minLength: 16); timingLabel; choices.pickerStyle(.segmented).fixedSize() }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { settingLabel; Spacer(minLength: 4); timingLabel }
                    choices.pickerStyle(.segmented)
                }
            }
        } else {
            HStack { settingLabel; Spacer(); timingLabel; choices.pickerStyle(.menu).fixedSize() }
        }
    }

    private var frameRateRow: some View {
        let value = m.values[s.env] ?? s.def
        let extended = (s.options?.count ?? 0) > 2
        let expanded = moreFrameRates ?? !["30", "60"].contains(value)
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { settingLabel; Spacer(minLength: 4); timingLabel; frameRateControls(value: value, extended: extended, expanded: expanded).fixedSize() }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { settingLabel; Spacer(minLength: 4); timingLabel }
                    frameRateControls(value: value, extended: extended, expanded: expanded)
                }
            }
            if extended && expanded {
                HStack {
                    Slider(value: Binding(get: { Double(m.values[s.env] ?? s.def) ?? 30 },
                                          set: { m.setValue(String(Int($0.rounded())), for: s) }),
                           in: 20...120, step: 5)
                        .disabled(locked)
                        .accessibilityLabel(Text("Frame rate"))
                        .accessibilityValue("\(value) fps")
                        .accessibilityIdentifier("DM_FPS_TARGET.slider")
                    Text("\(value) fps").monospacedDigit().font(.subheadline).frame(minWidth: 58, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(s.env)
    }

    @ViewBuilder private func frameRateControls(value: String, extended: Bool, expanded: Bool) -> some View {
        if extended {
            HStack(spacing: 4) {
                ForEach(["30", "60"], id: \.self) { rate in
                    Button { m.setValue(rate, for: s) } label: {
                        Text(rate).monospacedDigit().frame(minWidth: 24)
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(locked)
                    .tint(value == rate ? launcherTint : .secondary)
                    .accessibilityLabel("\(rate) fps").accessibilityIdentifier("DM_FPS_TARGET.\(rate)")
                }
                Button { withAnimation { moreFrameRates = !expanded } } label: {
                    HStack(spacing: 3) {
                        Text("More frame rates")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }.font(.caption).fixedSize()
                }.buttonStyle(.borderless).accessibilityIdentifier("DM_FPS_TARGET.more")
            }
        } else {
            choices.pickerStyle(.segmented).frame(maxWidth: 180)
        }
    }

    private var choices: some View {
        Picker(selection: m.binding(s)) {
            ForEach(s.options ?? [], id: \.[0]) { Text(LocalizedStringKey($0[1])).tag($0[0]) }
        } label: { Text(LocalizedStringKey(s.label)) }
        .labelsHidden().disabled(locked).accessibilityLabel(Text(LocalizedStringKey(s.label)))
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
    let onSaves: () -> Void
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
                            Button(action: onSaves) {
                                HStack {
                                    Label("Manage saves", systemImage: "folder")
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("launcher.saves")
                        }
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
                            LabeledContent("Memory available") {
                                HStack {
                                    if memoryBytes > 0 && memoryBytes < dm_low_memory_threshold() {
                                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                                            .accessibilityLabel("Low available memory")
                                    }
                                    Text(memoryBytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory) : NSLocalizedString("Unavailable", comment: "Resource status"))
                                }
                            }
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
        guard !model.saveOperationBusy, !model.saveSelectionPending else { return }
        if model.needsTouchFallbackNotice && shouldShowTouchNotice() { showTouchNotice = true }
        else { onPlay() }
    }
}

enum LauncherSettingsDestination: String, Identifiable {
    case graphics = "Game", saves = "Saves"
    var id: String { rawValue }
}

// Keep both columns visible on compact phones as well as larger displays.
struct LauncherSettingsPage: View {
    @ObservedObject var m: LauncherModel
    @Environment(\.colorScheme) private var colorScheme
    var gameBackground: Image? = nil
    var onPlay: (() -> Void)? = nil
    let close: () -> Void
    @State private var selection: String = "Game"
    @State private var touchPage: BotwTouchPage?
    @State private var pictureFilterPage = false
    #if os(macOS)
    @AppStorage("window.show") private var showLauncherAtLaunch = true
    #endif

    init(m: LauncherModel, gameBackground: Image? = nil, initialSection: String = "Game",
         onPlay: (() -> Void)? = nil, close: @escaping () -> Void) {
        self.m = m
        self.gameBackground = gameBackground
        self.onPlay = onPlay
        self.close = close
        _selection = State(initialValue: initialSection)
    }

    private var sections: [String] {
        var result = m.sections.filter { !LauncherModel.isTouchSection($0) && $0 != "General" }
        if m.touchStickResponse != nil && !result.contains("Controls") { result.insert("Controls", at: min(2, result.count)) }
        result.append("Saves")
        result.append("General")
        return result
    }

    private func sectionTitle(_ section: String) -> String { section == "Game" ? "Graphics" : section }
    private var detailTitle: String { selection == "Saves" ? "Save settings" : sectionTitle(selection) }

    private func sectionIcon(_ section: String) -> String {
        switch section {
        case "Game": return "display"
        case "Controls": return "gamecontroller"
        case "Performance": return "speedometer"
        case "Audio": return "speaker.wave.2"
        case "Touch": return "hand.tap"
        case "Saves": return "externaldrive"
        case "General": return "gearshape"
        default: return "slider.horizontal.3"
        }
    }

    // Keep this row separate so SwiftUI does not infer it with the whole settings page.
    private func pictureFilterRow(_ row: Setting) -> some View {
        let mode = m.values[row.env] ?? "off"
        let name: String
        if mode == "custom", let lutName = m.pictureLUTName {
            name = lutName
        } else {
            let key = row.options?.first { $0[0] == mode }?[1] ?? "Original"
            name = NSLocalizedString(key, comment: "Filter name")
        }
        return Button { pictureFilterPage = true } label: {
            HStack {
                Text(LocalizedStringKey(row.label))
                Spacer()
                Text(verbatim: name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.right").font(.caption)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("DM_PRESENT_FILTER")
    }

    private var settingsRows: [Setting] {
        let rows = m.rows(in: selection).filter { $0.env != "DM_PRESENT_FILTER_STRENGTH" }
        return rows.filter { $0.env == "DM_SHOW_FPS" } + rows.filter { $0.env != "DM_SHOW_FPS" }
    }

    @ViewBuilder private func settingOption(_ row: Setting) -> some View {
        if row.env == "DM_PRESENT_FILTER" {
            pictureFilterRow(row)
        } else {
            SettingRow(s: row, m: m)
        }
    }

    private var settingsForm: some View {
        Form {
            if selection == "Controls" && m.touchStickResponse != nil {
                BotwTouchSettingsMenu(m: m) { touchPage = $0 }
            }
            Section {
                ForEach(settingsRows, content: settingOption)
                #if os(macOS)
                if selection == "Game" && ProcessInfo.processInfo.environment["DM_TOUCH_PREVIEW"] != "1" {
                    Toggle("Show this window at launch", isOn: $showLauncherAtLaunch).toggleStyle(.checkbox)
                }
                #endif
            }.listRowBackground(launcherSettingsGroup)
            Section {
                Button("Reset to tested defaults") { m.reset() }.disabled(!m.changed)
            }
        }
    }

    private var settingsOptions: some View {
        Group {
            if selection == "Saves" {
                SaveManagementPage(launcher: m)
            } else {
                settingsForm
            }
        }
        .formStyle(.grouped)
        .contentMargins(.top, selection == "Controls" ? nil : 8, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(launcherSettingsBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("settings.options")
    }

    private func sectionLabel(_ section: String, compact: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: sectionIcon(section)).font(.title3).frame(width: 24)
            if !compact {
                Text(LocalizedStringKey(sectionTitle(section))).font(.headline).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).opacity(section == selection ? 1 : 0.4)
            }
        }
        .foregroundStyle(section == selection ? (colorScheme == .dark ? Color.black : Color.white) : Color.primary)
        .padding(.horizontal, 14).padding(.vertical, 14)
        .contentShape(Rectangle())
        .background(section == selection ? launcherTint : launcherSettingsGroup, in: RoundedRectangle(cornerRadius: 12))
        .background(launcherSettingsSidebar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringKey(sectionTitle(section))))
        .accessibilityIdentifier("settings.section." + section)
    }

    private func sectionList(compact: Bool) -> some View {
        Group {
        #if os(macOS)
        List(sections, id: \.self, selection: Binding<String?>(get: { selection }, set: { if let section = $0 { selection = section } })) { section in
            sectionLabel(section, compact: compact).tag(section)
                .background(SettingsSidebarHighlight())
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
        }
        #else
        List(sections, id: \.self) { section in
            Button { selection = section } label: { sectionLabel(section, compact: compact) }
                .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
        }
        #endif
        }
        .listStyle(.plain)
        .contentMargins(.horizontal, compact ? 8 : 16, for: .scrollContent)
        #if os(iOS)
        .listRowSpacing(2)
        #endif
        .scrollContentBackground(.hidden)
    }

    private var detailHeader: some View {
        HStack {
            Text(LocalizedStringKey(detailTitle)).font(.title3.weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Button("Done", action: close).font(.headline).buttonStyle(.plain)
                .foregroundStyle(launcherTint).frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("settings.done")
        }.padding(.horizontal, 24).frame(height: 64)
    }

    var body: some View {
        GeometryReader { geometry in
            if pictureFilterPage {
                PictureFilterSettingsView(m: m, close: close) { pictureFilterPage = false }
            } else if let touchPage, touchPage != .stick {
                BotwTouchSettingsView(m: m, portrait: touchPage == .compact, background: gameBackground,
                                      play: m.isRunning ? close : onPlay) { self.touchPage = nil }
                    .id(touchPage)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings.touch.page." + touchPage.identifier)
            } else {
            let compact = geometry.size.width < 600
            VStack(spacing: 0) {
                if let touchPage {
                    HStack {
                        Button { self.touchPage = nil } label: { Label("Back", systemImage: "chevron.left") }
                            .accessibilityIdentifier("settings.back")
                        Text(LocalizedStringKey(touchPage.rawValue)).font(.headline)
                        Spacer()
                        Button("Done", action: close).accessibilityIdentifier("settings.done")
                    }.padding(.horizontal, 24).frame(height: 64)
                    Divider()
                    BotwStickSettingsView(m: m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("settings.touch.page." + touchPage.identifier)
                } else {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Group {
                                if compact { Image(systemName: "gearshape").font(.title2).accessibilityLabel("Settings") }
                                else { Text("Settings").font(.title2.bold()) }
                            }.padding(.horizontal, compact ? 18 : 20).frame(height: 64)
                            sectionList(compact: compact).accessibilityIdentifier("settings.sections")
                        }.frame(width: compact ? 80 : min(250, geometry.size.width * 0.26))
                            .background(launcherSettingsSidebar)
                        Divider()
                        VStack(spacing: 0) { detailHeader; settingsOptions }
                    }
                }
            }
            }
        }
        .onAppear { if !sections.contains(selection) { selection = sections.first ?? "Game" } }
        .onDisappear { m.picturePreviewFrame = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("launcher.settings.page")
        .background(launcherSettingsBackground)
        .tint(launcherTint).accentColor(launcherTint)
    }
}

// Full-canvas editor, using one ungraded snapshot from the settings-open frame.
// Preview jobs never modify the live filter choice to render their thumbnails.
struct PictureFilterSettingsView: View {
    @ObservedObject var m: LauncherModel
    let close: () -> Void
    let back: () -> Void
    @State private var preview: CGImage?
    @State private var thumbnails: [String: CGImage] = [:]
    @State private var comparing = false
    @State private var importingLUT = false
    @State private var lutError: String?
    @State private var lutToRemove: PictureLUT?
    @State private var controlsVisible = true
    @ScaledMetric(relativeTo: .caption) private var captionHeight: CGFloat = 14

    private var filter: Setting? { m.settings.first { $0.env == "DM_PRESENT_FILTER" } }
    private var strengthRow: Setting? { m.settings.first { $0.env == "DM_PRESENT_FILTER_STRENGTH" } }
    private var mode: String { m.values["DM_PRESENT_FILTER"] ?? "off" }
    private var strength: Float { Float(m.values["DM_PRESENT_FILTER_STRENGTH"] ?? "1") ?? 1 }
    private var thumbnailID: String { "\(strength)-\(m.pictureLUTs.map(\.id).joined(separator: ","))" }
    private var previewID: String { "\(mode)-\(m.selectedPictureLUTID ?? "")-\(strength)-\(comparing)" }
    private var cardBarHeight: CGFloat {
        // macOS can reserve a legacy scroller gutter only when the row overflows.
        #if os(macOS)
        return 63 + captionHeight + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        #else
        return 63 + captionHeight
        #endif
    }

    private func render(_ image: CGImage, mode: String, width: Int, lutPath: String? = nil) async -> CGImage? {
        #if os(iOS) || DM_HOST_UI
        let amount = strength
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result: CGImage?
                if let lutPath { result = dm_launcher_lut_preview(image, lutPath, amount, Int32(width)) }
                else { result = dm_launcher_filter_preview(image, mode, amount, Int32(width)) }
                continuation.resume(returning: result)
            }
        }
        #else
        return nil   // The standalone launcher has no running game picture.
        #endif
    }

    private func card(id: String, name: String, selected: Bool = false, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Group {
                    if let symbol {
                        Rectangle().fill(.secondary.opacity(0.15))
                            .overlay { Image(systemName: symbol).font(.system(size: 30, weight: .light)) }
                    } else if let image = thumbnails[id] {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    } else { Rectangle().fill(.secondary.opacity(0.15)).overlay { Image(systemName: "photo") } }
                }
                .frame(width: 96, height: 54).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? launcherTint : .clear, lineWidth: 3))
                Text(name).font(.caption).lineLimit(1).truncationMode(.middle).frame(height: captionHeight)
            }.frame(width: 96)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private var filterCards: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach((filter?.options ?? []).filter { $0[0] != "custom" }, id: \.[0]) { option in
                    card(id: "pictureFilter." + option[0], name: NSLocalizedString(option[1], comment: "Filter name"), selected: mode == option[0]) {
                        comparing = false
                        if let filter { m.setValue(option[0], for: filter) }
                    }.disabled(filter.map { m.lockingKey($0) != nil } ?? true)
                }
                ForEach(m.pictureLUTs) { lut in
                    ZStack(alignment: .topTrailing) {
                        card(id: "pictureLUT." + lut.id, name: lut.name, selected: mode == "custom" && m.selectedPictureLUTID == lut.id) {
                            do { try m.selectPictureLUT(lut.id); comparing = false }
                            catch { lutError = error.localizedDescription }
                        }.disabled(filter.map { m.lockingKey($0) != nil } ?? true)
                        Button(role: .destructive) { lutToRemove = lut } label: {
                            Image(systemName: "trash").font(.system(size: 12, weight: .semibold))
                                .frame(width: 26, height: 26).background(Color.black.opacity(0.55), in: Circle())
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain).disabled(m.pictureLUTLocked)
                        .accessibilityLabel("Remove LUT").accessibilityIdentifier("pictureLUT.remove." + lut.id)
                    }.accessibilityElement(children: .contain)
                }
                card(id: "pictureLUT.import", name: NSLocalizedString("Custom LUT", comment: "Filter name"), symbol: "plus") { importingLUT = true }
                    .disabled(m.pictureLUTLocked).accessibilityLabel("Import .cube…")
            }.padding(3).frame(maxHeight: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
        .frame(height: cardBarHeight)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = comparing ? m.picturePreviewFrame : preview ?? m.picturePreviewFrame {
                GeometryReader { canvas in
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .frame(width: canvas.size.width, height: canvas.size.height).clipped()
                        .accessibilityLabel("Current game picture").accessibilityIdentifier("pictureFilter.image")
                }.ignoresSafeArea()
            } else {
                ContentUnavailableView("Current picture preview", systemImage: "photo",
                                       description: Text("Start the game to preview its current picture."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            HStack {
                Button(action: back) { Label("Back", systemImage: "chevron.left") }
                    .accessibilityIdentifier("pictureFilter.back")
                Text("Picture filter").font(.headline)
                Spacer(minLength: 4)
                Button { comparing.toggle() } label: { Image(systemName: comparing ? "circle.fill" : "circle.lefthalf.filled") }
                    .accessibilityLabel("Compare original")
                    .accessibilityAddTraits(comparing ? .isSelected : [])
                    .accessibilityIdentifier("pictureFilter.compare")
                Button { controlsVisible.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel(controlsVisible ? "Hide controls" : "Show controls")
                Button("Done", action: close)
            }
            .font(.subheadline).buttonStyle(.borderless).padding(12)
            .background(Color.black.opacity(0.45).ignoresSafeArea(edges: [.top, .horizontal]))
            .accessibilityIdentifier("pictureFilter.navigation")
        }
        .overlay(alignment: .bottom) {
            if controlsVisible {
                VStack(alignment: .leading, spacing: 4) {
                    if let strengthRow {
                        HStack {
                            Text("Filter strength")
                            Slider(value: Binding(get: { Double(strength) }, set: { m.setValue(String(format: "%.2f", $0), for: strengthRow) }), in: 0...1, step: 0.01)
                                .accessibilityLabel("Filter strength").accessibilityIdentifier(strengthRow.env)
                                .disabled(m.lockingKey(strengthRow) != nil)
                            Text("\(Int((strength * 100).rounded()))%").monospacedDigit().frame(width: 44)
                        }.font(.caption)
                    }
                    filterCards
                }.padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
                    .background(Color.black.opacity(0.45).ignoresSafeArea(edges: [.bottom, .horizontal]))
                    .accessibilityIdentifier("pictureFilter.controls")
            }
        }
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
        .tint(.white).accentColor(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pictureFilter.editor")
        .task(id: previewID) {
            guard let source = m.picturePreviewFrame else { return }
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled else { return }
            let lutPath = mode == "custom" ? m.pictureLUTs.first { $0.id == m.selectedPictureLUTID }.map { m.pictureLUTPath(for: $0) } : nil
            let image = comparing ? source : await render(source, mode: mode, width: 1280, lutPath: lutPath)
            guard !Task.isCancelled else { return }
            preview = image
        }
        .task(id: thumbnailID) {
            guard let source = m.picturePreviewFrame else { return }
            try? await Task.sleep(for: .milliseconds(60))
            for option in (filter?.options ?? []).filter({ $0[0] != "custom" }) {
                guard !Task.isCancelled else { return }
                let image = await render(source, mode: option[0], width: 224)
                guard !Task.isCancelled else { return }
                thumbnails["pictureFilter." + option[0]] = image
            }
            for lut in m.pictureLUTs {
                guard !Task.isCancelled else { return }
                let image = await render(source, mode: "custom", width: 224, lutPath: m.pictureLUTPath(for: lut))
                guard !Task.isCancelled else { return }
                thumbnails["pictureLUT." + lut.id] = image
            }
            let ids = Set(m.pictureLUTs.map { "pictureLUT." + $0.id })
            thumbnails = thumbnails.filter { $0.key.hasPrefix("pictureFilter.") || ids.contains($0.key) }
        }
        .fileImporter(isPresented: $importingLUT, allowedContentTypes: [UTType(filenameExtension: "cube", conformingTo: .data) ?? .data]) { result in
            do { try m.importPictureLUT(from: result.get()) }
            catch { if (error as NSError).code != NSUserCancelledError { lutError = error.localizedDescription } }
        }
        .alert("Unable to import LUT", isPresented: Binding(get: { lutError != nil }, set: { if !$0 { lutError = nil } })) {
            Button("OK", role: .cancel) { lutError = nil }
        } message: { Text(lutError ?? "") }
        .alert("Remove LUT?", isPresented: Binding(get: { lutToRemove != nil }, set: { if !$0 { lutToRemove = nil } }), presenting: lutToRemove) { lut in
            Button("Remove LUT", role: .destructive) { m.removePictureLUT(lut.id); lutToRemove = nil }
            Button("Cancel", role: .cancel) { lutToRemove = nil }
        } message: { lut in Text(verbatim: lut.name) }
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

    private static let deviceAndSystem: String = {
        #if os(iOS)
        let key = "hw.machine"
        var model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? UIDevice.current.model
        let system = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : UIDevice.current.systemName
        let version = UIDevice.current.systemVersion
        #else
        let key = "hw.model"
        var model = "Mac"
        let system = "macOS"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion == 0 ? "" : ".\(os.patchVersion)")
        #endif
        #if !targetEnvironment(simulator)
        var size = 0
        if sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname(key, &buffer, &size, nil, 0) == 0 { model = String(cString: buffer) }
        }
        #endif
        return "\(model) · \(system) \(version)"
    }()

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
            LabeledContent("Device / OS", value: Self.deviceAndSystem)
                .accessibilityIdentifier("nxnative.about.device")
            LabeledContent("Commit", value: Self.shortCommit(info("DMCommit")))
            LabeledContent("Built", value: Self.localBuildTime(info("DMBuildTime")))
            if let version = graphicsVersion { LabeledContent("Graphics package", value: "v" + version) }
            if let metal = graphicsMetal { LabeledContent("Metal compiler", value: metal) }
        }
        .accessibilityIdentifier("nxnative.about")
    }
}
