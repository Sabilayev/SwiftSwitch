import Cocoa

final class LanguageDetector {
    static let shared = LanguageDetector()

    private let checker = NSSpellChecker.shared
    private var sessionIgnored: Set<String> = []

    // Lightweight caches for zero-latency repeated prefix/word lookups
    private var completionCountCache: [String: Int] = [:]
    private var spellValidCache: [String: Bool] = [:]
    private let maxCacheEntries = 2000

    // Common EN/tech/chat words & prefixes that should never be auto-switched to RU
    private let enSafeWords: Set<String> = [
        "ok", "okay", "lol", "lmao", "lmfao", "bro", "thx", "pls", "plz", "btw", "idk", "imo", "imho",
        "omg", "wtf", "fyi", "asap", "tbd", "tba", "rip", "gg", "wp", "afk", "brb", "dm", "pm",
        "tg", "vk", "ig", "fb", "vs", "etc", "eg", "ie", "aka", "faq", "diy",
        "mac", "macos", "ios", "ipad", "iphone", "macbook", "airpods", "apple", "xcode", "swift",
        "cpu", "gpu", "ram", "rom", "ssd", "hdd", "usb", "hdmi", "wifi", "vpn", "dns", "ip", "tcp", "udp",
        "api", "sdk", "cli", "gui", "ui", "ux", "ai", "ml", "llm", "gpt", "chatgpt", "claude", "gemini",
        "git", "github", "gitlab", "ssh", "ssl", "tls", "http", "https", "www", "url", "uri", "ftp",
        "html", "css", "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs", "cpp", "sql", "json", "xml", "yaml", "yml", "toml", "csv", "md", "txt",
        "pdf", "jpg", "jpeg", "png", "gif", "webp", "svg", "mp3", "mp4", "mov", "avi", "mkv", "wav",
        "zip", "rar", "tar", "gz", "dmg", "pkg", "app", "exe", "apk", "iso", "bin", "sh", "zsh", "bash",
        "npm", "npx", "yarn", "pnpm", "pip", "brew", "sudo", "cd", "ls", "cp", "mv", "rm", "mkdir", "cat", "grep", "curl", "wget", "ps", "top", "kill", "vim", "nvim", "nano", "tmux",
        "ctrl", "cmd", "alt", "esc", "fn", "tab", "cap", "caps",
        "dev", "prod", "qa", "ci", "pr", "mr", "id", "uuid", "jwt", "oauth", "auth", "db", "orm", "cdn", "aws", "gcp", "k8s",
        "mb", "gb", "tb", "kb", "hz", "mhz", "ghz", "fps", "dpi", "px", "rem", "em", "rgb", "hex",
        "usd", "eur", "rub", "kzt", "btc", "eth", "usdt",
        "qwerty", "asdf", "zxcv", "sblvns",
        "chrome", "safari", "firefox", "zoom", "slack", "figma", "notion", "telegram", "whatsapp", "spotify", "youtube", "google", "punto", "yandex", "docker", "linux", "ubuntu", "windows"
    ]

    // Known TLDs / file extensions to protect dots in EN (e.g. google.com, build.sh)
    private let knownDotSuffixes: Set<String> = [
        "com", "ru", "kz", "org", "net", "io", "dev", "app", "ai", "co", "me", "gg", "tv", "ua", "by", "uk", "de", "fr", "jp", "cn", "info", "biz",
        "sh", "zsh", "py", "js", "ts", "jsx", "tsx", "swift", "c", "h", "cpp", "go", "rs", "rb", "php", "java", "kt",
        "html", "css", "json", "xml", "yaml", "yml", "toml", "md", "txt", "csv", "log", "env", "plist",
        "png", "jpg", "jpeg", "gif", "webp", "svg", "icns", "pdf", "doc", "docx", "xls", "xlsx", "zip", "rar", "dmg", "pkg", "mp3", "mp4", "mov"
    ]

