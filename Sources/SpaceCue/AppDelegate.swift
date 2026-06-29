import AppKit
import ApplicationServices
import CoreGraphics

private enum RefreshMode {
    case immediate
    case stabilized
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let privateAPI = PrivateSpacesAPI()
    private lazy var provider = SpaceProvider(api: privateAPI)
    private let store = SpaceStore()
    private let widget = WidgetWindowController()
    private let hotKeys = HotKeyManager()
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private var spaces: [SpaceInfo] = []
    private var observations: [String: (phrase: String, bundleIdentifier: String?, count: Int)] = [:]
    private var hasPromptedForAccessibility = false
    private var normalDesktopSwitchLockedUntil = Date.distantPast
    private var pendingActiveKey: String?
    private var pendingActiveConfirmations = 0
    private var lastRenderedActiveKey: String?
    private var pendingManagedSwitchKey: String?
    private var managedSwitchBusyUntil = Date.distantPast
    private var queuedManagedSwitch: SpaceInfo?
    private var queuedManagedFlushWorkItem: DispatchWorkItem?
    private var desktopSummaries: [String: (phrase: String, bundleIdentifier: String?)] = [:]

    override init() {
        SpaceCueLog.write("AppDelegate init")
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SpaceCueLog.write("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)

        configureStatusItem()
        configureWidget()
        configureWorkspaceObservers()
        refreshSpaces(mode: .immediate, reason: "launch")
        widget.show()
        SpaceCueLog.write("widget shown with \(spaces.count) spaces")

        hotKeys.register(maximumOrdinal: 9) { [weak self] ordinal in
            DispatchQueue.main.async {
                self?.switchToOrdinal(ordinal)
            }
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.refreshSpaces(mode: .stabilized, reason: "timer")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SpaceCueLog.write("applicationWillTerminate")
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        hotKeys.unregister()
        refreshTimer?.invalidate()
    }

    private func configureWidget() {
        widget.onSelect = { [weak self] space in
            self?.switchToSpace(space)
        }
        widget.onRename = { [weak self] space in
            self?.promptRename(space)
        }
        widget.onClear = { [weak self] space in
            self?.store.clearLabels(for: space.key)
            self?.refreshSpaces(mode: .immediate, reason: "clear-label")
        }
    }

    private func configureWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(workspaceActiveSpaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(workspaceApplicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(workspaceApplicationDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "SpaceCue")
        statusItem.button?.title = " Spaces"
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.addItem(menuItem("Refresh Spaces", action: #selector(refreshFromMenu), keyEquivalent: "r"))
        menu.addItem(menuItem("Show Widget", action: #selector(showWidget), keyEquivalent: "s"))
        menu.addItem(menuItem("Reset Widget Position", action: #selector(resetWidgetPosition), keyEquivalent: ""))
        menu.addItem(menuItem("Rename Current Space...", action: #selector(renameCurrentSpace), keyEquivalent: ""))
        menu.addItem(menuItem("Clear Current Label", action: #selector(clearCurrentLabel), keyEquivalent: ""))
        menu.addItem(menuItem("Reset Auto Labels", action: #selector(resetAutoLabels), keyEquivalent: ""))
        menu.addItem(.separator())

        let status = NSMenuItem(title: provider.apiStatus, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let hotkeys = NSMenuItem(title: "Hotkeys: ⌃1 ... ⌃9", action: nil, keyEquivalent: "")
        hotkeys.isEnabled = false
        menu.addItem(hotkeys)

        menu.addItem(.separator())
        menu.addItem(menuItem("Request Window Name Permission", action: #selector(requestWindowNamePermission), keyEquivalent: ""))
        menu.addItem(menuItem("Request Accessibility Permission", action: #selector(requestAccessibilityPermission), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit SpaceCue", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
        self.statusItem = statusItem
    }

    private func menuItem(_ title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func refreshSpaces(mode: RefreshMode = .immediate, reason: String = "manual") {
        var loaded = normalizeCurrentSpaceOrder(provider.loadSpaces())
        let activeKey = loaded.first(where: { $0.isCurrent })?.key

        if mode == .stabilized, shouldDeferRender(activeKey: activeKey, reason: reason) {
            return
        }

        pendingActiveKey = nil
        pendingActiveConfirmations = 0
        lastRenderedActiveKey = activeKey

        if let current = loaded.first(where: { $0.isCurrent }) {
            if current.type == 0,
               let context = WorkspaceIntrospector.visibleDesktopContext(excludingBundleID: Bundle.main.bundleIdentifier) {
                desktopSummaries[current.key] = (context.phrase, context.bundleIdentifier)
                if let bundleIdentifier = context.bundleIdentifier {
                    store.learnAppBundleIdentifier(bundleIdentifier, for: current.key)
                }
            } else if let context = WorkspaceIntrospector.currentAppContext(excludingBundleID: Bundle.main.bundleIdentifier) {
                observe(phrase: context.phrase, bundleIdentifier: context.bundleIdentifier ?? current.appBundleIdentifier, for: current)
            }
        }

        applyLabels(to: &loaded)
        applyAppIconHints(to: &loaded)

        guard loaded != spaces else {
            return
        }

        spaces = loaded
        widget.update(spaces: spaces)
        reassertWidget(reason: "refresh-\(reason)", delayed: false)
        let summary = spaces
            .map { "\($0.ordinal):\($0.label):\($0.isCurrent)" }
            .joined(separator: ", ")
        SpaceCueLog.write("refreshSpaces: \(summary)")
    }

    private func normalizeCurrentSpaceOrder(_ loaded: [SpaceInfo]) -> [SpaceInfo] {
        guard !loaded.isEmpty else {
            return loaded
        }

        return loaded
            .enumerated()
            .map { offset, space in
                var copy = space
                copy.ordinal = offset + 1
                return copy
            }
    }

    private func shouldDeferRender(activeKey: String?, reason: String) -> Bool {
        guard let activeKey, activeKey != lastRenderedActiveKey else {
            pendingActiveKey = nil
            pendingActiveConfirmations = 0
            return false
        }

        if pendingActiveKey == activeKey {
            pendingActiveConfirmations += 1
        } else {
            pendingActiveKey = activeKey
            pendingActiveConfirmations = 1
        }

        guard pendingActiveConfirmations < 2 else {
            return false
        }

        SpaceCueLog.write("refresh deferred reason=\(reason) activeKey=\(activeKey) confirmations=\(pendingActiveConfirmations)")
        return true
    }

    private func applyLabels(to loaded: inout [SpaceInfo]) {
        for index in loaded.indices {
            loaded[index].label = store.customLabel(for: loaded[index].key)
                ?? desktopSummaries[loaded[index].key]?.phrase
                ?? store.label(for: loaded[index].key)
                ?? loaded[index].defaultLabel
        }
    }

    private func applyAppIconHints(to loaded: inout [SpaceInfo]) {
        for index in loaded.indices where loaded[index].appBundleIdentifier == nil {
            let labelBundleIdentifier = AppIconResolver.bundleIdentifier(forAppName: loaded[index].label)
            let storedBundleIdentifier = store.appBundleIdentifier(for: loaded[index].key)
            let appNameBundleIdentifier = AppIconResolver.bundleIdentifier(forAppName: loaded[index].appName)

            if loaded[index].type == 0 {
                loaded[index].appBundleIdentifier = labelBundleIdentifier
                    ?? storedBundleIdentifier
                    ?? appNameBundleIdentifier
            } else {
                loaded[index].appBundleIdentifier = storedBundleIdentifier
                    ?? appNameBundleIdentifier
                    ?? labelBundleIdentifier
            }
        }
    }

    private func observe(phrase: String, bundleIdentifier: String?, for space: SpaceInfo) {
        if let bundleIdentifier {
            store.learnAppBundleIdentifier(bundleIdentifier, for: space.key)
        }

        guard !store.hasLabel(for: space.key) else {
            return
        }

        let previous = observations[space.key]
        let count = previous?.phrase == phrase ? (previous?.count ?? 0) + 1 : 1
        observations[space.key] = (phrase, bundleIdentifier, count)

        if count >= 2 {
            store.learn(phrase, for: space.key)
            if let bundleIdentifier {
                store.learnAppBundleIdentifier(bundleIdentifier, for: space.key)
            }
        }
    }

    private func switchToOrdinal(_ ordinal: Int) {
        guard ordinal > 0 else {
            return
        }

        guard ordinal <= spaces.count else {
            KeyboardFallback.sendDesktopShortcut(ordinal)
            scheduleRefresh(reason: "keyboard-ordinal-\(ordinal)")
            return
        }

        switchToSpace(spaces[ordinal - 1])
    }

    private func switchToSpace(_ requestedSpace: SpaceInfo) {
        var loaded = normalizeCurrentSpaceOrder(provider.loadSpaces())
        applyLabels(to: &loaded)
        applyAppIconHints(to: &loaded)

        let target = loaded.first(where: { $0.key == requestedSpace.key }) ?? requestedSpace
        let current = loaded.first(where: { $0.isCurrent })
        let activeKey = current?.key

        guard activeKey != target.key else {
            if !requestedSpace.isCurrent {
                refreshSpaces(mode: .immediate, reason: "switch-stale-current")
            }
            SpaceCueLog.write(
                "switch ignored actual-current ordinal=\(target.ordinal) renderedOrdinal=\(requestedSpace.ordinal) label=\(target.label)"
            )
            return
        }

        SpaceCueLog.write(
            "switch request ordinal=\(target.ordinal) renderedOrdinal=\(requestedSpace.ordinal) type=\(target.type) id64=\(target.id64) managedID=\(target.managedID.map(String.init) ?? "nil") label=\(target.label)"
        )

        switchToManagedSpace(target, attempt: 1)
    }

    private func switchToDesktop(_ space: SpaceInfo) {
        if Date() < normalDesktopSwitchLockedUntil {
            SpaceCueLog.write("switch desktop ignored; command already in flight ordinal=\(space.ordinal)")
            return
        }

        performDesktopKeyboardFallback(to: space, reason: "desktop-keyboard")
    }

    private func performDesktopKeyboardFallback(to space: SpaceInfo, reason: String) {
        if !KeyboardFallback.isAccessibilityTrusted {
            SpaceCueLog.write("switch desktop blocked; accessibility trusted=false ordinal=\(space.ordinal) reason=\(reason)")
            promptForAccessibilityIfNeeded()
            return
        }

        let actualSpaces = normalizeCurrentSpaceOrder(provider.loadSpaces())
        let actualTarget = actualSpaces.first(where: { $0.key == space.key }) ?? space
        let currentOrdinal = actualSpaces.first(where: { $0.isCurrent })?.ordinal
            ?? spaces.first(where: { $0.isCurrent })?.ordinal

        if let currentOrdinal, currentOrdinal != actualTarget.ordinal {
            let delta = actualTarget.ordinal - currentOrdinal
            let duration: TimeInterval
            let direction: String
            if delta < 0 {
                direction = "left"
                duration = KeyboardFallback.moveLeft(count: abs(delta))
            } else {
                direction = "right"
                duration = KeyboardFallback.moveRight(count: delta)
            }

            let delay = duration + 0.25
            normalDesktopSwitchLockedUntil = Date().addingTimeInterval(delay + 0.35)
            SpaceCueLog.write(
                "switch desktop fallback control-\(direction) count=\(abs(delta)) reason=\(reason) current=\(currentOrdinal) target=\(actualTarget.ordinal) renderedTarget=\(space.ordinal)"
            )
            scheduleRefresh(after: delay, mode: .immediate, reason: "desktop-fallback-\(direction)")
            scheduleRefresh(after: delay + 0.7, mode: .immediate, reason: "desktop-fallback-\(direction)-settle")
            verifyDesktopSwitch(to: actualTarget, after: delay + 0.35, reason: reason, attempt: 1)
            return
        }

        KeyboardFallback.sendDesktopShortcut(actualTarget.ordinal)
        normalDesktopSwitchLockedUntil = Date().addingTimeInterval(1.0)
        SpaceCueLog.write("switch desktop fallback control-number ordinal=\(actualTarget.ordinal) renderedTarget=\(space.ordinal) reason=\(reason)")
        scheduleRefresh(after: 0.8, mode: .immediate, reason: "desktop-control-number")
        scheduleRefresh(after: 1.4, mode: .immediate, reason: "desktop-control-number-settle")
        verifyDesktopSwitch(to: actualTarget, after: 0.9, reason: reason, attempt: 2)
    }

    private func verifyDesktopSwitch(to target: SpaceInfo, after delay: TimeInterval, reason: String, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.verifyDesktopSwitch(target: target, reason: reason, attempt: attempt)
        }
    }

    private func verifyDesktopSwitch(target: SpaceInfo, reason: String, attempt: Int) {
        let loaded = normalizeCurrentSpaceOrder(provider.loadSpaces())
        let current = loaded.first(where: { $0.isCurrent })
        if current?.key == target.key {
            refreshSpaces(mode: .immediate, reason: "desktop-\(target.ordinal)-verified")
            return
        }

        SpaceCueLog.write(
            "switch desktop missed target=\(target.ordinal) attempt=\(attempt) current=\(current?.ordinal.description ?? "nil") reason=\(reason)"
        )

        guard attempt == 1,
              let retryTarget = loaded.first(where: { $0.key == target.key }) else {
            return
        }

        KeyboardFallback.sendDesktopShortcut(retryTarget.ordinal)
        normalDesktopSwitchLockedUntil = Date().addingTimeInterval(1.0)
        SpaceCueLog.write("switch desktop retry control-number ordinal=\(retryTarget.ordinal) renderedTarget=\(target.ordinal) reason=\(reason)")
        scheduleRefresh(after: 0.8, mode: .immediate, reason: "desktop-control-number-retry")
        verifyDesktopSwitch(to: retryTarget, after: 0.9, reason: "\(reason)-control-number-retry", attempt: 2)
    }

    private func switchToManagedSpace(_ space: SpaceInfo, attempt: Int) {
        if attempt == 1, Date() < managedSwitchBusyUntil {
            queuedManagedSwitch = space
            let delay = max(0.06, managedSwitchBusyUntil.timeIntervalSinceNow + 0.03)
            SpaceCueLog.write("switch private queued ordinal=\(space.ordinal) delay=\(String(format: "%.2f", delay))")
            scheduleQueuedManagedSwitch(after: delay)
            return
        }

        managedSwitchBusyUntil = Date().addingTimeInterval(0.62)
        pendingManagedSwitchKey = space.key
        let didSwitch = provider.switchTo(space)
        SpaceCueLog.write("switch private result=\(didSwitch) ordinal=\(space.ordinal) attempt=\(attempt)")
        reassertWidget(reason: "switch-\(space.ordinal)-start")

        scheduleRefresh(after: 0.18, reason: "switch-\(space.ordinal)-attempt-\(attempt)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) { [weak self] in
            self?.verifyManagedSpaceSwitch(target: space, attempt: attempt, didSwitch: didSwitch)
        }
    }

    private func performKeyboardSpaceSwitch(
        to target: SpaceInfo,
        current: SpaceInfo?,
        reason: String,
        attempt: Int = 1
    ) {
        if attempt == 1, Date() < managedSwitchBusyUntil {
            queuedManagedSwitch = target
            let delay = max(0.06, managedSwitchBusyUntil.timeIntervalSinceNow + 0.03)
            SpaceCueLog.write("switch keyboard queued ordinal=\(target.ordinal) delay=\(String(format: "%.2f", delay)) reason=\(reason)")
            scheduleQueuedManagedSwitch(after: delay)
            return
        }

        guard KeyboardFallback.isAccessibilityTrusted else {
            SpaceCueLog.write("switch keyboard unavailable; falling back private ordinal=\(target.ordinal) reason=\(reason)")
            switchToManagedSpace(target, attempt: 1)
            return
        }

        let actualSpaces = provider.loadSpaces()
        let actualCurrent = actualSpaces.first(where: { $0.isCurrent }) ?? current
        let actualTarget = actualSpaces.first(where: { $0.key == target.key }) ?? target

        guard let actualCurrent else {
            SpaceCueLog.write("switch keyboard missing current; falling back private target=\(target.ordinal) reason=\(reason)")
            switchToManagedSpace(target, attempt: 1)
            return
        }

        let delta = actualTarget.ordinal - actualCurrent.ordinal
        guard delta != 0 else {
            refreshSpaces(mode: .immediate, reason: "switch-keyboard-already-current")
            return
        }

        pendingManagedSwitchKey = nil
        let direction: String
        let duration: TimeInterval
        if delta < 0 {
            direction = "left"
            duration = KeyboardFallback.moveLeft(count: abs(delta))
        } else {
            direction = "right"
            duration = KeyboardFallback.moveRight(count: delta)
        }

        let delay = duration + 0.25
        managedSwitchBusyUntil = Date().addingTimeInterval(delay + 0.25)
        SpaceCueLog.write(
            "switch keyboard control-\(direction) count=\(abs(delta)) reason=\(reason) current=\(actualCurrent.ordinal) target=\(actualTarget.ordinal) renderedTarget=\(target.ordinal) attempt=\(attempt)"
        )
        reassertWidget(reason: "keyboard-\(target.ordinal)-start")
        scheduleRefresh(after: delay, mode: .immediate, reason: "keyboard-\(target.ordinal)-\(direction)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.25) { [weak self] in
            self?.verifyKeyboardSpaceSwitch(target: target, reason: reason, attempt: attempt)
        }
    }

    private func verifyKeyboardSpaceSwitch(target: SpaceInfo, reason: String, attempt: Int) {
        let loaded = normalizeCurrentSpaceOrder(provider.loadSpaces())
        let current = loaded.first(where: { $0.isCurrent })
        if current?.key == target.key {
            refreshSpaces(mode: .immediate, reason: "keyboard-\(target.ordinal)-verified")
            flushQueuedManagedSwitch(after: 0.08)
            return
        }

        SpaceCueLog.write(
            "switch keyboard missed target=\(target.ordinal) attempt=\(attempt) current=\(current?.ordinal.description ?? "nil") reason=\(reason)"
        )

        if attempt < 2, let retryTarget = loaded.first(where: { $0.key == target.key }) {
            performKeyboardSpaceSwitch(to: retryTarget, current: current, reason: "\(reason)-retry", attempt: attempt + 1)
            return
        }

        flushQueuedManagedSwitch(after: 0.2)
    }

    private func verifyManagedSpaceSwitch(target: SpaceInfo, attempt: Int, didSwitch: Bool) {
        guard pendingManagedSwitchKey == target.key else {
            SpaceCueLog.write("switch verification ignored stale target=\(target.ordinal) attempt=\(attempt)")
            return
        }

        let currentKey = provider.loadSpaces().first(where: { $0.isCurrent })?.key
        if currentKey == target.key {
            pendingManagedSwitchKey = nil
            refreshSpaces(mode: .immediate, reason: "switch-\(target.ordinal)-verified")
            flushQueuedManagedSwitch(after: 0.08)
            return
        }

        if didSwitch, attempt < 3 {
            SpaceCueLog.write(
                "switch private missed target=\(target.ordinal) attempt=\(attempt) currentKey=\(currentKey ?? "nil"); retrying"
            )
            switchToManagedSpace(target, attempt: attempt + 1)
            return
        }

        SpaceCueLog.write(
            "switch private failed target=\(target.ordinal) type=\(target.type) currentKey=\(currentKey ?? "nil"); falling back to keyboard"
        )
        pendingManagedSwitchKey = nil
        if target.type == 0 {
            guard KeyboardFallback.isAccessibilityTrusted else {
                SpaceCueLog.write("switch desktop private failed and keyboard unavailable ordinal=\(target.ordinal)")
                flushQueuedManagedSwitch(after: 0.2)
                return
            }
            switchToDesktop(target)
        } else {
            performSpaceKeyboardFallback(to: target, reason: "managed-private-missed")
        }
        flushQueuedManagedSwitch(after: 0.35)
    }

    private func scheduleQueuedManagedSwitch(after delay: TimeInterval) {
        queuedManagedFlushWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            self?.flushQueuedManagedSwitch()
        }
        queuedManagedFlushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func flushQueuedManagedSwitch(after delay: TimeInterval = 0) {
        guard let queued = queuedManagedSwitch else {
            return
        }

        if delay > 0 {
            scheduleQueuedManagedSwitch(after: delay)
            return
        }

        if Date() < managedSwitchBusyUntil {
            scheduleQueuedManagedSwitch(after: max(0.06, managedSwitchBusyUntil.timeIntervalSinceNow + 0.03))
            return
        }

        queuedManagedSwitch = nil
        SpaceCueLog.write("switch private dequeued ordinal=\(queued.ordinal)")
        switchToSpace(queued)
    }

    private func performSpaceKeyboardFallback(to space: SpaceInfo, reason: String) {
        guard KeyboardFallback.isAccessibilityTrusted else {
            SpaceCueLog.write("switch keyboard fallback blocked; accessibility trusted=false ordinal=\(space.ordinal) reason=\(reason)")
            return
        }

        var loaded = normalizeCurrentSpaceOrder(provider.loadSpaces())
        applyLabels(to: &loaded)
        guard let currentOrdinal = loaded.first(where: { $0.isCurrent })?.ordinal else {
            SpaceCueLog.write("switch keyboard fallback missing current ordinal target=\(space.ordinal) reason=\(reason)")
            return
        }

        let target = loaded.first(where: { $0.key == space.key }) ?? space
        let delta = target.ordinal - currentOrdinal
        guard delta != 0 else {
            refreshSpaces(mode: .immediate, reason: "switch-keyboard-already-current")
            return
        }

        let duration: TimeInterval
        let direction: String
        if delta < 0 {
            direction = "left"
            duration = KeyboardFallback.moveLeft(count: abs(delta))
        } else {
            direction = "right"
            duration = KeyboardFallback.moveRight(count: delta)
        }

        let delay = duration + 0.25
        SpaceCueLog.write(
            "switch keyboard fallback control-\(direction) count=\(abs(delta)) reason=\(reason) current=\(currentOrdinal) target=\(target.ordinal) renderedTarget=\(space.ordinal)"
        )
        scheduleRefresh(after: delay, mode: .immediate, reason: "switch-keyboard-\(direction)")
        scheduleRefresh(after: delay + 0.7, mode: .immediate, reason: "switch-keyboard-\(direction)-settle")
    }

    private func promptForAccessibilityIfNeeded() {
        guard !hasPromptedForAccessibility else {
            NSSound.beep()
            return
        }

        hasPromptedForAccessibility = true
        requestAccessibilityPermission()
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Needed"
        alert.informativeText = "Normal Desktop switching uses Mission Control keyboard shortcuts, so SpaceCue needs Accessibility permission. After granting it, quit and reopen SpaceCue."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func scheduleRefresh(reason: String = "scheduled") {
        scheduleRefresh(after: 0.35, reason: reason)
    }

    private func scheduleRefresh(after delay: TimeInterval, mode: RefreshMode = .stabilized, reason: String = "scheduled") {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.refreshSpaces(mode: mode, reason: reason)
        }
    }

    private func scheduleRefreshBurst(reason: String) {
        SpaceCueLog.write("refresh burst reason=\(reason)")
        reassertWidget(reason: reason)
        for delay in [0.05, 0.2, 0.45, 0.9] {
            scheduleRefresh(after: delay, reason: reason)
        }
        scheduleRefresh(after: 1.4, mode: .immediate, reason: "\(reason)-settle")
    }

    private func reassertWidget(reason: String, delayed: Bool = true) {
        widget.reassertVisibility(reason: reason)
        guard delayed else {
            return
        }

        for delay in [0.12, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.widget.reassertVisibility(reason: "\(reason)-settle")
            }
        }
    }

    private func promptRename(_ space: SpaceInfo) {
        let alert = NSAlert()
        alert.messageText = "Rename Space \(space.ordinal)"
        alert.informativeText = "This label is shown in the floating widget."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = store.customLabel(for: space.key) ?? space.label
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return
        }

        store.setCustomLabel(field.stringValue, for: space.key)
        refreshSpaces(mode: .immediate, reason: "rename")
    }

    @objc private func refreshFromMenu() {
        refreshSpaces(mode: .immediate, reason: "menu")
    }

    @objc private func workspaceActiveSpaceDidChange(_ notification: Notification) {
        scheduleRefreshBurst(reason: "active-space")
    }

    @objc private func workspaceApplicationDidActivate(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }
        scheduleRefreshBurst(reason: "app-activate:\(app?.localizedName ?? "unknown")")
    }

    @objc private func workspaceApplicationDidLaunch(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }
        scheduleRefreshBurst(reason: "app-launch:\(app?.localizedName ?? "unknown")")
    }

    @objc private func showWidget() {
        widget.show()
    }

    @objc private func resetWidgetPosition() {
        widget.resetPosition()
    }

    @objc private func renameCurrentSpace() {
        guard let current = spaces.first(where: { $0.isCurrent }) else {
            NSSound.beep()
            return
        }
        promptRename(current)
    }

    @objc private func clearCurrentLabel() {
        guard let current = spaces.first(where: { $0.isCurrent }) else {
            NSSound.beep()
            return
        }
        store.clearLabels(for: current.key)
        refreshSpaces(mode: .immediate, reason: "clear-current-label")
    }

    @objc private func resetAutoLabels() {
        observations.removeAll()
        store.clearLearnedLabels()
        refreshSpaces(mode: .immediate, reason: "reset-auto-labels")
    }

    @objc private func requestWindowNamePermission() {
        _ = CGRequestScreenCaptureAccess()
        refreshSpaces(mode: .immediate, reason: "window-permission")
    }

    @objc private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
