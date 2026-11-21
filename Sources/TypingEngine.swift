import Cocoa
import Carbon
import ApplicationServices

struct TypedKey {
    let keyCode: UInt16
    let shifted: Bool
    let char: Character
}

struct AutoSwitchUndo {
    let original: String
    let replaced: String
    let originalLang: SwitchLang
    let triggerKeyCode: UInt16
    let timestamp: Date
}

final class TypingEngine {
    static let shared = TypingEngine()
    static let syntheticTag: Int64 = 0x53575357 // "SWSW"

    var isAutoSwitchEnabled: Bool = true
    var isDoubleRightShiftEnabled: Bool = true
    var isOptionSpaceEnabled: Bool = true
    var isSoundEnabled: Bool = false
    var excludedBundleIDs: Set<String> = []

    var onLayoutChanged: ((SwitchLang) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isInjecting: Bool = false
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

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Ignore our own synthetic events
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag || isInjecting {
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
            return nil // consume Option+Space (prevents inserting NBSP)
        }

        // Ignore Command / Control / Option shortcuts and reset buffer
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            buffer.removeAll()
            bufferLang = nil
            lastUndo = nil
            return Unmanaged.passUnretained(event)
        }

        // Escape: Undo last auto-switch if within 5 seconds
        if keyCode == kcEscape {
            if let undo = lastUndo, Date().timeIntervalSince(undo.timestamp) < 5.0 {
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

        // Ignore control chars
        if typedChar.isNewline || typedChar == "\t" {
            buffer.removeAll()
            bufferLang = nil
            return Unmanaged.passUnretained(event)
        }

        let curLang = LayoutManager.shared.currentLanguage() ?? .en
        if bufferLang == nil {
            bufferLang = curLang
        } else if bufferLang != curLang {
            // User manually switched layout mid-word -> start fresh buffer
            buffer.removeAll()
            bufferLang = curLang
        }

        let shifted = flags.contains(.maskShift) || flags.contains(.maskAlphaShift)
        buffer.append(TypedKey(keyCode: keyCode, shifted: shifted, char: typedChar))

        // Cap buffer length to avoid huge replacements
        if buffer.count > 64 {
            buffer.removeFirst()
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

        // 1. Check if user has selected text via Accessibility API (fast, no clipboard touch)
        if let selected = getSelectedTextViaAX(), !selected.isEmpty {
            let (converted, targetLang) = LayoutManager.shared.convertSelectedTextAuto(selected)
            replaceSelectionViaClipboard(with: converted, targetLang: targetLang)
            buffer.removeAll()
            lastCompletedBuffer.removeAll()
            return
        }

        // 2. If user is currently typing a word, convert current buffer directly
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

        // 3. Try clipboard copy fallback for apps (e.g. Chrome/Electron) that hide AXSelectedText
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
                    // Nothing selected -> restore clipboard and convert last completed word if available
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
                        // Just toggle keyboard layout
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
        injectQueue.async { [weak self] in
            guard let self = self else { return }
            for _ in 0..<deleteCount {
                self.postKey(keyCode: self.kcBackspace, flags: [])
                usleep(2500)
            }

            self.selectLayoutOnMain(targetLang)
            usleep(8000)

            self.postUnicodeString(replacement)
            usleep(3000)

            if let trigger = triggerKeyCode {
                self.postKey(keyCode: trigger, flags: [])
            }

            usleep(8000)
            DispatchQueue.main.async {
                self.isInjecting = false
                self.playFeedbackSound()
            }
        }
    }

    private func performUndo(_ undo: AutoSwitchUndo) {
        // Delete replaced word + trailing trigger character (Space/Return)
        let delCount = undo.replaced.count + 1
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
            usleep(1800)
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
