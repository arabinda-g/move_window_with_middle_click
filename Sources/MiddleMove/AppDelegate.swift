import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?
    private var selfTest: SelfTest?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `open -n -a MiddleMove --args --self-test <report path>` starts a second copy
        // that only runs the end-to-end check (see SelfTest.swift) and then quits.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--self-test") {
            let reportPath = arguments.indices.contains(index + 1)
                ? arguments[index + 1]
                : NSTemporaryDirectory() + "MiddleMove-self-test.txt"
            selfTest = SelfTest(reportPath: reportPath)
            selfTest?.run()
            return
        }

        Preferences.registerDefaults()
        MiddleDrag.shared.enabled = Preferences.enabled
        MiddleDrag.shared.raiseWindow = Preferences.raiseWindow
        statusMenu = StatusMenuController()
        MiddleDrag.shared.start()
    }
}

/// Settings that survive relaunches.
enum Preferences {
    private static let enabledKey = "MoveWindowsEnabled"
    private static let raiseWindowKey = "BringDraggedWindowToFront"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [enabledKey: true, raiseWindowKey: true])
    }

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var raiseWindow: Bool {
        get { UserDefaults.standard.bool(forKey: raiseWindowKey) }
        set { UserDefaults.standard.set(newValue, forKey: raiseWindowKey) }
    }
}

/// A value shared between threads, guarded by a lock.
final class Locked<Value> {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func read<Result>(_ body: (Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(value)
    }

    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
