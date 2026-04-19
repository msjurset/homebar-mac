import SwiftUI
import AppKit
import Carbon.HIToolbox
import Observation

extension Notification.Name {
    static let homebarPanelDidOpen = Notification.Name("HomeBar.panelDidOpen")
}

// MARK: - Launch at login (user LaunchAgent)

enum LaunchAgent {
    private static let label = "com.msjurset.homebar-mac"
    private static var plistPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents/\(label).plist"
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    static func setEnabled(_ enabled: Bool) {
        let uid = getuid()
        if enabled {
            let appPath = Bundle.main.executablePath ?? "/Applications/HomeBar.app/Contents/MacOS/HomeBar"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(label)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(appPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
            let parent = (plistPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootstrap", "gui/\(uid)", plistPath]
            try? process.run()
            process.waitUntilExit()
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootout", "gui/\(uid)/\(label)"]
            try? process.run()
            process.waitUntilExit()
            try? FileManager.default.removeItem(atPath: plistPath)
        }
    }
}

private func homebarHotkeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotkeyID = EventHotKeyID()
    GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID
    )
    if hotkeyID.id == 1 {
        DispatchQueue.main.async {
            AppController.shared.togglePanel()
        }
    }
    return noErr
}

// MARK: - Entry point

@main
enum HomeBarMain {
    static func main() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.msjurset.homebar-mac"
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        if !others.isEmpty { exit(0) }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        installMinimalMainMenu()

        AppController.shared.setup()
        app.run()
    }

    /// LSUIElement apps don't get a default Edit menu, which breaks ⌘C/⌘V/⌘A
    /// in any hosted SwiftUI text field. Install a minimal Edit-only menu so
    /// the responder chain routes those shortcuts.
    @MainActor
    private static func installMinimalMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit HomeBar",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApplication.shared.mainMenu = main
    }
}

// MARK: - Controller

@MainActor
final class AppController {
    static let shared = AppController()

    let store = HomeBarStore()

    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var settingsWindow: NSWindow?
    private var globalClickMonitor: Any?
    private var escapeMonitor: Any?
    private var tileHotkeyMonitor: Any?
    private var navigationMonitor: Any?
    private var optionFlagMonitor: Any?
    private var hotkeyRef: EventHotKeyRef?

    func setup() {
        MDIIcons.bootstrap()
        NotificationService.shared.bootstrap()
        _ = UpdaterService.shared
        setupStatusItem()
        panel = FloatingPanel(contentView: PopoverView().environment(store))
        registerHotkey()
    }

