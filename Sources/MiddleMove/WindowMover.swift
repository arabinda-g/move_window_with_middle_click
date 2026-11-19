import Cocoa
import ApplicationServices

/// The window a middle press landed on, as the window server sees it at press time.
struct WindowTarget {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String

    /// The window a click at `point` (global coordinates, top-left origin) lands on, if
    /// it's an ordinary app window. Returns nil for the Dock, the menu bar, open menus,
    /// the desktop and other system layers, so presses there pass straight through.
    ///
    /// Called on the event-tap thread, so it has to be quick: one window-server hit test
    /// and one window-list lookup, no Accessibility calls.
    static func under(_ point: CGPoint) -> WindowTarget? {
        // Ask the window server what a click there would hit. Unlike walking the window
        // list, this skips click-through overlays (dimming layers, HUDs and the like).
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let cocoaPoint = NSPoint(x: point.x, y: primaryHeight - point.y)
        let number = NSWindow.windowNumber(at: cocoaPoint, belowWindowWithWindowNumber: 0)
        guard number > 0,
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
              let info = list.first,
              let layer = info[kCGWindowLayer as String] as? Int,
              let pid = info[kCGWindowOwnerPID as String] as? Int
        else { return nil }

        // Normal, floating and panel levels only. The Dock (20) and everything above it
        // (menu bar, menus, Notification Center, screen saver…) are left alone.
        guard layer >= 0, layer < Int(CGWindowLevelForKey(.dockWindow)) else { return nil }
        guard pid_t(pid) != getpid() else { return nil }

        let appName = info[kCGWindowOwnerName as String] as? String ?? "pid \(pid)"
        return WindowTarget(windowID: CGWindowID(number), pid: pid_t(pid), appName: appName)
    }
}

/// One middle-button press that is being held back or turned into a window move.
/// Created on the event-tap thread; its Accessibility window is looked up and moved on
/// the mover's queue. The shared parts are guarded by `lock`.
final class Gesture {
    enum Resolution {
        case pending
        case movable(window: AXUIElement, origin: CGPoint)
        case unmovable(reason: String)
    }

    let target: WindowTarget
    /// Where the press happened (global, top-left origin).
    let start: CGPoint
    /// A copy of the press we held back, replayed if this turns out to be a click.
    let press: CGEvent

    private let lock = NSLock()
    private var _resolution: Resolution = .pending
    private var latestPointer: CGPoint?
    private var flushQueued = false

    // Mover queue only.
    fileprivate var movesApplied = 0
    fileprivate var lastMoveError: AXError?

    init(target: WindowTarget, start: CGPoint, press: CGEvent) {
        self.target = target
        self.start = start
        self.press = press
    }

    var resolution: Resolution {
        lock.lock(); defer { lock.unlock() }
        return _resolution
    }

    fileprivate func resolve(_ resolution: Resolution) {
        lock.lock(); defer { lock.unlock() }
        _resolution = resolution
    }

    /// Keeps only the newest pointer position. Returns true when a flush has to be queued.
    fileprivate func setPointer(_ pointer: CGPoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        latestPointer = pointer
        if flushQueued { return false }
        flushQueued = true
        return true
    }

    /// Takes the newest pointer position, or, when there's none, marks the flush finished.
    fileprivate func takePointer() -> CGPoint? {
        lock.lock(); defer { lock.unlock() }
        if let pointer = latestPointer {
            latestPointer = nil
            return pointer
        }
        flushQueued = false
        return nil
    }
}

/// Does all the Accessibility work (finding, raising and moving windows) on one serial
/// background queue. A slow or hung app can only ever delay its own window, never the
/// mouse, and the queue's order guarantees a window is looked up before it's moved.
final class WindowMover {
    private let queue = DispatchQueue(label: "arabinda.me.middlemove.windows", qos: .userInteractive)

    /// Find the window behind the press while the user is still deciding between a
    /// click and a drag. Usually done long before the pointer reaches the threshold.
    func lookUpWindow(for gesture: Gesture) {
        queue.async { gesture.resolve(Self.resolve(gesture)) }
    }

