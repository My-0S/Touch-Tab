import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private static let statusIcon        = templateImage(named: "StatusIcon")
    private static let statusIconWarning = templateImage(named: "StatusIcon-Warning")

    private var statusBarItem: NSStatusItem!
    private var aboutWindow: NSWindow!

    private static func templateImage(named: String) -> NSImage? {
        let image = NSImage(named: named)
        image?.isTemplate = true
        return image
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return
        }
        #endif

        createStatusBarItem()

        // Seed the MRU list and subscribe to app-activation notifications
        // before the accessibility check so the list is ready on first swipe.
        WindowNavigator.setup()

        requestAccessibilityPermission {
            SwipeManager.start()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBarItem.isVisible = true
        return true
    }

    // MARK: - Accessibility permission flow

    private func requestAccessibilityPermission(completion: @escaping () -> Void) {
        let granted = PrivacyHelper.isProcessTrustedWithPrompt()
        debugPrint("Accessibility permission:", granted)
        if granted {
            completion()
        } else {
            addAccessibilityWarning()
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] timer in
                if AXIsProcessTrusted() {
                    debugPrint("Accessibility permission granted")
                    removeAccessibilityWarning()
                    timer.invalidate()
                    completion()
                }
            }
        }
    }

    // MARK: - Status bar

    private func createStatusBarItem() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusBarItem.button?.image   = AppDelegate.statusIcon
        statusBarItem.button?.toolTip = BundleInfo.displayName()
        statusBarItem.behavior        = .removalAllowed

        statusBarItem.menu = NSMenu()
        statusBarItem.menu?.addItem(
            withTitle: "About \(BundleInfo.displayName())",
            action: #selector(AppDelegate.showAbout),
            keyEquivalent: "")
        statusBarItem.menu?.addItem(
            withTitle: "Quit",
            action: #selector(AppDelegate.quit),
            keyEquivalent: "")
    }

    private func addAccessibilityWarning() {
        statusBarItem.button?.image = AppDelegate.statusIconWarning
        let warningItem = NSMenuItem(title: "No Accessibility Access",
                                     action: nil, keyEquivalent: "")
        warningItem.image     = AppDelegate.templateImage(named: "MenuItem-Warning")
        warningItem.toolTip   = "Grant access in System Settings › Privacy & Security › Accessibility"
        warningItem.isEnabled = false
        let authorizeItem = NSMenuItem(title: "Authorize…",
                                       action: #selector(openPrivacyAccessibility),
                                       keyEquivalent: "")
        statusBarItem.menu?.insertItem(warningItem,    at: 0)
        statusBarItem.menu?.insertItem(authorizeItem,  at: 1)
        statusBarItem.menu?.insertItem(.separator(),   at: 2)
    }

    private func removeAccessibilityWarning() {
        statusBarItem.button?.image = AppDelegate.statusIcon
        statusBarItem.menu?.removeItem(at: 2)
        statusBarItem.menu?.removeItem(at: 1)
        statusBarItem.menu?.removeItem(at: 0)
    }

    // MARK: - Actions

    @objc private func openPrivacyAccessibility() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(self)
    }

    @objc private func showAbout() {
        if aboutWindow == nil {
            aboutWindow = NSWindow(
                contentViewController: NSHostingController(rootView: AboutView().fixedSize()))
            aboutWindow.styleMask = [.closable, .titled]
            aboutWindow.title = ""
        }
        aboutWindow.center()
        aboutWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