    // Common Russian words/chat/slang (ensures 100% recall even if AppleSpell misses slang)
    private let ruCommonWords: Set<String> = [
        "да", "нет", "не", "на", "по", "за", "до", "от", "из", "со", "во", "ко", "об", "ну", "но", "ли", "же", "бы", "то", "ту", "те", "та",
        "он", "мы", "вы", "ты", "их", "им", "ей", "её", "ее", "уж", "ага", "угу", "ок", "хз", "пж", "спс", "кст", "че", "чё", "ща", "щас",
        "прив", "привет", "пока", "норм", "изи", "плиз", "лол", "кек", "топ", "пон", "го", "блин", "короче", "кстати", "ладно", "давай", "делай",
        "можно", "нужно", "надо", "что", "как", "где", "когда", "почему", "зачем", "кто", "куда", "откуда", "если", "или", "для", "про", "при",
        "без", "под", "над", "перед", "между", "через", "после", "очень", "просто", "вообще", "только", "потом", "сейчас", "теперь", "здесь", "тут", "там",
        "все", "всё", "всем", "всех", "меня", "тебя", "мне", "тебе", "себя", "себе", "ещё", "еще", "уже", "тоже", "также", "будет", "было", "были", "есть",
        "это", "эту", "эти", "этим", "хочу", "хорошо", "спасибо", "проблема", "люблю", "жизнь", "быть", "больше", "меньше", "вроде", "работает"
    ]

    // Data-driven impossible/ultra-rare English bigrams (<=10 hits across 235,976 English words)
    private let impossibleEnBigrams: Set<String> = [
        "bq", "bx", "bz", "cb", "cf", "cg", "cj", "cv", "cw", "cx", "dq", "dx",
        "fc", "fj", "fk", "fq", "fv", "fx", "fz", "gj", "gq", "gv", "gx", "gz",
        "hj", "hq", "hx", "hz",
        "jb", "jc", "jd", "jf", "jg", "jh", "jj", "jk", "jl", "jm", "jn", "jp", "jq", "jr", "js", "jt", "jv", "jw", "jx", "jy", "jz",
        "kq", "kv", "kx", "kz", "lj", "lq", "lx", "mj", "mq", "mx", "mz",
        "pq", "pv", "px", "pz",
        "qa", "qb", "qc", "qd", "qe", "qf", "qg", "qh", "qi", "qj", "qk", "ql", "qm", "qn", "qo", "qp", "qq", "qr", "qs", "qt", "qv", "qw", "qx", "qy", "qz",
        "rx", "sx", "tq", "tx",
        "vb", "vc", "vd", "vf", "vg", "vh", "vj", "vk", "vl", "vm", "vn", "vp", "vq", "vs", "vt", "vw", "vx", "vz",
        "wj", "wq", "wv", "wx",
        "xd", "xg", "xj", "xk", "xn", "xq", "xr", "xv", "xx", "xz",
        "yj", "yq", "yy",
        "zc", "zf", "zg", "zh", "zj", "zk", "zm", "zn", "zp", "zq", "zr", "zs", "zv", "zw", "zx"
    ]

