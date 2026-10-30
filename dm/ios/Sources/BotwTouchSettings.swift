// The BOTW touch editor uses the same geometry as UIKit and the Mac touch preview.
import SwiftUI
import Charts
import DmTouchPad
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct BotwTouchSettingsView: View {
    @ObservedObject var m: LauncherModel
    @Environment(\.dismiss) private var dismiss
    var viewport = CGSize(width: 932, height: 430)
    var safeInsets = EdgeInsets()
    @State private var selected = BotwTouchControl.all[1]
    @State private var copied = false

    private func value(_ key: String, fallback: Double = 0) -> Double {
        guard let row = m.settings.first(where: { $0.env == key }) else { return fallback }
        let text = m.values[key] ?? row.def
        return Double(row.accepts(text) ? text : row.def) ?? fallback
    }
    private var layout: dm_botw_touch_layout {
        var result = dm_botw_layout_defaults()
        withUnsafeMutableBytes(of: &result.control) { bytes in
            let controls = bytes.bindMemory(to: dm_botw_control_transform.self)
            for control in BotwTouchControl.all {
                let base = controls[control.id]
                controls[control.id] = .init(x: Float(value(control.env("X"), fallback: Double(base.x))),
                    y: Float(value(control.env("Y"), fallback: Double(base.y))),
                    scale: control.id == 4 ? 1 : Float(value(control.env("SCALE"), fallback: Double(base.scale))))
            }
        }
        result.face_gap = Float(value("DM_BOTW_PAD_FACE_GAP", fallback: Double(result.face_gap)))
        result.badges = value("DM_BOTW_PAD_BADGES", fallback: Double(result.badges)) == 0 ? 0 : 1
        return result
    }
    private var canvas: dm_touchpad_rect { dm_botw_layout_canvas(Float(viewport.width), Float(viewport.height)) }
    private func rect(_ control: BotwTouchControl) -> CGRect {
        var config = layout
        let r = dm_botw_layout_control(&config, Int32(control.id), Float(viewport.width), Float(viewport.height),
            Float(safeInsets.leading), Float(safeInsets.top), Float(safeInsets.trailing), Float(safeInsets.bottom), canvas)
        let size = control.id == 4 ? value("DM_BOTW_MOVE_SIZE", fallback: 0.8) : 1
        return CGRect(x: Double(r.x) + Double(r.width) * (1-size) / 2,
            y: Double(r.y) + Double(r.height) * (1-size) / 2, width: Double(r.width)*size, height: Double(r.height)*size)
    }
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    #if os(iOS)
                    Button(action: { dismiss() }) { Image(systemName: "chevron.left") }
                        .accessibilityLabel(Text("Back"))
                    #endif
                    Text("Touch layout").font(.headline)
                }
                GeometryReader { geometry in
                    let scale = min(geometry.size.width / viewport.width, geometry.size.height / viewport.height)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.10))
                        ForEach(BotwTouchControl.all) { control in
                            let r = rect(control)
                            BotwControlPreview(control: control, m: m, selected: $selected, canvas: canvas,
                                previewScale: scale, rect: r, gap: Double(layout.face_gap))
                                .frame(width: r.width*scale, height: r.height*scale)
                                .position(x: r.midX*scale, y: r.midY*scale)
                        }
                    }
                    .coordinateSpace(name: "touch-preview")
                    .frame(width: viewport.width*scale, height: viewport.height*scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text("Select a control, then drag to move or pinch to resize. Outlines show its size. Changes are saved when you tap Play.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Control", selection: $selected) {
                        ForEach(BotwTouchControl.all) { Text(LocalizedStringKey($0.label)).tag($0) }
                    }.pickerStyle(.menu).accessibilityIdentifier("botw.touch.control")
                    ForEach(["X", "Y", "SCALE"], id: \.self) { field in
                        if let row = m.settings.first(where: { $0.env == selected.env(field) }) {
                            BotwLayoutSlider(row: row, title: field == "X" ? "Horizontal offset" : field == "Y" ? "Vertical offset" : "Size", m: m)
                        }
                    }
                    if selected.id == 0, let row = m.settings.first(where: { $0.env == "DM_BOTW_PAD_FACE_GAP" }) {
                        BotwLayoutSlider(row: row, title: "Button spacing", m: m)
                    }
                    Button("Restore this control") { m.reset(keys: selected.keys.union(selected.id == 0 ? ["DM_BOTW_PAD_FACE_GAP"] : [])) }
                    Divider()
                    if let row = m.settings.first(where: { $0.env == "DM_BOTW_PAD_BADGES" }) { SettingRow(s: row, m: m) }
                    Divider()
                    if let response = m.touchStickResponse {
                        Text("Left-stick response").font(.headline)
                        TouchStickPreview(response: response)
                        ForEach(m.rows(in: TouchStickResponse.section).filter { $0.env != "DM_BOTW_MOVE_SIZE" }) { SettingRow(s: $0, m: m) }
                    }
                    Button("Restore all touch defaults") { m.reset(keys: m.touchSettingsKeys) }
                    Divider()
                    Button(action: {
                        #if os(iOS)
                        UIPasteboard.general.string = m.touchSettingsExport
                        #else
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(m.touchSettingsExport, forType: .string)
                        #endif
                        copied = true
                    }) { Label(copied ? "Copied" : "Copy all parameters", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .accessibilityIdentifier("botw.touch.copy")
                    DisclosureGroup("Current parameters") {
                        Text(m.touchSettingsExport).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .accessibilityIdentifier("botw.touch.parameters")
                    }
                    Text("Send these values to use this layout as the default. Offsets are fractions of the game UI area; positive X moves right and positive Y moves down.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }.frame(width: 285)
        }
        .padding(16)
        .onChange(of: m.values) { _, _ in copied = false }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }
}

private struct BotwLayoutSlider: View {
    let row: Setting
    let title: String
    @ObservedObject var m: LauncherModel
    private var binding: Binding<Double> {
        .init(get: { Double(m.values[row.env] ?? row.def) ?? 0 }, set: { m.values[row.env] = String(format: "%.3f", $0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(LocalizedStringKey(title)); Spacer(); Text(String(format: "%.3f (%.1f%%)", binding.wrappedValue, binding.wrappedValue*100)).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: binding, in: (row.min ?? 0)...(row.max ?? 1), step: row.step ?? 0.01)
                .accessibilityLabel(Text(LocalizedStringKey(title))).accessibilityIdentifier(row.env)
        }.disabled(m.fixed.contains(row.env))
    }
}

private struct BotwControlPreview: View {
    let control: BotwTouchControl
    @ObservedObject var m: LauncherModel
    @Binding var selected: BotwTouchControl
    let canvas: dm_touchpad_rect
    let previewScale: CGFloat
    let rect: CGRect
    let gap: Double
    @State private var dragOrigin: CGPoint?
    @State private var scaleOrigin: Double?
    private var gold: Color { Color(red: 0.94, green: 0.88, blue: 0.70) }
    private var badges: Bool { (m.values["DM_BOTW_PAD_BADGES"] ?? "0") != "0" }
    private func icon(_ name: String) -> Image? {
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("dm/touch_\(name.lowercased()).png").path else { return nil }
        #if os(iOS)
        return UIImage(contentsOfFile: path).map { Image(uiImage: $0) }
        #else
        return NSImage(contentsOfFile: path).map { Image(nsImage: $0) }
        #endif
    }
    private func button(_ name: String, diameter: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color(white: 0.35).opacity(0.2))
                .overlay(Circle().strokeBorder(Color(white: 0.52).opacity(0.4), lineWidth: max(0.5, 1.8*previewScale)))
            if let art = icon(name) { art.resizable().scaledToFit().frame(width: diameter*0.5, height: diameter*0.5) }
            else { Text(name).font(.system(size: max(9,diameter*0.35))) }
            if badges {
                Circle().fill(Color(white: 0.2)).overlay(Circle().stroke(gold, lineWidth: max(0.5,previewScale)))
                    .overlay(Text(name).font(.system(size: max(5,diameter*0.17))))
                    .frame(width: diameter*0.3, height: diameter*0.3)
                    .offset(x: diameter*0.353553, y: -diameter*0.353553)
            }
        }
    }
    private func set(_ field: String, _ value: Double) {
        let key = control.env(field)
        guard !m.fixed.contains(key), let row = m.settings.first(where: { $0.env == key }) else { return }
        m.values[key] = String(format: "%.3f", min(max(value, row.min ?? 0), row.max ?? 1))
    }
    private func faceButton(_ index: Int) -> some View {
        let radius: CGFloat = rect.width * CGFloat(DM_TP_FACE_R) / (CGFloat(DM_TP_FACE_R) + CGFloat(DM_TP_FACE_GAP)*CGFloat(gap)) / 2
        let diameter: CGFloat = radius * 2 * previewScale
        let spacing: CGFloat = (rect.width / 2 - radius) * previewScale
        let position = CGPoint(x: index == 0 ? spacing : index == 3 ? -spacing : 0,
                               y: index == 1 ? spacing : index == 2 ? -spacing : 0)
        return button(["A","B","X","Y"][index], diameter: diameter)
            .frame(width: diameter, height: diameter)
            .offset(x: position.x, y: position.y)
    }
    var body: some View {
        ZStack {
            if control.id == 0 {
                ForEach(0..<4) { i in faceButton(i) }
            } else if control.id == 6 || control.id == 7 || control.id == 9 {
                button(control.key, diameter: rect.width*previewScale)
            } else {
                Circle().fill(Color(white: 0.35).opacity(0.2)).overlay(Circle().stroke(Color(white: 0.52).opacity(0.4), lineWidth: 1))
                if control.id == 4 || control.id == 12 || control.id == 8 {
                    Image(systemName: control.id == 8 ? "shield" : control.id == 12 ? "dpad" : "circle")
                        .font(.system(size: min(rect.width,rect.height)*previewScale*0.4))
                } else { Text(control.id == 6 ? "L" : control.label).font(.system(size: max(10,rect.width*previewScale*0.35))) }
            }
            if selected.id == control.id { RoundedRectangle(cornerRadius: 8).stroke(gold, style: StrokeStyle(lineWidth: 2, dash: [4,3])).padding(-3) }
        }
        .foregroundStyle(gold)
        .contentShape(Rectangle())
        .onTapGesture { selected = control }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("touch-preview")).onChanged { event in
            selected = control
            if dragOrigin == nil { dragOrigin = CGPoint(x: Double(m.values[control.env("X")] ?? "0") ?? 0, y: Double(m.values[control.env("Y")] ?? "0") ?? 0) }
            set("X", dragOrigin!.x + event.translation.width / (Double(canvas.width)*previewScale))
            set("Y", dragOrigin!.y + event.translation.height / (Double(canvas.height)*previewScale))
        }.onEnded { _ in dragOrigin = nil })
        .simultaneousGesture(MagnifyGesture().onChanged { event in
            selected = control
            if scaleOrigin == nil { scaleOrigin = Double(m.values[control.env("SCALE")] ?? "1") ?? 1 }
            set("SCALE", scaleOrigin! * event.magnification)
        }.onEnded { _ in scaleOrigin = nil })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(control.label))).accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("botw.touch.preview.\(control.key)")
        .accessibilityAction { selected = control }
    }
}

