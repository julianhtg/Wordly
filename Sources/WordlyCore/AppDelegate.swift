import AppKit
import AVFoundation

public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var infoItem: NSMenuItem!
    private var cleanupItem: NSMenuItem!
    private var indicatorItem: NSMenuItem!
    private var copyLastItem: NSMenuItem!
    private var micMenu: NSMenu!
    private var languageRoot: NSMenuItem!
    private var autoLanguageItem: NSMenuItem!
    private var languageItems: [String: NSMenuItem] = [:]
    private var engineItems: [String: NSMenuItem] = [:]

    private var config = Config.load()
    private let dictionary = UserDictionary()
    private let recorder = Recorder()
    private let indicator = FloatingIndicator()
    private var engine: (any SpeechEngine)?
    private var isLoadingEngine = false
    private var monitor: HotkeyMonitor?
    private var downloader: ModelDownloader?
    private var isProcessing = false
    private var lastTranscript = ""
    private var lastRun = ""  // "de · 0.9 s", shown in the menu's info line

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        indicator.enabled = config.showIndicator
        recorder.inputDeviceUID = config.inputDeviceUID
        recorder.onLevel = { [weak self] level in self?.indicator.updateLevel(level) }
        buildStatusItem()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        promptForAccessibility()
        startMonitorWhenTrusted()
        ensureEngine()
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // ponytail: whisper.cpp's prebuilt Metal backend aborts in its static
        // destructor at normal exit (ggml_metal_rsets_free -> ggml_abort), so the
        // app SIGABRTs on every quit. We do no cleanup on quit (config saves on
        // change), so exit immediately and skip the C++ finalizers that crash.
        _exit(0)
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

        indicatorItem = NSMenuItem(title: "Floating Indicator",
                                   action: #selector(toggleIndicator), keyEquivalent: "")
        indicatorItem.target = self
        indicatorItem.state = config.showIndicator ? .on : .off
        menu.addItem(indicatorItem)

        languageRoot = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        menu.setSubmenu(buildLanguageMenu(), for: languageRoot)
        menu.addItem(languageRoot)
        refreshLanguageMenu()

        let engineMenu = NSMenu()
        for (title, value) in [("Automatic", "auto"),
                               ("Parakeet — fast", EngineRouting.fast),
                               ("Whisper — every language", EngineRouting.general)] {
            let item = NSMenuItem(title: title, action: #selector(pickEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = config.engine == value ? .on : .off
            engineMenu.addItem(item)
            engineItems[value] = item
        }
        let engineRoot = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        menu.setSubmenu(engineMenu, for: engineRoot)
        menu.addItem(engineRoot)

        micMenu = NSMenu()
        micMenu.delegate = self  // refreshes the device list each time it opens
        rebuildMicMenu()
        let micRoot = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        menu.setSubmenu(micMenu, for: micRoot)
        menu.addItem(micRoot)

        let dictItem = NSMenuItem(title: "Edit Dictionary…",
                                  action: #selector(editDictionary), keyEquivalent: "")
        dictItem.target = self
        menu.addItem(dictItem)

        copyLastItem = NSMenuItem(title: "Copy Last Transcript",
                                  action: #selector(copyLast), keyEquivalent: "")
        copyLastItem.target = self
        copyLastItem.isEnabled = false
        menu.addItem(copyLastItem)

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

    // MARK: Engine lifecycle

    /// Loads whichever engine the current language selection needs. Cheap to
    /// call repeatedly — it returns immediately unless the answer changed, so
    /// toggling a language can just call it. Whisper's 1.6 GB model is only
    /// fetched when a language outside Parakeet's set is actually selected.
    private func ensureEngine() {
        guard !isLoadingEngine else { return }
        let wanted = EngineRouting.engineName(preference: config.engine,
                                              languages: config.languages,
                                              fastLanguages: ParakeetEngine.supported)
        guard engine?.name != wanted else { return }
        engine = nil
        isLoadingEngine = true
        if wanted == EngineRouting.fast { loadParakeet() } else { loadWhisper() }
    }

    private func loadParakeet() {
        setInfo("Loading speech models…")
        // FluidAudio calls this from whatever thread it likes, so it captures
        // nothing and looks the delegate up on the main thread instead — an
        // AppDelegate reference is not safe to carry into a @Sendable closure.
        let report: @Sendable (Int) -> Void = { percent in
            DispatchQueue.main.async {
                (NSApp.delegate as? AppDelegate)?
                    .setInfo("Downloading speech models… \(percent)%")
            }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let engine = try await ParakeetEngine.load(progress: report)
                await MainActor.run { [weak self] in self?.engineLoaded(engine) }
            } catch {
                wordlyLog("Wordly: parakeet failed to load: \(error)")
                await MainActor.run { [weak self] in
                    self?.engineFailed("Speech models failed — see Console")
                }
            }
        }
    }

    private func loadWhisper() {
        let url = config.modelURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            setInfo("Downloading model… 0%")
            let downloader = ModelDownloader(model: config.whisperModel, destination: url)
            downloader.onProgress = { [weak self] pct in
                self?.setInfo("Downloading model… \(pct)%")
            }
            downloader.onDone = { [weak self] result in
                switch result {
                case .success: self?.loadWhisper()
                case .failure(let error):
                    self?.engineFailed("Model download failed — quit & relaunch to retry")
                    wordlyLog("Wordly: model download failed: \(error)")
                }
            }
            self.downloader = downloader
            downloader.startIfNeeded()
            return
        }
        setInfo("Loading model…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let engine = WhisperEngine.load(modelPath: url.path)  // compiles Metal kernels
            DispatchQueue.main.async { [weak self] in
                guard let engine else {
                    self?.engineFailed("Model failed to load")
                    return
                }
                self?.engineLoaded(engine)
            }
        }
    }

    private func engineLoaded(_ engine: SpeechEngine) {
        self.engine = engine
        isLoadingEngine = false
        wordlyLog("Wordly: engine ready — \(engine.name)")
        refreshInfo()
        // The selection may have changed while this was loading; ensureEngine
        // returns immediately if it didn't, and can't recurse further than the
        // one other engine.
        ensureEngine()
    }

    private func engineFailed(_ message: String) {
        isLoadingEngine = false
        setInfo(message)
    }

    private func refreshInfo() {
        if engine == nil { return }  // loading status text owns the line until ready
        if monitor == nil {
            setInfo("Grant Accessibility, then wait…")
        } else {
            setInfo(lastRun.isEmpty ? "Ready — hold ^ to dictate" : "Ready — last: \(lastRun)")
            setIcon("mic", tint: nil)
        }
    }

    // MARK: Dictation pipeline

    private func startCapture() {
        guard !isProcessing, engine != nil else { return }
        recorder.start()
        if recorder.isRecording {
            setIcon("mic.fill", tint: .systemRed)
            indicator.showListening()
        }
    }

    private func discardCapture() {
        recorder.stop(discard: true)
        // Phantom gestures during transcription must not clobber the hourglass.
        if !isProcessing {
            setIcon("mic", tint: nil)
            indicator.hide()
        }
    }

    private func stopAndProcess() {
        let samples = recorder.stop()
        guard !samples.isEmpty, let engine, !isProcessing else {
            if !isProcessing { setIcon("mic", tint: nil); indicator.hide() }
            return
        }
        isProcessing = true
        setIcon("hourglass", tint: nil)
        indicator.showProcessing()
        let languages = config.languages
        let prompt = dictionary.initialPrompt()
        let terms = dictionary.terms()
        let cleanup = config.cleanupEnabled
        let model = config.ollamaModel

        // Timed from here, not from inside the model: this is the wait the user
        // actually feels — trim, transcribe, optional cleanup, hop back.
        let started = DispatchTime.now().uptimeNanoseconds

        Task.detached(priority: .userInitiated) { [weak self] in
            let trimmed = AudioTrim.trim(samples)
            let result = await engine.transcribe(trimmed, languages: languages,
                                                 initialPrompt: prompt)
            var text = result.text
            if cleanup {
                text = await Cleaner.clean(text, terms: terms,
                                           language: result.language, model: model)
            }
            let finalText = text
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            wordlyLog(String(format: "Wordly: dictation %.0fms end-to-end (%.1fs audio, %d chars)",
                         elapsed * 1000, Double(samples.count) / 16000, finalText.count))
            // Re-capture weakly here rather than reaching for the outer task's
            // captured `self` — that reference is what Swift 6 rejects.
            await MainActor.run { [weak self] in
                self?.finishDictation(finalText, language: result.language, elapsed: elapsed)
            }
        }
    }

    /// Paste the transcript if the focused element takes text; otherwise keep
    /// it in the rescue popup so it's never lost. Always retained for the
    /// Copy Last Transcript menu item.
    private func finishDictation(_ text: String, language: String, elapsed: TimeInterval) {
        isProcessing = false
        setIcon("mic", tint: nil)
        // The menu line doubles as the "what just happened" readout: which
        // language it settled on, and how long the user waited for it.
        lastRun = String(format: "%@ · %.1f s", language.isEmpty ? "?" : language, elapsed)
        refreshInfo()
        guard !text.isEmpty else { indicator.hide(); return }
        lastTranscript = text
        copyLastItem.isEnabled = true
        if PasteTarget.focusedAcceptsText() {
            Injector.paste(text)
            indicator.hide()
        } else {
            indicator.showRescue(text)
        }
    }

    // MARK: Menu actions

    @objc private func toggleCleanup() {
        config.cleanupEnabled.toggle()
        cleanupItem.state = config.cleanupEnabled ? .on : .off
        config.save()
    }

    @objc private func toggleIndicator() {
        config.showIndicator.toggle()
        indicator.enabled = config.showIndicator
        indicatorItem.state = config.showIndicator ? .on : .off
        // Keep an unread rescue popup up even when turning the pill off.
        if !config.showIndicator, !indicator.isShowingRescue { indicator.hide() }
        config.save()
    }

    // MARK: Languages

    /// The languages Whisper handles well go up top; the rest stay reachable
    /// but out of the way. Both lists come from the model's own table, so they
    /// cannot drift from what it actually supports.
    private func buildLanguageMenu() -> NSMenu {
        let menu = NSMenu()
        autoLanguageItem = NSMenuItem(title: "Auto — all languages",
                                      action: #selector(pickAllLanguages), keyEquivalent: "")
        autoLanguageItem.target = self
        menu.addItem(autoLanguageItem)
        menu.addItem(.separator())

        let common = Languages.all.filter { Languages.common.contains($0.code) }
        for language in common.sorted(by: { $0.title < $1.title }) {
            menu.addItem(languageItem(language))
        }
        menu.addItem(.separator())

        let rest = NSMenu()
        for language in Languages.all.filter({ !Languages.common.contains($0.code) })
            .sorted(by: { $0.title < $1.title }) {
            rest.addItem(languageItem(language))
        }
        let restRoot = NSMenuItem(title: "All languages…", action: nil, keyEquivalent: "")
        menu.setSubmenu(rest, for: restRoot)
        menu.addItem(restRoot)
        return menu
    }

    private func languageItem(_ language: Languages.Language) -> NSMenuItem {
        let item = NSMenuItem(title: language.title,
                              action: #selector(toggleLanguage(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = language.code
        languageItems[language.code] = item
        return item
    }

    @objc private func toggleLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        if let index = config.languages.firstIndex(of: code) {
            config.languages.remove(at: index)
        } else {
            config.languages.append(code)  // order matters: the first is the fallback
        }
        refreshLanguageMenu()
        config.save()
        ensureEngine()  // the selection may have moved the work to the other engine
    }

    @objc private func pickAllLanguages() {
        config.languages = []
        refreshLanguageMenu()
        config.save()
        ensureEngine()
    }

    @objc private func pickEngine(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        config.engine = value
        for (name, item) in engineItems { item.state = name == value ? .on : .off }
        config.save()
        ensureEngine()
    }

    private func refreshLanguageMenu() {
        for (code, item) in languageItems {
            item.state = config.languages.contains(code) ? .on : .off
        }
        autoLanguageItem.state = config.languages.isEmpty ? .on : .off
        let summary = config.languages.isEmpty
            ? "Auto" : config.languages.map { $0.uppercased() }.joined(separator: ", ")
        languageRoot.title = "Language (\(summary))"
    }

    // MARK: Microphone selection

    private func rebuildMicMenu() {
        micMenu.removeAllItems()
        let defaultItem = NSMenuItem(title: "System Default",
                                     action: #selector(pickMicrophone(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = ""  // empty == system default
        defaultItem.state = config.inputDeviceUID == nil ? .on : .off
        micMenu.addItem(defaultItem)
        micMenu.addItem(.separator())
        for device in AudioDevices.inputs() {
            let item = NSMenuItem(title: device.name,
                                  action: #selector(pickMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = config.inputDeviceUID == device.uid ? .on : .off
            micMenu.addItem(item)
        }
    }

    @objc private func pickMicrophone(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String ?? ""
        config.inputDeviceUID = uid.isEmpty ? nil : uid
        recorder.inputDeviceUID = config.inputDeviceUID
        config.save()
        rebuildMicMenu()
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === micMenu { rebuildMicMenu() }
    }

    @objc private func editDictionary() {
        _ = dictionary.terms()  // ensures file + template exist
        NSWorkspace.shared.open(dictionary.url)
    }

    @objc private func copyLast() {
        guard !lastTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }
}
