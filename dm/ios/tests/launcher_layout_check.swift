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
        let page = fitting(LauncherSettingsPage(m: model, close: {}), width: width)
        expect(page.width.isFinite && page.width <= width && page.height <= 540,
               "shared settings page fits the native window at \(width)pt")
    }
    return failed
}
