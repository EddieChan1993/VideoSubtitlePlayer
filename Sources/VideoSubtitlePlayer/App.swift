import SwiftUI

@main
struct VideoSubtitleApp: App {

    // Owned here (app lifetime) so PlayerViewModel survives window close/reopen.
    // ContentView receives it as an EnvironmentObject — no state is lost when the
    // user clicks the red X and reopens the window from the Dock.
    @StateObject private var playerVM = PlayerViewModel()

    init() {
        LicenseCheck.validateOrQuit()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(playerVM)
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
