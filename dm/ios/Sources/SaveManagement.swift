// Shared save library and native management page. Preview rules come from the
// game profile; the library always operates on whole committed save sets.
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import DmTouchPad
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SavePreviewRules: Decodable {
    let format: String
    let caption_file: String
    let image_file: String
    let time_lower: UInt32
    let time_upper: UInt32
    let location: UInt32
    let district: UInt32
    let deleted: UInt32
    let automatic: UInt32
    let hard_mode: UInt32
    let labels: [String: [String: String]]?
}

struct SaveProgress {
    var date: Date
    var location: String?
    var image: CGImage?
    var automatic = false
    var hardMode = false

    // Caption files are hash/value records, including strings spread over
    // repeated hashes. Bounds and the end marker are checked before decoding.
    static func read(_ url: URL, rules: SavePreviewRules, language: String) -> SaveProgress? {
        guard rules.format == "hash32", let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 65536,
              let raw = try? Data(contentsOf: url), raw.count >= 24, (raw.count - 16) % 8 == 0 else { return nil }
        let bytes = [UInt8](raw)
        let big = bytes[8...11].elementsEqual([0, 0, 0, 1])
        func u32(_ at: Int) -> UInt32 {
            let b = bytes[at..<at + 4]
            return (big ? Array(b) : Array(b.reversed())).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        guard u32(4) == UInt32.max, u32(8) == 1, u32(bytes.count - 4) == UInt32.max else { return nil }
        var fields: [UInt32: [UInt8]] = [:]
        for at in stride(from: 12, to: bytes.count - 4, by: 8) {
            fields[u32(at), default: []].append(contentsOf: bytes[at + 4..<at + 8])
        }
        func number(_ hash: UInt32) -> UInt32? {
            guard let b = fields[hash], b.count == 4 else { return nil }
            return (big ? b : Array(b.reversed())).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        func text(_ hash: UInt32) -> String? {
            guard let b = fields[hash], b.count <= 256, let end = b.firstIndex(of: 0) else { return nil }
            return String(bytes: b[..<end], encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard number(rules.deleted) != 1, let low = number(rules.time_lower), let high = number(rules.time_upper) else { return nil }
        let seconds = UInt64(high) << 32 | UInt64(low)
        guard seconds > 0, seconds < 4133980800 else { return nil }
        let table = rules.labels?[language] ?? rules.labels?["USen"] ?? [:]
        let name = text(rules.location), district = text(rules.district)
        var result = SaveProgress(date: Date(timeIntervalSince1970: TimeInterval(seconds)),
                                  location: name.flatMap { table[$0] } ?? district.flatMap { table[$0] } ?? name ?? district,
                                  automatic: number(rules.automatic) == 1, hardMode: number(rules.hard_mode) == 1)
        let imageURL = url.deletingLastPathComponent().appendingPathComponent(rules.image_file)
        if let values = try? imageURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
           values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 2 * 1024 * 1024,
           let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) {
            result.image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 320] as CFDictionary)
        }
        return result
    }

    static func latest(in folder: URL, rules: SavePreviewRules?, language: String) -> SaveProgress? {
        guard let rules, !rules.caption_file.contains("/"), !rules.image_file.contains("/"),
              let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                         options: [.skipsHiddenFiles]) else { return nil }
        var latest: SaveProgress?
        var visited = 0
        for case let url as URL in files {
            visited += 1
            if visited > 4096 { break } // ponytail: bounded scan; index if saves grow beyond this.
            let attributes = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if attributes?.isSymbolicLink == true { files.skipDescendants(); continue }
            if files.level > 4 { files.skipDescendants(); continue }
            if url.lastPathComponent == rules.caption_file,
               let preview = read(url, rules: rules, language: language), preview.date > (latest?.date ?? .distantPast) { latest = preview }
        }
        return latest
    }
}

struct ManagedSave: Decodable, Identifiable {
    let id: String
    let name: String
    let path: String
    let saved_at: Int64
    let bytes: Int64
    let files: Int
    let cloud_pending: Bool
    var progress: SaveProgress?
    enum CodingKeys: String, CodingKey { case id, name, path, saved_at, bytes, files, cloud_pending }
    var displayName: String { id == "default" && name == "Default" ? NSLocalizedString("Default", comment: "Save") : name }
    var date: Date? { progress?.date ?? (saved_at > 0 ? Date(timeIntervalSince1970: Double(saved_at)) : nil) }
}

private struct SaveInventory: Decodable {
    var current: String?
    var selection_error: String?
    var slots: [ManagedSave]
    var trash: [ManagedSave]
}
struct SaveImportLayout: Decodable, Identifiable {
    let source: String
    let folder: String
    let files: [String]
    let root_files: [String]?
    var id: String { source }
}