    private func registerHotkey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), homebarHotkeyCallback, 1, &eventType, nil, nil)

        // signature 'HMBR', id 1 — cmd-/
        let hotkeyID = EventHotKeyID(signature: OSType(0x484D4252), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Slash), UInt32(cmdKey), hotkeyID,
            GetApplicationEventTarget(), 0, &hotkeyRef
        )
    }

    private lazy var normalImage: NSImage? = {
        let img = NSImage(systemSymbolName: "house.fill", accessibilityDescription: "HomeBar")
        img?.isTemplate = true
        return img
    }()

    private lazy var alertImage: NSImage? = {
        // Non-template image rendered with a warm orange palette color.
        // Same glyph, different pixels — clearly visible on the menu bar
        // without relying on contentTintColor behavior for template images.
        let config = NSImage.SymbolConfiguration(paletteColors: [NSColor.systemOrange])
        let img = NSImage(systemSymbolName: "house.fill", accessibilityDescription: "HomeBar")?
            .withSymbolConfiguration(config)
        img?.isTemplate = false
        return img
    }()

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = normalImage
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        observeWatch()
    }

    private func observeWatch() {
        withObservationTracking {
            updateStatusTint()
        } onChange: {
            Task { @MainActor [weak self] in self?.observeWatch() }
        }
    }

    private func updateStatusTint() {
        guard let button = statusItem?.button else { return }
        let count = store.watchTriggeredCount
        if count > 0 {
            button.image = alertImage
            button.toolTip = "HomeBar — \(count) alert\(count == 1 ? "" : "s")"
        } else {
            button.image = normalImage
            button.toolTip = "HomeBar"
        }
    }

    // MARK: Click handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu(sender)
        } else {
            togglePanel()
        }
    }

    func togglePanel() {
        if panel.isVisible { closePanel() } else { openPanel() }
    }

    private func openPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        // Fresh open: no tile should wear the selection outline until the
        // user presses an arrow key.
        store.selectedEntityID = nil

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let x = buttonFrame.midX - panel.frame.width / 2
        let y = buttonFrame.minY - panel.frame.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.showAnimated()
        installMonitors()
        NotificationCenter.default.post(name: .homebarPanelDidOpen, object: nil)
    }

    private func closePanel() {
        panel.closeAnimated { [weak self] in self?.removeMonitors() }
    }

    private func installMonitors() {
        store.optionHeld = NSEvent.modifierFlags.contains(.option)
        optionFlagMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = event.modifierFlags.contains(.option)
            if self?.store.optionHeld != held {
                self?.store.optionHeld = held
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, event.keyCode == 53 else { return event }
            self.closePanel()
            return nil
        }
        tileHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            // Only fire on pure ⌥+key — ignore ⌥⇧, ⌥⌘, etc. so they can still type special chars.
            let relevant: NSEvent.ModifierFlags = [.option, .command, .control, .shift]
            guard event.modifierFlags.intersection(relevant) == .option else { return event }
            let key = (event.charactersIgnoringModifiers ?? "").lowercased()
            guard let entity = self.store.entity(forHotkey: key) else { return event }
            Task { @MainActor in
                await self.store.fire(entity)
                self.closePanel()
            }
            return nil
        }
        navigationMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            let significantMods: NSEvent.ModifierFlags = [.command, .control, .shift]
            let hasSignificant = !event.modifierFlags.intersection(significantMods).isEmpty
            // In grid mode ↓/↑ move by one row (4 cols); in list mode by 1.
            let gridMode = UserDefaults.standard.bool(forKey: "homebar.gridMode")
            let columns = gridMode ? 4 : 1
            switch event.keyCode {
            case 126: // up arrow
                if hasSignificant { return event }
                self.store.selectUp(columns: columns)
                return nil
            case 125: // down arrow
                if hasSignificant { return event }
                self.store.selectDown(columns: columns)
                return nil
            case 123: // left arrow
                if hasSignificant || !gridMode { return event }
                self.store.selectLeft()
                return nil
            case 124: // right arrow
                if hasSignificant || !gridMode { return event }
                self.store.selectRight()
                return nil
            case 36, 76: // return / enter
                if hasSignificant { return event }
                guard self.store.selectedEntityID != nil else { return event }
                if event.modifierFlags.contains(.option) {
                    self.store.copySelectedID()
                    return nil
                }
                Task { @MainActor in
                    await self.store.fireSelected()
                    self.closePanel()
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = escapeMonitor { NSEvent.removeMonitor(m); escapeMonitor = nil }
        if let m = tileHotkeyMonitor { NSEvent.removeMonitor(m); tileHotkeyMonitor = nil }
        if let m = navigationMonitor { NSEvent.removeMonitor(m); navigationMonitor = nil }
        if let m = optionFlagMonitor { NSEvent.removeMonitor(m); optionFlagMonitor = nil }
        store.optionHeld = false
    }

    // MARK: Context menu

    private func showContextMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = LaunchAgent.isEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About HomeBar", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = UpdaterService.shared.canCheckForUpdates
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        sender.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAgent.setEnabled(!LaunchAgent.isEnabled)
    }

    @objc private func showAbout() {
        openAbout()
    }

    @objc func openAbout() {
        if panel.isVisible { closePanel() }
        aboutWindow?.close()
        aboutWindow = nil

        let hosting = NSHostingController(rootView: AboutView().environment(store))
        let window = NSWindow(contentViewController: hosting)
        window.title = "About HomeBar"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        aboutWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closeAbout() {
        aboutWindow?.close()
        aboutWindow = nil
    }

    @objc private func checkForUpdates() {
        UpdaterService.shared.checkForUpdates()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Settings window

    @objc func openSettings() {
        if panel.isVisible { closePanel() }

        // Re-create each open so SettingsView mounts fresh and reloads state
        // from disk. isReleasedWhenClosed stays false in Swift — our strong
        // reference owns the window, and we release it here by reassigning.
        settingsWindow?.close()
        settingsWindow = nil

        let hosting = NSHostingController(rootView: SettingsView().environment(store))
        let window = NSWindow(contentViewController: hosting)
        window.title = "HomeBar Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closeSettings() {
        settingsWindow?.close()
    }

    private var automationConfigWindow: NSWindow?
    private var aboutWindow: NSWindow?

    func openAutomationConfig(for entity: HAEntity) {
        if panel.isVisible { closePanel() }
        automationConfigWindow?.close()
        automationConfigWindow = nil

        let view = AutomationAffectsView(automation: entity) { [weak self] in
            self?.automationConfigWindow?.close()
            self?.automationConfigWindow = nil
        }
        .environment(store)

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Tile Entities"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        automationConfigWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Floating panel

final class FloatingPanel: NSPanel {
    init<V: View>(contentView: V) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .popUpMenu
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        // Disabling the window-level shadow because macOS draws it against
        // the panel's rectangular frame, not the rounded content, which
        // shows as a ghost rectangular "second layer" below the popover.
        // Shadow is applied to the effect view's layer instead.
        hasShadow = false
        // Avoid interfering with fullscreen spaces: this panel is auxiliary
        // to whatever app owns the active space and should follow the user.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // Wrapper view hosts the effect view. Shadow temporarily disabled
        // while we isolate the double-edge rendering artifact.
        let wrapperFrame = NSRect(x: 0, y: 0, width: 360, height: 440)
        let wrapper = NSView(frame: wrapperFrame)
        wrapper.wantsLayer = true
        wrapper.layer?.masksToBounds = false

        let effectView = NSVisualEffectView(frame: wrapper.bounds)
        effectView.material = .popover
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 10
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        effectView.autoresizingMask = [.width, .height]
        wrapper.addSubview(effectView)

        let hosting = NSHostingView(rootView: contentView)
        hosting.frame = effectView.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.layer?.backgroundColor = nil
        effectView.addSubview(hosting)

        self.contentView = wrapper
    }

    override var canBecomeKey: Bool { true }

    func showAnimated() {
        guard let contentView = self.contentView else { return }
        alphaValue = 0
        contentView.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.95, y: 0.95))

        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
            contentView.layer?.setAffineTransform(.identity)
        }
    }

    func closeAnimated(completion: @escaping () -> Void) {
        guard let contentView = self.contentView else {
            orderOut(nil); completion(); return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            contentView.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.95, y: 0.95))
        }, completionHandler: {
            self.orderOut(nil)
            self.alphaValue = 1
            contentView.layer?.setAffineTransform(.identity)
            completion()
        })
    }
}
