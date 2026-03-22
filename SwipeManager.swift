import Cocoa

class SwipeManager {
    private static let accVelXThreshold: Float = 0.07
    private static let gestureRepeatDelay: Double = 0.2

    private static var eventTap: CFMachPort? = nil

    // Per-event state
    private static var accVelX: Float = 0
    private static var prevTouchPositions: [String: NSPoint] = [:]

    // Per-gesture state
    private static var startTime: Date? = nil
    private static var hasSwitchedInCurrentGesture: Bool = false
    private static var gestureResetTimer: Timer? = nil

    // 4-finger cooldown: suppress 3-finger detection briefly after
    // 4 fingers are seen, to avoid false triggers during desktop switching.
    private static var fourFingerCooldownTimer: Timer? = nil
    private static var inFourFingerCooldown: Bool = false
    private static let fourFingerCooldownDuration: Double = 0.5

    // MARK: - Listener

    private static func listener(_ eventType: EventType) {
        switch eventType {
        case .startOrContinue(let direction):
            guard !hasSwitchedInCurrentGesture else { return }
            hasSwitchedInCurrentGesture = true
            // Safety timer: if the end-gesture event is never received
            // (e.g. consumed by Xcode's own event tap), reset the flag
            // automatically so the next gesture is not silently ignored.
            gestureResetTimer?.invalidate()
            gestureResetTimer = Timer.scheduledTimer(withTimeInterval: 1.0,
                                                      repeats: false) { _ in
                hasSwitchedInCurrentGesture = false
                startTime = nil
            }
            switch direction {
            case .left:  WindowNavigator.navigate(direction: .backward)
            case .right: WindowNavigator.navigate(direction: .forward)
            }
        case .end:
            gestureResetTimer?.invalidate()
            gestureResetTimer = nil
            hasSwitchedInCurrentGesture = false
        }
    }

    // MARK: - Start

    static func start() {
        if eventTap != nil {
            return
        }
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: NSEvent.EventTypeMask.gesture.rawValue,
            callback: { proxy, type, cgEvent, userInfo in
                return SwipeManager.eventHandler(proxy: proxy,
                                                 eventType: type,
                                                 cgEvent: cgEvent,
                                                 userInfo: userInfo)
            },
            userInfo: nil
        )
        guard let tap = eventTap else {
            return
        }
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - Event handling

    private static func eventHandler(proxy: CGEventTapProxy,
                                     eventType: CGEventType,
                                     cgEvent: CGEvent,
                                     userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {

        if eventType.rawValue == NSEvent.EventType.gesture.rawValue,
           let nsEvent = NSEvent(cgEvent: cgEvent) {

            let touches = nsEvent.allTouches()
            let activeCount: Int
            if touches.isEmpty {
                activeCount = 0
            } else if touches.allSatisfy({ $0.phase == .ended }) {
                activeCount = 0
            } else {
                activeCount = touches.filter { $0.phase != .ended }.count
            }

            touchEventHandler(nsEvent)

            // Consume all 3-finger gesture events so macOS never sees them.
            // This prevents Mission Control and App Exposé from firing.
            // To avoid conflicts with desktop switching (4 fingers), set
            // "Swipe between full-screen apps" to 4 fingers in System Settings.
            if activeCount == 3 || touches.count == 3 {
                return nil
            }

        } else if eventType == .tapDisabledByUserInput || eventType == .tapDisabledByTimeout {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }

        return Unmanaged.passUnretained(cgEvent)
    }

    // MARK: - Touch processing

    private static func touchEventHandler(_ nsEvent: NSEvent) {
        let touches = nsEvent.allTouches()
        if touches.isEmpty { return }
        let touchesCount = touches.allSatisfy({ $0.phase == .ended }) ? 0 : touches.count

        switch touchesCount {
        case 2:
            clearEventState()
        case 3:
            // Ignore if we recently saw 4 fingers — this frame is likely
            // a transitional artifact of a 4-finger desktop-switch gesture.
            guard !inFourFingerCooldown else {
                clearEventState()
                return
            }
            processThreeFingers(touches: touches)
        default:
            if touchesCount >= 4 {
                // Arm cooldown so subsequent 3-finger frames are suppressed.
                startFourFingerCooldown()
            }
            processOtherFingers()
        }
    }

    private static func processThreeFingers(touches: Set<NSTouch>) {
        guard let velX = horizontalSwipeVelocity(touches: touches) else { return }

        accVelX += velX
        if abs(accVelX) < accVelXThreshold { return }

        if startTime == nil {
            startTime = Date()
        } else if -startTime!.timeIntervalSinceNow < gestureRepeatDelay {
            clearEventState()
            return
        }

        startOrContinueGesture()
        clearEventState()
    }

    private static func processOtherFingers() {
        if startTime != nil {
            endGesture()
            clearEventState()
            startTime = nil
        }
    }

    // MARK: - Gesture helpers

    private static func startFourFingerCooldown() {
        inFourFingerCooldown = true
        // Also invalidate the navigation session cache so the next 3-finger
        // gesture rebuilds a fresh list on the new virtual desktop, rather
        // than reusing a stale list from the previous space.
        WindowNavigator.invalidateSessionCache()
        fourFingerCooldownTimer?.invalidate()
        fourFingerCooldownTimer = Timer.scheduledTimer(
            withTimeInterval: fourFingerCooldownDuration,
            repeats: false
        ) { _ in
            inFourFingerCooldown = false
        }
    }

    private static func clearEventState() {
        accVelX = 0
        prevTouchPositions.removeAll()
    }

    private static func startOrContinueGesture() {
        let direction: EventType.Direction = accVelX < 0 ? .left : .right
        listener(.startOrContinue(direction: direction))
    }

    private static func endGesture() {
        listener(.end)
    }

    // MARK: - Velocity

    private static func horizontalSwipeVelocity(touches: Set<NSTouch>) -> Float? {
        var allRight = true
        var allLeft  = true
        var sumVelX  = Float(0)
        var sumVelY  = Float(0)

        for touch in touches {
            let (vx, vy) = touchVelocity(touch)
            allRight = allRight && vx >= 0
            allLeft  = allLeft  && vx <= 0
            sumVelX += vx
            sumVelY += vy

            if touch.phase == .ended {
                prevTouchPositions.removeValue(forKey: "\(touch.identity)")
            } else {
                prevTouchPositions["\(touch.identity)"] = touch.normalizedPosition
            }
        }

        if !allRight && !allLeft { return nil }
        let velX = sumVelX / Float(touches.count)
        let velY = sumVelY / Float(touches.count)
        if abs(velX) <= abs(velY) { return nil }
        return velX
    }

    private static func touchVelocity(_ touch: NSTouch) -> (Float, Float) {
        guard let prev = prevTouchPositions["\(touch.identity)"] else { return (0, 0) }
        let pos = touch.normalizedPosition
        return (Float(pos.x - prev.x), Float(pos.y - prev.y))
    }

    // MARK: - Types

    enum EventType {
        case startOrContinue(direction: Direction)
        case end
        enum Direction { case left, right }
    }
}
