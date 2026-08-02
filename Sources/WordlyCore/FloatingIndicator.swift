import AppKit

/// A small floating pill shown above the Dock while dictating. Three modes:
/// listening (live level bars), processing (spinner), and rescue (the last
/// transcript with a Copy button, shown when it couldn't be pasted). The panel
/// is non-activating and joins all Spaces, so it never steals focus from the
/// app you're dictating into.
///
/// Main-thread only: every method touches AppKit and must be called on the
/// main thread (AppDelegate already does).
public final class FloatingIndicator {
    /// When false, listening/processing are suppressed. Rescue still shows —
    /// losing a transcript is worse than honoring the toggle.
    public var enabled = true

    /// True while the rescue panel is up, so callers can avoid dismissing a
    /// transcript the user hasn't copied yet (e.g. on the menu toggle).
    public private(set) var isShowingRescue = false

    private var panel: NSPanel?
    private let bars = WaveformView()
    private var animationTimer: Timer?
    private let spinner: NSProgressIndicator = {
        let s = NSProgressIndicator()
        s.style = .spinning
        s.controlSize = .small
        s.isDisplayedWhenStopped = false
        return s
    }()
    private let rescueTextView: NSTextView = {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 12)
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 2, height: 2)
        return tv
    }()
    private lazy var rescueScroll: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.drawsBackground = false
        sv.documentView = rescueTextView
        return sv
    }()
    private lazy var copyButton = NSButton(
        title: "Copy", target: self, action: #selector(copyRescue))
    private lazy var closeButton = NSButton(
        title: "✕", target: self, action: #selector(hide))
    private var rescueText = ""
    private var dismissTimer: Timer?
    /// True between a show…() and hide(), i.e. the panel is meant to be on
    /// screen right now. Drives the post-show health check.
    private var wantsVisible = false
    /// One window rebuild per show, so recovery can never loop.
    private var hasRebuilt = false

    private let pillSize = NSSize(width: 92, height: 32)
    private let rescueSize = NSSize(width: 340, height: 132)
    private static let panelBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    public init() {
        // A panel kept across a sleep or a display reconfigure can come back
        // wedged — AppKit reports it on screen, the WindowServer disagrees and
        // the pill never appears again. Cheaper to throw the window away than to
        // diagnose the WindowServer.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(environmentChanged),
            name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(environmentChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Public API (main thread)

    public func showListening() {
        guard enabled else { return }
        dismissTimer?.invalidate()
        wantsVisible = true
        hasRebuilt = false
        isShowingRescue = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        bars.isHidden = false
        rescueContainer.isHidden = true
        resize(to: pillSize, clickable: false)
        show()
        startWaveAnimation()
    }

    public func updateLevel(_ level: Float) {
        guard enabled, !bars.isHidden else { return }
        bars.level = CGFloat(level)  // target only; the animation loop eases to it
    }

    public func showProcessing() {
        guard enabled else { return }
        dismissTimer?.invalidate()
        stopWaveAnimation()
        wantsVisible = true
        hasRebuilt = false
        isShowingRescue = false
        bars.isHidden = true
        rescueContainer.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        resize(to: pillSize, clickable: false)
        show()
    }

    // Drive the waveform at a steady 30 fps so it eases smoothly toward the
    // latest level instead of stepping on each ~12/s audio callback.
    private func startWaveAnimation() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) {
            [weak self] _ in self?.bars.tick()
        }
    }

    private func stopWaveAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        bars.level = 0
    }

    /// Shown regardless of `enabled`: the transcript couldn't be pasted, so it
    /// must not vanish. Auto-dismisses after a while; user can Copy or close.
    public func showRescue(_ text: String) {
        stopWaveAnimation()
        rescueText = text
        rescueTextView.string = text
        rescueTextView.scroll(NSPoint(x: 0, y: 0))
        wantsVisible = true
        hasRebuilt = false
        isShowingRescue = true
        bars.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        rescueContainer.isHidden = false
        copyButton.title = "Copy"
        resize(to: rescueSize, clickable: true)
        show()
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) {
            [weak self] _ in self?.hide()
        }
    }

    @objc public func hide() {
        dismissTimer?.invalidate()
        stopWaveAnimation()
        wantsVisible = false
        isShowingRescue = false
        spinner.stopAnimation(nil)
        panel?.orderOut(nil)
    }

    // MARK: Panel plumbing

    private lazy var rescueContainer: NSView = {
        let container = NSView()
        rescueScroll.translatesAutoresizingMaskIntoConstraints = false
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.bezelStyle = .rounded
        closeButton.bezelStyle = .rounded
        closeButton.setButtonType(.momentaryPushIn)
        container.addSubview(rescueScroll)
        container.addSubview(copyButton)
        container.addSubview(closeButton)
        NSLayoutConstraint.activate([
            // Scrollable text fills the space above the button row, so a long
            // rescued transcript scrolls instead of clipping behind the buttons.
            rescueScroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            rescueScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            rescueScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            rescueScroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -8),
            copyButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            copyButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            closeButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }()

    /// Every mode's views, in one reusable container. Built once and re-parented
    /// into whatever panel is current, so a panel can be thrown away and rebuilt
    /// without orphaning the constraints between these views.
    private lazy var content: NSView = {
        let content = NSView()
        for view in [bars, spinner] {  // pill modes: centered
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
        }
        bars.widthAnchor.constraint(equalToConstant: 60).isActive = true
        bars.heightAnchor.constraint(equalToConstant: 22).isActive = true

        rescueContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rescueContainer)
        // Top/bottom are .defaultLow so the rescue button-stack's ~55pt minimum
        // height does NOT clamp the panel: in pill mode the panel stays at
        // pillSize.height; in rescue mode setFrame(rescueSize) lets them fill.
        let rcTop = rescueContainer.topAnchor.constraint(equalTo: content.topAnchor)
        let rcBottom = rescueContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        rcTop.priority = .defaultLow
        rcBottom.priority = .defaultLow
        NSLayoutConstraint.activate([  // rescue mode: fills the panel
            rescueContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rescueContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rcTop, rcBottom,
        ])
        return content
    }()

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: pillSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = Self.panelBehavior

        // Solid dark capsule drawn directly (a layer backgroundColor wasn't
        // fully opaque and its corner radius didn't read as a true pill).
        // Forced-dark appearance so child text/controls render light.
        let container = CapsuleBackgroundView()
        container.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = container

        // Only these four constraints are per-panel; addSubview moves `content`
        // out of any previous container and takes its own constraints with it.
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return panel
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        reposition(panel)
        let wasVisible = panel.isVisible
        panel.orderFrontRegardless()
        if !wasVisible {  // gentle fade-in only on first appearance
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                // Never strand a half-faded (invisible) pill if the implicit
                // animation gets dropped.
                ctx.completionHandler = { panel.alphaValue = 1 }
                panel.animator().alphaValue = 1
            }
        }
        wordlyLog("Wordly: pill shown frame=\(NSStringFromRect(panel.frame)) "
              + "screens=\(NSScreen.screens.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.verifyVisible()
        }
    }

    /// A pill that AppKit ordered front but that isn't actually on screen is the
    /// "pill vanished after wake" bug. Log the full state either way — comparing
    /// a working dictation against a broken one is what will name the cause —
    /// then rebuild the window once if it looks wrong.
    ///
    /// ponytail: occlusionState is logged but NOT judged. A visible, on-active-
    /// space pill reports an undocumented 8192 rather than `.visible`, so gating
    /// on it would rebuild (and blink) the pill on every single dictation.
    private func verifyVisible() {
        guard wantsVisible, let panel else { return }
        let screens = NSScreen.screens.map(\.frame)
        let healthy = PillHealth.isHealthy(isVisible: panel.isVisible,
                                           alpha: panel.alphaValue,
                                           isOnActiveSpace: panel.isOnActiveSpace,
                                           hasScreen: panel.screen != nil,
                                           frame: panel.frame, screenFrames: screens)
        wordlyLog("""
              Wordly: pill \(healthy ? "ok" : "NOT ON SCREEN") — \
              visible=\(panel.isVisible) \
              alpha=\(panel.alphaValue) activeSpace=\(panel.isOnActiveSpace) \
              occlusion=\(panel.occlusionState.rawValue) screen=\(panel.screen != nil) \
              frame=\(NSStringFromRect(panel.frame)) level=\(panel.level.rawValue) \
              behavior=\(panel.collectionBehavior.rawValue) screens=\(screens)
              """)
        guard !healthy, !hasRebuilt else { return }
        hasRebuilt = true
        let size = panel.frame.size
        let clickable = !panel.ignoresMouseEvents
        panel.orderOut(nil)
        self.panel = nil        // `content` re-parents into the fresh panel
        resize(to: size, clickable: clickable)
        show()
        wordlyLog("Wordly: pill window rebuilt")
    }

    /// Wake from sleep or a display change. An idle panel is discarded (the next
    /// dictation builds a fresh window); a visible one gets its level, Spaces
    /// behaviour and position re-asserted.
    @objc private func environmentChanged() {
        guard let panel else { return }
        if wantsVisible {
            panel.level = .statusBar
            panel.collectionBehavior = Self.panelBehavior
            reposition(panel)
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
            self.panel = nil
        }
    }

    private func resize(to size: NSSize, clickable: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.ignoresMouseEvents = !clickable
        var frame = panel.frame
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    private func reposition(_ panel: NSPanel) {
        // NSScreen.main can be nil right after a wake; falling back to any screen
        // beats returning early and leaving the pill at a stale, possibly
        // off-screen, origin.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrameOrigin(pillOrigin(in: screen.visibleFrame,  // excl. Dock + menu bar
                                        size: panel.frame.size))
    }

    @objc private func copyRescue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rescueText, forType: .string)
        copyButton.title = "Copied ✓"
    }
}

