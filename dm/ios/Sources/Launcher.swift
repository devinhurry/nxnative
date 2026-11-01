// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json, which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. Settings are grouped by section (rows: LauncherRow.swift); BOTW touch controls have a separate editor. Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
import SwiftUI
import UIKit
import GameController
import UniformTypeIdentifiers
import os

private final class LandscapeLauncherController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
}

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }


/// Cloud saves: an iCloud Drive folder shared with the Mac app (chosen in its settings window's
/// Cloud saves too). The host brings the save in from there when the game starts and
/// sends it there after each save (dm/host/save_sync.h); the folder is a bookmark (CloudSaves.m).
private struct CloudSavesSection: View {
    @State private var folder: String = ""
    @State private var note: String = ""
    @State private var picking = false

    var body: some View {
        Section {
            HStack {
                Text("Cloud saves")
                Spacer()
                Text(folder.isEmpty ? "Off" : (folder as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button(folder.isEmpty ? "Choose a folder in iCloud Drive…" : "Choose a different folder…") { picking = true }
                // The sheet sits on the button, not on the Section: SwiftUI hands a Section's modifiers to every row, so one tap presented a picker per row and they invalidated each other (LNPANDY/NX2Apple#315).
                .sheet(isPresented: $picking) {
                    DocumentPicker(types: [.folder]) { url in
                        picking = false
                        if dm_store_cloud_saves(url) {
                            note = "Saved. The game uses this folder when you press Play."
                            refresh()
                        } else {
                            note = "That folder could not be remembered — try a different one."
                        }
                    } onCancel: { picking = false }
                }
            if !folder.isEmpty {
                Button("Turn off cloud saves", role: .destructive) {
                    dm_clear_cloud_saves(); refresh(); note = ""
                }
            }
        } footer: {
            Text(note.isEmpty
                 ? "Choose a folder in iCloud Drive, and the same one in the Mac app's Cloud saves. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in save-backups."
                 : note)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var stale: ObjCBool = false
        folder = dm_cloud_saves_path(&stale) ?? ""
        if stale.boolValue && folder.isEmpty {
            note = "The folder you chose before is no longer readable (the app was signed differently). Please choose it again."
        }
    }
}

/// UIDocumentPickerViewController for a folder, in the two callbacks a SwiftUI sheet wants.
private struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.folder]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .open (not .import): the folder stays where it is and the bookmark keeps pointing at it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var showTouchSettings = false
    @State private var showTouchNotice = false
    @State private var memory = os_proc_available_memory()
    @State private var importing: ImportKind?
    @State private var importBusy = false
    @State private var checkingResources = false
    @State private var romReady = false
    @State private var shadersReady = false
    @State private var resourceStatus: String?
    @State private var importError: String?
    @State private var importProgress: Double = 0
    @State private var graphicsVersion: String?
    @State private var graphicsMetal: String?

    private enum ImportKind: String, Identifiable {
        case rom, shaders
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ScrollView {
                    VStack(spacing: 8) {
                        if let icon = appIcon() {
                            let size: CGFloat = m.lowMemoryEnabled ? 52 : 64
                            Image(uiImage: icon).resizable().frame(width: size, height: size)
                                .clipShape(RoundedRectangle(cornerRadius: 15))
                                .accessibilityHidden(true)
                        }
                        Text((info("CFBundleDisplayName") as? String) ?? "Game")
                            .font(.title3.weight(.bold)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                        Text(String(format: NSLocalizedString("Version %@", comment: "Game version"), (info("CFBundleShortVersionString") as? String) ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                        playButton
                            .disabled(importBusy || checkingResources || !romReady || !shadersReady)
                        HStack(spacing: 8) {
                            if romReady {
                                Label("ROM imported", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityIdentifier("startup.import.rom.ready")
                            } else {
                                Button("Import ROM") { importing = .rom }
                                    .accessibilityIdentifier("startup.import.rom")
                                    .buttonStyle(.bordered).disabled(importBusy || checkingResources)
                            }
                            if shadersReady {
                                Label("Shaders imported", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityIdentifier("startup.import.shaders.ready")
                            } else {
                                Button("Import shaders") { importing = .shaders }
                                    .accessibilityIdentifier("startup.import.shaders")
                                    .buttonStyle(.bordered).disabled(importBusy || checkingResources)
                            }
                        }
                        Button { refreshResources() } label: {
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
                        if importBusy {
                            ProgressView(value: importProgress)
                            Text("Importing…").font(.caption).foregroundStyle(.secondary)
                        } else if let status = resourceStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("startup.resources.status")
                        }
                        if m.lowMemoryEnabled {
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
                    List {
                        if m.touchStickResponse != nil {
                            Section("Touch") {
                                Button("BOTW touch settings") { showTouchSettings = true }
                                    .accessibilityIdentifier("botw.touch.settings")
                            }
                        }
                        ForEach(m.sections.filter { !LauncherModel.isTouchSection($0) }, id: \.self) { section in
                            Section(LocalizedStringKey(section)) {
                                ForEach(m.rows(in: section)) { SettingRow(s: $0, m: m) }
                            }
                        }
                        Section {
                            Button("Reset to tested defaults") { m.reset() }
                                .disabled(!m.changed)
                        } footer: {
                            Text("Brings back all settings this game was tested with.")
                        }
                        CloudSavesSection()
                        Section {
                            HStack {
                                Text("Memory available")
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        AboutSection(graphicsVersion: graphicsVersion, graphicsMetal: graphicsMetal)
                    }
                    .listStyle(.insetGrouped)
                    .contentMargins(.horizontal, 12, for: .scrollContent)
                    .frame(width: geometry.size.width * 0.62)
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $showTouchSettings) {
                    BotwTouchSettingsView(m: m,
                        viewport: CGSize(width: geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing,
                                         height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom),
                        safeInsets: geometry.safeAreaInsets)
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert("Touch controls", isPresented: $showTouchNotice) {
            Button("I know I can double-tap with three fingers") {
                m.acknowledgeTouchFallbackNotice()
                finishStart()
            }
        } message: {
            Text("Touch UI cannot cover every game screen. If a button does not respond, double-tap with three fingers to temporarily show the virtual gamepad and continue. Please report the issue to the developer.")
        }
        .alert("Import failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
        .sheet(item: $importing) { kind in
            DocumentPicker(types: kind == .rom ? [.data] : [.zip]) { url in
                importing = nil
                importResource(url, kind: kind)
            } onCancel: { importing = nil }
        }
        .onAppear { refreshResources() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refreshResources() }
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                m.refreshMemoryDefault(available: UInt64(memory))
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder var playButton: some View {
        let button = Button(action: startGame) { Text("Play").font(.title3.weight(.semibold)).frame(maxWidth: 220) }.controlSize(.large)
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
    }

    private func startGame() {
        if m.needsTouchFallbackNotice && GCController.controllers().isEmpty { showTouchNotice = true }
        else { finishStart() }
    }

    private func finishStart() {
        m.apply()
        if dm_startup_prepare() { play() }
        else { refreshResources() }
    }

    private func refreshResources(autoImport: Bool = true) {
        guard !importBusy && !checkingResources else { return }
        checkingResources = true
        DispatchQueue.global(qos: .userInitiated).async {
            let rom = dm_startup_rom_error()
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            var graphicsError: NSError?
            let info = dm_graphics_current_info(documents, Bundle.main.resourceURL!, &graphicsError)
            let shaders = graphicsError?.localizedDescription
            var discoveryError: NSError?
            let package = autoImport && shaders != nil
                ? dm_graphics_pending_package(documents, Bundle.main.resourceURL!, &discoveryError) : nil
            let discoveryMessage = discoveryError?.localizedDescription
            let version = (info?["version"] as? NSNumber)?.stringValue
            let compilers = info?["compilers"] as? [String: Any]
            let metal = (compilers?["metal_versions"] as? [String])?.joined(separator: ", ")
            DispatchQueue.main.async {
                romReady = rom == nil; shadersReady = shaders == nil
                resourceStatus = rom ?? shaders
                graphicsVersion = version; graphicsMetal = metal?.isEmpty == false ? metal : nil
                checkingResources = false
                if let message = discoveryMessage { importError = message }
                if let package { importResource(package, kind: .shaders) }
            }
        }
    }

    private func importResource(_ url: URL, kind: ImportKind) {
        guard !importBusy else { return }
        importBusy = true; importProgress = 0
        let scoped = url.startAccessingSecurityScopedResource()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSError?
            let ok: Bool
            if kind == .rom { ok = dm_import_game_image(url, documents, &error) }
            else {
                let required = dm_graphics_requirements(Bundle.main.resourceURL!) ?? [:]
                var lastProgress = Date.distantPast
                ok = dm_import_graphics_package(url, documents, required, { done, total in
                    let now = Date()
                    if now.timeIntervalSince(lastProgress) >= 0.1 || done == total {
                        lastProgress = now
                        DispatchQueue.main.async { importProgress = total > 0 ? Double(done) / Double(total) : 0 }
                    }
                }, &error)
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = previousIdle
                importBusy = false
                if !ok { importError = error?.localizedDescription ?? NSLocalizedString("Import failed", comment: "Resource import") }
                // Do not retry a failed automatic import in a refresh/import loop.
                refreshResources(autoImport: kind == .rom)
            }
        }
    }

    private func appIcon() -> UIImage? {
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = info("CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
}

// Shows settings and resource imports; calls done after preparation, or returns false for an explicitly skipped, ready launcher.
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json")
    let data = url.flatMap { try? Data(contentsOf: $0) }
    let settings = data.flatMap { try? JSONDecoder().decode(SettingsFile.self, from: $0) }?.settings ?? []
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" && dm_startup_rom_error() == nil && dm_startup_graphics_error() == nil {
        fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); LauncherModel(settings).applySaved(); return false
    }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let model = LauncherModel(settings)
    var host: UIViewController?
    let view = LauncherView(m: model) {
        guard let h = host else { return }
        host = nil
        h.dismiss(animated: false) { done() }
    }
    let h = LandscapeLauncherController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(settings.count) settings shown\n", stderr)
    return true
}
