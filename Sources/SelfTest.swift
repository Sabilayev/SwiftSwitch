import Cocoa
import Carbon
import ApplicationServices

final class SelfTestRunner {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        guard AXIsProcessTrusted() else {
            print("E2E_ERROR: AXIsProcessTrusted() == false. Grant Accessibility to SwiftSwitch.app first.")
            exit(2)
        }

        LanguageDetector.shared.warmUp()
        guard TypingEngine.shared.start() else {
            print("E2E_ERROR: TypingEngine.shared.start() failed (CGEvent.tapCreate returned nil).")
            exit(3)
        }

        let win = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 420, height: 90),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "SwiftSwitch Live E2E Test"
        let field = NSTextField(frame: NSRect(x: 20, y: 25, width: 380, height: 36))
        field.font = NSFont.systemFont(ofSize: 18)
        win.contentView?.addSubview(field)
        win.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        win.makeFirstResponder(field)

        let origLang = LayoutManager.shared.currentLanguage() ?? .en

        // KeyCode map (ANSI US physical keys)
        let cases: [(name: String, startLang: SwitchLang, keyCodes: [UInt16], expectedText: String, expectedLang: SwitchLang)] = [
            ("ctqxfc -> сейчас", .en, [8, 17, 12, 7, 3, 8, 49], "сейчас ", .ru),
            ("руддщ -> hello",   .ru, [4, 14, 37, 37, 31, 49],   "hello ",  .en),
            ("ghbdtn -> привет", .en, [5, 4, 11, 2, 17, 45, 49], "привет ", .ru),
            ("hello stays EN",   .en, [4, 14, 37, 37, 31, 49],   "hello ",  .en),
        ]

        DispatchQueue.global(qos: .userInitiated).async {
            usleep(400_000)
            var passed = 0
            var failed = 0

            for tc in cases {
                DispatchQueue.main.sync {
                    TypingEngine.shared.resetBuffers()
                    field.stringValue = ""
                    win.makeFirstResponder(field)
                    _ = LayoutManager.shared.selectLanguage(tc.startLang)
                }
                usleep(200_000)

                // Send REAL physical key events (without syntheticTag!) so CGEventTap processes them identically to human typing
                let src = CGEventSource(stateID: .privateState)
                for kc in tc.keyCodes {
                    if let down = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true) {
                        down.flags = []
                        down.post(tap: .cghidEventTap)
                    }
                    usleep(12_000)
                    if let up = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false) {
                        up.flags = []
                        up.post(tap: .cghidEventTap)
                    }
                    usleep(65_000) // ~180 WPM human typing cadence
                }

                usleep(250_000)
                var actualText = ""
                var actualLang: SwitchLang? = nil
                DispatchQueue.main.sync {
                    actualText = field.stringValue
                    actualLang = LayoutManager.shared.currentLanguage()
                }

                if actualText == tc.expectedText && actualLang == tc.expectedLang {
                    passed += 1
                    print("PASS [\(tc.name)]: text='\(actualText)' lang=\(actualLang?.rawValue ?? "nil")")
                } else {
                    failed += 1
                    print("FAIL [\(tc.name)]: expected text='\(tc.expectedText)' (\(tc.expectedLang.rawValue)), got text='\(actualText)' (\(actualLang?.rawValue ?? "nil"))")
                }
            }

            DispatchQueue.main.sync {
                _ = LayoutManager.shared.selectLanguage(origLang)
                TypingEngine.shared.stop()
                win.close()
                print("E2E Summary: \(passed) passed, \(failed) failed out of \(cases.count)")
                exit(failed == 0 ? 0 : 1)
            }
        }

        app.run()
    }
}