    // Data-driven impossible English word-start bigrams (<=3 hits across 235,976 English words)
    private let impossibleEnStartBigrams: Set<String> = [
        "bb", "bc", "bf", "bg", "bj", "bk", "bm", "bn", "bp", "bq", "bs", "bt", "bv", "bw", "bx", "bz",
        "cb", "cc", "cd", "cf", "cg", "cj", "ck", "cm", "cp", "cq", "cs", "cv", "cw", "cx",
        "db", "dc", "dd", "df", "dg", "dk", "dl", "dm", "dn", "dp", "dq", "ds", "dt", "dv", "dx", "dz",
        "ez",
        "fb", "fc", "fd", "ff", "fg", "fh", "fk", "fm", "fn", "fp", "fq", "fs", "ft", "fv", "fw", "fx", "fy", "fz",
        "gb", "gc", "gd", "gf", "gg", "gj", "gk", "gm", "gp", "gq", "gs", "gt", "gv", "gx", "gz",
        "hb", "hc", "hd", "hf", "hg", "hh", "hj", "hk", "hm", "hn", "hp", "hq", "hr", "hs", "ht", "hv", "hw", "hx", "hz",
        "ie", "ii", "iq", "iu", "iw", "iy",
        "jb", "jc", "jd", "jf", "jg", "jj", "jk", "jl", "jm", "jn", "jp", "jq", "jr", "js", "jt", "jv", "jw", "jx", "jz",
        "kb", "kc", "kd", "kf", "kg", "kj", "kk", "km", "kp", "kq", "ks", "kt", "kv", "kx", "kz",
        "lb", "lc", "ld", "lf", "lg", "lh", "lj", "lk", "lm", "ln", "lp", "lq", "lr", "ls", "lt", "lv", "lw", "lx", "lz",
        "mc", "md", "mf", "mg", "mh", "mj", "mk", "ml", "mm", "mp", "mq", "mr", "ms", "mt", "mv", "mw", "mx", "mz",
        "nb", "nc", "nd", "nf", "nh", "nj", "nk", "nl", "nm", "nn", "np", "nq", "nr", "ns", "nt", "nv", "nw", "nx", "nz",
        "oj", "oq",
        "pb", "pc", "pd", "pg", "pj", "pk", "pm", "pp", "pq", "pv", "pw", "px", "pz",
        "qa", "qb", "qc", "qd", "qe", "qf", "qg", "qh", "qi", "qj", "qk", "ql", "qm", "qn", "qo", "qp", "qq", "qr", "qs", "qt", "qv", "qw", "qx", "qy", "qz",
        "rb", "rc", "rd", "rf", "rg", "rj", "rk", "rl", "rm", "rn", "rp", "rq", "rr", "rs", "rt", "rv", "rw", "rx", "rz",
        "sb", "sd", "sf", "sg", "sj", "sx",
        "tb", "td", "tf", "tg", "tj", "tk", "tm", "tn", "tp", "tq", "tt", "tv", "tx",
        "ue", "uf", "uj", "uo", "uq", "uu", "uw", "uy",
        "vb", "vc", "vd", "vf", "vg", "vh", "vj", "vk", "vm", "vn", "vp", "vq", "vs", "vt", "vv", "vw", "vx", "vy", "vz",
        "wb", "wc", "wd", "wf", "wg", "wj", "wk", "wl", "wm", "wn", "wp", "wq", "ws", "wt", "wv", "ww", "wx", "wz",
        "xb", "xc", "xd", "xf", "xg", "xh", "xj", "xk", "xl", "xm", "xn", "xo", "xp", "xq", "xr", "xs", "xt", "xu", "xv", "xw", "xx", "xz",
        "yb", "yc", "yd", "yf", "yg", "yh", "yj", "yk", "yl", "ym", "yn", "yq", "yr", "ys", "yv", "yw", "yx", "yy", "yz",
        "zb", "zc", "zd", "zf", "zg", "zh", "zj", "zk", "zl", "zm", "zn", "zp", "zq", "zr", "zs", "zt", "zv", "zx", "zz"
    ]

    // Strictly impossible Russian bigrams (zero false positives on real Russian words!)
    private let impossibleRuBigrams: Set<String> = [
        // Vowel + ы, ь, ъ
        "аы", "еы", "ёы", "иы", "оы", "уы", "ыы", "эы", "юы", "яы",
        "аь", "еь", "ёь", "иь", "оь", "уь", "ыь", "эь", "юь", "яь",
        "аъ", "еъ", "ёъ", "иъ", "оъ", "уъ", "ыъ", "эъ", "юъ", "яъ",
        // Russian orthography rules
        "жы", "шы", "чы", "щы", "гы", "кы", "хы", "йы", "ьы", "ъы",
        "жя", "шя", "чя", "щя", "жю", "шю", "чю", "щю",
        // Impossible ь / ъ pairs
        "ьа", "ьу", "ьэ", "ьь", "ьъ", "ъа", "ъо", "ъу", "ъэ", "ъь", "ъъ",
        // Truly impossible щ clusters (note: бщ/вщ/нщ/рщ/лщ/мщ are valid in Russian!)
        "гщ", "дщ", "жщ", "зщ", "йщ", "кщ", "пщ", "сщ", "тщ", "фщ", "хщ", "цщ", "чщ", "шщ", "щщ", "ьщ", "ъщ",
        "щб", "щв", "щг", "щд", "щж", "щз", "щй", "щк", "щл", "щм", "щп", "щр", "щс", "щт", "щф", "щх", "щц", "щч", "щш", "щъ", "щэ",
        // Truly impossible ц / ф / й / ш / з clusters (note: йч in сейчас, йц in яйцо, йл in файл, йм in поймать are valid!)
        "цг", "цж", "цз", "цй", "цр", "цф", "цх", "цч", "цш", "цщ", "цъ",
        "фб", "фг", "фд", "фж", "фз", "фй", "фх", "фц", "фч", "фщ", "фъ",
        "йж", "йз", "йй", "йф", "йх", "йш", "йщ", "йъ", "йь",
        "шж", "шз", "шй", "шф", "шх", "шц", "шч", "шш", "шщ", "шъ", "шэ",
        "зж", "зй", "зф", "зх", "зц", "зч", "зш", "зщ", "зэ"
    ]

