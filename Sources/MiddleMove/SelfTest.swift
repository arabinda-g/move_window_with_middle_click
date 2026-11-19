import Cocoa

/// End-to-end check of the real event path:
///
///     open -n -a MiddleMove --args --self-test /tmp/MiddleMove-self-test.txt
///
/// Runs as a second copy of the app while the normal copy (the one with the event tap)
/// keeps running. It opens a small window, posts synthetic middle-button clicks and
/// drags over it, records what the window really receives and where it ends up, writes
/// a PASS/FAIL report and quits. Posting events needs the Accessibility permission,
/// which is why this lives inside the app instead of in a separate tool.
///
/// It moves the pointer for about five seconds, so don't touch the mouse meanwhile.
final class SelfTest {
    private let reportPath: String
    private var window: NSWindow!
    private let recorder = RecorderView(frame: NSRect(x: 0, y: 0, width: 440, height: 260))
    private let source = CGEventSource(stateID: .hidSystemState)
    private var report: [String] = []
    private var problems = 0

    init(reportPath: String) {
        self.reportPath = reportPath
    }

    func run() {
        guard AXIsProcessTrusted() else {
            return finish(abort: "MiddleMove has no Accessibility permission, so the test can't post events.")
        }
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() }
        guard !others.isEmpty else {
            return finish(abort: "The normal MiddleMove isn't running; start it first.")
        }

        window = NSWindow(contentRect: recorder.frame, styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.title = "MiddleMove self-test"
        window.isReleasedWhenClosed = false
        window.contentView = recorder
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        Thread.detachNewThread { self.runChecks() }
    }

    // MARK: - Checks (background thread; the main thread stays free to receive events)

    private func runChecks() {
        usleep(800_000) // let the window appear and settle
        let originalPointer = CGEvent(source: nil)?.location
        defer {
            if let originalPointer { CGWarpMouseCursorPosition(originalPointer) }
            DispatchQueue.main.async { self.finish() }
        }

        guard onMain({ self.isTopWindowAtCentre() }) else {
            problems += 1
            report.append("ABORTED: the test window isn't the top window under its centre, so nothing was posted.")
            return
        }

        check("click in place reaches the app as one middle click") {
            let point = centre(), before = windowOrigin()
            post(.otherMouseDown, point)
            usleep(60_000)
            post(.otherMouseUp, point)
            usleep(400_000)
            return expect(["down2", "up2"], at: point, windowMovedFrom: before, by: .zero)
        }

        check("small wobble (4 pt) while clicking is still a click") {
            let point = centre(), before = windowOrigin()
            post(.otherMouseDown, point)
            usleep(30_000)
            post(.otherMouseDragged, point.offset(2, 1))
            usleep(30_000)
            post(.otherMouseDragged, point.offset(4, 2))
            usleep(30_000)
            post(.otherMouseUp, point.offset(4, 2))
            usleep(400_000)
            return expect(["down2", "up2"], at: point, windowMovedFrom: before, by: .zero)
        }

        check("press, hold 0.7 s, release without moving is a click") {
            let point = centre(), before = windowOrigin()
            post(.otherMouseDown, point)
            usleep(700_000)
            post(.otherMouseUp, point)
            usleep(400_000)
            return expect(["down2", "up2"], at: point, windowMovedFrom: before, by: .zero)
        }

        check("drag moves the window with the pointer; the app sees no click") {
            drag(by: CGPoint(x: 160, y: 90))
        }

        check("second drag straight after moves it back") {
            drag(by: CGPoint(x: -160, y: -90))
        }

        check("double middle-click arrives as two clicks, in order") {
            let point = centre(), before = windowOrigin()
            post(.otherMouseDown, point, clickState: 1)
            usleep(40_000)
            post(.otherMouseUp, point, clickState: 1)
            usleep(60_000)
            post(.otherMouseDown, point, clickState: 2)
            usleep(40_000)
            post(.otherMouseUp, point, clickState: 2)
            usleep(400_000)
            return expect(["down2", "up2", "down2", "up2"], at: point, windowMovedFrom: before, by: .zero)
        }

        check("back button (button 3) passes through immediately") {
            let point = centre()
            post(.otherMouseDown, point, button: 3)
            usleep(250_000)
            let afterPress = received()
            post(.otherMouseUp, point, button: 3)
            usleep(300_000)
            if afterPress != ["down3"] {
                return "after the press (before release) the window had \(afterPress), expected [down3]"
            }
            let all = received()
            return all == ["down3", "up3"] ? nil : "window received \(all), expected [down3, up3]"
        }
    }

