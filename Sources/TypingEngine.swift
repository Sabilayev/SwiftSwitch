import Cocoa
import Carbon
import ApplicationServices

struct TypedKey {
    let keyCode: UInt16
    let shifted: Bool
    let char: Character
}

struct PendingKeyEvent {
    let keyCode: UInt16
    let flags: CGEventFlags
}

struct AutoSwitchUndo {
    let original: String
    let replaced: String
    let originalLang: SwitchLang
    let triggerKeyCode: UInt16?
    let timestamp: Date
}

final class TypingEngine {
    static let shared = TypingEngine()
    static let syntheticTag: Int64 = 0x53575357 // "SWSW"

    var isAutoSwitchEnabled: Bool = true
    var isOnTheFlyEnabled: Bool = true
    var isDoubleRightShiftEnabled: Bool = true
    var isOptionSpaceEnabled: Bool = true
    var isSoundEnabled: Bool = false
    var excludedBundleIDs: Set<String> = []

    var onLayoutChanged: ((SwitchLang) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isInjecting: Bool = false
    private var injectingTargetLang: SwitchLang?
    private var pendingKeys: [PendingKeyEvent] = []
    private let pendingLock = NSLock()
    private let injectQueue = DispatchQueue(label: "com.swiftswitch.inject", qos: .userInteractive)

    // Current word buffer
    private var buffer: [TypedKey] = []
    private var bufferLang: SwitchLang?

    // Last completed word (for manual hotkey right after Space)
    private var lastCompletedBuffer: [TypedKey] = []
    private var lastCompletedLang: SwitchLang?
    private var lastCompletedHadTrailingSpace: Bool = false

    // Undo state for Escape right after auto-switch
    private var lastUndo: AutoSwitchUndo?

    // Double Right Shift detection
    private var rightShiftDownAlone: Bool = false
    private var lastRightShiftTapTime: TimeInterval = 0

    // KeyCodes
    private let kcSpace: UInt16 = 49
    private let kcReturn: UInt16 = 36
    private let kcEnter: UInt16 = 76
    private let kcTab: UInt16 = 48
    private let kcBackspace: UInt16 = 51
    private let kcEscape: UInt16 = 53
    private let kcRightShift: UInt16 = 60

    // Characters that are never letters in either EN or RU layout and act as clean word separators
    private let neutralSeparators: Set<Character> = [
        "(", ")", "!", "?", "=", "+", "*", "/", "\\", "|", "«", "»", "—", "-", "@", "#", "$", "%", "^", "&", "_"
    ]

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appSwitched),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func appSwitched() {
        resetBuffers()
        if let lang = LayoutManager.shared.currentLanguage() {
            onLayoutChanged?(lang)
        }
    }

    func resetBuffers() {
        buffer.removeAll()
        bufferLang = nil
        lastCompletedBuffer.removeAll()
        lastCompletedLang = nil
        lastUndo = nil
    }

