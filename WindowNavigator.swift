import Cocoa

class WindowNavigator {

    // MARK: - MRU tracking

    // Keyed by bundle ID (stable across relaunches) rather than PID
    // (which macOS can recycle and assign to a different process).
    private static var mruList: [String] = []
    private static var pendingBundleID: String? = nil
    private static var debounceTimer: Timer? = nil
    private static let mruUpdateDelay: TimeInterval = 1.0

    // Navigation session cache: the sorted candidate list is frozen for the
    // duration of a navigation session and only refreshed after the user has
    // been idle for sessionExpiryDelay seconds. This prevents MRU reordering
    // mid-session from causing unpredictable jump targets.
    private static var sessionCache: [NSRunningApplication]? = nil
    private static var sessionExpiryTimer: Timer? = nil
    private static let sessionExpiryDelay: TimeInterval = 3.0

    // MARK: - Setup

    static func setup() {
        for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular {
            if let bid = app.bundleIdentifier { mruList.append(bid) }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  let bid = app.bundleIdentifier else { return }
            schedulePromote(bundleID: bid)
        }
    }

    // MARK: - Navigation

    /// Called by SwipeManager when a 4-finger gesture is detected,
    /// so the next 3-finger navigation starts with a fresh candidate list.
    static func invalidateSessionCache() {
        sessionCache = nil
        sessionExpiryTimer?.invalidate()
        sessionExpiryTimer = nil
    }

    static func navigate(direction: Direction) {
        // A plain async is not enough when an app like Xcode also registers a
        // headInsertEventTap: depending on registration order, Xcode can consume
        // the gesture first. A short asyncAfter lets the entire event-tap chain
        // finish before we switch, regardless of which app is frontmost.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            _navigate(direction: direction)
        }
    }

    private static func _navigate(direction: Direction) {
        // Use cached list if available, otherwise build a fresh one.
        let sorted: [NSRunningApplication]
        if let cache = sessionCache {
            sorted = cache
        } else {
            let candidates = appsWithVisibleWindows()
            guard !candidates.isEmpty else { return }
            sorted = sortedByMRU(candidates)
            sessionCache = sorted
        }

        guard !sorted.isEmpty else { return }

        // Restart the expiry timer on every navigation event.
        sessionExpiryTimer?.invalidate()
        sessionExpiryTimer = Timer.scheduledTimer(
            withTimeInterval: sessionExpiryDelay,
            repeats: false
        ) { _ in
            sessionCache = nil
        }

        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let currentIdx = sorted.firstIndex { $0.processIdentifier == frontPID } ?? -1

        let targetIdx: Int
        switch direction {
        case .forward:  targetIdx = (currentIdx + 1) % sorted.count
        case .backward: targetIdx = ((currentIdx - 1) + sorted.count) % sorted.count
        }

        activateApp(sorted[targetIdx])
    }

    // MARK: - Activation (cross-space)

    /// Activates an app and switches to its Space if needed.
    ///
    /// Strategy:
    /// 1. Find the first non-minimised AX window of the app.
    /// 2. Call kAXRaiseAction on it — macOS interprets this as "bring to front"
    ///    and automatically switches to the Space containing that window.
    /// 3. Call activate() to make the app frontmost on the new Space.
    ///
    /// This avoids NSWorkspace.open(bundleURL) which re-launches apps like
    /// Finder and always opens a new window.
    private static func activateApp(_ app: NSRunningApplication) {

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Find the first non-minimised window to raise.
        if let window = firstVisibleWindow(axApp) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }

        // activate() brings the app to front on whatever space it just moved to.
        app.activate(options: [.activateIgnoringOtherApps])
    }

    /// Returns the first AX window that is not minimised, or nil.
    private static func firstVisibleWindow(_ axApp: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }

        return windows.first { window in
            var minVal: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minVal)
            return (minVal as? Bool) != true
        }
    }

    // MARK: - Window detection

    private static func appsWithVisibleWindows() -> [NSRunningApplication] {
        let selfPID = NSRunningApplication.current.processIdentifier

        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular,
                  app.processIdentifier != selfPID,
                  !app.isTerminated,
                  !app.isHidden
            else { return false }

            // Finder always runs but should only appear when it has a real
            // window open. Use strict mode for known always-running system apps.
            let strictBundleIDs: Set<String> = [
                "com.apple.finder"
            ]
            let strict = strictBundleIDs.contains(app.bundleIdentifier ?? "")
            return hasNonMinimisedWindow(app, strict: strict)
        }
    }

    /// - Parameter strict: if true, only kAXStandardWindowSubrole windows count.
    ///   Use for always-running system apps (Finder) that have internal AX
    ///   windows even when no user-facing window is open.
    private static func hasNonMinimisedWindow(_ app: NSRunningApplication,
                                               strict: Bool = false) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)

        // AX error → assume visible (covers Electron apps, games, etc.)
        // In strict mode we cannot safely assume, so return false.
        guard result == .success, let windows = value as? [AXUIElement] else {
            return !strict
        }

        if windows.isEmpty { return false }

        for window in windows {
            var minVal: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minVal)
            guard (minVal as? Bool) != true else { continue }

            var subroleVal: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleVal)
            let subrole = subroleVal as? String

            if strict {
                // Strict: only count explicit standard windows.
                if subrole == kAXStandardWindowSubrole as String { return true }
            } else {
                // Lenient: accept standard windows and windows without a subrole.
                if subrole == nil || subrole == kAXStandardWindowSubrole as String { return true }
            }
        }
        return false
    }

    // MARK: - MRU helpers

    private static func schedulePromote(bundleID: String) {
        pendingBundleID = bundleID
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: mruUpdateDelay,
                                             repeats: false) { _ in
            guard let bid = pendingBundleID else { return }
            mruList.removeAll { $0 == bid }
            mruList.insert(bid, at: 0)
            pendingBundleID = nil
        }
    }

    private static func sortedByMRU(_ apps: [NSRunningApplication]) -> [NSRunningApplication] {
        apps.sorted { a, b in
            let ia = a.bundleIdentifier.flatMap { mruList.firstIndex(of: $0) } ?? Int.max
            let ib = b.bundleIdentifier.flatMap { mruList.firstIndex(of: $0) } ?? Int.max
            if ia != ib { return ia < ib }
            return (a.localizedName ?? "") < (b.localizedName ?? "")
        }
    }

    // MARK: - Types

    enum Direction { case forward, backward }
}
