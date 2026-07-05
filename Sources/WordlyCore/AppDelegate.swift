import AppKit
import AVFoundation

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var infoItem: NSMenuItem!
    private var cleanupItem: NSMenuItem!
    private var languageItems: [String: NSMenuItem] = [:]

    private var config = Config.load()
    private let dictionary = UserDictionary()
    private let recorder = Recorder()
    private var transcriber: Transcriber?
    private var monitor: HotkeyMonitor?
    private var downloader: ModelDownloader?
    private var isProcessing = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        promptForAccessibility()
        startMonitorWhenTrusted()
        ensureModel()
    }

    // MARK: Status item + menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon("mic", tint: nil)

        let menu = NSMenu()
        infoItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)
        menu.addItem(.separator())

        cleanupItem = NSMenuItem(title: "Cleanup (Ollama)",
                                 action: #selector(toggleCleanup), keyEquivalent: "")
        cleanupItem.target = self
        cleanupItem.state = config.cleanupEnabled ? .on : .off
        menu.addItem(cleanupItem)

        let languageMenu = NSMenu()
        for (title, code) in [("Auto", "auto"), ("Deutsch", "de"), ("English", "en")] {
            let item = NSMenuItem(title: title,
                                  action: #selector(pickLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = config.language == code ? .on : .off
            languageMenu.addItem(item)
            languageItems[code] = item
        }
        let languageRoot = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        menu.setSubmenu(languageMenu, for: languageRoot)
        menu.addItem(languageRoot)

        let dictItem = NSMenuItem(title: "Edit Dictionary…",
                                  action: #selector(editDictionary), keyEquivalent: "")
        dictItem.target = self
        menu.addItem(dictItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Wordly",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func setIcon(_ symbol: String, tint: NSColor?) {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Wordly")
        button.contentTintColor = tint
    }

    private func setInfo(_ text: String) { infoItem.title = text }

    // MARK: Permissions + hotkey

    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private func startMonitorWhenTrusted() {
        let monitor = HotkeyMonitor(keyCode: config.keyCode)
        monitor.onStartCapture = { [weak self] in self?.startCapture() }
        monitor.onStopAndProcess = { [weak self] in self?.stopAndProcess() }
        monitor.onDiscardCapture = { [weak self] in self?.discardCapture() }
        if monitor.start() {
            self.monitor = monitor
            refreshInfo()
        } else {
            setInfo("Grant Accessibility, then wait…")
            setIcon("mic.slash", tint: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.startMonitorWhenTrusted()
            }
        }
    }

    // MARK: Model lifecycle

    private func ensureModel() {
        let url = config.modelURL
        if FileManager.default.fileExists(atPath: url.path) {
            loadModel(url)
        } else {
            setInfo("Downloading model… 0%")
            let downloader = ModelDownloader(model: config.whisperModel, destination: url)
            downloader.onProgress = { [weak self] pct in
                self?.setInfo("Downloading model… \(pct)%")
            }
            downloader.onDone = { [weak self] result in
                switch result {
                case .success(let url): self?.loadModel(url)
                case .failure(let error):
                    self?.setInfo("Model download failed — quit & relaunch to retry")
                    NSLog("Wordly: model download failed: \(error)")
                }
            }
            self.downloader = downloader
            downloader.startIfNeeded()
        }
    }

    private func loadModel(_ url: URL) {
        setInfo("Loading model…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let transcriber = Transcriber(modelPath: url.path)
            DispatchQueue.main.async {
                self?.transcriber = transcriber
                self?.refreshInfo()
                if transcriber == nil { self?.setInfo("Model failed to load") }
            }
        }
    }

    private func refreshInfo() {
        if transcriber == nil { return }  // model status text owns the line until ready
        if monitor == nil {
            setInfo("Grant Accessibility, then wait…")
        } else {
            setInfo("Ready — hold ^ to dictate")
            setIcon("mic", tint: nil)
        }
    }

    // MARK: Dictation pipeline

    private func startCapture() {
        guard !isProcessing, transcriber != nil else { return }
        recorder.start()
        if recorder.isRecording { setIcon("mic.fill", tint: .systemRed) }
    }

    private func discardCapture() {
        recorder.stop(discard: true)
        // Phantom gestures during transcription must not clobber the hourglass.
        if !isProcessing { setIcon("mic", tint: nil) }
    }

    private func stopAndProcess() {
        let samples = recorder.stop()
        guard !samples.isEmpty, let transcriber, !isProcessing else {
            if !isProcessing { setIcon("mic", tint: nil) }
            return
        }
        isProcessing = true
        setIcon("hourglass", tint: nil)
        let language = config.language
        let prompt = dictionary.initialPrompt()
        let terms = dictionary.terms()
        let cleanup = config.cleanupEnabled
        let model = config.ollamaModel

        Task.detached(priority: .userInitiated) { [weak self] in
            var text = transcriber.transcribe(samples, language: language,
                                              initialPrompt: prompt)
            if cleanup {
                text = await Cleaner.clean(text, terms: terms, model: model)
            }
            let finalText = text
            await MainActor.run {
                guard let self else { return }
                Injector.paste(finalText)
                self.isProcessing = false
                self.setIcon("mic", tint: nil)
            }
        }
    }

    // MARK: Menu actions

    @objc private func toggleCleanup() {
        config.cleanupEnabled.toggle()
        cleanupItem.state = config.cleanupEnabled ? .on : .off
        config.save()
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        config.language = code
        for (itemCode, item) in languageItems {
            item.state = itemCode == code ? .on : .off
        }
        config.save()
    }

    @objc private func editDictionary() {
        _ = dictionary.terms()  // ensures file + template exist
        NSWorkspace.shared.open(dictionary.url)
    }
}
