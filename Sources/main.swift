import AppKit
import ServiceManagement

/// Slip — lightweight menu-bar icon hider for macOS.
///
/// There is no public API to hide another app's status items. Slip uses the
/// Hidden Bar technique: an invisible status item (the spacer) sits just left
/// of the › toggle and widens so everything on its left is pushed off-screen.
///
/// Use: ⌘-drag icons left of ›, then click › / ‹ to tuck or reveal.
@main
enum Slip {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var toggleItem: NSStatusItem?
    private var spacerItem: NSStatusItem?
    private var isCollapsed = false
    private var menuBarEnabled = true
    private var preferencesVisible = false
    private var autoCollapseSeconds: TimeInterval = 0
    private var autoCollapseTimer: Timer?
    private var prefs: PreferencesController?
    /// Toggle glyph animation: 0 = open (●›), 1 = tucked (‹●).
    private var glyphProgress: CGFloat = 0
    private var glyphTimer: Timer?
    private var glyphActivity: NSObjectProtocol?

    /// macOS 27 drops a status item that reaches ~50% of the display width
    /// instead of letting it push; stay under that.
    private var hideLength: CGFloat {
        let narrowest = NSScreen.screens.map(\.frame.width).min() ?? 1440
        return max(floor(narrowest * 0.45), 200)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        autoCollapseSeconds = UserDefaults.standard.double(forKey: "autoCollapseSeconds")
        installMenuBar()
        scheduleAutoCollapseIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Opening Slip.app again shows Preferences — the way back if the menu-bar icon is off.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPreferences()
        return false
    }

    // MARK: Menu bar

    private func installMenuBar() {
        guard toggleItem == nil else { return }

        // Created first → further right.
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggle.autosaveName = "SlipToggle"
        if let button = toggle.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(handleToggleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        toggleItem = toggle

        let spacer = NSStatusBar.system.statusItem(withLength: 0)
        spacer.autosaveName = "SlipSpacer"
        // Never take the spacer out of the bar: when it comes back, macOS 27
        // re-inserts it at the far left and nothing gets pushed.
        spacer.isVisible = true
        spacer.button?.isEnabled = false
        spacerItem = spacer

        applyCollapsedState()
    }

    private func removeMenuBar() {
        cancelAutoCollapse()
        stopGlyphAnimation()
        if let toggleItem { NSStatusBar.system.removeStatusItem(toggleItem) }
        if let spacerItem { NSStatusBar.system.removeStatusItem(spacerItem) }
        toggleItem = nil
        spacerItem = nil
        isCollapsed = false
    }

    private func applyCollapsedState(animated: Bool = false) {
        guard let spacerItem, let toggleItem else { return }
        spacerItem.length = isCollapsed ? hideLength : 0
        toggleItem.button?.toolTip = isCollapsed ? "Slip Back" : "Slip Away"
        animateGlyph(to: isCollapsed ? 1 : 0,
                     animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func animateGlyph(to target: CGFloat, animated: Bool) {
        stopGlyphAnimation()
        guard animated, glyphProgress != target else {
            glyphProgress = target
            toggleItem?.button?.image = Icons.glyph(progress: target)
            return
        }
        let step: CGFloat = target > glyphProgress ? 0.125 : -0.125
        // App Nap otherwise throttles this background app's timers and the animation stalls.
        glyphActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Slip toggle animation")
        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            guard let self else { return }
            let next = self.glyphProgress + step
            self.glyphProgress = step > 0 ? min(next, target) : max(next, target)
            self.toggleItem?.button?.image = Icons.glyph(progress: self.glyphProgress)
            if self.glyphProgress == target { self.stopGlyphAnimation() }
        }
        glyphTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopGlyphAnimation() {
        glyphTimer?.invalidate()
        glyphTimer = nil
        if let glyphActivity { ProcessInfo.processInfo.endActivity(glyphActivity) }
        glyphActivity = nil
    }

    @objc private func screenParametersChanged() {
        if isCollapsed { applyCollapsedState() }
    }

    // MARK: Actions

    func setMenuBarEnabled(_ on: Bool) {
        menuBarEnabled = on
        if on { installMenuBar() } else { removeMenuBar() }
        prefs?.sync(from: self)
    }

    func setCollapsed(_ collapsed: Bool) {
        guard toggleItem != nil else { return }
        isCollapsed = collapsed
        applyCollapsedState(animated: true)
        if collapsed {
            cancelAutoCollapse()
        } else {
            scheduleAutoCollapseIfNeeded()
        }
        prefs?.sync(from: self)
    }

    func setAutoCollapseSeconds(_ seconds: TimeInterval) {
        autoCollapseSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: "autoCollapseSeconds")
        scheduleAutoCollapseIfNeeded()
        prefs?.sync(from: self)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Slip launch-at-login: \(error.localizedDescription)")
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        prefs?.sync(from: self)
    }

    func setPreferencesVisible(_ visible: Bool) {
        preferencesVisible = visible
        scheduleAutoCollapseIfNeeded()
    }

    var snapshot: SlipState {
        SlipState(
            menuBarEnabled: menuBarEnabled,
            isCollapsed: isCollapsed,
            autoCollapseSeconds: autoCollapseSeconds,
            launchAtLogin: SMAppService.mainApp.status == .enabled
        )
    }

    @objc private func handleToggleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            presentMenu(for: event, from: sender)
        } else {
            setCollapsed(!isCollapsed)
        }
    }

