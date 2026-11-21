import Cocoa

@main
struct TestRunner {
    static func main() {
        let lm = LayoutManager.shared
        let det = LanguageDetector.shared
        print("EN source: \(lm.enSourceID), RU source: \(lm.ruSourceID)")

        let cases: [(raw: String, lang: SwitchLang, expected: String?)] = [
            // EN typed when meaning RU
            ("ltkfq", .en, "делай"),
            ("ghbdtn", .en, "привет"),
            ("Ghbdtn!", .en, "Привет!"),
            ("ghj,ktvf", .en, "проблема"),
            ("k.,k.", .en, "люблю"),
            ("cgfcb,j", .en, "спасибо"),
            ("vj;yj", .en, "можно"),
            ("xnj", .en, "что"),
            ("rfr", .en, "как"),
            ("lf", .en, "да"),
            ("gjrf", .en, "пока"),
            ("dctv", .en, "всем"),
            // RU typed when meaning EN
            ("руддщ", .ru, "hello"),
            ("цщкдв", .ru, "world"),
            ("знерщт", .ru, "python"),
            ("сркщьу", .ru, "chrome"),
            ("пщщпду", .ru, "google"),
            // Should NOT switch!
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
            ("делай", .ru, nil),
            ("проблема", .ru, nil),
            ("можно", .ru, nil),
            ("да", .ru, nil),
            ("нет", .ru, nil),
        ]

        var passed = 0
        var failed = 0
        for c in cases {
            let converted = lm.convertText(c.raw, from: c.lang, to: c.lang.opposite)
            let res = det.shouldAutoSwitch(rawWord: c.raw, convertedWord: converted, currentLang: c.lang)
            let got = res?.replacement
            if got == c.expected {
                passed += 1
            } else {
                failed += 1
                print("FAIL: raw='\(c.raw)' (\(c.lang.rawValue)) conv='\(converted)' expected=\(String(describing: c.expected)) got=\(String(describing: got))")
            }
        }
        print("Tests: \(passed) passed, \(failed) failed out of \(cases.count)")
        if failed > 0 { exit(1) }
    }
}