struct TouchStickPreview: View {
    let response: TouchStickResponse
    @State private var travel = 0.2

    private var readout: String {
        String(format: NSLocalizedString("Drag %d%% → Stick %d%%", comment: "Touch response preview"), Int((travel * 100).rounded()), Int((response.strength(at: travel) * 100).rounded()))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(readout).monospacedDigit().font(.callout)
            Chart {
                RuleMark(x: .value("Deadzone", response.deadzone * 100))
                    .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                RuleMark(x: .value("Full movement", response.full * 100))
                    .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ForEach(0...100, id: \.self) { i in
                    LineMark(x: .value("Finger travel", Double(i)), y: .value("Stick strength", response.strength(at: Double(i) / 100) * 100))
                        .foregroundStyle(Color.accentColor)
                }
                PointMark(x: .value("Finger travel", travel * 100), y: .value("Stick strength", response.strength(at: travel) * 100))
                    .foregroundStyle(Color.primary).symbolSize(45)
            }
            .chartXScale(domain: 0...100).chartYScale(domain: 0...100)
            .chartXAxis { AxisMarks(values: [0, 25, 50, 75, 100]) }
            .chartYAxis { AxisMarks(values: [0, 50, 100]) }
            .chartXAxisLabel("Finger travel (%)")
            .chartYAxisLabel("Stick strength (%)")
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { event in
                            guard let frame = proxy.plotFrame,
                                  let x: Double = proxy.value(atX: event.location.x - geometry[frame].minX) else { return }
                            travel = min(max(x / 100, 0), 1)
                        })
                }
            }
            .frame(height: 150)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Left-stick response preview")
            .accessibilityValue(readout)
            .accessibilityAdjustableAction { direction in
                travel = min(max(travel + (direction == .increment ? 0.05 : -0.05), 0), 1)
            }
            Text("Drag across the chart to preview. Applies to BOTW touch movement. Saved when you tap Play.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

