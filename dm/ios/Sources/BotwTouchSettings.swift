// The BOTW touch editor uses the same geometry as UIKit and the Mac touch preview.
import SwiftUI
import Charts
import DmTouchPad
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum BotwTouchPage: String, CaseIterable {
    case normal = "Normal layout"
    case compact = "Compact layout"
    case stick = "Left-stick parameters"
    var identifier: String {
        switch self { case .normal: return "normal"; case .compact: return "compact"; case .stick: return "stick" }
    }
}

struct BotwTouchSettingsMenu: View {
    @ObservedObject var m: LauncherModel
    let open: (BotwTouchPage) -> Void
    var body: some View {
        Section("BOTW touch settings") {
            ForEach(BotwTouchPage.allCases, id: \.self) { page in
                Button { open(page) } label: {
                    HStack {
                        Text(LocalizedStringKey(page.rawValue))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }.contentShape(Rectangle())
                }
                .accessibilityIdentifier("settings.touch." + page.identifier)
            }
        }
        Section("Saved touch layouts") { BotwTouchLibraryControls(m: m) }
        if let row = m.settings.first(where: { $0.env == "DM_BOTW_PORTRAIT" }) {
            Section { SettingRow(s: row, m: m) }
        }
        Section {
            Button("Restore all touch defaults") { m.reset(keys: m.touchSettingsKeys) }
        }
    }
}

private struct BotwTouchJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw BotwTouchFileError.invalid }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct BotwTouchLibraryControls: View {
    @ObservedObject var m: LauncherModel
    @State private var importing = false
    @State private var exporting = false
    @State private var document: BotwTouchJSONDocument?
    @State private var naming = false
    @State private var namingAction = "New layout"
    @State private var name = ""
    @State private var showingMessage = false
    @State private var message = ""

    private func show(_ text: String) { message = text; showingMessage = true }
    private func areas() -> (BotwTouchArea, BotwTouchArea) {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
            .sorted { $0.activationState == .foregroundActive && $1.activationState != .foregroundActive }
        let windows = scenes.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return (.normal, .compact) }
        let bounds = window.bounds
        let division = dm_botw_touch_division(window)
        let width = Double(bounds.width), height = Double(division.isNull ? bounds.height : bounds.height - division.maxY)
        if !division.isNull {
            let pane = BotwTouchArea(width: width, height: height)
            return (pane, pane)
        }
        let normal = height > width && width < 600 ? BotwTouchArea(width: height, height: width) : BotwTouchArea(width: width, height: height)
        return (normal, BotwTouchArea(width: min(width, height), height: max(width, height)))
        #else
        let windows = NSApplication.shared.windows
        let gameWindow = windows.first { $0.contentView.map { String(describing: type(of: $0)) == "DmGameView" } ?? false }
        let size = (gameWindow ?? windows.first(where: { $0.isKeyWindow }))?.contentView?.bounds.size ?? CGSize(width: 932, height: 430)
        let normal = BotwTouchArea(width: Double(size.width), height: Double(size.height))
        if ProcessInfo.processInfo.environment["DM_TEST_BOTW_SEATED"] == "1" {
            let pane = BotwTouchArea(width: normal.width, height: normal.height * 0.49)
            return (pane, pane)
        }
        return (normal, BotwTouchArea(width: min(normal.width, normal.height), height: max(normal.width, normal.height)))
        #endif
    }
    private func export(all: Bool) {
        do {
            let (normal, compact) = areas()
            document = BotwTouchJSONDocument(data: try m.exportTouchLayouts(all: all, normalArea: normal, compactArea: compact))
            exporting = true
        } catch { show(error.localizedDescription) }
    }
    private func beginNaming(_ action: String) {
        namingAction = action
        name = action == "Rename layout" ? m.touchLayouts.first(where: { $0.id == m.selectedTouchLayoutID })?.name ?? "" :
            String(format: NSLocalizedString("Layout %d", comment: ""), m.touchLayouts.count + 1)
        naming = true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Saved layout", selection: Binding(get: { m.selectedTouchLayoutID }, set: m.selectTouchLayout)) {
                ForEach(m.touchLayouts) { layout in
                    Text(layout.name == "Default layout" ? NSLocalizedString("Default layout", comment: "") : layout.name).tag(layout.id)
                }
            }.accessibilityIdentifier("botw.layouts.selection")
            HStack {
                Menu("Manage layouts") {
                    Button("New layout") { beginNaming("New layout") }
                    Button("Duplicate layout") { beginNaming("Duplicate layout") }
                    Button("Rename layout") { beginNaming("Rename layout") }
                    Button("Delete layout", role: .destructive) { m.deleteTouchLayout(m.selectedTouchLayoutID) }
                        .disabled(m.touchLayouts.count <= 1)
                }.accessibilityIdentifier("botw.layouts.manage")
                Spacer()
                Button("Import JSON") { importing = true }.accessibilityIdentifier("botw.layouts.import")
                Menu("Export JSON") {
                    Button("Export current layout") { export(all: false) }
                    Button("Export all layouts") { export(all: true) }
                }.accessibilityIdentifier("botw.layouts.export")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 4_194_304 { throw BotwTouchFileError.limit }
                let (normal, compact) = areas()
                let count = try m.importTouchLayouts(Data(contentsOf: url, options: .mappedIfSafe), normalArea: normal, compactArea: compact)
                show(String(format: NSLocalizedString("Imported %d layouts. Select a layout to use it.", comment: ""), count))
            } catch { if (error as NSError).code != NSUserCancelledError { show(error.localizedDescription) } }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "botw-touch-layouts") { result in
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { show(error.localizedDescription) }
        }
        .alert(LocalizedStringKey(namingAction), isPresented: $naming) {
            TextField("Layout name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if namingAction == "Rename layout" { m.renameTouchLayout(name) }
                else { m.addTouchLayout(name: name, copyCurrent: namingAction == "Duplicate layout") }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
        }
        .alert("Touch layouts", isPresented: $showingMessage) { Button("OK", role: .cancel) {} } message: { Text(message) }
    }
}

