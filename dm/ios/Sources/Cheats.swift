// iOS controls for the shared Atmosphere cheat engine. Used before Play and in the in-game settings.
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private func cheatText(_ text: UnsafePointer<CChar>?) -> String {
    text.map { String(cString: $0) } ?? ""
}

private struct CheatRow: Identifiable {
    let id: Int32
    let name, section, why, note, type, bounds: String
    let kind, flags: Int32
    let on: Bool
    let value: String?

    init(_ index: Int32) {
        id = index
        name = cheatText(dm_cheat_name_at(index))
        section = cheatText(dm_cheat_section_at(index))
        why = cheatText(dm_cheat_why_at(index))
        note = cheatText(dm_cheat_note_at(index))
        type = cheatText(dm_cheat_type_at(index))
        bounds = cheatText(dm_cheat_value_bounds(index))
        kind = dm_cheat_kind_at(index); flags = dm_cheat_flags_at(index)
        on = dm_cheat_on_at(index) != 0
        var text = [CChar](repeating: 0, count: 64)
        value = dm_cheat_value_get(index, &text, text.count) != 0 ? String(cString: text) : nil
    }

    var visible: Bool { flags & Int32(DM_CHEAT_PAIR_OFF | DM_CHEAT_SECTION_START | DM_CHEAT_SECTION_END) == 0 }
    var once: Bool { flags & Int32(DM_CHEAT_ONCE) != 0 }
    var selectable: Bool { kind == 0 && !once && visible }
}

private struct CheatState {
    let build = cheatText(dm_cheats_build())
    let version = cheatText(dm_cheats_version())
    let folder = cheatText(dm_cheats_dir_path())
    let master = dm_cheats_master() != 0
    let rows = (0..<dm_cheats_ncheats()).map(CheatRow.init).filter(\.visible)
    let others = (0..<dm_cheats_nothers()).map { cheatText(dm_cheats_other($0)) }
    let skipped = (0..<dm_cheats_nskipped()).map { cheatText(dm_cheats_skipped_name($0)) + ": " + cheatText(dm_cheats_skipped_why($0)) }
}

private struct CheatDetail: Identifiable {
    let id = UUID()
    let title, text: String
}

struct CheatsView: View {
    let isRunning: Bool
    @State private var state = CheatState()
    @State private var search = ""
    @State private var importing = false
    @State private var importBusy = false
    @State private var pending: [CheatImport] = []
    @State private var confirmBuild = false
    @State private var error: String?
    @State private var detail: CheatDetail?

