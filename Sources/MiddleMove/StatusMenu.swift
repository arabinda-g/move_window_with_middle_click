import Cocoa
import ServiceManagement

/// The menu-bar icon and its menu.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Move Windows with Middle-Drag",
                                         action: #selector(toggleEnabled), keyEquivalent: "")
    private let raiseItem = NSMenuItem(title: "Bring Dragged Window to Front",
                                       action: #selector(toggleRaise), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login",
                                       action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Open Accessibility Settings…",
                                               action: #selector(openAccessibilitySettings), keyEquivalent: "")

    override init() {
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
                                accessibilityDescription: "MiddleMove")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "MiddleMove: hold the middle mouse button and drag to move a window"
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let titleItem = NSMenuItem(title: "MiddleMove \(version)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())

        for item in [enabledItem, raiseItem, loginItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MiddleMove",
                                  action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        statusItem.menu = menu
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: .middleDragStateChanged, object: nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    @objc private func refresh() {
        let drag = MiddleDrag.shared
        if !drag.isActive {
            stateItem.title = "Waiting for Accessibility permission"
        } else if drag.enabled {
            stateItem.title = "On: hold the middle button and drag"
        } else {
            stateItem.title = "Paused"
        }
        enabledItem.state = drag.enabled ? .on : .off
        raiseItem.state = drag.raiseWindow ? .on : .off
        raiseItem.isEnabled = drag.enabled

        switch SMAppService.mainApp.status {
        case .enabled:
            loginItem.state = .on
            loginItem.title = "Launch at Login"
        case .requiresApproval:
            loginItem.state = .mixed
            loginItem.title = "Launch at Login (allow it in Login Items)"
        default:
            loginItem.state = .off
            loginItem.title = "Launch at Login"
        }

        statusItem.button?.appearsDisabled = !(drag.isActive && drag.enabled)
    }

    @objc private func toggleEnabled() {
        MiddleDrag.shared.enabled.toggle()
        Preferences.enabled = MiddleDrag.shared.enabled
        refresh()
    }

    @objc private func toggleRaise() {
        MiddleDrag.shared.raiseWindow.toggle()
        Preferences.raiseWindow = MiddleDrag.shared.raiseWindow
        refresh()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            logger.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        refresh()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
