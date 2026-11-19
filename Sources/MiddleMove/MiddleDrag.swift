import Cocoa
import ApplicationServices
import os

let logger = Logger(subsystem: "arabinda.me.middlemove", category: "middle-drag")

extension Notification.Name {
    /// Posted on the main thread when the event tap starts, so the menu can update.
    static let middleDragStateChanged = Notification.Name("arabinda.me.middlemove.stateChanged")
}

/// How far the pointer has to travel, in points, with the middle button held before
/// the press counts as a drag instead of a click. Small enough that a drag starts
/// promptly; big enough that the wobble of pressing a stiff scroll wheel is still a click.
private let kDragThreshold: CGFloat = 6

/// Written into `eventSourceUserData` of every event we re-post, so that if one ever
/// comes back through our own tap it's let straight through.
private let kReplayMarker: Int64 = 0x4D4D_5250 // "MMRP"

/// Watches the middle mouse button with an event tap and turns press-and-drag into
/// moving the window under the pointer.
///
/// The catch: when the button goes down, nobody can know yet whether this is a click
/// or the start of a drag. So the press is held back:
///  - The pointer moves `kDragThreshold` points → it's a drag. The window follows the
///    pointer, and the app never sees the press or the release. (If the app saw them,
///    a drag that starts on a browser tab would close that tab on release, because
///    the tab moves along with the window and is still under the pointer.)
///  - The button comes up before that → it's a click. The held-back press and the
///    release are handed to the app together, so it gets an ordinary middle click,
///    just at release time instead of press time.
///
/// Mouse buttons aren't affected by Secure Input (unlike keystrokes), so this keeps
/// working while a password field has focus.
final class MiddleDrag {
    static let shared = MiddleDrag()

    private struct Options {
        var enabled = true
        var raiseWindow = true
    }
    private let options = Locked(Options())

    /// Whether middle-drag moves windows. When off, every middle-button event passes through untouched.
    var enabled: Bool {
        get { options.read { $0.enabled } }
        set { options.mutate { $0.enabled = newValue } }
    }

    /// Whether a window comes to the front (and its app activates) when a drag starts,
    /// like dragging it by its title bar.
    var raiseWindow: Bool {
        get { options.read { $0.raiseWindow } }
        set { options.mutate { $0.raiseWindow = newValue } }
    }

    /// True once the event tap is running. Main thread.
    private(set) var isActive = false

    private let mover = WindowMover()
    private var permissionTimer: Timer?
    private var tapThread: Thread?
    private var appNapGuard: NSObjectProtocol?

    // Used only on the event-tap thread.
    private var tap: CFMachPort?
    private var phase: Phase = .idle

    private enum Phase {
        /// No middle press in progress.
        case idle
        /// Press held back; click or drag not decided yet.
        case pending(Gesture)
        /// Moving the window. The app never saw the press.
        case dragging(Gesture)
        /// The app has the press (nothing movable there, or we're switched off); stay
        /// out of the way until the release.
        case passthrough
    }

    // MARK: - Starting up