    private func presentMenu(for event: NSEvent, from sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: isCollapsed ? "Slip Back" : "Slip Away",
                     action: #selector(menuToggle), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Slip", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: sender)
    }

    @objc private func menuToggle() { setCollapsed(!isCollapsed) }

    @objc func openPreferences() {
        if prefs == nil { prefs = PreferencesController(app: self) }
        prefs?.show()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Auto-collapse

    private func scheduleAutoCollapseIfNeeded() {
        cancelAutoCollapse()
        guard toggleItem != nil, !isCollapsed, !preferencesVisible, autoCollapseSeconds > 0 else { return }
        autoCollapseTimer = Timer.scheduledTimer(withTimeInterval: autoCollapseSeconds, repeats: false) { [weak self] _ in
            self?.setCollapsed(true)
        }
    }

    private func cancelAutoCollapse() {
        autoCollapseTimer?.invalidate()
        autoCollapseTimer = nil
    }
}

struct SlipState {
    var menuBarEnabled: Bool
    var isCollapsed: Bool
    var autoCollapseSeconds: TimeInterval
    var launchAtLogin: Bool
}

// MARK: - Preferences

final class PreferencesController: NSObject, NSWindowDelegate {
    private weak var app: AppDelegate?
    private var window: NSWindow!
    /// Set while pushing model state into the controls, so their actions don't fire back.
    private var isUpdatingUI = false

    private let menuBarSwitch = NSSwitch()
    private let slipSwitch = NSSwitch()
    private let loginSwitch = NSSwitch()
    private let autoCollapsePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(labelWithString: "")

    private let autoCollapseTitles = ["5초", "10초", "30초", "1분", "끔"]
    private let autoCollapseValues: [TimeInterval] = [5, 10, 30, 60, 0]

    init(app: AppDelegate) {
        self.app = app
        super.init()
        buildWindow()
        sync(from: app)
    }

    func show() {
        if let app {
            sync(from: app)
            app.setPreferencesVisible(true)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        app?.setPreferencesVisible(false)
    }

    func sync(from app: AppDelegate) {
        isUpdatingUI = true
        defer { isUpdatingUI = false }

        let s = app.snapshot
        menuBarSwitch.state = s.menuBarEnabled ? .on : .off
        slipSwitch.state = s.isCollapsed ? .on : .off
        slipSwitch.isEnabled = s.menuBarEnabled
        loginSwitch.state = s.launchAtLogin ? .on : .off
        autoCollapsePopup.selectItem(at: autoCollapseValues.firstIndex(of: s.autoCollapseSeconds) ?? autoCollapseValues.count - 1)
        statusLabel.stringValue = s.isCollapsed ? "상태: 숨김 (‹●)" : "상태: 보임 (●›)"
    }

    private func buildWindow() {
        let w: CGFloat = 340
        let h: CGFloat = 260
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Slip"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        window.contentView = content

        let title = NSTextField(labelWithString: "Preferences")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 20, y: h - 34, width: 200, height: 18)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 20, y: h - 54, width: w - 40, height: 16)