    var isRunning: Bool {
        eventTap != nil
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<TypingEngine>.fromOpaque(refcon).takeUnretainedValue()
            return engine.handleEvent(proxy: proxy, type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let src = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func isCurrentAppExcluded() -> Bool {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return excludedBundleIDs.contains(bid)
    }

    private func detectLangFromChar(_ ch: Character) -> SwitchLang? {
        guard let scalar = ch.unicodeScalars.first else { return nil }
        if (0x0400...0x04FF).contains(scalar.value) { return .ru }
        if (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value) { return .en }
        return nil
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Ignore our own synthetic events
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag {
            return Unmanaged.passUnretained(event)
        }

        // While we are injecting a replacement (~18ms), queue fast user keystrokes so nothing gets lost or scrambled!
        if isInjecting {
            if type == .keyDown {
                let flags = event.flags
                if !flags.contains(.maskCommand) && !flags.contains(.maskControl) && !flags.contains(.maskAlternate) {
                    let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                    pendingLock.lock()
                    pendingKeys.append(PendingKeyEvent(keyCode: kc, flags: flags))
                    pendingLock.unlock()
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Never inspect password / secure fields
        if IsSecureEventInputEnabled() {
            resetBuffers()
            return Unmanaged.passUnretained(event)
        }

        // Reset word buffer on mouse clicks
        if type == .leftMouseDown || type == .rightMouseDown {
            buffer.removeAll()
            bufferLang = nil
            lastUndo = nil
            return Unmanaged.passUnretained(event)
        }

        // Handle Double-Tap Right Shift via flagsChanged
        if type == .flagsChanged {
            let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if isDoubleRightShiftEnabled && kc == kcRightShift {
                let flags = event.flags
                let shiftPressed = flags.contains(.maskShift)
                let otherMods = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
                if shiftPressed && !otherMods {
                    rightShiftDownAlone = true
                } else if !shiftPressed && rightShiftDownAlone {
                    rightShiftDownAlone = false
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastRightShiftTapTime < 0.35 {
                        lastRightShiftTapTime = 0
                        DispatchQueue.main.async { [weak self] in
                            self?.triggerManualSwitch()
                        }
                    } else {
                        lastRightShiftTapTime = now
                    }
                } else {
                    rightShiftDownAlone = false
                }
            } else {
                rightShiftDownAlone = false
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        // Any normal key cancels "right shift alone"
        rightShiftDownAlone = false

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Hotkey: Option + Space (convert selection or last word)
        if isOptionSpaceEnabled && keyCode == kcSpace &&
           flags.contains(.maskAlternate) &&
           !flags.contains(.maskCommand) &&
           !flags.contains(.maskControl) &&
           !flags.contains(.maskShift) {
            DispatchQueue.main.async { [weak self] in
                self?.triggerManualSwitch()
            }
            return nil
        }

        // Ignore Command / Control / Option shortcuts and reset buffer
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            buffer.removeAll()
            bufferLang = nil
            lastUndo = nil
            return Unmanaged.passUnretained(event)
        }

        // Escape: Undo last auto-switch if within 6 seconds
        if keyCode == kcEscape {
            if let undo = lastUndo, Date().timeIntervalSince(undo.timestamp) < 6.0 {
                lastUndo = nil
                LanguageDetector.shared.addSessionIgnored(undo.original)
                performUndo(undo)
                return nil
            }
            buffer.removeAll()
            bufferLang = nil
            return Unmanaged.passUnretained(event)
        }

        // Backspace updates buffer
        if keyCode == kcBackspace {
            if !buffer.isEmpty {
                buffer.removeLast()
                if buffer.isEmpty { bufferLang = nil }
            } else {
                lastCompletedBuffer.removeAll()
            }
            lastUndo = nil
            return Unmanaged.passUnretained(event)
        }

        // Word boundary keys: Space / Return / Enter / Tab
        if keyCode == kcSpace || keyCode == kcReturn || keyCode == kcEnter || keyCode == kcTab {
            if !buffer.isEmpty {
                let wordKeys = buffer
                let lang = bufferLang ?? LayoutManager.shared.currentLanguage() ?? .en
                buffer.removeAll()
                bufferLang = nil

                lastCompletedBuffer = wordKeys
                lastCompletedLang = lang
                lastCompletedHadTrailingSpace = (keyCode == kcSpace)

                if isAutoSwitchEnabled && !isCurrentAppExcluded() && keyCode != kcTab {
                    let rawWord = String(wordKeys.map { $0.char })
                    let convertedWord = convertBuffer(wordKeys, to: lang.opposite)

                    if let decision = LanguageDetector.shared.shouldAutoSwitch(
                        rawWord: rawWord,
                        convertedWord: convertedWord,
                        currentLang: lang
                    ) {
                        lastUndo = AutoSwitchUndo(
                            original: rawWord,
                            replaced: decision.replacement,
                            originalLang: lang,
                            triggerKeyCode: keyCode,
                            timestamp: Date()
                        )
                        lastCompletedBuffer.removeAll()
                        performAutoReplace(
                            deleteCount: rawWord.count,
                            replacement: decision.replacement,
                            targetLang: decision.targetLang,
                            triggerKeyCode: keyCode
                        )
                        return nil // consume Space/Return; re-sent after replacement
                    }
                }
            } else {
                lastCompletedBuffer.removeAll()
            }
            lastUndo = nil
            return Unmanaged.passUnretained(event)
        }

        // Navigation keys clear buffer
        if (123...126).contains(keyCode) || keyCode == 115 || keyCode == 119 || keyCode == 116 || keyCode == 121 || keyCode == 117 {
            buffer.removeAll()
            bufferLang = nil
            lastUndo = nil
            return Unmanaged.passUnretained(event)
        }

        // Regular character key
        lastUndo = nil
        guard let typedChar = extractString(from: event)?.first else {
            return Unmanaged.passUnretained(event)
        }

        // Control chars or neutral separators reset buffer cleanly (so "(ctqxfc" starts clean buffer "ctqxfc")
        if typedChar.isNewline || typedChar == "\t" || neutralSeparators.contains(typedChar) {
            buffer.removeAll()
            bufferLang = nil
            return Unmanaged.passUnretained(event)
        }

        // Detect active layout directly from typed character's Unicode script (100% immune to stale TIS cache!)
        let detectedLang = detectLangFromChar(typedChar)
        let curLang = detectedLang ?? bufferLang ?? LayoutManager.shared.currentLanguage() ?? .en

        if bufferLang == nil {
            bufferLang = curLang
        } else if let dl = detectedLang, bufferLang != dl {
            // User manually switched layout mid-word -> start fresh buffer
            buffer.removeAll()
            bufferLang = dl
        }

        let shifted = flags.contains(.maskShift) || flags.contains(.maskAlphaShift)
        buffer.append(TypedKey(keyCode: keyCode, shifted: shifted, char: typedChar))

        if buffer.count > 64 {
            buffer.removeFirst()
        }

        // Real-Time On-The-Fly Detection ("На лету", like Punto Switcher)
        if isAutoSwitchEnabled && isOnTheFlyEnabled && buffer.count >= 3 && !isCurrentAppExcluded() {
            let rawPrefix = String(buffer.map { $0.char })
            let convertedPrefix = convertBuffer(buffer, to: curLang.opposite)

            if let decision = LanguageDetector.shared.shouldAutoSwitchOnTheFly(
                rawPrefix: rawPrefix,
                convertedPrefix: convertedPrefix,
                currentLang: curLang
            ) {
                let deleteCount = buffer.count - 1 // Current key hasn't been emitted yet!
                let targetLang = decision.targetLang

                lastUndo = AutoSwitchUndo(
                    original: rawPrefix,
                    replaced: decision.replacement,
                    originalLang: curLang,
                    triggerKeyCode: nil,
                    timestamp: Date()
                )

                // Update buffer to reflect the converted prefix in targetLang so typing continues seamlessly
                let convChars = Array(decision.replacement)
                var newBuf: [TypedKey] = []
                for (i, k) in buffer.enumerated() where i < convChars.count {
                    newBuf.append(TypedKey(keyCode: k.keyCode, shifted: k.shifted, char: convChars[i]))
                }
                buffer = newBuf
                bufferLang = targetLang
                lastCompletedBuffer.removeAll()

                performAutoReplace(
                    deleteCount: deleteCount,
                    replacement: decision.replacement,
                    targetLang: targetLang,
                    triggerKeyCode: nil
                )
                return nil // consume triggering keystroke; emitted as part of convertedPrefix!
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func convertBuffer(_ keys: [TypedKey], to targetLang: SwitchLang) -> String {
        var out = ""
        out.reserveCapacity(keys.count)
        for k in keys {
            if let mapped = LayoutManager.shared.charForKey(keyCode: k.keyCode, shifted: k.shifted, lang: targetLang) {
                out.append(mapped)
            } else {
                out.append(LayoutManager.shared.convertText(String(k.char), from: targetLang.opposite, to: targetLang))
            }
        }
        return out
    }

    private func extractString(from event: CGEvent) -> String? {
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else { return nil }
        var chars = [UniChar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: length)
    }

    // MARK: - Replacement & Manual Switch

    func triggerManualSwitch() {
        guard !isInjecting else { return }

        if let selected = getSelectedTextViaAX(), !selected.isEmpty {
            let (converted, targetLang) = LayoutManager.shared.convertSelectedTextAuto(selected)
            replaceSelectionViaClipboard(with: converted, targetLang: targetLang)
            buffer.removeAll()
            lastCompletedBuffer.removeAll()
            return
        }

        if !buffer.isEmpty {
            let wordKeys = buffer
            let lang = bufferLang ?? LayoutManager.shared.currentLanguage() ?? .en
            let targetLang = lang.opposite
            let replacement = convertBuffer(wordKeys, to: targetLang)
            buffer.removeAll()
            bufferLang = nil
            performAutoReplace(deleteCount: wordKeys.count, replacement: replacement, targetLang: targetLang, triggerKeyCode: nil)
            return
        }

        trySelectionViaCopyOrFallbackToLastWord()
    }

    private func getSelectedTextViaAX() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedObj: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedObj) == .success,
              let focused = focusedObj else { return nil }
        let elem = focused as! AXUIElement
        var selectedObj: AnyObject?
        guard AXUIElementCopyAttributeValue(elem, kAXSelectedTextAttribute as CFString, &selectedObj) == .success,
              let text = selectedObj as? String, !text.isEmpty else { return nil }
        return text
    }

    private func trySelectionViaCopyOrFallbackToLastWord() {
        let pb = NSPasteboard.general
        let savedItems = savePasteboard(pb)
        let beforeCount = pb.changeCount

        isInjecting = true
        injectQueue.async { [weak self] in
            guard let self = self else { return }
            self.postKey(keyCode: 8, flags: .maskCommand) // Cmd+C
            usleep(60_000)

            DispatchQueue.main.async {
                let afterCount = pb.changeCount
                if afterCount != beforeCount, let copied = pb.string(forType: .string), !copied.isEmpty {
                    let (converted, targetLang) = LayoutManager.shared.convertSelectedTextAuto(copied)
                    pb.clearContents()
                    pb.setString(converted, forType: .string)

                    self.injectQueue.async {
                        self.selectLayoutOnMain(targetLang)
                        self.postKey(keyCode: 9, flags: .maskCommand) // Cmd+V
                        usleep(120_000)
                        DispatchQueue.main.async {
                            self.restorePasteboard(pb, items: savedItems)
                            self.isInjecting = false
                            self.playFeedbackSound()
                        }
                    }
                } else {
                    self.isInjecting = false
                    if !self.lastCompletedBuffer.isEmpty {
                        let wordKeys = self.lastCompletedBuffer
                        let lang = self.lastCompletedLang ?? LayoutManager.shared.currentLanguage() ?? .en
                        let hadSpace = self.lastCompletedHadTrailingSpace
                        let targetLang = lang.opposite
                        let replacement = self.convertBuffer(wordKeys, to: targetLang)
                        self.lastCompletedBuffer.removeAll()

                        self.performAutoReplace(
                            deleteCount: wordKeys.count + (hadSpace ? 1 : 0),
                            replacement: replacement,
                            targetLang: targetLang,
                            triggerKeyCode: hadSpace ? self.kcSpace : nil
                        )
                    } else {
                        let next = (LayoutManager.shared.currentLanguage() ?? .en).opposite
                        LayoutManager.shared.selectLanguage(next)
                        self.onLayoutChanged?(next)
                        self.playFeedbackSound()
                    }
                }
            }
        }
    }

    private func replaceSelectionViaClipboard(with text: String, targetLang: SwitchLang) {
        let pb = NSPasteboard.general
        let savedItems = savePasteboard(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)

        isInjecting = true
        injectQueue.async { [weak self] in
            guard let self = self else { return }
            self.selectLayoutOnMain(targetLang)
            self.postKey(keyCode: 9, flags: .maskCommand) // Cmd+V
            usleep(120_000)
            DispatchQueue.main.async {
                self.restorePasteboard(pb, items: savedItems)
                self.isInjecting = false
                self.playFeedbackSound()
            }
        }
    }

    private func performAutoReplace(deleteCount: Int, replacement: String, targetLang: SwitchLang, triggerKeyCode: UInt16?) {
        isInjecting = true
        injectingTargetLang = targetLang
        injectQueue.async { [weak self] in
            guard let self = self else { return }
            for _ in 0..<deleteCount {
                self.postKey(keyCode: self.kcBackspace, flags: [])
                usleep(1800)
            }

            self.selectLayoutOnMain(targetLang)
            usleep(12_000)

            self.postUnicodeString(replacement)

            if let trigger = triggerKeyCode {
                usleep(2000)
                self.postKey(keyCode: trigger, flags: [])
            }

            // Drain any fast keystrokes queued during the ~18ms injection, mapped to targetLang!
            self.drainPendingKeys(in: targetLang)

            usleep(4000)
            DispatchQueue.main.async {
                self.isInjecting = false
                self.injectingTargetLang = nil
                self.playFeedbackSound()
            }
        }
    }

    private func drainPendingKeys(in targetLang: SwitchLang) {
        while true {
            pendingLock.lock()
            if pendingKeys.isEmpty {
                pendingLock.unlock()
                break
            }
            let queued = pendingKeys
            pendingKeys.removeAll()
            pendingLock.unlock()

            for ev in queued {
                if ev.keyCode == kcSpace || ev.keyCode == kcReturn || ev.keyCode == kcEnter || ev.keyCode == kcTab || ev.keyCode == kcBackspace {
                    postKey(keyCode: ev.keyCode, flags: ev.flags)
                    if ev.keyCode == kcSpace || ev.keyCode == kcReturn || ev.keyCode == kcEnter || ev.keyCode == kcTab {
                        DispatchQueue.main.async {
                            self.buffer.removeAll()
                            self.bufferLang = nil
                        }
                    } else if ev.keyCode == kcBackspace {
                        DispatchQueue.main.async {
                            if !self.buffer.isEmpty { self.buffer.removeLast() }
                        }
                    }
                } else {
                    let shifted = ev.flags.contains(.maskShift) || ev.flags.contains(.maskAlphaShift)
                    if let ch = LayoutManager.shared.charForKey(keyCode: ev.keyCode, shifted: shifted, lang: targetLang) {
                        postUnicodeString(String(ch))
                        DispatchQueue.main.async {
                            self.buffer.append(TypedKey(keyCode: ev.keyCode, shifted: shifted, char: ch))
                            self.bufferLang = targetLang
                        }
                    } else {
                        postKey(keyCode: ev.keyCode, flags: ev.flags)
                    }
                }
                usleep(1500)
            }
        }
    }

    private func performUndo(_ undo: AutoSwitchUndo) {
        let extra = (undo.triggerKeyCode != nil) ? 1 : 0
        let delCount = undo.replaced.count + extra
        buffer.removeAll()
        bufferLang = undo.originalLang
        performAutoReplace(
            deleteCount: delCount,
            replacement: undo.original,
            targetLang: undo.originalLang,
            triggerKeyCode: undo.triggerKeyCode
        )
    }

    private func selectLayoutOnMain(_ lang: SwitchLang) {
        DispatchQueue.main.sync {
            LayoutManager.shared.selectLanguage(lang)
            self.onLayoutChanged?(lang)
        }
    }

    private func postKey(keyCode: UInt16, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            down.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func postUnicodeString(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for scalar in text.unicodeScalars {
            var utf16 = Array(String(scalar).utf16)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                down.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.post(tap: .cgAnnotatedSessionEventTap)
            }
            usleep(1500)
        }
    }

    private func savePasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            if !dict.isEmpty { saved.append(dict) }
        }
        return saved
    }

    private func restorePasteboard(_ pb: NSPasteboard, items: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        var pbItems: [NSPasteboardItem] = []
        for dict in items {
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            pbItems.append(item)
        }
        if !pbItems.isEmpty {
            pb.writeObjects(pbItems)
        }
    }

    private func playFeedbackSound() {
        guard isSoundEnabled else { return }
        NSSound(named: "Tink")?.play()
    }
}