/// Centered horizontally, just above the Dock, and always fully inside the
/// visible area — a frame left over from a bigger or now-detached display must
/// never survive a reposition.
func pillOrigin(in visibleFrame: NSRect, size: NSSize) -> NSPoint {
    func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }
    return NSPoint(
        x: clamp(visibleFrame.midX - size.width / 2,
                 visibleFrame.minX, visibleFrame.maxX - size.width),
        y: clamp(visibleFrame.minY + 24,
                 visibleFrame.minY, visibleFrame.maxY - size.height))
}

/// Whether a pill that was ordered front is genuinely on screen. Split out as
/// plain values so the "why did it vanish" logic is testable without a
/// WindowServer.
enum PillHealth {
    static func isHealthy(isVisible: Bool, alpha: CGFloat, isOnActiveSpace: Bool,
                          hasScreen: Bool, frame: NSRect,
                          screenFrames: [NSRect]) -> Bool {
        isVisible && alpha > 0.99 && isOnActiveSpace && hasScreen
            && screenFrames.contains { $0.intersects(frame) }
    }
}

/// Solid dark background with fully-rounded (capsule) ends. Drawn rather than
/// layer-tinted so it's genuinely opaque and the short sides are true
/// semicircles, not a rounded rectangle.
private final class CapsuleBackgroundView: NSView {
    override var isOpaque: Bool { false }  // corners are transparent

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(bounds.height / 2, 16)  // capsule when short (pill mode)
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        path.fill()
    }
}