        let hint = NSTextField(labelWithString: "⌘-드래그로 ●› 왼쪽 = 숨김 대상")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 20, y: h - 74, width: w - 40, height: 16)

        content.addSubview(title)
        content.addSubview(statusLabel)
        content.addSubview(hint)
        content.addSubview(row("메뉴바 아이콘", "끄면 메뉴바에서 숨김", y: 150, width: w, control: menuBarSwitch, #selector(menuBarChanged)))
        content.addSubview(row("Slip Away", "지금 숨김/표시", y: 108, width: w, control: slipSwitch, #selector(slipChanged)))
        content.addSubview(row("로그인 시 실행", "Mac 켜면 같이 실행", y: 66, width: w, control: loginSwitch, #selector(loginChanged)))

        autoCollapsePopup.addItems(withTitles: autoCollapseTitles)
        autoCollapsePopup.frame.size = NSSize(width: 110, height: 26)
        content.addSubview(row("자동 숨김", "펼친 뒤 다시 접기", y: 18, width: w, control: autoCollapsePopup, #selector(autoCollapseChanged)))
    }

    private func row(_ title: String, _ detail: String, y: CGFloat, width: CGFloat, control: NSControl, _ action: Selector) -> NSView {
        let row = NSView(frame: NSRect(x: 20, y: y, width: width - 40, height: 40))
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .medium)
        t.frame = NSRect(x: 0, y: 18, width: 180, height: 18)
        let d = NSTextField(labelWithString: detail)
        d.font = .systemFont(ofSize: 11)
        d.textColor = .secondaryLabelColor
        d.frame = NSRect(x: 0, y: 0, width: 180, height: 16)
        let size = control is NSSwitch ? NSSize(width: 42, height: 24) : control.frame.size
        control.frame = NSRect(x: row.bounds.width - size.width, y: (40 - size.height) / 2, width: size.width, height: size.height)
        control.target = self
        control.action = action
        row.addSubview(t)
        row.addSubview(d)
        row.addSubview(control)
        return row
    }

    @objc private func menuBarChanged() {
        guard !isUpdatingUI else { return }
        app?.setMenuBarEnabled(menuBarSwitch.state == .on)
    }

    @objc private func slipChanged() {
        guard !isUpdatingUI else { return }
        app?.setCollapsed(slipSwitch.state == .on)
    }

    @objc private func loginChanged() {
        guard !isUpdatingUI else { return }
        app?.setLaunchAtLogin(loginSwitch.state == .on)
    }

    @objc private func autoCollapseChanged() {
        guard !isUpdatingUI else { return }
        let index = max(0, autoCollapsePopup.indexOfSelectedItem)
        app?.setAutoCollapseSeconds(autoCollapseValues[min(index, autoCollapseValues.count - 1)])
    }
}

// MARK: - Icons

private enum Icons {
    /// Toggle glyph: a chevron pushing a ball.
    /// progress 0 = open (●›), 1 = tucked (‹●); in between the chevron flips and the
    /// ball slips past it, shrinking as they cross. Fixed width so the bar doesn't shift.
    static func glyph(progress: CGFloat) -> NSImage {
        let size: CGFloat = 14, mid: CGFloat = 7
        let t = progress < 0.5 ? 2 * progress * progress : 1 - pow(2 - 2 * progress, 2) / 2
        let direction = 1 - 2 * t   // 1 = ›, -1 = ‹
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let center = mid + 2.8 * direction
            let path = NSBezierPath()
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: center - 2.2 * direction, y: mid + 4.2))
            path.line(to: NSPoint(x: center + 2.2 * direction, y: mid))
            path.line(to: NSPoint(x: center - 2.2 * direction, y: mid - 4.2))
            NSColor.black.setStroke()
            path.stroke()

            let ballX = mid - 3.2 * direction
            let ball = 4.2 * (0.45 + 0.55 * abs(direction))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: ballX - ball / 2, y: mid - ball / 2, width: ball, height: ball)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = progress < 0.5 ? "Slip Away" : "Slip Back"
        return image
    }
}