struct BotwStickSettingsView: View {
    @ObservedObject var m: LauncherModel
    @State private var portrait = false
    var body: some View {
        Form {
            Section {
                Picker("Layout", selection: $portrait) {
                    Text("Normal layout").tag(false)
                    Text("Compact layout").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("botw.touch.profile")
            }
            if let response = m.touchStickResponse(portrait: portrait) {
                Section("Left-stick response") { TouchStickPreview(response: response) }
                Section {
                    ForEach(m.rows(in: TouchStickResponse.section).filter { m.touchSettingsKeys(portrait: portrait).contains($0.env) }) {
                        SettingRow(s: $0, m: m)
                    }
                }
                Section {
                    Button("Restore left-stick defaults") {
                        m.reset(keys: Set(TouchStickResponse.keys.map { botwTouchKey($0, portrait: portrait) }))
                    }
                }
            }
        }.formStyle(.grouped)
    }
}

struct BotwTouchSettingsView: View {
    @ObservedObject var m: LauncherModel
    let portrait: Bool
    let background: Image?
    let close: () -> Void
    @State private var values: [String: String]
    @State private var originalValues: [String: String]
    @State private var selected = BotwTouchControl.all[4]
    @State private var confirmingExit = false
    @State private var saveFailed = false
    @State private var exporting = false
    @State private var document: BotwTouchJSONDocument?
    @State private var exportError: String?
    @State private var controlRegion = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var panelInsets = EdgeInsets()
    @State private var editorArea = CGSize(width: 932, height: 430)
    private var controls: [BotwTouchControl] {
        BotwTouchControl.editable.filter { control in
            var config = layout
            return dm_botw_layout_control_visible(&config, Int32(control.id)) != 0
        }
    }
    private var controlOptions: [Setting] {
        let keys = selected.keys(portrait: portrait)
        return m.settings.filter { keys.contains($0.env) && $0.kind == "choice" && !$0.env.hasSuffix("_ANCHOR") }
    }
    private func controlOption(_ row: Setting) -> some View {
        Picker(LocalizedStringKey(row.env.hasSuffix("_MODE") ? "Button action" : row.label),
               selection: Binding(get: { values[row.env] ?? row.def }, set: { values[row.env] = $0 })) {
            if row.env == selected.option("MODE", portrait: portrait) {
                if selected.id == 6 {
                    Text("Native L").tag("0")
                    Text("Hold to switch (release to close)").tag("1")
                    Text("Hold to switch (cancel to close)").tag("2")
                } else {
                    Text("Open inventory").tag("0")
                    Text("Hold to switch (release to close)").tag("1")
                    Text("Tap to switch (cancel to close)").tag("2")
                }
            } else {
                ForEach(row.options ?? [], id: \.[0]) { Text(LocalizedStringKey($0[1])).tag($0[0]) }
            }
        }
        .pickerStyle(.menu)
        .disabled(m.fixed.contains(row.env))
        .accessibilityIdentifier(row.env)
    }

