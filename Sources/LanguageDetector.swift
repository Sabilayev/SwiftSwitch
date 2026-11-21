import Cocoa

final class LanguageDetector {
    static let shared = LanguageDetector()

    private let checker = NSSpellChecker.shared
    private var sessionIgnored: Set<String> = []

    // Common EN/tech/chat abbreviations that should never be auto-switched to RU
    private let enSafeWords: Set<String> = [
        "ok", "okay", "lol", "lmao", "bro", "thx", "pls", "plz", "btw", "idk", "imo", "imho",
        "omg", "wtf", "fyi", "asap", "tbd", "tba", "rip", "gg", "wp", "afk", "dm", "pm",
        "tg", "vk", "yt", "ig", "fb", "x", "vs", "etc", "eg", "ie", "aka", "faq", "diy",
        "mac", "macos", "ios", "ipad", "iphone", "macbook", "airpods", "apple", "xcode", "swift",
        "cpu", "gpu", "ram", "rom", "ssd", "hdd", "usb", "hdmi", "wifi", "vpn", "dns", "ip", "tcp", "udp",
        "api", "sdk", "cli", "gui", "ui", "ux", "ai", "ml", "llm", "gpt", "chatgpt", "claude", "gemini",
        "git", "github", "gitlab", "ssh", "ssl", "tls", "http", "https", "www", "url", "uri", "ftp",
        "html", "css", "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs", "cpp", "sql", "json", "xml", "yaml", "yml", "toml", "csv", "md", "txt",
        "pdf", "jpg", "jpeg", "png", "gif", "webp", "svg", "mp3", "mp4", "mov", "avi", "mkv", "wav",
        "zip", "rar", "tar", "gz", "dmg", "pkg", "app", "exe", "apk", "iso", "bin", "sh", "zsh", "bash",
        "npm", "npx", "yarn", "pnpm", "pip", "brew", "sudo", "cd", "ls", "cp", "mv", "rm", "mkdir", "cat", "grep", "curl", "wget", "ps", "top", "kill", "vim", "nano",
        "dev", "prod", "qa", "ci", "cd", "pr", "mr", "id", "uuid", "jwt", "oauth", "auth", "db", "orm", "cdn", "aws", "gcp",
        "mb", "gb", "tb", "kb", "hz", "mhz", "ghz", "fps", "dpi", "px", "rem", "em", "rgb", "hex",
        "usd", "eur", "rub", "kzt", "btc", "eth", "usdt",
        "chrome", "safari", "firefox", "zoom", "slack", "figma", "notion", "telegram", "whatsapp", "spotify", "youtube", "google", "punto", "yandex", "docker", "linux", "ubuntu", "windows"
    ]

    // Common Russian chat words / slang that spellcheckers sometimes miss
    private let ruCommonWords: Set<String> = [
        "да", "нет", "не", "на", "по", "за", "до", "от", "из", "со", "во", "ко", "об", "ну", "но", "ли", "же", "бы", "то", "ту", "те", "та",
        "он", "мы", "вы", "ты", "их", "им", "ей", "её", "ее", "им", "уж", "ага", "угу", "ок", "хз", "пж", "спс", "кст", "че", "чё", "ща", "щас",
        "прив", "привет", "пока", "норм", "изи", "плиз", "лол", "кек", "топ", "пон", "го", "блин", "короче", "кстати", "ладно", "давай", "делай",
        "можно", "нужно", "надо", "что", "как", "где", "когда", "почему", "зачем", "кто", "куда", "откуда", "если", "или", "для", "про", "при",
        "без", "под", "над", "перед", "между", "через", "после", "очень", "просто", "вообще", "только", "потом", "сейчас", "теперь", "здесь", "тут", "там",
        "все", "всё", "всем", "всех", "меня", "тебя", "мне", "тебе", "себя", "себе", "ещё", "еще", "уже", "тоже", "также", "будет", "было", "были", "есть"
    ]

    // Non-letter trailing punctuation we can safely strip before checking
    private let neutralTrailingPunct: Set<Character> = ["!", "?", ")", "(", "-", "—", ":", "=", "+", "/", "\\", "*"]

    private init() {}

    func addSessionIgnored(_ word: String) {
        sessionIgnored.insert(word.lowercased())
    }

    func clearSessionIgnored() {
        sessionIgnored.removeAll()
    }

    /// Returns the target language and converted string if an auto-switch should happen, or nil otherwise.
    func shouldAutoSwitch(rawWord: String, convertedWord: String, currentLang: SwitchLang) -> (targetLang: SwitchLang, replacement: String)? {
        guard rawWord.count >= 2, rawWord.count == convertedWord.count else { return nil }

        let lowerRaw = rawWord.lowercased()
        if sessionIgnored.contains(lowerRaw) { return nil }

        // Skip URLs, emails, paths, numbers
        if lowerRaw.hasPrefix("http") || lowerRaw.hasPrefix("www.") || rawWord.contains("@") || rawWord.contains("/") {
            return nil
        }
        if rawWord.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) {
            return nil
        }