    private func drag(by offset: CGPoint) -> String? {
        let point = centre()
        guard let before = windowOrigin() else { return "couldn't read the window position" }
        post(.otherMouseDown, point)
        usleep(20_000)
        let steps = 24
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            post(.otherMouseDragged, point.offset(offset.x * fraction, offset.y * fraction))
            usleep(12_000)
        }
        post(.otherMouseUp, point.offset(offset.x, offset.y))
        usleep(700_000)
        return expect([], at: nil, windowMovedFrom: before, by: offset)
    }

    // MARK: - Helpers

    private func check(_ name: String, _ body: () -> String?) {
        onMain { recorder.reset() }
        if let problem = body() {
            problems += 1
            report.append("FAIL  \(name): \(problem)")
        } else {
            report.append("PASS  \(name)")
        }
    }

    private func expect(_ events: [String], at point: CGPoint?, windowMovedFrom before: CGPoint?, by offset: CGPoint) -> String? {
        let got = received()
        if got != events {
            return "window received \(got), expected \(events)"
        }
        if let point, let first = onMain({ recorder.hits.first?.point }),
           abs(first.x - point.x) > 1 || abs(first.y - point.y) > 1 {
            return "press arrived at \(first), expected \(point)"
        }
        guard let before, let after = windowOrigin() else { return "couldn't read the window position" }
        let moved = CGPoint(x: after.x - before.x, y: after.y - before.y)
        if abs(moved.x - offset.x) > 2 || abs(moved.y - offset.y) > 2 {
            return "window moved by (\(Int(moved.x)), \(Int(moved.y))), expected (\(Int(offset.x)), \(Int(offset.y)))"
        }
        return nil
    }

    private func received() -> [String] {
        onMain { recorder.hits.map(\.kind) }
    }

    private func post(_ type: CGEventType, _ point: CGPoint, button: Int64 = 2, clickState: Int64 = 1) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .center) else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: button)
        if type != .otherMouseDragged {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        event.post(tap: .cghidEventTap)
    }

    /// Centre of the window's content, in global top-left-origin coordinates.
    private func centre() -> CGPoint {
        onMain {
            let frame = window.convertToScreen(recorder.convert(recorder.bounds, to: nil))
            let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
            return CGPoint(x: frame.midX.rounded(), y: (primaryHeight - frame.midY).rounded())
        }
    }

    /// The window's top-left corner as the window server has it.
    private func windowOrigin() -> CGPoint? {
        let number = onMain { CGWindowID(window.windowNumber) }
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return nil }
        return rect.origin
    }

    private func isTopWindowAtCentre() -> Bool {
        let frame = window.convertToScreen(recorder.convert(recorder.bounds, to: nil))
        let hit = NSWindow.windowNumber(at: NSPoint(x: frame.midX, y: frame.midY), belowWindowWithWindowNumber: 0)
        return hit == window.windowNumber
    }

    private func onMain<T>(_ body: () -> T) -> T {
        DispatchQueue.main.sync(execute: body)
    }

    private func finish(abort: String? = nil) {
        if let abort {
            problems += 1
            report.append("ABORTED: \(abort)")
        }
        let summary = problems == 0
            ? "RESULT: all \(report.count) checks passed"
            : "RESULT: \(problems) problem(s)"
        let text = (report + [summary]).joined(separator: "\n") + "\n"
        try? text.write(toFile: reportPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

/// Records the middle/other-button events the test window actually receives.
private final class RecorderView: NSView {
    struct Hit {
        let kind: String
        let point: CGPoint
    }

    private(set) var hits: [Hit] = []

    func reset() { hits.removeAll() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func otherMouseDown(with event: NSEvent) { record("down", event) }
    override func otherMouseDragged(with event: NSEvent) { record("drag", event) }
    override func otherMouseUp(with event: NSEvent) { record("up", event) }

    private func record(_ kind: String, _ event: NSEvent) {
        hits.append(Hit(kind: "\(kind)\(event.buttonNumber)", point: event.cgEvent?.location ?? .zero))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        let text = "MiddleMove self-test\nPlease don't touch the mouse for a few seconds."
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let size = text.size(withAttributes: attributes)
        let rect = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: bounds.width, height: size.height)
        text.draw(in: rect, withAttributes: attributes)
    }
}

private extension CGPoint {
    func offset(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }
}