    func start() {
        // Never let a slow or hung app hold us for the default 6 s per Accessibility call.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

        // An idle menu-bar app gets App Nap'd, which can make the tap thread slow to
        // answer. Every middle-button event waits for the tap, so opt out.
        appNapGuard = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Watching the middle mouse button")

        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            startTapThread()
        } else {
            waitForPermission()
        }
    }

    /// Poll until the user grants Accessibility permission, then start. No relaunch needed.
    private func waitForPermission() {
        guard permissionTimer == nil else { return }
        logger.notice("Waiting for Accessibility permission…")
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted() else { return }
            timer.invalidate()
            self.permissionTimer = nil
            self.startTapThread()
        }
    }

    /// The tap gets a thread and run loop of its own, so nothing on the main thread
    /// (an open menu, say) can ever delay mouse events.
    private func startTapThread() {
        guard tapThread == nil else { return }
        let thread = Thread { [weak self] in self?.runTap() }
        thread.name = "MiddleMove event tap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    private func runTap() {
        let mask = (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, _ in
            MiddleDrag.shared.handle(proxy: proxy, type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: nil
        ) else {
            // Happens for a moment right after the permission is granted. Try again shortly.
            logger.error("Couldn't create the event tap yet; retrying.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.tapThread = nil
                self.waitForPermission()
            }
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.notice("Event tap running: middle-drag moves windows.")
        DispatchQueue.main.async {
            self.isActive = true
            NotificationCenter.default.post(name: .middleDragStateChanged, object: nil)
        }
        CFRunLoopRun()
    }

    // MARK: - Event handling (event-tap thread)

    fileprivate func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        switch type {
        case .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            break
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it ever answers too slowly. Switch it straight back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
            logger.notice("macOS switched the event tap off (\(reason, privacy: .public)); switched it back on.")
            abandonGesture()
            return passThrough
        default:
            return passThrough
        }

        // Only the middle button. Back/forward and any other buttons pass untouched.
        guard event.getIntegerValueField(.mouseEventButtonNumber) == 2,
              event.getIntegerValueField(.eventSourceUserData) != kReplayMarker
        else { return passThrough }

        switch type {
        case .otherMouseDown:
            return pressed(event)
        case .otherMouseDragged:
            return dragged(event, proxy: proxy)
        default:
            return released(event, proxy: proxy)
        }
    }

    private func pressed(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // If we never saw the last release (the tap was off for a moment), drop that press.
        abandonGesture()

        let location = event.location
        guard enabled,
              let target = WindowTarget.under(location),
              let heldPress = event.copy()
        else {
            // Switched off, or nothing movable under the pointer (Dock, menu bar, an open
            // menu, the desktop…): the app gets the press right away.
            phase = .passthrough
            return Unmanaged.passUnretained(event)
        }

        let gesture = Gesture(target: target, start: location, press: heldPress)
        phase = .pending(gesture)
        mover.lookUpWindow(for: gesture) // in the background, while the user decides
        return nil // hold the press back until we know whether it's a click or a drag
    }

    private func dragged(_ event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        let location = event.location

        switch phase {
        case .idle, .passthrough:
            return Unmanaged.passUnretained(event)

        case .dragging(let gesture):
            mover.move(gesture, pointer: location)
            return nil

        case .pending(let gesture):
            let distance = hypot(location.x - gesture.start.x, location.y - gesture.start.y)
            guard distance >= kDragThreshold else {
                return nil // may still turn out to be a click; the app hasn't seen the press yet
            }

            if case .unmovable(let reason) = gesture.resolution {
                // This window can't be moved (full screen, fixed position…). Give the app
                // the press after all, so its own middle-drag behaviour still works.
                phase = .passthrough
                replay([gesture.press, event], proxy: proxy)
                logger.notice("Can't move \(gesture.target.appName, privacy: .public) window (\(reason, privacy: .public)); passed the drag to the app.")
                return nil
            }

            phase = .dragging(gesture)
            mover.beginDrag(gesture, raise: raiseWindow)
            mover.move(gesture, pointer: location)
            return nil
        }
    }

    private func released(_ event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        let finished = phase
        phase = .idle

        switch finished {
        case .idle, .passthrough:
            return Unmanaged.passUnretained(event)

        case .pending(let gesture):
            // A click: give the app the press we held back, then this release.
            replay([gesture.press, event], proxy: proxy)
            logger.notice("Middle click passed to \(gesture.target.appName, privacy: .public).")
            return nil

        case .dragging(let gesture):
            mover.move(gesture, pointer: event.location)
            mover.endDrag(gesture)
            return nil
        }
    }

    /// Re-inject events at our tap's place in the stream. They reach the app (and any
    /// taps after ours) in this order, ahead of anything the callback returns.
    private func replay(_ events: [CGEvent], proxy: CGEventTapProxy) {
        for event in events {
            guard let copy = event.copy() else { continue }
            copy.setIntegerValueField(.eventSourceUserData, value: kReplayMarker)
            copy.tapPostEvent(proxy)
        }
    }

    private func abandonGesture() {
        if case .dragging(let gesture) = phase { mover.endDrag(gesture) }
        phase = .idle
    }
}
