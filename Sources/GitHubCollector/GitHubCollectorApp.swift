import AppKit
import SwiftUI

@main
struct GitHubCollectorApp: App {
    init() {
        DispatchQueue.main.async {
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let image = NSImage(contentsOf: iconURL) {
                NSApplication.shared.applicationIconImage = image
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