/// Thin animated waveform. `level` is the latest input amplitude (the target);
/// `tick()`, driven at 30 fps by the owner, eases each bar toward that target
/// with a per-bar shimmer so motion looks fluid and organic rather than
/// stepping once per audio callback.
private final class WaveformView: NSView {
    var level: CGFloat = 0

    private let count = 7
    private let envelope: [CGFloat] = [0.42, 0.62, 0.85, 1.0, 0.85, 0.62, 0.42]
    private var heights: [CGFloat]
    private var phase: CGFloat = 0

    private let baseline: CGFloat = 0.05

    override init(frame: NSRect) {
        heights = [CGFloat](repeating: baseline, count: count)
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// One animation frame: advance the shimmer and ease bars toward the
    /// level-scaled envelope. Silent input rests at a low flat line of dots.
    func tick() {
        phase += 0.22
        for i in 0..<count {
            let shimmer = 0.85 + 0.15 * sin(phase + CGFloat(i) * 0.9)
            let target = max(baseline, min(1, level * envelope[i] * shimmer))
            heights[i] += (target - heights[i]) * 0.35  // critically-ish damped
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 4
        let barWidth = (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count)
        NSColor.white.withAlphaComponent(0.92).setFill()  // on the dark capsule
        for i in 0..<count {
            let h = max(barWidth, bounds.height * heights[i])  // min = round dot
            let x = CGFloat(i) * (barWidth + gap)
            let rect = NSRect(x: x, y: (bounds.height - h) / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