        // Skip mixed internal camelCase (e.g. iPhone, MacBook, camelCase)
        if isInternalMixedCase(rawWord) {
            return nil
        }

        // Strip neutral trailing punctuation (that is not a letter in either lang)
        var rawCore = rawWord
        var convCore = convertedWord
        var trailingSuffix = ""
        while let lastRaw = rawCore.last, let lastConv = convCore.last,
              neutralTrailingPunct.contains(lastRaw), !lastConv.isLetter {
            trailingSuffix = String(lastRaw) + trailingSuffix
            rawCore.removeLast()
            convCore.removeLast()
        }

        guard rawCore.count >= 2 else { return nil }
        let targetLang = currentLang.opposite

        // Also handle case where trailing '.' or ',' in EN was actually punctuation rather than RU 'ю'/'б'
        if let result = evaluatePair(rawCore: rawCore, convCore: convCore, currentLang: currentLang, targetLang: targetLang) {
            return (targetLang, result + trailingSuffix)
        }

        if let lastRaw = rawCore.last, (lastRaw == "." || lastRaw == ","), rawCore.count >= 3 {
            let trimmedRaw = String(rawCore.dropLast())
            let trimmedConv = String(convCore.dropLast())
            if let result = evaluatePair(rawCore: trimmedRaw, convCore: trimmedConv, currentLang: currentLang, targetLang: targetLang) {
                return (targetLang, result + String(lastRaw) + trailingSuffix)
            }
        }

        return nil
    }

    private func evaluatePair(rawCore: String, convCore: String, currentLang: SwitchLang, targetLang: SwitchLang) -> String? {
        let lowerRaw = rawCore.lowercased()
        let lowerConv = convCore.lowercased()

        // Never convert safe EN abbreviations when typing in EN
        if currentLang == .en && enSafeWords.contains(lowerRaw) {
            return nil
        }

        // Check if rawCore is already a valid word in currentLang
        if isValidWord(rawCore, lang: currentLang) {
            return nil
        }

        // For 2-letter words, require higher confidence: must be in explicit common word list (RU) or strict EN dictionary
        if rawCore.count == 2 {
            if targetLang == .ru {
                if ruCommonWords.contains(lowerConv) && isPureScript(convCore, lang: .ru) {
                    return convCore
                }
                return nil
            } else {
                // 2-letter RU -> EN: only switch if raw is NOT valid RU and conv is a common EN word
                let common2En: Set<String> = ["ok", "no", "hi", "go", "do", "to", "in", "on", "is", "it", "my", "we", "he", "me", "up", "by", "of", "or", "if", "at", "as", "an", "so", "be", "cd", "ls"]
                if common2En.contains(lowerConv) && isPureScript(convCore, lang: .en) {
                    return convCore
                }
                return nil
            }
        }

        // Check if converted word is valid in targetLang
        if isValidWord(convCore, lang: targetLang) {
            return convCore
        }

        return nil
    }

    private func isValidWord(_ word: String, lang: SwitchLang) -> Bool {
        guard isPureScript(word, lang: lang) else { return false }

        let lower = word.lowercased()
        if lang == .ru && ruCommonWords.contains(lower) {
            return true
        }
        if lang == .en && enSafeWords.contains(lower) {
            return true
        }

        // Query macOS native dictionary via NSSpellChecker
        let checkLang = (lang == .ru) ? "ru" : "en"
        let range = checker.checkSpelling(
            of: lower,
            startingAt: 0,
            language: checkLang,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        if range.location == NSNotFound {
            return true
        }

        // Also try original casing (for proper nouns like Moscow / Москва)
        if word != lower {
            let rangeOrig = checker.checkSpelling(
                of: word,
                startingAt: 0,
                language: checkLang,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            if rangeOrig.location == NSNotFound {
                return true
            }
        }

        return false
    }

    private func isPureScript(_ word: String, lang: SwitchLang) -> Bool {
        guard !word.isEmpty else { return false }
        for scalar in word.unicodeScalars {
            if scalar == "-" || scalar == "'" || scalar == "’" { continue }
            if lang == .ru {
                if !(0x0400...0x04FF).contains(scalar.value) { return false }
            } else {
                let isLat = (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value)
                if !isLat { return false }
            }
        }
        return true
    }

    private func isInternalMixedCase(_ word: String) -> Bool {
        let chars = Array(word)
        guard chars.count >= 2 else { return false }
        let rest = chars.dropFirst()
        let hasUpper = rest.contains { $0.isUppercase }
        let hasLower = rest.contains { $0.isLowercase }
        // e.g. "iPhone" (first lower, rest has upper) or "MacBook" (rest has both upper and lower)
        if chars[0].isLowercase && hasUpper { return true }
        if hasUpper && hasLower { return true }
        return false
    }
}