final class SaveLibrary: ObservableObject {
    @Published var saves: [ManagedSave] = []
    @Published var trash: [ManagedSave] = []
    @Published var current: String?
    @Published var busy = false
    @Published var activity = "Reading saves…"
    @Published var error: String?
    @Published var selectionError: String?
    @Published var importLayout: SaveImportLayout?
    @Published var importedCount = 0
    let root: URL?
    let title: String?
    let externalSave: Bool
    private let rules: SavePreviewRules?
    private var selecting = false

    init() {
        let env = ProcessInfo.processInfo.environment
        let settings = env["DM_LAUNCHER_FILE"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json")
        let record = settings.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        title = record?["game"] as? String ?? Bundle.main.object(forInfoDictionaryKey: "DMTitleID") as? String
        if let path = env["DM_SAVES_ROOT"] { root = URL(fileURLWithPath: path, isDirectory: true) }
        else {
            #if os(macOS)
            root = title.map { URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support/nxnative/" + $0) }
            #else
            root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            #endif
        }
        externalSave = env["DM_SAVE"] != nil && env["DM_SAVES_MANAGED"] != "1"
        rules = settings?.deletingLastPathComponent().appendingPathComponent("save-preview.json")
            .flatMapData().flatMap { try? JSONDecoder().decode(SavePreviewRules.self, from: $0) }
    }

    private static func command(root: URL, title: String, _ command: String, _ first: String = "", _ second: String = "") throws -> Data {
        var error = [CChar](repeating: 0, count: 2048)
        guard let result = dm_saves_command(root.path, title, command, first, second, &error, error.count) else {
            throw NSError(domain: "nxnative.saves", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: error)])
        }
        defer { free(result) }
        return Data(bytes: result, count: strlen(result))
    }

    func perform(_ command: String = "list", _ first: String = "", _ second: String = "", language: String, readOnly: Bool = false, owner: LauncherModel? = nil,
                 completion: ((Bool) -> Void)? = nil) {
        guard !busy, !selecting, owner?.saveSelectionPending != true, let root, let title else { completion?(false); return }
        if command == "select" {
            selecting = true; owner?.saveSelectionPending = true
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { _ = try Self.command(root: root, title: title, "select", first) }
                DispatchQueue.main.async {
                    self.selecting = false; owner?.saveSelectionPending = false
                    switch result {
                    case .success:
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            self.current = first
                            if self.selectionError != nil { self.selectionError = nil }
                            if self.error != nil { self.error = nil }
                        }
                        completion?(true)
                    case .failure(let error): self.error = NSLocalizedString(error.localizedDescription, comment: "Save management error"); completion?(false)
                    }
                }
            }
            return
        }
        activity = command.hasPrefix("import") ? "Importing save…" : command.hasPrefix("export") ? "Exporting save…" : "Reading saves…"
        busy = true; error = nil; owner?.saveOperationBusy = true
        importedCount = 0
        let rules = rules
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> (SaveInventory?, SaveImportLayout?, Int) in
                var count = 0
                if command != "list" {
                    let data = try Self.command(root: root, title: title, command, first, second)
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    if let layout = object?["needs_layout"] {
                        let data = try JSONSerialization.data(withJSONObject: layout)
                        return (nil, try JSONDecoder().decode(SaveImportLayout.self, from: data), 0)
                    }
                    if command.hasPrefix("import") { count = object?["count"] as? Int ?? 1 }
                    if (command.hasPrefix("import") || ["create", "copy"].contains(command)), let id = object?["id"] as? String {
                        _ = try Self.command(root: root, title: title, "select", id)
                    }
                }
                let data = try Self.command(root: root, title: title, readOnly ? "inspect" : "list")
                var inventory = try JSONDecoder().decode(SaveInventory.self, from: data)
                for index in inventory.slots.indices {
                    inventory.slots[index].progress = SaveProgress.latest(in: URL(fileURLWithPath: inventory.slots[index].path).appendingPathComponent("save"), rules: rules, language: language)
                }
                inventory.slots.sort {
                    return ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
                }
                return (inventory, nil, count)
            }
            DispatchQueue.main.async {
                self.busy = false
                owner?.saveOperationBusy = false
                switch result {
                case .success(let (inventory, layout, count)):
                    if let inventory {
                        self.current = inventory.current; self.saves = inventory.slots; self.trash = inventory.trash; self.selectionError = inventory.selection_error
                    }
                    self.importLayout = layout; self.importedCount = count
                    completion?(true)
                case .failure(let error): self.error = NSLocalizedString(error.localizedDescription, comment: "Save management error"); completion?(false)
                }
            }
        }
    }
}