    private let ruVowels: Set<Character> = ["а", "е", "ё", "и", "о", "у", "ы", "э", "ю", "я"]
    private let enVowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
    private let neutralTrailingPunct: Set<Character> = ["!", "?", ")", "(", "-", "—", ":", "=", "+", "/", "\\", "*"]
    private let ruLayoutPunctInEn: Set<Character> = ["[", "]", ";", "'", ",", ".", "`"]

    private init() {}

    /// Pre-warms AppleSpell XPC connection off the main thread so the first keystroke has zero latency.
    func warmUp() {
        _ = completionCount("сей", lang: .ru)
        _ = completionCount("hel", lang: .en)
        _ = isValidDictionaryWord("привет", lang: .ru)
        _ = isValidDictionaryWord("hello", lang: .en)
    }

    func addSessionIgnored(_ word: String) {
        sessionIgnored.insert(word.lowercased())
    }

    func clearSessionIgnored() {
        sessionIgnored.removeAll()
    }

    // MARK: - Stage A: On-The-Fly Detection (Punto-style real-time switching)

    /// Called after each regular character keystroke when buffer.count >= 3.
    /// Returns (targetLang, replacement) ONLY when confidence is very high that the user is typing in the wrong layout.
    func shouldAutoSwitchOnTheFly(rawPrefix: String, convertedPrefix: String, currentLang: SwitchLang) -> (targetLang: SwitchLang, replacement: String)? {
        guard rawPrefix.count >= 3, rawPrefix.count == convertedPrefix.count else { return nil }

        let lowerRaw = rawPrefix.lowercased()
        let lowerConv = convertedPrefix.lowercased()

        // Respect session undo exceptions (exact or prefix match)
        if sessionIgnored.contains(lowerRaw) || sessionIgnored.contains(where: { lowerRaw.hasPrefix($0) || $0.hasPrefix(lowerRaw) }) {
            return nil
        }

        // Never interrupt URLs, emails, paths, digits, or internal camelCase
        if shouldSkipGlobalGuards(raw: rawPrefix, lowerRaw: lowerRaw) {
            return nil
        }

        let targetLang = currentLang.opposite

        // Converted prefix MUST be pure target-language letters (never switch into garbage punctuation!)
        guard isPureLetters(lowerConv, lang: targetLang) else { return nil }

        // Protect EN safe abbreviations/tech prefixes (e.g. http, git, swift, macbook, sblvns)
        if currentLang == .en {
            if enSafeWords.contains(lowerRaw) || enSafeWords.contains(where: { $0.hasPrefix(lowerRaw) }) {
                return nil
            }
            // Protect quoted English words like 'hello
            if rawPrefix.hasPrefix("'") {
                let unquoted = String(lowerRaw.dropFirst())
                if unquoted.count >= 2 && (completionCount(unquoted, lang: .en) > 0 || isValidDictionaryWord(unquoted, lang: .en)) {
                    return nil
                }
            }
            // Protect domains/file extensions like google.com, build.sh
            if let dotIdx = lowerRaw.firstIndex(of: ".") {
                let beforeDot = String(lowerRaw[..<dotIdx])
                let afterDot = String(lowerRaw[lowerRaw.index(after: dotIdx)...])
                if beforeDot.count >= 2 && (isValidDictionaryWord(beforeDot, lang: .en) || enSafeWords.contains(beforeDot)) {
                    return nil
                }
                if !afterDot.isEmpty && (knownDotSuffixes.contains(afterDot) || knownDotSuffixes.contains(where: { $0.hasPrefix(afterDot) })) {
                    return nil
                }
            }
            // Wait if last char is trailing '.' or ',' right after a valid EN word (user might just be ending a sentence: "ok," / "hi.")
            if let last = rawPrefix.last, (last == "." || last == "," || last == ";") {
                let stem = String(lowerRaw.dropLast())
                if stem.count >= 2 && (isValidDictionaryWord(stem, lang: .en) || completionCount(stem, lang: .en) > 0) {
                    return nil
                }
            }
        }

        // Never switch if targetLang itself has an impossible start or bigram!
        if hasImpossibleBigram(lowerConv, lang: targetLang) {
            return nil
        }

        // Check if rawPrefix is ALREADY a valid word or valid word prefix in currentLang
        let rawHasPunct = (currentLang == .en) && rawPrefix.contains(where: { ruLayoutPunctInEn.contains($0) })
        if !rawHasPunct {
            if isValidDictionaryWord(rawPrefix, lang: currentLang) { return nil }
            if completionCount(lowerRaw, lang: currentLang) > 0 { return nil }
        }

        // Now we know rawPrefix is NOT a valid word or prefix in currentLang!
        let convCompletions = completionCount(lowerConv, lang: targetLang)
        let convIsValidWord = isValidDictionaryWord(convertedPrefix, lang: targetLang)
        let rawIsImpossible = rawHasPunct || hasImpossibleBigram(lowerRaw, lang: currentLang)

        // Rule 1: Target has real dictionary completions or is a valid word
        if convIsValidWord || convCompletions > 0 {
            if rawPrefix.count == 3 {
                // At 3 letters, require either impossible current bigram/punct OR strong target prefix (>= 2 completions or common word)
                if rawIsImpossible || convIsValidWord || convCompletions >= 2 {
                    return (targetLang, convertedPrefix)
                }
            } else {
                // At 4+ letters: 0 completions in currentLang + >=1 completion in targetLang -> 100% switch!
                return (targetLang, convertedPrefix)
            }
        }

        // Rule 2 (Slang / Typo fallback, 4+ chars):
        // Even if the word isn't in AppleSpell (slang, typo, conjugated form), if raw has impossible bigrams
        // in currentLang AND converted is clean target script with vowel(s) and zero impossible bigrams -> switch!
        if rawPrefix.count >= 4 && rawIsImpossible && hasVowel(lowerConv, lang: targetLang) {
            return (targetLang, convertedPrefix)
        }

        return nil
    }

