import AppKit

final class WidgetWindowController: NSObject, NSWindowDelegate {
    private let contentView = WidgetView(frame: .zero)
    private let originKey = "widget.origin.v1"
    private var placedInitialFrame = false
    private var globalMouseMonitor: Any?
    private var lastLocalClickAt = Date.distantPast

    var onSelect: ((SpaceInfo) -> Void)? {
        get { contentView.onSelect }
        set { contentView.onSelect = newValue }
    }

    var onRename: ((SpaceInfo) -> Void)? {
        get { contentView.onRename }
        set { contentView.onRename = newValue }
    }

    var onClear: ((SpaceInfo) -> Void)? {
        get { contentView.onClear }
        set { contentView.onClear = newValue }
    }

    override init() {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 216, height: 194),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver

        super.init()

        panel.contentView = contentView
        panel.delegate = self
        self.window = panel
        installGlobalMouseMonitor()
    }

    private(set) var window: NSWindow!

    deinit {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
    }

    func show() {
        placeOnVisibleScreenIfNeeded()
        reassertVisibility(reason: "show")
    }

    func update(spaces: [SpaceInfo]) {
        contentView.render(spaces: spaces)
        resizeToFit()
    }

    func resetPosition() {
        let size = contentView.desiredSize()
        var frame = window.frame
        frame.size = size
        frame.origin = defaultOrigin(for: size)
        placedInitialFrame = true
        window.setFrame(frame, display: true)
        UserDefaults.standard.set([Double(frame.origin.x), Double(frame.origin.y)], forKey: originKey)
        window.orderFrontRegardless()
    }

    func reassertVisibility(reason: String) {
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.level = .screenSaver
        window.orderFrontRegardless()
        SpaceCueLog.write("widget reassert reason=\(reason)")
    }

    func windowDidMove(_ notification: Notification) {
        guard placedInitialFrame else {
            return
        }
        let frame = window.frame
        UserDefaults.standard.set([Double(frame.origin.x), Double(frame.origin.y)], forKey: originKey)
    }

    private func resizeToFit() {
        let size = contentView.desiredSize()
        var frame = window.frame
        let oldMaxY = frame.maxY
        frame.size = size

        if !placedInitialFrame {
            if let stored = UserDefaults.standard.array(forKey: originKey) as? [Double],
               stored.count == 2,
               isVisible(origin: NSPoint(x: stored[0], y: stored[1]), size: size) {
                frame.origin = NSPoint(x: stored[0], y: stored[1])
            } else {
                frame.origin = defaultOrigin(for: size)
            }
            placedInitialFrame = true
        } else {
            frame.origin.y = oldMaxY - size.height
        }

        window.setFrame(frame, display: true)
    }

    private func placeOnVisibleScreenIfNeeded() {
        guard !placedInitialFrame else {
            return
        }
        let size = contentView.desiredSize()
        window.setFrame(NSRect(origin: defaultOrigin(for: size), size: size), display: true)
    }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        let frame = activeScreenFrame()
        return NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 42
        )
    }

    private func isVisible(origin: NSPoint, size: NSSize) -> Bool {
        let rect = NSRect(origin: origin, size: size)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
    }

    private func activeScreenFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func installGlobalMouseMonitor() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleGlobalMouseUp()
            }
        }
    }

    private func handleGlobalMouseUp() {
        guard Date().timeIntervalSince(lastLocalClickAt) > 0.2 else {
            return
        }

        guard window.isVisible else {
            return
        }

        let screenPoint = NSEvent.mouseLocation
        guard window.frame.contains(screenPoint) else {
            return
        }

        let windowPoint = NSPoint(
            x: screenPoint.x - window.frame.minX,
            y: screenPoint.y - window.frame.minY
        )
        guard let space = contentView.space(atWindowPoint: windowPoint) else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self,
                  Date().timeIntervalSince(self.lastLocalClickAt) > 0.2 else {
                return
            }

            SpaceCueLog.write("global button action ordinal=\(space.ordinal) label=\(space.label)")
            self.onSelect?(space)
            self.reassertVisibility(reason: "global-click")
        }
    }
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class WidgetView: NSView {
    private let stackView = NSStackView()
    private var dragAnchor: NSPoint?

    var onSelect: ((SpaceInfo) -> Void)?
    var onRename: ((SpaceInfo) -> Void)?
    var onClear: ((SpaceInfo) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.distribution = .fillEqually
        stackView.spacing = 6
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(spaces: [SpaceInfo]) {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for space in spaces {
            let button = SpaceButton(space: space)
            button.target = self
            button.action = #selector(spaceButtonPressed(_:))
            button.menu = menu(for: space)
            stackView.addArrangedSubview(button)
        }
    }

    func desiredSize() -> NSSize {
        layoutSubtreeIfNeeded()
        let fitting = stackView.fittingSize
        return NSSize(width: max(216, fitting.width), height: max(40, fitting.height))
    }

    func space(atWindowPoint windowPoint: NSPoint) -> SpaceInfo? {
        let localPoint = convert(windowPoint, from: nil)
        for view in stackView.arrangedSubviews {
            guard let button = view as? SpaceButton else {
                continue
            }

            let buttonPoint = button.convert(localPoint, from: self)
            if button.bounds.contains(buttonPoint) {
                return button.space
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        dragAnchor = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragAnchor else {
            return
        }

        let mouse = NSEvent.mouseLocation
        let newOrigin = NSPoint(x: mouse.x - dragAnchor.x, y: mouse.y - dragAnchor.y)
        window.setFrameOrigin(newOrigin)
    }

    @objc private func spaceButtonPressed(_ sender: SpaceButton) {
        SpaceCueLog.write("button action ordinal=\(sender.space.ordinal) label=\(sender.space.label)")
        notifyLocalClick()
        onSelect?(sender.space)
    }

    @objc private func renameSpace(_ sender: NSMenuItem) {
        guard let space = sender.representedObject as? SpaceBox else {
            return
        }
        onRename?(space.value)
    }

    @objc private func clearSpace(_ sender: NSMenuItem) {
        guard let space = sender.representedObject as? SpaceBox else {
            return
        }
        onClear?(space.value)
    }

    private func menu(for space: SpaceInfo) -> NSMenu {
        let menu = NSMenu()
        let box = SpaceBox(space)

        let rename = NSMenuItem(title: "Rename...", action: #selector(renameSpace(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = box
        menu.addItem(rename)

        let clear = NSMenuItem(title: "Clear Label", action: #selector(clearSpace(_:)), keyEquivalent: "")
        clear.target = self
        clear.representedObject = box
        menu.addItem(clear)

        return menu
    }

    private func notifyLocalClick() {
        var view: NSView? = self
        while let current = view {
            if let controller = current.window?.delegate as? WidgetWindowController {
                controller.noteLocalClick()
                return
            }
            view = current.superview
        }
    }
}

private extension WidgetWindowController {
    func noteLocalClick() {
        lastLocalClickAt = Date()
    }
}

private final class SpaceBox: NSObject {
    let value: SpaceInfo

    init(_ value: SpaceInfo) {
        self.value = value
    }
}

private final class SpaceButton: NSButton {
    static let preferredWidth: CGFloat = 216

    let space: SpaceInfo
    private let glassBackgroundView = LiquidGlassBackgroundView()
    private let contentStack = PassthroughStackView()
    private let nameLabel = ButtonLabel()
    private let shortcutLabel = ButtonLabel()
    private var trackingAnchorInWindow: NSPoint?
    private var trackingStartMouse: NSPoint?
    private var didDragWindow = false

    init(space: SpaceInfo) {
        self.space = space
        super.init(frame: .zero)
        title = ""
        toolTip = "Switch to \(space.label): ⌥ \(space.ordinal)"
        setButtonType(.momentaryChange)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = space.isCurrent ? 0.2 : 0.14
        layer?.shadowRadius = space.isCurrent ? 10 : 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        lineBreakMode = .byTruncatingTail
        font = .systemFont(ofSize: 14, weight: space.isCurrent ? .semibold : .medium)
        contentTintColor = textColor(for: space)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        widthAnchor.constraint(equalToConstant: Self.preferredWidth).isActive = true

        configureGlass(for: space)
        configureContent(for: space)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.preferredWidth, height: 34)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        )
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        trackingAnchorInWindow = event.locationInWindow
        trackingStartMouse = NSEvent.mouseLocation
        didDragWindow = false
        highlight(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let anchorInWindow = trackingAnchorInWindow,
              let startMouse = trackingStartMouse else {
            return
        }

        let mouse = NSEvent.mouseLocation
        let distance = hypot(mouse.x - startMouse.x, mouse.y - startMouse.y)
        if distance > 9 {
            didDragWindow = true
            highlight(false)
        }

        if didDragWindow {
            window.setFrameOrigin(NSPoint(x: mouse.x - anchorInWindow.x, y: mouse.y - anchorInWindow.y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        highlight(false)
        defer {
            trackingAnchorInWindow = nil
            trackingStartMouse = nil
            didDragWindow = false
        }

        guard !didDragWindow,
              bounds.contains(convert(event.locationInWindow, from: nil)),
              let action else {
            return
        }

        NSApp.sendAction(action, to: target, from: self)
    }

    private func textColor(for space: SpaceInfo) -> NSColor {
        space.isCurrent ? .black : NSColor(calibratedWhite: 0.16, alpha: 1)
    }

    private func configureGlass(for space: SpaceInfo) {
        glassBackgroundView.isActive = space.isCurrent
        glassBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassBackgroundView)

        NSLayoutConstraint.activate([
            glassBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassBackgroundView.topAnchor.constraint(equalTo: topAnchor),
            glassBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func configureContent(for space: SpaceInfo) {
        let textColor = textColor(for: space)
        let font = NSFont.systemFont(ofSize: 14, weight: space.isCurrent ? .semibold : .medium)

        nameLabel.stringValue = space.label
        nameLabel.font = font
        nameLabel.textColor = textColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        shortcutLabel.stringValue = "⌥ \(space.ordinal)"
        shortcutLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        shortcutLabel.textColor = shortcutTextColor(for: space)
        shortcutLabel.alignment = .right
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.distribution = .fill
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        if let icon = AppIconResolver.icon(for: space) {
            let iconBoxSize: CGFloat = 24
            let iconVisualSize: CGFloat = 22
            let iconOffsetX: CGFloat = space.type == 0 ? 1 : 0
            let iconContainer = ButtonIconContainerView(frame: .zero)
            let iconView = ButtonIconView(image: icon)
            iconView.imageScaling = .scaleProportionallyDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconContainer.translatesAutoresizingMaskIntoConstraints = false
            iconContainer.setContentHuggingPriority(.required, for: .horizontal)
            iconContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
            iconContainer.addSubview(iconView)
            NSLayoutConstraint.activate([
                iconContainer.widthAnchor.constraint(equalToConstant: iconBoxSize),
                iconContainer.heightAnchor.constraint(equalToConstant: iconBoxSize),
                iconView.widthAnchor.constraint(equalToConstant: iconVisualSize),
                iconView.heightAnchor.constraint(equalToConstant: iconVisualSize),
                iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor, constant: iconOffsetX),
                iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor)
            ])
            contentStack.addArrangedSubview(iconContainer)
        }

        contentStack.addArrangedSubview(nameLabel)

        let spacer = ButtonSpacerView(frame: .zero)
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentStack.addArrangedSubview(spacer)

        let shortcutContainer = ButtonShortcutContainerView(frame: .zero)
        shortcutContainer.translatesAutoresizingMaskIntoConstraints = false
        shortcutContainer.setContentHuggingPriority(.required, for: .horizontal)
        shortcutContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutContainer.addSubview(shortcutLabel)
        NSLayoutConstraint.activate([
            shortcutContainer.heightAnchor.constraint(equalToConstant: 24),
            shortcutLabel.leadingAnchor.constraint(equalTo: shortcutContainer.leadingAnchor),
            shortcutLabel.trailingAnchor.constraint(equalTo: shortcutContainer.trailingAnchor),
            shortcutLabel.centerYAnchor.constraint(equalTo: shortcutContainer.centerYAnchor, constant: -1)
        ])
        contentStack.addArrangedSubview(shortcutContainer)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func shortcutTextColor(for space: SpaceInfo) -> NSColor {
        space.isCurrent
            ? NSColor.black.withAlphaComponent(0.5)
            : NSColor(calibratedWhite: 0.36, alpha: 0.62)
    }
}

private final class LiquidGlassBackgroundView: NSView {
    private let effectView = NSVisualEffectView()
    private let tintView = LiquidGlassTintView()

    var isActive: Bool = false {
        didSet {
            applyAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        effectView.blendingMode = .behindWindow
        effectView.material = .popover
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 8
        effectView.layer?.masksToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)

        tintView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tintView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        applyAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func applyAppearance() {
        effectView.material = isActive ? .hudWindow : .popover
        tintView.isActive = isActive
        tintView.needsDisplay = true
    }
}

private final class LiquidGlassTintView: NSView {
    var isActive: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)

        if isActive {
            NSColor.systemOrange.withAlphaComponent(0.72).setFill()
        } else {
            NSColor.white.withAlphaComponent(0.26).setFill()
        }
        path.fill()

        let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5)
        NSColor.white.withAlphaComponent(isActive ? 0.52 : 0.68).setStroke()
        highlight.lineWidth = 1
        highlight.stroke()

        let lowerEdge = NSBezierPath()
        lowerEdge.move(to: NSPoint(x: rect.minX + 8, y: rect.minY + 1))
        lowerEdge.line(to: NSPoint(x: rect.maxX - 8, y: rect.minY + 1))
        NSColor.black.withAlphaComponent(isActive ? 0.12 : 0.08).setStroke()
        lowerEdge.lineWidth = 1
        lowerEdge.stroke()
    }
}

private final class PassthroughStackView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class ButtonLabel: NSTextField {
    init() {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        backgroundColor = .clear
        maximumNumberOfLines = 1
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class ButtonIconView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class ButtonIconContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class ButtonShortcutContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class ButtonSpacerView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: 0, height: 1)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