private extension URL {
    func flatMapData() -> Data? { try? Data(contentsOf: self) }
}

private struct SaveExportSelection: Identifiable {
    let id = UUID()
    let saves: [ManagedSave]
}

private struct SaveSelectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

private struct SaveExportSelectionPage: View {
    let saves: [ManagedSave]
    let onExport: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>

    init(saves: [ManagedSave], onExport: @escaping ([String]) -> Void) {
        self.saves = saves
        self.onExport = onExport
        _selected = State(initialValue: Set(saves.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Select all saves", isOn: Binding(get: { selected.count == saves.count }, set: { selected = $0 ? Set(saves.map(\.id)) : [] }))
                ForEach(saves) { save in
                    Toggle(save.displayName, isOn: Binding(get: { selected.contains(save.id) }, set: { if $0 { selected.insert(save.id) } else { selected.remove(save.id) } }))
                }
                Text(String.localizedStringWithFormat(NSLocalizedString("Selected: %d", comment: "Export selection count"), selected.count))
            }.navigationTitle("Export saves")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Export") {
                            onExport(saves.map(\.id).filter { selected.contains($0) }); dismiss()
                        }.disabled(selected.isEmpty).accessibilityIdentifier("saves.export.confirm")
                    }
                }
        }.frame(minWidth: 280, minHeight: 330)
    }
}

struct SaveManagementPage: View {
    @ObservedObject var launcher: LauncherModel
    @StateObject private var library = SaveLibrary()
    @Environment(\.scenePhase) private var scenePhase
    @State private var editing: String?
    @State private var editID = ""
    @State private var name = ""
    @State private var deleting: ManagedSave?
    @State private var importing = false
    @State private var exportURL: URL?
    @State private var showDeleted = false
    @State private var importURLs: [URL] = []
    @State private var importScopes: [URL] = []
    @State private var importChoices: [String: String] = [:]
    @State private var retryImport = false
    @State private var exportSelection: SaveExportSelection?
    @State private var pendingExports: [String]?
    private var language: String {
        launcher.values["DM_LANG"] ?? ProcessInfo.processInfo.environment["DM_LANG"]
            ?? Bundle.main.object(forInfoDictionaryKey: "DMLanguage") as? String ?? "USen"
    }
    private var locked: Bool { launcher.isRunning || library.externalSave }