    func beginDrag(_ gesture: Gesture, raise: Bool) {
        guard raise else { return }
        queue.async {
            guard case .movable(let window, _) = gesture.resolution else { return }
            Self.bringToFront(window, pid: gesture.target.pid)
        }
    }

    /// Move the window so it keeps its offset from the pointer. While one move is in
    /// flight only the newest position is kept, so a slow app never builds up a
    /// backlog of stale moves and the window never lags behind the pointer.
    func move(_ gesture: Gesture, pointer: CGPoint) {
        guard gesture.setPointer(pointer) else { return }
        queue.async { Self.flush(gesture) }
    }

    func endDrag(_ gesture: Gesture) {
        queue.async {
            switch gesture.resolution {
            case .movable:
                if let error = gesture.lastMoveError, gesture.movesApplied == 0 {
                    logger.error("Couldn't move \(gesture.target.appName, privacy: .public) window (AXError \(error.rawValue)).")
                } else {
                    logger.notice("Moved \(gesture.target.appName, privacy: .public) window (\(gesture.movesApplied) steps).")
                }
            case .unmovable(let reason):
                logger.notice("Didn't move \(gesture.target.appName, privacy: .public) window: \(reason, privacy: .public).")
            case .pending:
                break
            }
        }
    }

    // MARK: - Mover queue

    private static func flush(_ gesture: Gesture) {
        while let pointer = gesture.takePointer() {
            guard case .movable(let window, let origin) = gesture.resolution else { continue }
            var position = CGPoint(x: origin.x + pointer.x - gesture.start.x,
                                   y: origin.y + pointer.y - gesture.start.y)
            guard let value = AXValueCreate(.cgPoint, &position) else { continue }
            let error = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
            if error == .success {
                gesture.movesApplied += 1
            } else {
                gesture.lastMoveError = error
            }
        }
    }

    private static func resolve(_ gesture: Gesture) -> Gesture.Resolution {
        let app = AXUIElementCreateApplication(gesture.target.pid)
        // Match the exact window the window server reported. Fall back to hit-testing
        // for windows that aren't in the app's window list (sheets, child windows…).
        guard let window = findWindow(withID: gesture.target.windowID, in: app)
                ?? findWindow(at: gesture.start, in: app)
        else { return .unmovable(reason: "no Accessibility window found") }

        if boolValue(window, "AXFullScreen") == true {
            return .unmovable(reason: "it's full screen")
        }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success,
              settable.boolValue
        else { return .unmovable(reason: "its position can't be changed") }
        guard let origin = pointValue(window, kAXPositionAttribute) else {
            return .unmovable(reason: "its position can't be read")
        }
        return .movable(window: window, origin: origin)
    }

    private static func findWindow(withID id: CGWindowID, in app: AXUIElement) -> AXUIElement? {
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        for window in windows {
            var windowID: CGWindowID = 0
            if _AXUIElementGetWindow(window, &windowID) == .success, windowID == id {
                return window
            }
        }
        return nil
    }

    private static func findWindow(at point: CGPoint, in app: AXUIElement) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else {
            return nil
        }
        // Climb to the enclosing window. A sheet's "window" is the sheet itself, so keep
        // climbing until we reach a real AXWindow.
        var element = hit
        for _ in 0..<64 {
            guard let current = element else { return nil }
            if role(of: current) == kAXWindowRole { return current }
            if let window = elementValue(current, kAXWindowAttribute), !CFEqual(window, current) {
                element = window
            } else {
                element = elementValue(current, kAXParentAttribute)
            }
        }
        return nil
    }

    /// Bring the window to the front and activate its app, like a title-bar drag does.
    private static func bringToFront(_ window: AXUIElement, pid: pid_t) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        DispatchQueue.main.async {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isActive else { return }
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }
}

// MARK: - Accessibility helpers

/// Private but long-standing (used by Rectangle, Hammerspoon, AltTab…): the window-server
/// ID of an Accessibility window, so we can match it exactly to the window under the pointer.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func elementValue(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

private func role(of element: AXUIElement) -> String? {
    attribute(element, kAXRoleAttribute) as? String
}

private func boolValue(_ element: AXUIElement, _ name: String) -> Bool? {
    attribute(element, name) as? Bool
}

private func pointValue(_ element: AXUIElement, _ name: String) -> CGPoint? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
}