    private var filtered: [CheatRow] {
        state.rows.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.section.localizedCaseInsensitiveContains(search) }
    }
    private var sections: [String] {
        filtered.reduce(into: []) { if !$0.contains($1.section) { $0.append($1.section) } }
    }

    var body: some View {
        Form { contents }
            .formStyle(.grouped)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): readImports(urls)
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .confirmationDialog("Import for this game build?", isPresented: $confirmBuild, titleVisibility: .visible) {
                Button("Import for This Build") { installPending() }
                Button("Cancel", role: .cancel) { pending = [] }
            } message: {
                Text("These files have no Build ID in their names. Only continue if they match this game's version.")
                Text(state.build)
            }
            .alert("Import failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
            .task {
                refresh()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    refresh()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                if !importBusy { reload() }
            }
            .sheet(item: $detail) { item in
                NavigationStack {
                    ScrollView {
                        Text(verbatim: item.text).font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                    .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detail = nil } } }
                }
            }
    }

    @ViewBuilder
    private var contents: some View {
        Section {
            LabeledContent("Build ID") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(state.build.isEmpty ? "Unknown" : state.build).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    if !state.version.isEmpty { Text(state.version).font(.caption).foregroundStyle(.secondary) }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { masterSwitch.fixedSize(); Spacer(); selectionButtons }
                VStack(alignment: .leading) { masterSwitch; HStack { selectionButtons } }
            }.buttonStyle(.borderless)
            HStack {
                Button("Import Cheats…") { importing = true }
                    .accessibilityIdentifier("cheats.import")
                    .disabled(importBusy || state.folder.isEmpty)
                Spacer()
                Button("Reload") { reload() }.disabled(importBusy).accessibilityIdentifier("cheats.reload")
            }.buttonStyle(.borderless)
            if importBusy { ProgressView("Importing…") }
            TextField("Search cheats", text: $search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("cheats.search")
        } header: { Text("Cheats") } footer: {
            Text("iOS supports data cheats. Cheats that modify game code cannot run on iOS. Choices are saved for this game build.")
        }

        if state.rows.isEmpty {
            Section {
                Text("No cheats for this build.").foregroundStyle(.secondary)
                Text("Import an Atmosphere .txt file for the Build ID above. You can also import its .meta.tsv companion for sections and editable values.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else if filtered.isEmpty {
            Section { Text("No matching cheats.").foregroundStyle(.secondary) }
        }
        ForEach(sections, id: \.self) { section in
            Section {
                ForEach(filtered.filter { $0.section == section }) { row in
                    cheatRow(row)
                }
            } header: { if !section.isEmpty { Text(verbatim: section) } }
        }
        if !state.others.isEmpty {
            Section("Files for other game versions") {
                ForEach(state.others, id: \.self) { Text(verbatim: $0).font(.system(.footnote, design: .monospaced)) }
            }
        }
        if !state.skipped.isEmpty {
            Section("Unavailable cheats") {
                ForEach(Array(state.skipped.enumerated()), id: \.offset) { Text(verbatim: $0.element).font(.footnote) }
            }
        }
        Section {
            Button("Load report") { detail = CheatDetail(title: NSLocalizedString("Load report", comment: "Cheats"), text: cheatText(dm_cheats_report())) }
                .accessibilityIdentifier("cheats.report")

        } footer: {
            Text("Files are stored in Documents/cheats and can also be managed in the Files app. Replaced files are kept with a .bak extension.")
        }
    }

    private var masterSwitch: some View {
        Toggle("Cheats On", isOn: Binding(get: { state.master }, set: {
            dm_cheats_master_set($0 ? 1 : 0); refresh()
        })).accessibilityIdentifier("cheats.master")
    }

    @ViewBuilder
    private var selectionButtons: some View {
        Button("Select All") { setSelection(true) }
            .disabled(!state.master || !state.rows.contains { $0.selectable && !$0.on })
            .accessibilityIdentifier("cheats.selectAll")
        Button("Deselect All") { setSelection(false) }
            .disabled(!state.master || !state.rows.contains { $0.selectable && $0.on })
            .accessibilityIdentifier("cheats.deselectAll")
    }

    private func cheatRow(_ row: CheatRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                if row.kind == 3 {
                    Text(verbatim: row.name).foregroundStyle(.secondary)
                } else if row.kind == 1 {
                    VStack(alignment: .leading) { Text(verbatim: row.name); Text("Master code (always on)").font(.caption).foregroundStyle(.secondary) }
                } else if row.once {
                    VStack(alignment: .leading) {
                        Text(verbatim: row.name)
                        Button("Apply") { dm_cheat_toggle(row.id); refresh() }.buttonStyle(.borderless).disabled(row.kind != 0 || !state.master || !isRunning)
                        if !isRunning { Text("Start the game to apply one-time cheats.").font(.caption).foregroundStyle(.secondary) }
                    }
                } else {
                    Toggle(isOn: Binding(get: { row.on }, set: { on in
                        if (dm_cheat_on_at(row.id) != 0) != on { dm_cheat_toggle(row.id) }
                        refresh()
                    })) { Text(verbatim: row.name) }
                    .disabled(row.kind != 0 || !state.master)
                    .accessibilityIdentifier("cheats.toggle.\(row.id)")
                }
                if row.kind != 3 {
                    Button { showDetails(row) } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless).accessibilityLabel(Text("Cheat details"))
                        .accessibilityIdentifier("cheats.details.\(row.id)")
                }
            }
            if !row.why.isEmpty { Text(verbatim: row.why).font(.footnote).foregroundStyle(.secondary) }
            if let value = row.value {
                CheatValueField(id: row.id, value: value, bounds: row.bounds) { refresh() }
                    .disabled(row.kind != 0 || !state.master)
            }
        }
    }

    private func refresh() { state = CheatState() }
    private func reload() { dm_cheats_reload(); refresh() }
    private func setSelection(_ on: Bool) {
        for row in state.rows where row.selectable && (dm_cheat_on_at(row.id) != 0) != on { dm_cheat_toggle(row.id) }
        refresh()
    }
    private func showDetails(_ row: CheatRow) {
        var buffer = [CChar](repeating: 0, count: 4096)
        _ = dm_cheat_preview(row.id, &buffer, buffer.count)
        let text = [row.note, row.type, row.bounds, String(cString: buffer)].filter { !$0.isEmpty }.joined(separator: "\n\n")
        detail = CheatDetail(title: row.name, text: text)
    }
    private func readImports(_ urls: [URL]) {
        guard !importBusy, !urls.isEmpty else { return }
        importBusy = true
        let build = state.build
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                let files = try urls.map { try CheatImport(url: $0, build: build) }
                guard Set(files.map(\.name)).count == files.count else {
                    throw NSError(domain: "nxnative.cheats", code: 2, userInfo: [NSLocalizedDescriptionKey:
                        NSLocalizedString("Select only one cheat file and one companion per game build.", comment: "Cheat import")])
                }
                return files
            }
            DispatchQueue.main.async {
                importBusy = false
                switch result {
                case .success(let files):
                    pending = files
                    if files.contains(where: \.needsBuildConfirmation) { confirmBuild = true }
                    else { installPending() }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
    }
    private func installPending() {
        let files = pending
        pending = []
        guard !files.isEmpty, !state.folder.isEmpty else { return }
        importBusy = true
        let folder = URL(fileURLWithPath: state.folder, isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { for file in files { try file.install(in: folder) } }
            DispatchQueue.main.async {
                importBusy = false
                if case .failure(let failure) = result { error = failure.localizedDescription }
                reload()
            }
        }
    }
}

private struct CheatValueField: View {
    let id: Int32
    let value, bounds: String
    let changed: () -> Void
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Value", text: $text).keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused).onSubmit(commit)
                    .accessibilityIdentifier("cheats.value.\(id)")
                Button("Set value", action: commit).buttonStyle(.borderless)
            }
            if !bounds.isEmpty { Text(verbatim: bounds).font(.caption).foregroundStyle(.secondary) }
            if invalid { Text("Enter a value within the allowed range.").font(.caption).foregroundStyle(.red) }
        }
        .onAppear { text = value }
        .onChange(of: value) { _, new in if !focused { text = new } }
    }
    private func commit() {
        invalid = dm_cheat_value_set(id, text) != 0
        if !invalid { focused = false; changed() }
    }
}