    var body: some View {
        Form {
        Section {
            if library.title == nil || library.root == nil { Text("Save management is unavailable for this app.") }
            else {
                if library.externalSave { Label("A custom save path is active. Manage that folder outside the app.", systemImage: "folder") }
                else if launcher.isRunning { Label("Close the game to switch or manage saves.", systemImage: "lock").accessibilityIdentifier("saves.readonly") }
                if let error = library.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("saves.error")
                } else if library.selectionError != nil {
                    Label("Choose a save to continue. Your progress has been kept.", systemImage: "info.circle").font(.callout)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 8) { newSaveButton; importSaveButton; exportSavesButton }
                    VStack(alignment: .leading, spacing: 8) { newSaveButton; importSaveButton; exportSavesButton }
                }.buttonStyle(.bordered).controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 8))
                    .disabled(locked || library.busy)
                if library.busy { ProgressView(LocalizedStringKey(library.activity)).accessibilityIdentifier("saves.busy") }
                if library.importedCount > 0 { Text(String.localizedStringWithFormat(NSLocalizedString("Imported %d saves.", comment: "Save import result"), library.importedCount)).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        if !library.saves.isEmpty {
            Section("Save list") {
                ForEach(library.saves) { save in
                    saveRow(save).listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
            }
            .listRowBackground(launcherSettingsGroup)
        }
        Section {
            #if os(macOS)
            if let root = library.root {
                Button { NSWorkspace.shared.open(root.appendingPathComponent("saves")) } label: {
                    Label("Open saves folder", systemImage: "folder")
                }.accessibilityIdentifier("saves.folder")
            }
            #endif
            DisclosureGroup("Add a save folder manually") {
                Text("Put your game save files in saves/Your name/save, then tap Refresh saves. No setup file is needed.")
                    .font(.footnote).textSelection(.enabled)
                #if os(iOS)
                Text("Find this app under On My iPhone in Files.").font(.footnote)
                #endif
            }
            Button { refresh() } label: { Label("Refresh saves", systemImage: "arrow.clockwise") }
                .disabled(library.busy).accessibilityIdentifier("saves.refresh")
            if !library.trash.isEmpty {
                DisclosureGroup("Recently deleted", isExpanded: $showDeleted) {
                    ForEach(library.trash) { save in
                        HStack {
                            Text(save.displayName); Spacer()
                            Button("Restore") { perform("restore", save.id) }.disabled(locked || library.busy)
                        }
                    }
                }
            }
        }.listRowBackground(launcherSettingsGroup)
        CloudSavesSection().listRowBackground(launcherSettingsGroup).disabled(launcher.isRunning || library.busy)
        }
        .formStyle(.grouped)
        .contentMargins(.top, 8, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(launcherSettingsBackground)
        .task { refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
        .alert(editing == "rename" ? "Rename save" : editing == "copy" ? "Duplicate save" : "New save", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Save name", text: $name)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") { let operation = editing ?? "create"; editing = nil; perform(operation, operation == "create" ? name : editID, operation == "create" ? "" : name) }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Delete save?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let save = deleting { perform("delete", save.id) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("You can restore it from Recently deleted. Its cloud copy is kept.") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .data, .zip] + ["7z", "rar", "dmsync"].compactMap { UTType(filenameExtension: $0) }, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importSaves(urls)
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .sheet(item: $library.importLayout, onDismiss: {
            if retryImport { retryImport = false; runImport() } else { finishImport() }
        }) { layout in
            NavigationStack {
                Form {
                    Text("The archive contains one folder. Choose which layout matches your game save.")
                    Section {
                        layoutButton("Use the files inside", layout: layout, choice: "inside", lines: ["save/"] + layout.files.map { "  " + $0 })
                        layoutButton("Keep the outer folder", layout: layout, choice: "root", lines: outerLayoutLines(layout))
                    }
                }.navigationTitle("Choose the save folder")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { library.importLayout = nil } } }
            }.frame(minWidth: 280, minHeight: 330)
        }
        .sheet(item: $exportSelection, onDismiss: {
            if let ids = pendingExports { pendingExports = nil; chooseExport(ids: ids) }
        }) { selection in
            SaveExportSelectionPage(saves: selection.saves) { pendingExports = $0 }
        }
        #if os(iOS)
        .sheet(item: Binding(get: { exportURL.map { SaveExportURL(url: $0) } }, set: { if $0 == nil { clearExport() } })) { item in
            SaveExportPicker(url: item.url) { clearExport() }
        }
        #endif
    }

    private var newSaveButton: some View {
        Button { editID = ""; name = ""; editing = "create" } label: {
            Label("New save", systemImage: "plus").font(.subheadline.weight(.medium)).fixedSize()
        }.accessibilityIdentifier("saves.new")
    }

