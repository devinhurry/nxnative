import SwiftUI
import UniformTypeIdentifiers
import UIKit

private func documentsURL() -> URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
private func expectedGameData() throws -> GameDataDescriptor {
    guard let url = Bundle.main.url(forResource: "game-data", withExtension: "json", subdirectory: "dm") else {
        throw GameData.fail("This app has no external game-data descriptor. Rebuild with --separate-rom, or copy the extracted RomFS folder to this app's Documents/romfs and restart.")
    }
    return try JSONDecoder().decode(GameDataDescriptor.self, from: Data(contentsOf: url))
}

// Called before host preloading. A receipt from another data package never enables boot.
@_cdecl("dm_imported_game_ready")
public func dmImportedGameReady() -> Bool {
    do {
        let expected = try expectedGameData(), documents = documentsURL()
        guard try GameData.isInstalled(expected, in: documents) else { return false }
        let data = GameData.live(documents)
        setenv("DM_ROMFS", data.appendingPathComponent("romfs").path, 1)
        // Set even when absent: stale DLC from a bundled build must not become owned.
        setenv("DM_AOC_DIR", data.appendingPathComponent("aoc").path, 1)
        return true
    } catch { fputs("game data: \(error.localizedDescription)\n", stderr); return false }
}

private final class GameImportModel: ObservableObject {
    @Published var busy = false
    @Published var progress = 0.0
    @Published var error: String?

    func importPackage(_ url: URL, done: @escaping () -> Void) {
        busy = true; error = nil; progress = 0
        let access = url.startAccessingSecurityScopedResource()
        let wasIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        DispatchQueue.global(qos: .userInitiated).async {
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            var failure: Error?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                do {
                    let expected = try expectedGameData()
                    var lastUpdate = Date.distantPast
                    try GameData.install(readable, expected: expected, in: documentsURL()) { fraction in
                        let now = Date()
                        if now.timeIntervalSince(lastUpdate) >= 0.1 || fraction == 1 {
                            lastUpdate = now
                            DispatchQueue.main.async { self.progress = fraction }
                        }
                    }
                } catch { failure = error }
            }
            let result = coordinationError ?? failure
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled
                self.busy = false
                if let result { self.error = result.localizedDescription }
                else { done() }
            }
        }
    }
}

private struct GameImportView: View {
    @StateObject private var model = GameImportModel()
    @State private var picking = false
    let done: () -> Void
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Import Game Data").font(.title.bold())
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Game").font(.title2)
                Text("Select the .nxrom file created alongside this game's IPA. Keep the app open until the import finishes.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                if model.busy {
                    ProgressView(value: model.progress)
                    Text("Importing and verifying… \(Int(model.progress * 100))%")
                        .monospacedDigit().accessibilityLabel("Import progress \(Int(model.progress * 100)) percent")
                } else {
                    Button("Choose .nxrom File") { picking = true }.buttonStyle(.borderedProminent).controlSize(.large)
                }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .padding(32).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(exportedAs: "org.nxnative.game-data", conformingTo: .data)]) { result in
            switch result {
            case .success(let url): model.importPackage(url, done: done)
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .onAppear {
            do { _ = try expectedGameData() }
            catch { model.error = error.localizedDescription }
        }
    }
}

@_cdecl("dm_show_game_import")
public func dmShowGameImport(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) {
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    var host: UIViewController?
    let view = GameImportView {
        guard dmImportedGameReady(), let controller = host else { return }
        host = nil
        controller.dismiss(animated: false) { done() }
    }
    let controller = UIHostingController(rootView: view)
    controller.modalPresentationStyle = .fullScreen
    host = controller
    parent.present(controller, animated: false)
}
