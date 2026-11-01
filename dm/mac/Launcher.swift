// Native Mac window and resource adapters for the shared SwiftUI launcher pages.
// Packaged apps apply choices before spawning their host; direct hosts do so before module loading.
// Both use launcher.<VAR> preferences and keep launch/environment-file overrides fixed.
import AppKit
import SwiftUI
import GameController
import DmTouchPad

private var launcherDetails: [String: String] = [:]
private var launcherDefaults = UserDefaults.standard
private var sessionModel: LauncherModel?
private func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? launcherDetails[key] }

private func loadModel() -> LauncherModel? {
    let path = ProcessInfo.processInfo.environment["DM_LAUNCHER_FILE"]
    let url = path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json")
    guard let url, let data = try? Data(contentsOf: url),
          let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { return nil }
    let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    launcherDetails = record["metadata"] as? [String: String] ?? [:]
    if Bundle.main.bundleIdentifier == nil, let game = record["game"] as? String {
        launcherDefaults = UserDefaults(suiteName: "org.nxnative." + game.lowercased()) ?? .standard
    }
    let model = LauncherModel(file.settings, defaults: launcherDefaults)
    sessionModel = model
    return model
}

struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let done: (Bool) -> Void
    @State private var showSettings = false
    @State private var availableMemory = dm_low_memory_available()

    private var romfs: String {
        if let value = ProcessInfo.processInfo.environment["DM_ROMFS"] { return value }
        let root = Bundle.main.resourceURL!
        let image = root.appendingPathComponent("romfs.img")
        return FileManager.default.fileExists(atPath: image.path) ? image.path : root.appendingPathComponent("romfs").path
    }
    private var dlcCount: Int {
        if let directory = ProcessInfo.processInfo.environment["DM_AOC_DIR"] { return Int(dm_aoc_count_paths(directory, romfs)) }
        let count = Int(dm_aoc_combined_count(romfs))
        if count >= 0 { return count }
        return Int(dm_aoc_count_paths(Bundle.main.resourceURL!.appendingPathComponent("aoc").path, nil))
    }
    private var graphicsReady: Bool {
        let path = ProcessInfo.processInfo.environment["DM_MSL_DIR"] ?? Bundle.main.resourceURL!.appendingPathComponent("msl").path
        return FileManager.default.fileExists(atPath: path)
    }

    var body: some View {
        LauncherDashboard(
            model: m,
            title: info("CFBundleName") ?? "Game",
            version: info("CFBundleShortVersionString") ?? "1.0",
            icon: Image(nsImage: NSApp.applicationIconImage),
            romReady: FileManager.default.fileExists(atPath: romfs),
            shadersReady: graphicsReady, dlcCount: dlcCount,
            memoryBytes: availableMemory, importBusy: false, checkingResources: false,
            resourceStatus: nil, importProgress: 0, graphicsVersion: nil, graphicsCompiler: nil,
            buildInfo: launcherDetails,
            shouldShowTouchNotice: {
                ProcessInfo.processInfo.environment["DM_TOUCH_PREVIEW"] == "1" && GCController.controllers().isEmpty
            },
            onPlay: { done(true) }, onSettings: { showSettings = true },
            onImportROM: nil, onImportShaders: nil)
            .frame(minWidth: 720, minHeight: 420)
            .sheet(isPresented: $showSettings) {
                LauncherSettingsPage(m: m) { showSettings = false }.frame(width: 1000, height: 620)
            }
            .task {
                while !Task.isCancelled {
                    availableMemory = dm_low_memory_available()
                    m.refreshMemoryDefault(available: availableMemory)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
    }

}

/// Cloud saves: a folder the save is synced through (dm/host/save_sync.h), the one the iPhone app picks in its launcher's Cloud saves section. It is kept in this app's
/// preferences as cloudSaves.folder, which launcher.c puts into DM_SAVE_SYNC before the host starts; a DM_SAVE_SYNC an env file or the launch environment set wins, and is shown here.
struct CloudSavesSection: View {
    @AppStorage("cloudSaves.folder") private var folder = ""
    private let fixed: String? = {
        let env = ProcessInfo.processInfo.environment
        let keys = ((env["DM_ENV_FILE_KEYS"] ?? "") + " " + (env["DM_ENV_LAUNCH_KEYS"] ?? "")).split(separator: " ")
        return keys.contains("DM_SAVE_SYNC") || env["DM_SAVE_SYNC"] != nil ? env["DM_SAVE_SYNC"] : nil
    }()

    var body: some View {
        Section {
            LabeledContent("Cloud saves") {
                Text(fixed.map { "\(Self.shown($0)) (env.txt)" } ?? (folder.isEmpty ? "Off" : Self.shown(folder)))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            if fixed == nil {
                HStack {
                    Button(folder.isEmpty ? "Choose a folder…" : "Choose a different folder…", action: choose)
                    if !folder.isEmpty { Button("Turn off") { folder = "" } }
                }
            }
        } footer: {
            Text("Choose the iCloud Drive folder the iPhone app uses for this game. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in the save's -backups folder.")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = "Use for Cloud Saves"
        panel.message = "The folder the iPhone app chose in its launcher's Cloud saves"
        panel.directoryURL = URL(fileURLWithPath: folder.isEmpty ? Self.drive : folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    static let drive = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"   // iCloud Drive, as the Finder shows it

    /// A path under iCloud Drive as the Finder and the Files app name it: iCloud Drive › Documents › dev › Zelda; any other path as it is
    static func shown(_ path: String) -> String {
        guard path == drive || path.hasPrefix(drive + "/") else { return path }
        return (["iCloud Drive"] + path.dropFirst(drive.count).split(separator: "/").map(String.init)).joined(separator: " › ")
    }
}

private final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: LauncherModel
    var window: NSWindow?
    var play = false

    init(_ model: LauncherModel) { self.model = model }

    func applicationDidFinishLaunching(_ n: Notification) {
        let name = info("CFBundleName") ?? "Game"
        let menu = NSMenu(), item = NSMenuItem(), app = NSMenu()
        app.addItem(withTitle: NSLocalizedString("Close Window", comment: "Menu"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(withTitle: String(format: NSLocalizedString("Quit %@", comment: "Menu"), name), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app; menu.addItem(item); NSApp.mainMenu = menu
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = name; w.isReleasedWhenClosed = false; w.delegate = self
        w.contentMinSize = NSSize(width: 720, height: 420)
        window = w
        if let screen = w.screen ?? NSScreen.main {
            w.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.midX - w.frame.width / 2, y: screen.visibleFrame.maxY))
        }
        let host = NSHostingView(rootView: LauncherView(m: model, done: { [weak self] in self?.finish($0) }).defaultAppStorage(launcherDefaults))
        host.sizingOptions = []   // Keep the resizable dashboard's window size independent of its scroll content.
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        // LaunchServices activates packaged apps and respects open -g. Direct
        // terminal hosts have no bundle or LaunchServices activation event.
        if Bundle.main.bundleIdentifier == nil {
            w.makeKeyAndOrderFront(nil); NSApp.activate()
        } else if NSApp.isActive { w.makeKeyAndOrderFront(nil) } else { w.orderBack(nil) }
    }
    func applicationDidBecomeActive(_ n: Notification) { window?.makeKeyAndOrderFront(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {   // ⌘Q, or a logout or restart: the app ends without the game (exit 0, as Quit)
        fputs("launcher: quit without starting the game\n", stderr)
        return .terminateNow   // not terminateCancel, which a logout or restart takes as a refusal and stops
    }
    func windowWillClose(_ n: Notification) { finish(false) }

    func finish(_ play: Bool) {
        guard let w = window else { return }
        window = nil; self.play = play
        w.delegate = nil; w.orderOut(nil)
        NSApp.stop(nil)
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)   // run returns at the next event
    }
}

// 1: Play (the window's settings are in the environment), 0: the player quit, 2: no window (no launcher.json, or "Show this window at launch" off): launcher.c applies the saved choices
@_cdecl("dm_mac_launcher")
public func dmMacLauncher() -> Int32 {
    guard let model = loadModel() else { return 2 }
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" ||
        ((launcherDefaults.object(forKey: "window.show") as? Bool) == false && !NSEvent.modifierFlags.contains(.option)) {
        fputs("launcher: settings window off (hold Option at launch to show it)\n", stderr)
        model.applySaved()
        applyCloudSaves()
        return 2
    }
    let app = NSApplication.shared, launcher = Launcher(model)
    app.setActivationPolicy(.regular)
    app.delegate = launcher
    fputs("launcher: \(model.settings.count) settings shown\n", stderr)
    app.run()
    app.setActivationPolicy(.prohibited)   // the host is the game's app from here on
    guard launcher.play else { fputs("launcher: quit without starting the game\n", stderr); return 0 }
    model.apply()
    applyCloudSaves()
    return 1
}

private func applyCloudSaves() {
    if getenv("DM_SAVE_SYNC") == nil, let folder = launcherDefaults.string(forKey: "cloudSaves.folder"), !folder.isEmpty {
        setenv("DM_SAVE_SYNC", folder, 1)
    }
}

#if DM_HOST_UI
private var gameSettings: GameSettingsWindow?
private final class GameSettingsWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    weak var parent: NSWindow?
    let done: @convention(c) () -> Void
    private var closed = false

    init(model: LauncherModel, parent: NSWindow, done: @escaping @convention(c) () -> Void) {
        self.parent = parent; self.done = done
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = NSLocalizedString("Settings", comment: "In-game settings")
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentMinSize = NSSize(width: 720, height: 420)
        window.contentView = NSHostingView(rootView: LauncherSettingsPage(m: model) { [weak self] in self?.finish() }
            .defaultAppStorage(launcherDefaults))
        parent.beginSheet(window)
    }
    func finish() {
        guard !closed else { return }
        closed = true
        parent?.endSheet(window); window.orderOut(nil)
        parent?.makeKeyAndOrderFront(nil)
        gameSettings = nil
        dm_launcher_settings_pause(0)
        done()
    }
    func windowWillClose(_ notification: Notification) { finish() }
}

@_cdecl("dm_mac_show_game_settings")
public func dmMacShowGameSettings(_ parentPointer: UnsafeMutableRawPointer, _ done: @escaping @convention(c) () -> Void) -> Int32 {
    if let current = gameSettings { current.window.makeKeyAndOrderFront(nil); return 1 }
    guard let model = sessionModel ?? loadModel() else {
        fputs("launcher: no settings configuration for this game\n", stderr); return 0
    }
    let parent = Unmanaged<NSWindow>.fromOpaque(parentPointer).takeUnretainedValue()
    model.beginRuntime()
    dm_launcher_settings_pause(1)
    gameSettings = GameSettingsWindow(model: model, parent: parent, done: done)
    return 1
}
#endif