    init(m: LauncherModel, portrait: Bool, background: Image? = nil, close: @escaping () -> Void) {
        self.m = m; self.portrait = portrait; self.background = background; self.close = close
        _values = State(initialValue: m.values)
        _originalValues = State(initialValue: m.values)
    }
    private func key(_ base: String) -> String { botwTouchKey(base, portrait: portrait) }
    private var layout: dm_botw_touch_layout { m.touchLayout(portrait: portrait, values: values) }
    private func rect(_ control: BotwTouchControl, in area: CGSize) -> CGRect {
        var config = layout
        let r = dm_botw_layout_control(&config, Int32(control.id), Float(area.width), Float(area.height), 0, 0, 0, 0,
            dm_botw_layout_canvas(Float(area.width), Float(area.height)))
        return CGRect(x: Double(r.x), y: Double(r.y), width: Double(r.width), height: Double(r.height))
    }
    private func menuRect(_ id: Int, in area: CGRect) -> CGRect {
        let r: dm_touchpad_rect
        if area.minY > 0 {
            r = dm_touchpad_seated_menu(dm_touchpad_rect(x: 0, y: 0, width: Float(area.width), height: Float(area.height)), id == 11 ? 1 : 0)
        } else {
            var config = layout
            r = dm_botw_layout_control(&config, Int32(id), Float(area.width), Float(area.height),
                Float(panelInsets.leading), Float(panelInsets.top), Float(panelInsets.trailing), Float(panelInsets.bottom),
                dm_botw_layout_canvas(Float(area.width), Float(area.height)))
        }
        return CGRect(x: Double(r.x), y: Double(r.y), width: Double(r.width), height: Double(r.height))
    }
    private func reset(_ keys: Set<String>) {
        for row in m.settings where keys.contains(row.env) && !m.fixed.contains(row.env) { values[row.env] = row.def }
    }
    private var hasUnsavedChanges: Bool {
        let keys = m.touchSettingsKeys(portrait: portrait)
        return m.settings.contains { row in
            guard keys.contains(row.env), !m.fixed.contains(row.env) else { return false }
            let original = originalValues[row.env] ?? row.def, current = values[row.env] ?? row.def
            return row.kind == "range" ? Double(original) != Double(current) : original != current
        }
    }
    private func requestExit() {
        if hasUnsavedChanges { confirmingExit = true }
        else { close() }
    }
    private func exportParameters() {
        do {
            document = BotwTouchJSONDocument(data: try m.exportTouchLayoutDraft(values, portrait: portrait,
                area: .init(width: Double(editorArea.width), height: Double(editorArea.height))))
            exporting = true
        } catch { exportError = error.localizedDescription }
    }
    private var panel: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: requestExit) { Text("Exit").frame(minWidth: 44, minHeight: 44) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("botw.touch.exit")
                Spacer(minLength: 8)
                Text(LocalizedStringKey(portrait ? "Compact layout" : "Normal layout")).font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                Menu("Reset") {
                    Button("Restore this control") { reset(selected.keys(portrait: portrait)) }
                    Button("Restore this layout") { reset(m.touchSettingsKeys(portrait: portrait)) }
                }.accessibilityIdentifier("botw.touch.reset")
                Button("Save") {
                    if m.saveTouchSettings(values, portrait: portrait) { close() }
                    else { saveFailed = true }
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("botw.touch.save")
            }
            HStack {
                Picker("Control", selection: $selected) {
                    ForEach(controls) { Text(LocalizedStringKey($0.label)).tag($0) }
                }.pickerStyle(.menu).labelsHidden().accessibilityIdentifier("botw.touch.control")
                if controlOptions.count == 1, let row = controlOptions.first {
                    controlOption(row).labelsHidden()
                } else if controlOptions.count > 1 {
                    Menu {
                        ForEach(controlOptions) { controlOption($0) }
                    } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Button options") }
                    .accessibilityIdentifier("botw.touch.control.options")
                }
                Menu {
                    ForEach((BotwTouchControl.added + [BotwTouchControl.all.last!]).filter { !controls.contains($0) }) { control in
                        Button(LocalizedStringKey(control.label)) {
                            values[control.visibilityKey(portrait: portrait)] = "1"
                            selected = control
                        }.disabled(m.fixed.contains(control.visibilityKey(portrait: portrait)))
                    }
                } label: { Image(systemName: "plus.circle").accessibilityLabel("Add button") }
                .accessibilityIdentifier("botw.touch.add")
                Spacer(minLength: 8)
                Menu {
                    if let row = m.settings.first(where: { $0.env == key("DM_BOTW_PAD_BADGES") }) {
                        Toggle("Corner button labels", isOn: Binding(
                            get: { values[row.env] == row.onValue },
                            set: { values[row.env] = $0 ? row.onValue : row.offValue }))
                            .disabled(m.fixed.contains(row.env))
                    }
                    Button(action: exportParameters) {
                        Label("Export JSON", systemImage: "square.and.arrow.up")
                    }.accessibilityIdentifier("botw.touch.export")
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Layout options") }
                .accessibilityIdentifier("botw.touch.options")
            }
            if let row = m.settings.first(where: { $0.env == selected.env("SIZE", portrait: portrait) }) {
                BotwLayoutSlider(row: row, values: $values, locked: m.fixed.contains(row.env))
            }
        }
        .padding(12)
        .frame(maxWidth: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("botw.touch.panel")
    }
    var body: some View {
        GeometryReader { geometry in
            let area = CGRect(x: controlRegion.minX * geometry.size.width, y: controlRegion.minY * geometry.size.height,
                width: controlRegion.width * geometry.size.width, height: controlRegion.height * geometry.size.height)
            ZStack(alignment: .topLeading) {
                Color(white: background == nil ? 0.07 : 0)
                if let background {
                    background.resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                if area.minY > 0 {
                    Rectangle().fill(.white.opacity(background == nil ? 0.04 : 0)).frame(height: area.minY)
                        .overlay(alignment: .bottom) { Divider() }.allowsHitTesting(false)
                }
                ForEach(10...11, id: \.self) { id in
                    let r = menuRect(id, in: area)
                    BotwTouchArtwork(control: id, size: r.size, badges: false)
                        .position(x: area.minX + r.midX, y: area.minY + r.midY)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                ForEach(controls) { control in
                    let r = rect(control, in: area.size)
                    BotwControlPreview(control: control, m: m, values: $values, selected: $selected,
                        rect: r, area: area.size, layout: layout, portrait: portrait)
                        .frame(width: r.width, height: r.height)
                        .position(x: area.minX + r.midX, y: area.minY + r.midY)
                        .zIndex(selected.id == control.id ? 1 : 0)
                }
            }
            .onChange(of: area.size, initial: true) { _, size in
                editorArea = size
                m.rememberTouchArea(.init(width: Double(size.width), height: Double(size.height)), portrait: portrait)
            }
            .coordinateSpace(name: "touch-preview")
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("botw.touch.canvas")
            #if os(iOS)
            .background(BotwTouchAreaReader(region: $controlRegion, insets: $panelInsets, portrait: portrait, running: m.isRunning))
            #endif
            .overlay(alignment: .top) {
                panel
                    .padding(.horizontal, max(12, max(max(geometry.safeAreaInsets.leading, geometry.safeAreaInsets.trailing), max(panelInsets.leading, panelInsets.trailing))))
                    .padding(.top, max(12, max(geometry.safeAreaInsets.top, panelInsets.top)))
            }
        }
        .ignoresSafeArea()
        #if os(macOS)
        .onAppear {
            if ProcessInfo.processInfo.environment["DM_TEST_BOTW_SEATED"] == "1" {
                controlRegion = CGRect(x: 0, y: 0.51, width: 1, height: 0.49)
            }
        }
        #endif
        .onChange(of: values) { _, _ in
            if !controls.contains(selected) { selected = BotwTouchControl.all[4] }
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .alert("Unsaved layout changes", isPresented: $confirmingExit) {
            Button("Exit without saving", role: .destructive, action: close)
                .accessibilityIdentifier("botw.touch.discard")
            Button("Continue editing", role: .cancel) {}
                .accessibilityIdentifier("botw.touch.continue")
        } message: { Text("Exit without saving your changes?") }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "botw-touch-layout") { result in
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { exportError = error.localizedDescription }
        }
        .alert("Unable to export layout", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
        .alert("Unable to save layout", isPresented: $saveFailed) { Button("OK", role: .cancel) {} }
        .preferredColorScheme(.dark)
    }
}

#if os(iOS)
private struct BotwTouchAreaReader: UIViewRepresentable {
    @Binding var region: CGRect
    @Binding var insets: EdgeInsets
    let portrait: Bool
    let running: Bool
    func makeUIView(context: Context) -> BotwTouchAreaView {
        let view = BotwTouchAreaView()
        view.isUserInteractionEnabled = false
        view.changed = update
        view.portrait = portrait; view.running = running
        return view
    }
    func updateUIView(_ view: BotwTouchAreaView, context: Context) { view.changed = update }
    private func update(_ area: CGRect, _ safe: UIEdgeInsets) {
        region = area
        insets = EdgeInsets(top: safe.top, leading: safe.left, bottom: safe.bottom, trailing: safe.right)
    }
}

private final class BotwTouchAreaView: UIView {
    var changed: ((CGRect, UIEdgeInsets) -> Void)?
    var portrait = false
    var running = false
    private weak var editorWindow: UIWindow?
    private var previous = CGRect.null
    private var previousInsets = UIEdgeInsets.zero
    override var bounds: CGRect { didSet { if bounds != oldValue { setNeedsUpdateConstraints() } } }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsUpdateConstraints() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            editorWindow = window
            setBotwTouchEditorOrientation(portrait, window: window, running: running)
        } else if let editorWindow {
            setBotwTouchEditorOrientation(nil, window: editorWindow, running: running)
        }
        setNeedsUpdateConstraints()
    }
    override func updateConstraints() {
        let division = dm_botw_touch_division(self)
        let top = division.isNull || bounds.height <= 0 ? 0 : division.maxY / bounds.height
        let region = CGRect(x: 0, y: top, width: 1, height: 1 - top)
        // Only the floating panel avoids system insets. Control anchors use
        // the complete pane, just like the gamepad.
        let insets = window?.safeAreaInsets ?? safeAreaInsets
        if region != previous || insets != previousInsets {
            previous = region; previousInsets = insets
            let changed = changed
            DispatchQueue.main.async { changed?(region, insets) }
        }
        super.updateConstraints()
    }
}
#endif

private struct BotwLayoutSlider: View {
    let row: Setting
    @Binding var values: [String: String]
    let locked: Bool
    private var binding: Binding<Double> {
        .init(get: { Double(values[row.env] ?? row.def) ?? 0 }, set: { values[row.env] = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) })
    }
    var body: some View {
        HStack(spacing: 10) {
            Text("Size")
            Slider(value: binding, in: (row.min ?? 0)...(row.max ?? 1), step: row.step ?? 0.01)
                .accessibilityLabel("Size").accessibilityIdentifier(row.env)
            Text(String(format: "%.1f pt", binding.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
                .fixedSize()
        }.disabled(locked)
    }
}

// Use the game's assets, paths and palette, including the neutral stick state.
// The control's outer rectangle is its editable reach, not visible artwork.
private struct BotwTouchArtwork: View {
    let control: Int
    let size: CGSize
    let badges: Bool
    private var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    private var glyph: Color { Color(red: 226 / 255, green: 222 / 255, blue: 211 / 255).opacity(0.8) }
    private var outline: Color { Color(white: DM_BOTW_STROKE_GRAY).opacity(DM_BOTW_STROKE_ALPHA) }
    private var gold: Color { Color(red: 0.94, green: 0.88, blue: 0.70) }
    private static let icons: [Int: Image] = {
        var result: [Int: Image] = [:]
        for control in BotwTouchControl.editable {
            guard let path = dm_botw_touch_button_icon_path(Int32(control.id)) else { continue }
            #if os(iOS)
            if let image = UIImage(contentsOfFile: path) { result[control.id] = Image(uiImage: image).renderingMode(.original) }
            #else
            if let image = NSImage(contentsOfFile: path) { result[control.id] = Image(nsImage: image).renderingMode(.original) }
            #endif
        }
        return result
    }()
    var body: some View {
        ZStack(alignment: .topLeading) {
            if control == 4 {
                let unit = size.width / 154
                let radius = CGFloat(DM_TP_KNOB_R) * unit
                Path(ellipseIn: CGRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2))
                    .stroke(Color.white.opacity(DM_BOTW_STICK_GRAPH_ALPHA), lineWidth: 1.5)
                if let arrows = dm_botw_four_arrows_path(center, 17*unit, 12*unit) {
                    Path(arrows).fill(Color.white.opacity(DM_BOTW_STICK_GRAPH_ALPHA))
                }
            } else if control == 8 {
                if let shield = dm_botw_shield_graph_path(center, size.width / 154) { Path(shield).fill(glyph) }
            } else if control == 12 {
                ForEach(12..<16, id: \.self) { direction in
                    if let key = dm_botw_dpad_key_path(center, size.width / 2, Int32(direction)) { Path(key).fill(glyph) }
                }
            } else if control == 10 || control == 11 {
                Circle().fill(.black.opacity(0.4))
                if let key = dm_botw_menu_key_path(center, size.width * CGFloat(DM_TP_BOTW_MENU_GLYPH_SIZE / DM_TP_BOTW_MENU_SIZE), size.width, control == 10 ? 1 : 0) {
                    Path(key).fill(.white)
                }
            } else {
                let disk = CGPath(ellipseIn: CGRect(origin: .zero, size: size), transform: nil)
                Path(disk).fill(Color(white: DM_BOTW_BUTTON_GRAY).opacity(DM_BOTW_BUTTON_ALPHA))
                if let border = dm_botw_outer_border_path(disk, 1.5 * CGFloat(DM_BOTW_STROKE_WIDTH_SCALE)) {
                    Path(border).fill(outline)
                }
                if let icon = Self.icons[control] {
                    icon.resizable().scaledToFit().frame(width: size.width*0.5, height: size.height*0.5)
                        .position(center)
                }
                if control == 20, let cancel = dm_botw_switch_cancel_path(center, size.width) { Path(cancel).fill(glyph) }
                if badges && control < 16 {
                    let rect = dm_botw_button_badge_rect(center, size.width / 2)
                    let badge = CGPath(ellipseIn: rect, transform: nil)
                    Path(badge).fill(Color(white: 0.2))
                    if let border = dm_botw_outer_border_path(badge, 1.15 * CGFloat(DM_BOTW_STROKE_WIDTH_SCALE)) { Path(border).fill(gold) }
                    Text(BotwTouchControl.all.first(where: { $0.id == control })?.key ?? "")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(gold)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }.frame(width: size.width, height: size.height)
    }
}

private struct BotwControlPreview: View {
    let control: BotwTouchControl
    @ObservedObject var m: LauncherModel
    @Binding var values: [String: String]
    @Binding var selected: BotwTouchControl
    let rect: CGRect
    let area: CGSize
    let layout: dm_botw_touch_layout
    let portrait: Bool
    @State private var dragRect: CGRect?
    @State private var scaleOrigin: Double?
    private var gold: Color { Color(red: 0.94, green: 0.88, blue: 0.70) }
    private var badges: Bool { layout.badges != 0 }
    private func set(_ field: String, _ value: Double) {
        let key = control.env(field, portrait: portrait)
        guard !m.fixed.contains(key), let row = m.settings.first(where: { $0.env == key }) else { return }
        guard value.isFinite else { return }
        values[key] = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), min(max(value, row.min ?? 0), row.max ?? 1))
    }
    var body: some View {
        ZStack {
            BotwTouchArtwork(control: control.id, size: rect.size, badges: badges)
            if selected.id == control.id { RoundedRectangle(cornerRadius: 8).stroke(gold, style: StrokeStyle(lineWidth: 2, dash: [4,3])).padding(-3) }
        }
        .foregroundStyle(gold)
        .contentShape(Circle())
        .onTapGesture { selected = control }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("touch-preview")).onChanged { event in
            selected = control
            let anchorKey = control.option("ANCHOR", portrait: portrait)
            let xKey = control.env("X", portrait: portrait), yKey = control.env("Y", portrait: portrait)
            guard !m.fixed.contains(anchorKey), !m.fixed.contains(xKey), !m.fixed.contains(yKey) else { return }
            if dragRect == nil { dragRect = rect }
            if let start = dragRect {
                let x = min(max(start.minX + event.translation.width, 0), max(0, area.width - start.width))
                let y = min(max(start.minY + event.translation.height, 0), max(0, area.height - start.height))
                let right = x + start.width / 2 > area.width / 2
                var next = values
                next[anchorKey] = right ? "2" : "1"
                next[xKey] = LauncherModel.touchPoint(Double(max(0, right ? area.width - x - start.width : x)))
                next[yKey] = LauncherModel.touchPoint(Double(max(0, area.height - y - start.height)))
                values = next
            }
        }.onEnded { _ in dragRect = nil })
        .simultaneousGesture(MagnifyGesture().onChanged { event in
            selected = control
            if scaleOrigin == nil { scaleOrigin = Double(values[control.env("SIZE", portrait: portrait)] ?? "1") ?? 1 }
            set("SIZE", scaleOrigin! * event.magnification)
        }.onEnded { _ in scaleOrigin = nil })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(control.label))).accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("botw.touch.preview.\(control.key)")
        .accessibilityAction { selected = control }
        .overlay(alignment: .topTrailing) {
            if control.removable {
                Button {
                    values[control.visibilityKey(portrait: portrait)] = "0"
                    if selected == control { selected = BotwTouchControl.all[4] }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .frame(width: 32, height: 32).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(m.fixed.contains(control.visibilityKey(portrait: portrait)))
                .accessibilityLabel("Remove button")
                .accessibilityIdentifier("botw.touch.remove.\(control.key)")
            }
        }
    }
}

struct TouchStickPreview: View {
    let response: TouchStickResponse
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                RuleMark(x: .value("Deadzone", response.deadzone * 100))
                    .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                RuleMark(x: .value("Full movement", response.full * 100))
                    .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ForEach(0...100, id: \.self) { i in
                    LineMark(x: .value("Finger travel", Double(i)), y: .value("Stick strength", response.strength(at: Double(i) / 100) * 100))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .chartXScale(domain: 0...100).chartYScale(domain: 0...100)
            .chartXAxis { AxisMarks(values: [0, 25, 50, 75, 100]) }
            .chartYAxis { AxisMarks(values: [0, 50, 100]) }
            .chartXAxisLabel("Finger travel (%)")
            .chartYAxisLabel("Stick strength (%)")
            .frame(height: 150)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Left-stick response preview")
            .accessibilityIdentifier("botw.touch.curve")
            .allowsHitTesting(false)
            Text("Applies to BOTW touch movement.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