    private var importSaveButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { chooseImport() } label: {
                Label("Import saves", systemImage: "square.and.arrow.down").font(.subheadline.weight(.medium)).fixedSize()
            }.accessibilityIdentifier("saves.import")
            Text("Importing will not delete your current save.").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 160, alignment: .leading)
        }
    }

    private var exportSavesButton: some View {
        Button { exportSelection = SaveExportSelection(saves: library.saves) } label: {
            Label("Export saves", systemImage: "square.and.arrow.up").font(.subheadline.weight(.medium)).fixedSize()
        }.disabled(library.saves.isEmpty).accessibilityIdentifier("saves.export-many")
    }

    private func saveRow(_ save: ManagedSave) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button { if save.id != library.current { perform("select", save.id) } } label: {
                HStack(spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { thumbnail(save).frame(width: 96, height: 54); summary(save).frame(minWidth: 100, maxWidth: .infinity, alignment: .leading) }
                        HStack(spacing: 8) { thumbnail(save).frame(width: 64, height: 36); summary(save).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    Image(systemName: "checkmark").font(.title3.weight(.semibold)).foregroundStyle(launcherTint)
                        .frame(width: 24).opacity(save.id == library.current ? 1 : 0)
                        .accessibilityLabel("Current save").accessibilityHidden(save.id != library.current)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(SaveSelectionButtonStyle()).disabled(locked || library.busy)
                .accessibilityAddTraits(save.id == library.current ? .isSelected : [])
                .accessibilityIdentifier("saves.select." + save.id)
            Menu {
                Button("Rename…") { editID = save.id; name = save.displayName; editing = "rename" }
                Button("Duplicate…") { editID = save.id; name = save.displayName + " " + NSLocalizedString("Copy", comment: "Save"); editing = "copy" }
                Button("Export…") { chooseExport(save) }
                if save.id != "default" {
                    Button("Delete…", role: .destructive) { deleting = save }.disabled(save.id == library.current)
                }
            } label: { Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(minWidth: 28, minHeight: 44).contentShape(Rectangle()) }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .menuIndicator(.hidden)
                .disabled(locked || library.busy).accessibilityLabel("Save actions").accessibilityIdentifier("saves.actions." + save.id)
        }.padding(.vertical, 2)
    }

    private func thumbnail(_ save: ManagedSave) -> some View {
        Group {
            if let image = save.progress?.image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) }
            else { Rectangle().fill(.quaternary).overlay { Image(systemName: save.cloud_pending ? "icloud.and.arrow.down" : "photo").foregroundStyle(.secondary) } }
        }.clipped().clipShape(RoundedRectangle(cornerRadius: 7))
    }
    private func summary(_ save: ManagedSave) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(save.displayName).font(.headline).lineLimit(1)
            if save.cloud_pending { Text("Downloads when you play").font(.caption).foregroundStyle(.secondary) }
            else if let date = save.date {
                if let location = save.progress?.location { Text(location).font(.caption).lineLimit(1) }
                Text(date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                if save.progress?.hardMode == true { Text("Master Mode").font(.caption).foregroundStyle(.secondary) }
            } else { Text("No saved progress yet").font(.caption).foregroundStyle(.secondary) }
        }.foregroundStyle(.primary).multilineTextAlignment(.leading)
    }
    private func perform(_ command: String, _ first: String = "", _ second: String = "", completion: ((Bool) -> Void)? = nil) {
        guard !locked else { completion?(false); return }
        library.perform(command, first, second, language: language, owner: launcher, completion: completion)
    }
    private func refresh() {
        guard importURLs.isEmpty && library.importLayout == nil else { return }
        if !locked { configureSaveCloud() }
        library.perform(locked ? "list" : "refresh", language: language, readOnly: locked, owner: launcher)
    }
    private func chooseImport() { importing = true }
    private func importSaves(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importURLs = urls; importChoices = [:]
        importScopes = urls.filter { $0.startAccessingSecurityScopedResource() }
        runImport()
    }
    private func json(_ object: Any) -> String { String(data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), encoding: .utf8) ?? "" }
    private func runImport() {
        perform("import-many", json(importURLs.map(\.path)), json(importChoices)) { _ in
            if library.importLayout == nil { finishImport() }
        }
    }
    private func finishImport() {
        importScopes.forEach { $0.stopAccessingSecurityScopedResource() }
        importScopes = []; importURLs = []; importChoices = [:]
    }
    private func outerLayoutLines(_ layout: SaveImportLayout) -> [String] {
        let root = layout.root_files ?? [layout.folder + "/"]
        return ["save/"] + root.flatMap { name in
            ["  " + name] + (name == layout.folder + "/" ? layout.files.map { "    " + $0 } : [])
        }
    }
    private func layoutButton(_ title: LocalizedStringKey, layout: SaveImportLayout, choice: String, lines: [String]) -> some View {
        Button {
            importChoices[layout.source] = choice; retryImport = true; library.importLayout = nil
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(lines.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
        }.buttonStyle(.plain)
    }
    private func chooseExport(_ save: ManagedSave) {
        chooseExport(ids: [save.id], name: save.displayName)
    }
    private func chooseExport(ids: [String], name: String? = nil) {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "nxnative-\(library.title ?? "save")-\(safeFilename(name ?? "saves"))-\(formatter.string(from: Date())).zip"
        let command = name == nil ? "export-many" : "export"
        let argument = name == nil ? json(ids) : (ids.first ?? "")
        #if os(macOS)
        let panel = NSSavePanel(); panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [.zip]
        if panel.runModal() == .OK, let url = panel.url { perform(command, argument, url.path) }
        #else
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { library.error = error.localizedDescription; return }
        let url = folder.appendingPathComponent(filename)
        perform(command, argument, url.path) { ok in
            if ok { exportURL = url } else { try? FileManager.default.removeItem(at: folder) }
        }
        #endif
    }
    private func safeFilename(_ name: String) -> String {
        var cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        while cleaned.utf8.count > 60 { cleaned.removeLast() }
        return cleaned.isEmpty ? "Save" : cleaned
    }
    private func clearExport() { if let url = exportURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }; exportURL = nil }
}

#if os(iOS)
private struct SaveExportURL: Identifiable { let url: URL; var id: URL { url } }
private struct SaveExportPicker: UIViewControllerRepresentable {
    let url: URL
    let done: () -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done) }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: () -> Void
        init(_ done: @escaping () -> Void) { self.done = done }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done() }
    }
}
#endif
