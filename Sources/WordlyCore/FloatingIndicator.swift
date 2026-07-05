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

    private let pillSize = NSSize(width: 92, height: 26)
    private let rescueSize = NSSize(width: 340, height: 132)

    public init() {}

    // MARK: Public API (main thread)

    public func showListening() {
        guard enabled else { return }
        dismissTimer?.invalidate()
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        // Always dark, like Wispr's Flow Bar, regardless of system theme.
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = pillSize.height / 2   // true capsule
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        for view in [bars, spinner] {  // pill modes: centered
            view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            ])
        }
        bars.widthAnchor.constraint(equalToConstant: 62).isActive = true
        bars.heightAnchor.constraint(equalToConstant: 12).isActive = true

        rescueContainer.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(rescueContainer)
        NSLayoutConstraint.activate([  // rescue mode: fills the panel
            rescueContainer.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            rescueContainer.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            rescueContainer.topAnchor.constraint(equalTo: effect.topAnchor),
            rescueContainer.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
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
                panel.animator().alphaValue = 1
            }
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
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame            // excludes Dock + menu bar
        let size = panel.frame.size
        let origin = NSPoint(
            x: vf.midX - size.width / 2,
            y: vf.minY + 24)
        panel.setFrameOrigin(origin)
    }

    @objc private func copyRescue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rescueText, forType: .string)
        copyButton.title = "Copied ✓"
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
