import Foundation
import AppKit

// MARK: - Apple ID License Binding
//
// At build time (make_app.sh), the current machine's Apple ID is read from
// ~/Library/Preferences/MobileMeAccounts.plist and embedded in Info.plist
// under the key "BoundAppleID".
//
// At runtime, this check reads the same plist and compares the live Apple ID
// against the embedded value. A mismatch (or missing ID on either side) means
// the app is running on an unauthorised machine → alert + quit.

enum LicenseCheck {

    /// Call once at app startup (main thread). Quits if the machine is not authorised.
    static func validateOrQuit() {
        let bound = boundAppleID()
        let live  = liveAppleID()

        guard !bound.isEmpty else {
            // App was packaged without an Apple ID embedded — allow for dev builds
            return
        }

        guard !live.isEmpty, live.lowercased() == bound.lowercased() else {
            showUnauthorisedAlert()
        }
    }

    // MARK: - Private helpers

    /// Apple ID embedded at build time via Info.plist key "BoundAppleID".
    private static func boundAppleID() -> String {
        (Bundle.main.infoDictionary?["BoundAppleID"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// Live Apple ID from the system's iCloud / MobileMe accounts plist.
    private static func liveAppleID() -> String {
        let path = (NSString("~/Library/Preferences/MobileMeAccounts.plist")
                        .expandingTildeInPath)
        guard let dict = NSDictionary(contentsOfFile: path),
              let accounts = dict["Accounts"] as? [[String: Any]],
              let first = accounts.first,
              let accountID = first["AccountID"] as? String
        else { return "" }
        return accountID.trimmingCharacters(in: .whitespaces)
    }

    /// Show a modal alert and terminate the app.
    private static func showUnauthorisedAlert() -> Never {
        let alert = NSAlert()
        alert.messageText     = "未授权设备"
        alert.informativeText = "此版本未授权在当前设备上运行。\n请联系软件授权：wx DC_Wen"
        alert.alertStyle      = .critical
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
        // Never actually reached; satisfies the compiler
        fatalError("Terminated by license check")
    }
}
