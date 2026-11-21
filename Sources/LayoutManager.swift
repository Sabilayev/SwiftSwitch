import Cocoa
import Carbon

enum SwitchLang: String {
    case en = "en"
    case ru = "ru"

    var opposite: SwitchLang {
        self == .en ? .ru : .en
    }

    var badge: String {
        self == .en ? "EN" : "RU"
    }
}

final class LayoutManager {
    static let shared = LayoutManager()

    private(set) var enSource: TISInputSource?
    private(set) var ruSource: TISInputSource?
    private(set) var enSourceID: String = ""
    private(set) var ruSourceID: String = ""

    // Maps from physical keyCode + shifted -> character in each layout
    private var enKeyMap: [Int: Character] = [:] // key = keyCode * 2 + (shifted ? 1 : 0)
    private var ruKeyMap: [Int: Character] = [:]

    // Character-to-character fallback maps for converting arbitrary selected text
    private var enToRuChar: [Character: Character] = [:]
    private var ruToEnChar: [Character: Character] = [:]

    // KeyCodes that produce letters in either EN or RU layout
    private let relevantKeyCodes: [UInt16] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
        30, 31, 32, 33, 34, 35, 37, 38, 39, 40, 41, 42, 43, 45, 46, 47, 50
    ]

    private init() {
        refreshSources()
    }

    func refreshSources() {
        enSource = nil
        ruSource = nil

        let filter: CFDictionary = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ] as CFDictionary

        guard let cfList = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else { return }
        let sources = cfList as NSArray

        for item in sources {
            let src = item as! TISInputSource
            let id = sourceID(of: src)
            let langs = sourceLanguages(of: src)

            if ruSource == nil && (id.lowercased().contains("russian") || langs.contains("ru")) {
                ruSource = src
                ruSourceID = id
            }
            if enSource == nil && (id == "com.apple.keylayout.ABC" || id == "com.apple.keylayout.US" || langs.contains("en")) {
                enSource = src
                enSourceID = id
            }
        }

        buildKeyMaps()
    }

    func currentLanguage() -> SwitchLang? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        let id = sourceID(of: current)
        if !ruSourceID.isEmpty && id == ruSourceID { return .ru }
        if !enSourceID.isEmpty && id == enSourceID { return .en }

        let langs = sourceLanguages(of: current)
        if langs.contains("ru") || id.lowercased().contains("russian") { return .ru }
        if langs.contains("en") || id.lowercased().contains("abc") || id.lowercased().contains("us") { return .en }
        return nil
    }

    @discardableResult
    func selectLanguage(_ lang: SwitchLang) -> Bool {
        let target = (lang == .ru) ? ruSource : enSource
        guard let src = target else {
            refreshSources()
            guard let retry = (lang == .ru ? ruSource : enSource) else { return false }
            return TISSelectInputSource(retry) == noErr
        }
        return TISSelectInputSource(src) == noErr
    }

    func charForKey(keyCode: UInt16, shifted: Bool, lang: SwitchLang) -> Character? {
        let key = Int(keyCode) * 2 + (shifted ? 1 : 0)
        return (lang == .en) ? enKeyMap[key] : ruKeyMap[key]
    }

    func convertText(_ text: String, from: SwitchLang, to: SwitchLang) -> String {
        guard from != to else { return text }
        let map = (from == .en) ? enToRuChar : ruToEnChar
        var result = ""
        result.reserveCapacity(text.count)
        for ch in text {
            if let mapped = map[ch] {
                result.append(mapped)
            } else {
                result.append(ch)
            }
        }
        return result
    }

    /// Auto-detect dominant script of arbitrary selected text and convert to opposite layout
    func convertSelectedTextAuto(_ text: String) -> (converted: String, targetLang: SwitchLang) {
        var cyrillicCount = 0
        var latinCount = 0
        for scalar in text.unicodeScalars {
            if (0x0400...0x04FF).contains(scalar.value) {
                cyrillicCount += 1
            } else if (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value) {
                latinCount += 1
            }
        }
        if cyrillicCount >= latinCount && cyrillicCount > 0 {
            return (convertText(text, from: .ru, to: .en), .en)
        } else {
            return (convertText(text, from: .en, to: .ru), .ru)
        }
    }

    private func buildKeyMaps() {
        enKeyMap.removeAll()
        ruKeyMap.removeAll()
        enToRuChar.removeAll()
        ruToEnChar.removeAll()

        let enData = enSource.flatMap { layoutData(of: $0) }
        let ruData = ruSource.flatMap { layoutData(of: $0) }

        for kc in relevantKeyCodes {
            for shifted in [false, true] {
                let key = Int(kc) * 2 + (shifted ? 1 : 0)
                let enCh = enData.flatMap { translate(keyCode: kc, shifted: shifted, layoutData: $0) }
                let ruCh = ruData.flatMap { translate(keyCode: kc, shifted: shifted, layoutData: $0) }

                if let c = enCh { enKeyMap[key] = c }
                if let c = ruCh { ruKeyMap[key] = c }

                if let ec = enCh, let rc = ruCh {
                    // Only map characters where at least one side is a letter
                    if ec.isLetter || rc.isLetter {
                        if enToRuChar[ec] == nil { enToRuChar[ec] = rc }
                        if ruToEnChar[rc] == nil { ruToEnChar[rc] = ec }
                    }
                }
            }
        }

        // Ensure fallback standard RU/EN mappings if UCKeyTranslate misses anything
        let fallbackPairs: [(Character, Character)] = [
            ("q","й"), ("w","ц"), ("e","у"), ("r","к"), ("t","е"), ("y","н"), ("u","г"), ("i","ш"), ("o","щ"), ("p","з"),
            ("[","х"), ("]","ъ"), ("a","ф"), ("s","ы"), ("d","в"), ("f","а"), ("g","п"), ("h","р"), ("j","о"), ("k","л"),
            ("l","д"), (";","ж"), ("'","э"), ("z","я"), ("x","ч"), ("c","с"), ("v","м"), ("b","и"), ("n","т"), ("m","ь"),
            (",","б"), (".","ю"), ("`","ё"),
            ("Q","Й"), ("W","Ц"), ("E","У"), ("R","К"), ("T","Е"), ("Y","Н"), ("U","Г"), ("I","Ш"), ("O","Щ"), ("P","З"),
            ("{","Х"), ("}","Ъ"), ("A","Ф"), ("S","Ы"), ("D","В"), ("F","А"), ("G","П"), ("H","Р"), ("J","О"), ("K","Л"),
            ("L","Д"), (":","Ж"), ("\"","Э"), ("Z","Я"), ("X","Ч"), ("C","С"), ("V","М"), ("B","И"), ("N","Т"), ("M","Ь"),
            ("<","Б"), (">","Ю"), ("~","Ё")
        ]
        for (ec, rc) in fallbackPairs {
            if enToRuChar[ec] == nil { enToRuChar[ec] = rc }
            if ruToEnChar[rc] == nil { ruToEnChar[rc] = ec }
        }
    }

    private func sourceID(of source: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private func sourceLanguages(of source: TISInputSource) -> [String] {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        return (Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String]) ?? []
    }

    private func layoutData(of source: TISInputSource) -> Data? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    }

    private func translate(keyCode: UInt16, shifted: Bool, layoutData: Data) -> Character? {
        let modifierKeyState: UInt32 = shifted ? UInt32((shiftKey >> 8) & 0xFF) : 0
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLength: Int = 0

        let status = layoutData.withUnsafeBytes { rawBuf -> OSStatus in
            guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(-1)
            }
            return UCKeyTranslate(
                ptr,
                keyCode,
                UInt16(kUCKeyActionDown),
                modifierKeyState,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &actualLength,
                &chars
            )
        }

        guard status == noErr, actualLength > 0 else { return nil }
        let str = String(utf16CodeUnits: chars, count: actualLength)
        return str.first
    }
}
