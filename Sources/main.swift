import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Korean when the user's first preferred language is Korean, English otherwise.
func L(_ ko: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("ko") == true ? ko : en
}

/// SlipBar — lightweight menu-bar icon hider for macOS.
///
/// There is no public API to hide another app's status items. SlipBar uses the
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
    private let glyphView = GlyphView()
    private var spacerItem: NSStatusItem?
    private var isCollapsed = false
    private var menuBarEnabled = true
    private var preferencesVisible = false
    private var autoCollapseSeconds: TimeInterval = 0
    private var autoCollapseTimer: Timer?
    private var prefs: PreferencesController?
    /// Toggle glyph animation: 0 = open (›), 1 = tucked (‹).
    private var glyphProgress: CGFloat = 0
    private var glyphTimer: Timer?
    private var glyphActivity: NSObjectProtocol?
    private var hotKey: HotKey?
    private var scrollMonitors: [Any] = []
    private var swipeDistance: CGFloat = 0
    private var swipeHandled = false
    private var onboarding: OnboardingController?

    private var hotKeyEnabled: Bool { UserDefaults.standard.bool(forKey: "hotKeyEnabled") }
    private var swipeEnabled: Bool { UserDefaults.standard.bool(forKey: "swipeEnabled") }

    /// macOS 27 only hides the pushed icons quietly within a narrow band of spacer lengths, measured
    /// at about half the display width minus 235…15pt: shorter shows its « overflow button, longer
    /// gets the spacer ignored and the icons pop back. Stay in the lower part of that band, which
    /// holds up better behind long app menus.
    private var hideLength: CGFloat {
        let width = (toggleItem?.button?.window?.screen ?? NSScreen.main)?.frame.width ?? 1440
        return floor(width / 2 - 180)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["hotKeyEnabled": true, "swipeEnabled": true])
        autoCollapseSeconds = UserDefaults.standard.double(forKey: "autoCollapseSeconds")
        installMenuBar()
        scheduleAutoCollapseIfNeeded()
        updateHotKey()
        updateSwipeMonitor()
        if !UserDefaults.standard.bool(forKey: "onboardingShown") {
            // Give the status item a moment to settle into the bar before anchoring to it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.showOnboarding() }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Opening SlipBar.app again shows Preferences — the way back if the menu-bar icon is off.
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
            button.image = Icons.placeholder
            // Drawn over the button's left padding, which the image itself can't reach.
            glyphView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(glyphView)
            NSLayoutConstraint.activate([
                glyphView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                glyphView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                glyphView.widthAnchor.constraint(equalToConstant: Icons.glyphSize.width),
                glyphView.heightAnchor.constraint(equalToConstant: Icons.glyphSize.height),
            ])
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
        toggleItem.button?.setAccessibilityLabel(isCollapsed ? "Slip Back" : "Slip Away")
        animateGlyph(to: isCollapsed ? 1 : 0,
                     animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func animateGlyph(to target: CGFloat, animated: Bool) {
        stopGlyphAnimation()
        guard animated, glyphProgress != target else {
            glyphProgress = target
            glyphView.image = Icons.glyph(progress: target)
            return
        }
        // Matches how long macOS takes to slide the icons in or out.
        let duration = 0.28 * Double(abs(target - glyphProgress))
        let from = glyphProgress, start = CACurrentMediaTime()
        // App Nap otherwise throttles this background app's timers and the animation stalls.
        glyphActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "SlipBar toggle animation")
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = min((CACurrentMediaTime() - start) / duration, 1)
            self.glyphProgress = from + (target - from) * CGFloat(t)
            self.glyphView.image = Icons.glyph(progress: self.glyphProgress)
            if t >= 1 { self.stopGlyphAnimation() }
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
        // Let the bar settle on the new display layout before reading which screen › is on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isCollapsed else { return }
            self.applyCollapsedState()
        }
    }

    // MARK: Actions

    func setMenuBarEnabled(_ on: Bool) {
        menuBarEnabled = on
        if on { installMenuBar() } else { removeMenuBar() }
        updateHotKey()
        updateSwipeMonitor()
        prefs?.sync(from: self)
    }

    func setHotKeyEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "hotKeyEnabled")
        updateHotKey()
        prefs?.sync(from: self)
    }

    func setSwipeEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "swipeEnabled")
        updateSwipeMonitor()
        prefs?.sync(from: self)
    }

    // MARK: Hot key & swipe

    /// ⌥⌘\ (the ₩ key on Korean layouts) toggles from anywhere. Carbon hot keys need no permission.
    private func updateHotKey() {
        guard hotKeyEnabled, toggleItem != nil else { hotKey = nil; return }
        guard hotKey == nil else { return }
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            guard let self else { return }
            self.setCollapsed(!self.isCollapsed)
        }
    }

    /// Two-finger swipe on the menu bar: toward the right brings icons back, toward the left tucks them.
    private func updateSwipeMonitor() {
        if swipeEnabled, toggleItem != nil {
            guard scrollMonitors.isEmpty else { return }
            let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScroll(event)
            }
            // A swipe that starts over › is delivered to SlipBar itself, which global monitors skip.
            let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScroll(event)
                return event
            }
            scrollMonitors = [global, local].compactMap { $0 }
        } else {
            scrollMonitors.forEach(NSEvent.removeMonitor)
            scrollMonitors = []
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) {
            swipeDistance = 0
            swipeHandled = false
        }
        guard !swipeHandled, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), pointerIsOnMenuBar() else { return }
        // Normalize to the direction the fingers actually moved, regardless of natural scrolling.
        swipeDistance += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        guard abs(swipeDistance) > 36 else { return }
        swipeHandled = true
        let collapse = swipeDistance < 0
        guard collapse != isCollapsed else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        setCollapsed(collapse)
    }

    private func pointerIsOnMenuBar() -> Bool {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return false }
        let barHeight = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top,
                            screen.frame.maxY - screen.visibleFrame.maxY)
        return point.y >= screen.frame.maxY - barHeight
    }

    // MARK: Onboarding

    @objc func showOnboarding() {
        guard let button = toggleItem?.button else { return }
        if onboarding == nil { onboarding = OnboardingController() }
        onboarding?.show(from: button)
        UserDefaults.standard.set(true, forKey: "onboardingShown")
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
            NSLog("SlipBar launch-at-login: \(error.localizedDescription)")
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
            launchAtLogin: SMAppService.mainApp.status == .enabled,
            hotKeyEnabled: hotKeyEnabled,
            swipeEnabled: swipeEnabled
        )
    }

    @objc private func handleToggleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        // On macOS 27 the click event's modifier flags lag one click behind for a background app.
        if event.type == .rightMouseUp || CGEventSource.flagsState(.combinedSessionState).contains(.maskControl) {
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
        menu.addItem(withTitle: L("설정…", "Preferences…"), action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(withTitle: L("사용법 보기", "How to Use SlipBar"), action: #selector(showOnboarding), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("SlipBar 종료", "Quit SlipBar"), action: #selector(quit), keyEquivalent: "q")
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
    var hotKeyEnabled: Bool
    var swipeEnabled: Bool
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
    private let swipeSwitch = NSSwitch()
    private let hotKeySwitch = NSSwitch()
    private let autoCollapsePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(labelWithString: "")

    private let autoCollapseTitles = [L("5초", "5 sec"), L("10초", "10 sec"), L("30초", "30 sec"), L("1분", "1 min"), L("끔", "Off")]
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
        swipeSwitch.state = s.swipeEnabled ? .on : .off
        hotKeySwitch.state = s.hotKeyEnabled ? .on : .off
        autoCollapsePopup.selectItem(at: autoCollapseValues.firstIndex(of: s.autoCollapseSeconds) ?? autoCollapseValues.count - 1)
        statusLabel.stringValue = s.isCollapsed ? L("상태: 숨김 (‹)", "Status: Tucked (‹)") : L("상태: 보임 (›)", "Status: Shown (›)")
    }

    private func buildWindow() {
        let w: CGFloat = 340
        let h: CGFloat = 364
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SlipBar"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        window.contentView = content

        let icon = NSImageView(frame: NSRect(x: 16, y: h - 62, width: 48, height: 48))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let titleText = NSMutableAttributedString(string: "SlipBar", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)])
        titleText.append(NSAttributedString(string: "  " + version, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        let title = NSTextField(labelWithAttributedString: titleText)
        title.frame = NSRect(x: 70, y: h - 38, width: w - 90, height: 20)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 70, y: h - 57, width: w - 90, height: 16)

        let hint = NSTextField(labelWithString: L("⌘-드래그로 › 왼쪽 = 숨김 대상", "⌘-drag icons left of › to hide them"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 20, y: h - 86, width: w - 40, height: 16)

        content.addSubview(icon)
        content.addSubview(title)
        content.addSubview(statusLabel)
        content.addSubview(hint)
        content.addSubview(row(L("메뉴바 아이콘", "Menu Bar Icon"), L("끄면 메뉴바에서 숨김", "Off removes › from the menu bar"),
                               y: 234, width: w, control: menuBarSwitch, #selector(menuBarChanged)))
        content.addSubview(row("Slip Away", L("지금 숨김/표시", "Tuck or reveal now"), y: 192, width: w, control: slipSwitch, #selector(slipChanged)))
        content.addSubview(row(L("쓸어서 열기", "Swipe to Slip"), L("메뉴바에서 두 손가락으로 좌우로 쓸기", "Two-finger swipe on the menu bar"),
                               y: 150, width: w, control: swipeSwitch, #selector(swipeChanged)))
        content.addSubview(row(L("단축키 ⌥⌘\\", "Shortcut ⌥⌘\\"), L("어디서든 숨김/표시 (한글 자판은 ₩ 키)", "Tuck or reveal from anywhere"),
                               y: 108, width: w, control: hotKeySwitch, #selector(hotKeyChanged)))
        content.addSubview(row(L("로그인 시 실행", "Launch at Login"), L("Mac 켜면 같이 실행", "Start with your Mac"),
                               y: 66, width: w, control: loginSwitch, #selector(loginChanged)))

        autoCollapsePopup.addItems(withTitles: autoCollapseTitles)
        autoCollapsePopup.frame.size = NSSize(width: 110, height: 26)
        content.addSubview(row(L("자동 숨김", "Auto-Tuck"), L("펼친 뒤 다시 접기", "Tuck again after revealing"),
                               y: 18, width: w, control: autoCollapsePopup, #selector(autoCollapseChanged)))
    }

    private func row(_ title: String, _ detail: String, y: CGFloat, width: CGFloat, control: NSControl, _ action: Selector) -> NSView {
        let row = NSView(frame: NSRect(x: 20, y: y, width: width - 40, height: 40))
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .medium)
        t.frame = NSRect(x: 0, y: 18, width: 230, height: 18)
        let d = NSTextField(labelWithString: detail)
        d.font = .systemFont(ofSize: 11)
        d.textColor = .secondaryLabelColor
        d.frame = NSRect(x: 0, y: 0, width: 240, height: 16)
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

    @objc private func swipeChanged() {
        guard !isUpdatingUI else { return }
        app?.setSwipeEnabled(swipeSwitch.state == .on)
    }

    @objc private func hotKeyChanged() {
        guard !isUpdatingUI else { return }
        app?.setHotKeyEnabled(hotKeySwitch.state == .on)
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

// MARK: - Onboarding

/// First-run popover under the toggle: a looping mini menu bar plus three short steps.
final class OnboardingController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let demo = DemoBarView(frame: NSRect(x: 20, y: 212, width: 260, height: 44))

    override init() {
        super.init()
        let w: CGFloat = 300, h: CGFloat = 272
        let view = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        view.addSubview(demo)

        let title = NSTextField(labelWithString: L("메뉴바를 정리해 볼까요", "Let's tidy up your menu bar"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 20, y: 176, width: w - 40, height: 22)
        view.addSubview(title)

        let steps = [
            L("⌘를 누른 채, 숨길 아이콘을\n› 왼쪽으로 끌어다 놓으세요", "Hold ⌘ and drag the icons you want to hide to the left of ›"),
            L("›를 누르면 숨고, 다시 누르면 돌아와요", "Click › to tuck them away. Click again to bring them back."),
            L("메뉴바를 두 손가락으로 쓸어도 되고,\n⌥⌘\\ 단축키도 있어요", "Or swipe the menu bar with two fingers, or press ⌥⌘\\"),
        ]
        var top: CGFloat = 164
        for (i, text) in steps.enumerated() {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 12.5)
            label.preferredMaxLayoutWidth = w - 66
            let height = ceil(label.fittingSize.height)
            label.frame = NSRect(x: 46, y: top - height, width: w - 66, height: height)
            let badge = NSImageView(frame: NSRect(x: 20, y: top - 17, width: 18, height: 18))
            badge.image = NSImage(systemSymbolName: "\(i + 1).circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            badge.contentTintColor = .controlAccentColor
            view.addSubview(badge)
            view.addSubview(label)
            top -= height + 12
        }

        let done = NSButton(title: L("시작하기", "Got It"), target: self, action: #selector(close))
        done.bezelStyle = .push
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: w - 20 - 100, y: 16, width: 100, height: 32)
        view.addSubview(done)

        let controller = NSViewController()
        controller.view = view
        popover.contentViewController = controller
        popover.contentSize = view.frame.size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    func show(from button: NSStatusBarButton) {
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        demo.start()
    }

    @objc private func close() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) { demo.stop() }
}

/// A tiny menu bar that tucks and reveals three icons on a loop.
final class DemoBarView: NSView {
    private var timer: Timer?
    private var startedAt = Date()

    func start() {
        startedAt = Date()
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.needsDisplay = true }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 0 = open, 1 = tucked. Hold 1.2s, slip over 0.35s, hold, slip back.
    private var progress: CGFloat {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return 0 }
        let hold = 1.2, move = 0.35
        let t = Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: 2 * (hold + move))
        switch t {
        case ..<hold: return 0
        case ..<(hold + move): return CGFloat((t - hold) / move)
        case ..<(2 * hold + move): return 1
        default: return CGFloat(1 - (t - 2 * hold - move) / move)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: 0, y: (bounds.height - 30) / 2, width: bounds.width, height: 30)
        let shape = NSBezierPath(roundedRect: bar, xRadius: 9, yRadius: 9)
        NSGradient(starting: NSColor(srgbRed: 0.33, green: 0.40, blue: 0.56, alpha: 1),
                   ending: NSColor(srgbRed: 0.55, green: 0.47, blue: 0.66, alpha: 1))?.draw(in: shape, angle: 0)
        shape.addClip()

        let p = progress
        let eased = p < 0.5 ? 2 * p * p : 1 - pow(2 - 2 * p, 2) / 2
        let midY = bar.midY
        let white = NSColor.white

        let time = NSAttributedString(string: "9:41", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: white,
        ])
        time.draw(at: NSPoint(x: bar.maxX - 14 - time.size().width, y: midY - time.size().height / 2))

        let glyphX = bar.maxX - 64
        let glyph = Icons.glyph(progress: p)
        glyph.lockFocus()
        white.set()
        NSRect(origin: .zero, size: glyph.size).fill(using: .sourceAtop)
        glyph.unlockFocus()
        let gs = Icons.glyphSize
        glyph.draw(in: NSRect(x: glyphX, y: midY - gs.height / 2, width: gs.width, height: gs.height))

        white.withAlphaComponent(1 - eased).setFill()
        for i in 0..<3 {
            let x = glyphX - 22 - CGFloat(i) * 20 - eased * 60
            let r = NSRect(x: x, y: midY - 5.5, width: 11, height: 11)
            switch i {
            case 0: NSBezierPath(ovalIn: r).fill()
            case 1: NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            default:
                let tri = NSBezierPath()
                tri.move(to: NSPoint(x: r.midX, y: r.maxY)); tri.line(to: NSPoint(x: r.maxX, y: r.minY)); tri.line(to: NSPoint(x: r.minX, y: r.minY))
                tri.close(); tri.fill()
            }
        }

        let finder = NSAttributedString(string: "  Finder   File   Edit", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: white.withAlphaComponent(0.9),
        ])
        finder.draw(at: NSPoint(x: bar.minX + 6, y: midY - finder.size().height / 2))
    }
}

// MARK: - Hot key

/// A global hot key via Carbon — works without Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x534C_4950), id: 1)   // 'SLIP'
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

// MARK: - Icons

/// Shows the toggle glyph without taking the button's clicks.
final class GlyphView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private enum Icons {
    static let glyphSize = NSSize(width: 13.2, height: 16)

    /// Sizes the toggle button. macOS pads a status item's image 8pt on each side, and the spacer on
    /// the left already leaves 8pt, so the glyph (drawn separately, flush left) keeps only the right
    /// padding and the gap to the icons on its left matches the gap between any two icons.
    static let placeholder: NSImage = {
        let image = NSImage(size: NSSize(width: glyphSize.width + 8 - 16, height: glyphSize.height))
        image.isTemplate = true
        return image
    }()

    /// Toggle glyph: a faint bar (the edge the icons slip behind) and a chevron, drawn with one
    /// stroke so both share width and height, in the app icon's proportions. progress 0 = open (|›),
    /// 1 = tucked (|‹, toward the hidden icons like macOS's «); in between the chevron turns over the
    /// top while the bar stays put. The canvas is just wide enough for the turning chevron.
    static func glyph(progress: CGFloat) -> NSImage {
        let size = glyphSize, midY = glyphSize.height / 2
        let stroke: CGFloat = 1.8, halfHeight: CGFloat = 4.5, depth: CGFloat = 4.1
        let barX: CGFloat = 0.95, tipX: CGFloat = 5.25
        let t = progress < 0.5 ? 2 * progress * progress : 1 - pow(2 - 2 * progress, 2) / 2
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setLineWidth(stroke)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            context.strokeLineSegments(between: [CGPoint(x: barX, y: midY - halfHeight),
                                                 CGPoint(x: barX, y: midY + halfHeight)])
            context.translateBy(x: tipX + depth / 2, y: midY)
            context.rotate(by: .pi * (t - 1))
            context.move(to: CGPoint(x: depth / 2, y: halfHeight))
            context.addLine(to: CGPoint(x: -depth / 2, y: 0))
            context.addLine(to: CGPoint(x: depth / 2, y: -halfHeight))
            context.setStrokeColor(NSColor.black.cgColor)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = progress < 0.5 ? "Slip Away" : "Slip Back"
        return image
    }
}