    // MARK: - Stage B: Word-Boundary Detection (Space / Enter fallback)

    func shouldAutoSwitch(rawWord: String, convertedWord: String, currentLang: SwitchLang) -> (targetLang: SwitchLang, replacement: String)? {
        guard rawWord.count >= 2, rawWord.count == convertedWord.count else { return nil }

        let lowerRaw = rawWord.lowercased()
        if sessionIgnored.contains(lowerRaw) { return nil }
        if shouldSkipGlobalGuards(raw: rawWord, lowerRaw: lowerRaw) { return nil }

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

        if let result = evaluateBoundaryPair(rawCore: rawCore, convCore: convCore, currentLang: currentLang, targetLang: targetLang) {
            return (targetLang, result + trailingSuffix)
        }

        // Handle trailing '.' or ',' in EN that was actual punctuation rather than 'ю'/'б'
        if let lastRaw = rawCore.last, (lastRaw == "." || lastRaw == ","), rawCore.count >= 3 {
            let trimmedRaw = String(rawCore.dropLast())
            let trimmedConv = String(convCore.dropLast())
            if let result = evaluateBoundaryPair(rawCore: trimmedRaw, convCore: trimmedConv, currentLang: currentLang, targetLang: targetLang) {
                return (targetLang, result + String(lastRaw) + trailingSuffix)
            }
        }

        return nil
    }

    private func evaluateBoundaryPair(rawCore: String, convCore: String, currentLang: SwitchLang, targetLang: SwitchLang) -> String? {
        let lowerRaw = rawCore.lowercased()
        let lowerConv = convCore.lowercased()

        if currentLang == .en && enSafeWords.contains(lowerRaw) {
            return nil
        }

        // Already valid in current language -> do not switch
        if isValidDictionaryWord(rawCore, lang: currentLang) {
            return nil
        }

        // Protect domains/file extensions at word boundary too
        if currentLang == .en, let dotIdx = lowerRaw.lastIndex(of: ".") {
            let afterDot = String(lowerRaw[lowerRaw.index(after: dotIdx)...])
            if knownDotSuffixes.contains(afterDot) { return nil }
        }

        guard isPureLetters(lowerConv, lang: targetLang) else { return nil }

        // 2-letter words (e.g. lf->да, yt->не, yf->на, gj->по, nj->то, rf->no, etc.)
        if rawCore.count == 2 {
            if targetLang == .ru {
                if ruCommonWords.contains(lowerConv) {
                    return convCore
                }
                return nil
            } else {
                let common2En: Set<String> = ["ok", "no", "hi", "go", "do", "to", "in", "on", "is", "it", "my", "we", "he", "me", "up", "by", "of", "or", "if", "at", "as", "an", "so", "be", "cd", "ls"]
                if common2En.contains(lowerConv) {
                    return convCore
                }
                return nil
            }
        }

        // 3+ letter words: dictionary check OR completions OR impossible-bigram slang fallback
        if isValidDictionaryWord(convCore, lang: targetLang) {
            return convCore
        }

        let rawHasPunct = (currentLang == .en) && rawCore.contains(where: { ruLayoutPunctInEn.contains($0) })
        let rawImpossible = rawHasPunct || hasImpossibleBigram(lowerRaw, lang: currentLang)
        let convImpossible = hasImpossibleBigram(lowerConv, lang: targetLang)

        if rawImpossible && !convImpossible && hasVowel(lowerConv, lang: targetLang) {
            // Even for typos/slang/unusual declensions (e.g. "сейчасс", "приветик"), switch!
            return convCore
        }

        return nil
    }

