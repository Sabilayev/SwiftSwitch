import Cocoa

@main
struct TestRunner {
    static func main() {
        let lm = LayoutManager.shared
        let det = LanguageDetector.shared
        print("EN source: \(lm.enSourceID), RU source: \(lm.ruSourceID)")

        // 1. On-The-Fly ("На лету") tests
        let onTheFlyCases: [(raw: String, lang: SwitchLang, expected: String?)] = [
            // Instant 3-char & 4-char RU-on-EN prefixes
            ("ctq", .en, "сей"),          // сейчас -> switches on 3rd char!
            ("ctqxfc", .en, "сейчас"),
            ("ghb", .en, "при"),          // привет
            ("ltk", .en, "дел"),          // делай
            ("xnj", .en, "что"),          // что
            ("rfr", .en, "как"),          // как
            ("dct", .en, "все"),          // все
            ("vj;", .en, "мож"),          // можно
            ("ghj,", .en, "проб"),        // проблема
            (",el", .en, "буд"),          // будет
            ("[jh", .en, "хор"),          // хорошо
            ("'nj", .en, "это"),          // это
            ("k.,", .en, "люб"),          // люблю
            ("cgf", .en, "спа"),          // спасибо
            (";bp", .en, "жиз"),          // жизнь
            ("ytd", .en, "нев"),          // невозможно
            ("ctqxfcc", .en, "сейчасс"),  // typo slang fallback!
            // Instant RU-on-EN -> NO false positives!
            ("hel", .en, nil),
            ("wor", .en, nil),
            ("pro", .en, nil),
            ("com", .en, nil),
            ("mac", .en, nil),
            ("git", .en, nil),
            ("sbl", .en, nil),
            ("http", .en, nil),
            ("google.com", .en, nil),
            ("build.sh", .en, nil),
            ("'hel", .en, nil),
            ("ok,", .en, nil),
            ("hi.", .en, nil),
            ("iPh", .en, nil),
            // Instant EN-on-RU prefixes
            ("руд", .ru, nil),            // WAIT! Could be Russian "руда" / "рудник"
            ("рудд", .ru, "hell"),        // Switches on 4th char!
            ("пщщ", .ru, "goo"),          // google / good
            ("срк", .ru, "chr"),          // chrome
            ("знер", .ru, "pyth"),        // python
            ("цщк", .ru, "wor"),          // world / work
            ("ыцш", .ru, "swi"),          // swift
            ("ьфс", .ru, "mac"),          // mac
            ("еуы", .ru, "tes"),          // test
            // Valid Russian prefixes -> NO false positives!
            ("при", .ru, nil),
            ("сей", .ru, nil),
            ("про", .ru, nil),
            ("маг", .ru, nil),
            ("шту", .ru, nil),
            ("дел", .ru, nil),
        ]

        // 2. Word-boundary (Space/Enter) tests
        let boundaryCases: [(raw: String, lang: SwitchLang, expected: String?)] = [
            ("ltkfq", .en, "делай"),
            ("ctqxfc", .en, "сейчас"),
            ("ghbdtn", .en, "привет"),
            ("Ghbdtn!", .en, "Привет!"),
            ("ghj,ktvf", .en, "проблема"),
            ("k.,k.", .en, "люблю"),
            ("cgfcb,j", .en, "спасибо"),
            ("vj;yj", .en, "можно"),
            ("lf", .en, "да"),
            ("yt", .en, "не"),
            ("yf", .en, "на"),
            ("руддщ", .ru, "hello"),
            ("цщкдв", .ru, "world"),
            ("знерщт", .ru, "python"),
            ("сркщьу", .ru, "chrome"),
            ("пщщпду", .ru, "google"),
            // Should NOT switch
            ("hello", .en, nil),
            ("world", .en, nil),
            ("macbook", .en, nil),
            ("iPhone", .en, nil),
            ("ok", .en, nil),
            ("no", .en, nil),
            ("vs", .en, nil),
            ("https://google.com", .en, nil),
            ("test@mail.com", .en, nil),
            ("привет", .ru, nil),
            ("сейчас", .ru, nil),
            ("делай", .ru, nil),
            ("проблема", .ru, nil),
            ("можно", .ru, nil),
            ("да", .ru, nil),
            ("нет", .ru, nil),
        ]

        var passed = 0
        var failed = 0

        for c in onTheFlyCases {
            let converted = lm.convertText(c.raw, from: c.lang, to: c.lang.opposite)
            let res = det.shouldAutoSwitchOnTheFly(rawPrefix: c.raw, convertedPrefix: converted, currentLang: c.lang)
            let got = res?.replacement
            if got == c.expected {
                passed += 1
            } else {
                failed += 1
                print("FAIL [ON-THE-FLY]: raw='\(c.raw)' (\(c.lang.rawValue)) conv='\(converted)' expected=\(String(describing: c.expected)) got=\(String(describing: got))")
            }
        }

        for c in boundaryCases {
            let converted = lm.convertText(c.raw, from: c.lang, to: c.lang.opposite)
            let res = det.shouldAutoSwitch(rawWord: c.raw, convertedWord: converted, currentLang: c.lang)
            let got = res?.replacement
            if got == c.expected {
                passed += 1
            } else {
                failed += 1
                print("FAIL [BOUNDARY]: raw='\(c.raw)' (\(c.lang.rawValue)) conv='\(converted)' expected=\(String(describing: c.expected)) got=\(String(describing: got))")
            }
        }

        let total = onTheFlyCases.count + boundaryCases.count
        print("Tests: \(passed) passed, \(failed) failed out of \(total)")
        if failed > 0 { exit(1) }
    }
}
