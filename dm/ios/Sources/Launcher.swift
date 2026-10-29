// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json, which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. Settings are grouped by section (rows: LauncherRow.swift); BOTW touch controls have a separate editor. Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
import SwiftUI
import UIKit
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var showTouchSettings = false
    @State private var memory = os_proc_available_memory()

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    VStack(spacing: 16) {
                        if let icon = appIcon() {
                            Image(uiImage: icon).resizable().frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 22))
                                .accessibilityHidden(true)
                        }
                        Text((info("CFBundleDisplayName") as? String) ?? "Game")
                            .font(.title.weight(.bold)).multilineTextAlignment(.center)
                        Text(String(format: NSLocalizedString("Version %@", comment: "Game version"), (info("CFBundleShortVersionString") as? String) ?? ""))
                            .font(.callout).foregroundStyle(.secondary)
                        playButton
                    }
                    .padding(16)
                    .frame(width: geometry.size.width / 3, height: geometry.size.height)
                    List {
                        if m.touchStickResponse != nil {
                            Section("Touch") {
                                Button("Touch settings") { showTouchSettings = true }
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
                        Section {
                            HStack {
                                Text("Memory available")
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .contentMargins(.horizontal, 12, for: .scrollContent)
                    .frame(width: geometry.size.width * 2 / 3)
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
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder var playButton: some View {
        let button = Button(action: play) { Text("Play").font(.title3.weight(.semibold)).frame(maxWidth: 220) }.controlSize(.large)
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
    }

    private func appIcon() -> UIImage? {
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = info("CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); LauncherModel(file.settings).applySaved(); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let model = LauncherModel(file.settings)
    var host: UIViewController?
    let view = LauncherView(m: model) {
        guard let h = host else { return }
        host = nil
        model.apply()
        h.dismiss(animated: false) { done() }
    }
    let h = UIHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
