import SwiftUI
import UIKit

// Full-screen SwiftUI views leave orientation restrictions to the scene.
final class DmHostingController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
}
