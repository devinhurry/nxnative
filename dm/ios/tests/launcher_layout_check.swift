// Native layout smoke checks for the status dashboard and shared settings page.
import AppKit
import SwiftUI

func checkLauncherLayout(_ model: LauncherModel, defaults: UserDefaults) -> Int {
    NSApplication.shared.setActivationPolicy(.prohibited)
    var failed = 0
    func expect(_ condition: Bool, _ message: String) {
        print((condition ? "PASS " : "FAIL ") + message)
        if !condition { failed += 1 }
    }
    var backgroundCalls = 0
    prepareGameSettingsBackground(model) {
        backgroundCalls += 1
        expect(model.picturePreviewFrame == nil, "a renderer without a frame still allows settings to pause")
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    expect(backgroundCalls == 1, "capture readiness signals pause once, including the no-frame timeout")
    var cancelledCalls = 0
    let cancel = prepareGameSettingsBackground(model) { cancelledCalls += 1 }
    cancel()
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    expect(cancelledCalls == 0 && model.picturePreviewFrame == nil && model.gameSettingsBackground == nil,
           "closing settings cancels frame delivery and the timeout without a late pause")
    expect(checkSettingsPauseQueue(), "GPU/audio pause and resume run in order off the UI thread")
    func fitting<V: View>(_ content: V, width: CGFloat) -> NSSize {
        let view = NSHostingView(rootView: content.defaultAppStorage(defaults))
        view.sizingOptions = []
        view.frame = NSRect(x: 0, y: 0, width: width, height: 540)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return view.fittingSize
    }
    for width: CGFloat in [720, 1000] {
        let dashboard = fitting(LauncherView(m: model, done: { _ in }), width: width)
        expect(dashboard.width.isFinite && dashboard.width <= width && dashboard.height <= 540,
               "status dashboard fits the native window at \(width)pt")
    }
    for width: CGFloat in [320, 430, 720, 1000] {
        let page = fitting(LauncherSettingsPage(m: model, close: {}), width: width)
        expect(page.width.isFinite && page.width <= width && page.height <= 540,
               "shared settings page fits the native window at \(width)pt")
    }
    for width: CGFloat in [320, 720, 1000] {
        let filter = fitting(PictureFilterSettingsView(m: model, close: {}, back: {}), width: width)
        expect(filter.width.isFinite && filter.width <= width && filter.height <= 540,
               "current-picture filter editor fits at \(width)pt")
    }
    return failed
}