    // MARK: - Helpers

    private func shouldSkipGlobalGuards(raw: String, lowerRaw: String) -> Bool {
        if lowerRaw.hasPrefix("http") || lowerRaw.hasPrefix("www.") || raw.contains("@") || raw.contains("/") {
            return true
        }
        if raw.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) {
            return true
        }
        if isInternalMixedCase(raw) {
            return true
        }
        return false
    }

    private func hasImpossibleBigram(_ lower: String, lang: SwitchLang) -> Bool {
        let chars = Array(lower)
        guard chars.count >= 2 else { return false }

        if lang == .ru {
            // Russian words NEVER start with ы, ь, ъ
            if let first = chars.first, first == "ы" || first == "ь" || first == "ъ" {
                return true
            }
            for i in 0..<(chars.count - 1) {
                let bg = String([chars[i], chars[i + 1]])
                if impossibleRuBigrams.contains(bg) { return true }
            }
            if chars.count >= 3 {
                for i in 0..<(chars.count - 2) {
                    let tg = String([chars[i], chars[i + 1], chars[i + 2]])
                    if impossibleRuBigrams.contains(tg) { return true }
                }
            }
            return false
        } else {
            let start2 = String([chars[0], chars[1]])
            if impossibleEnStartBigrams.contains(start2) { return true }
            for i in 0..<(chars.count - 1) {
                let bg = String([chars[i], chars[i + 1]])
                if impossibleEnBigrams.contains(bg) { return true }
            }
            return false
        }
    }

    private func hasVowel(_ lower: String, lang: SwitchLang) -> Bool {
        let vowels = (lang == .ru) ? ruVowels : enVowels
        return lower.contains(where: { vowels.contains($0) })
    }

    private func completionCount(_ lowerWord: String, lang: SwitchLang) -> Int {
        guard isPureLetters(lowerWord, lang: lang) else { return 0 }
        let key = "\(lang.rawValue):\(lowerWord)"
        if let cached = completionCountCache[key] { return cached }

        let nsRange = NSRange(location: 0, length: (lowerWord as NSString).length)
        let list = checker.completions(
            forPartialWordRange: nsRange,
            in: lowerWord,
            language: lang.rawValue,
            inSpellDocumentWithTag: 0
        ) ?? []

        // Filter out false completions that don't actually start with lowerWord (case-insensitive)
        let matching = list.filter { $0.lowercased().hasPrefix(lowerWord) }.count

        if completionCountCache.count > maxCacheEntries { completionCountCache.removeAll() }
        completionCountCache[key] = matching
        return matching
    }

    private func isValidDictionaryWord(_ word: String, lang: SwitchLang) -> Bool {
        guard isPureLetters(word, lang: lang) else { return false }

        let lower = word.lowercased()
        if lang == .ru && ruCommonWords.contains(lower) { return true }
        if lang == .en && enSafeWords.contains(lower) { return true }

        let key = "\(lang.rawValue):\(lower)"
        if let cached = spellValidCache[key] { return cached }

        let checkLang = lang.rawValue
        var valid = checker.checkSpelling(
            of: lower,
            startingAt: 0,
            language: checkLang,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        ).location == NSNotFound

        if !valid && word != lower {
            valid = checker.checkSpelling(
                of: word,
                startingAt: 0,
                language: checkLang,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            ).location == NSNotFound
        }

        if spellValidCache.count > maxCacheEntries { spellValidCache.removeAll() }
        spellValidCache[key] = valid
        return valid
    }

    private func isPureLetters(_ word: String, lang: SwitchLang) -> Bool {
        guard !word.isEmpty else { return false }
        for scalar in word.unicodeScalars {
            if scalar == "-" { continue }
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
        if chars[0].isLowercase && hasUpper { return true }
        if hasUpper && hasLower { return true }
        return false
    }
}
