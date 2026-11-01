// A small simulator app using the production launcher. Play exposes the applied
// values; Reopen checks saved choices without needing game files or a GPU host.
import UIKit

// The production launcher reads cloud-save providers through its app bridge.
// This isolated UI fixture has no shared-folder access or cloud-save storage.
func dm_clear_cloud_saves() {}
func dm_store_cloud_saves(_ url: URL) -> Bool { false }
func dm_cloud_saves_path(_ stale: UnsafeMutablePointer<ObjCBool>?) -> String? { nil }

final class LauncherHarnessRoot: UIViewController {
    private var shown = false
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !shown else { return }
        shown = true; reopen()
    }
    @objc func reopen() {
        _ = dmShowLauncher(Unmanaged.passUnretained(self).toOpaque(), {
            let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
            (scene.windows.first!.rootViewController as! LauncherHarnessRoot).showApplied()
        })
    }
    func showApplied() {
        view.subviews.forEach { $0.removeFromSuperview() }
        let values = (TouchStickResponse.keys.union(["DM_FPS_TARGET", "DM_LOW_MEMORY", "DM_PRESENT_UPSCALE", "DM_FRAMEGEN"])).sorted().map { "\($0)=\(ProcessInfo.processInfo.environment[$0] ?? "unset")" }.joined(separator: "\n")
        let text = UILabel(); text.text = "Applied to the game environment\n\n" + values
        text.textColor = .white; text.numberOfLines = 0; text.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        let reopen = UIButton(type: .system); reopen.setTitle("Reopen launcher", for: .normal)
        reopen.addTarget(self, action: #selector(self.reopen), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [text, reopen]); stack.axis = .vertical; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
    }
}

final class LauncherHarnessScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        if CommandLine.arguments.contains("--custom-stick") {
            for (key, value) in ["DM_BOTW_MOVE_DEADZONE": "0.15", "DM_BOTW_MOVE_CURVE": "1.00",
                                 "DM_BOTW_MOVE_FULL": "0.60", "DM_BOTW_MOVE_SIZE": "1.25", "DM_FPS_TARGET": "30"] {
                UserDefaults.standard.set(value, forKey: "launcher." + key)
            }
        }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = LauncherHarnessRoot(); window.backgroundColor = .black
        window.makeKeyAndVisible(); self.window = window
    }
}

@main final class LauncherHarnessApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Launcher test", sessionRole: session.role)
        config.delegateClass = LauncherHarnessScene.self
        return config
    }
}
