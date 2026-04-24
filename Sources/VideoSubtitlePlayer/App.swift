import SwiftUI

@main
struct VideoSubtitleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Open Video…") {
                    NotificationCenter.default.post(name: .openVideoFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let openVideoFile = Notification.Name("openVideoFile")
}
