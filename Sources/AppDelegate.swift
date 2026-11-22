import Cocoa
import Carbon
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var permissionTimer: Timer?

    private let launchAgentPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents/com.swiftswitch.app.plist")

    // UserDefaults keys
    private let kAutoSwitch = "autoSwitchEnabled"
    private let kOnTheFly = "onTheFlyEnabled"
    private let kDoubleShift = "doubleRightShiftEnabled"
    private let kOptionSpace = "optionSpaceEnabled"
    private let kSound = "soundEnabled"
    private let kExcluded = "excludedBundleIDs"

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadPreferences()
        setupStatusBar()
        observeLayoutChanges()

        TypingEngine.shared.onLayoutChanged = { [weak self] lang in
            DispatchQueue.main.async {
                self?.updateBadge(lang: lang)
            }
        }

        if AXIsProcessTrusted() {
            TypingEngine.shared.start()
            updateBadge()
        } else {
            requestAccessibilityPermission()
            startPermissionWatcher()
            updateBadge()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TypingEngine.shared.stop()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateBadge()
    }

    private func updateBadge(lang: SwitchLang? = nil) {
        guard let button = statusItem.button else { return }
        let current = lang ?? LayoutManager.shared.currentLanguage()
        let code = current?.badge ?? "SW"

        if !AXIsProcessTrusted() {
            button.title = "⚠ \(code)"
        } else if !TypingEngine.shared.isAutoSwitchEnabled {
            button.title = "(\(code))"
        } else {
            button.title = code
        }
        button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    }

    private func observeLayoutChanges() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceDidChange),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
    }

    @objc private func inputSourceDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.updateBadge()
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Accessibility warning if needed
        if !AXIsProcessTrusted() {
            let warn = NSMenuItem(title: "⚠ Нужен доступ «Универсальный доступ»", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(NSMenuItem.separator())
        } else if !TypingEngine.shared.isRunning {
            TypingEngine.shared.start()
        }

        // Toggle Auto-Switch
        let autoItem = NSMenuItem(title: "Автопереключение (RU ↔ EN)", action: #selector(toggleAutoSwitch), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = TypingEngine.shared.isAutoSwitchEnabled ? .on : .off
        menu.addItem(autoItem)

        // Toggle On-The-Fly (Punto-style)
        let flyItem = NSMenuItem(title: "Переключать на лету (как Punto)", action: #selector(toggleOnTheFly), keyEquivalent: "")
        flyItem.target = self
        flyItem.state = TypingEngine.shared.isOnTheFlyEnabled ? .on : .off
        flyItem.isEnabled = TypingEngine.shared.isAutoSwitchEnabled
        menu.addItem(flyItem)

        // Manual switch hint/action
        let manualItem = NSMenuItem(title: "Исправить слово / выделение (⌥Space)", action: #selector(toggleOptionSpace), keyEquivalent: "")
        manualItem.target = self
        manualItem.state = TypingEngine.shared.isOptionSpaceEnabled ? .on : .off
        menu.addItem(manualItem)

        let shiftItem = NSMenuItem(title: "Двойной правый Shift для исправления", action: #selector(toggleDoubleShift), keyEquivalent: "")
        shiftItem.target = self
        shiftItem.state = TypingEngine.shared.isDoubleRightShiftEnabled ? .on : .off
        menu.addItem(shiftItem)

        let soundItem = NSMenuItem(title: "Звук при переключении", action: #selector(toggleSound), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = TypingEngine.shared.isSoundEnabled ? .on : .off
        menu.addItem(soundItem)

        menu.addItem(NSMenuItem.separator())

        // Exclude frontmost app
        if let app = NSWorkspace.shared.frontmostApplication,
           let bid = app.bundleIdentifier,
           bid != Bundle.main.bundleIdentifier {
            let appName = app.localizedName ?? bid
            let isExcluded = TypingEngine.shared.excludedBundleIDs.contains(bid)
            let exclItem = NSMenuItem(
                title: isExcluded ? "Включить автопереключение в «\(appName)»" : "Отключить в «\(appName)»",
                action: #selector(toggleExcludeCurrentApp(_:)),
                keyEquivalent: ""
            )
            exclItem.representedObject = bid
            exclItem.target = self
            menu.addItem(exclItem)
        }

        // Launch at login
        let loginItem = NSMenuItem(title: "Запускать при входе в систему", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = FileManager.default.fileExists(atPath: launchAgentPath) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        let hintItem = NSMenuItem(title: "Esc после автозамены — отменить", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Выход из SwiftSwitch", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func toggleAutoSwitch() {
        TypingEngine.shared.isAutoSwitchEnabled.toggle()
        UserDefaults.standard.set(TypingEngine.shared.isAutoSwitchEnabled, forKey: kAutoSwitch)
        updateBadge()
    }

    @objc private func toggleOnTheFly() {
        TypingEngine.shared.isOnTheFlyEnabled.toggle()
        UserDefaults.standard.set(TypingEngine.shared.isOnTheFlyEnabled, forKey: kOnTheFly)
    }

    @objc private func toggleOptionSpace() {
        TypingEngine.shared.isOptionSpaceEnabled.toggle()
        UserDefaults.standard.set(TypingEngine.shared.isOptionSpaceEnabled, forKey: kOptionSpace)
    }

    @objc private func toggleDoubleShift() {
        TypingEngine.shared.isDoubleRightShiftEnabled.toggle()
        UserDefaults.standard.set(TypingEngine.shared.isDoubleRightShiftEnabled, forKey: kDoubleShift)
    }

    @objc private func toggleSound() {
        TypingEngine.shared.isSoundEnabled.toggle()
        UserDefaults.standard.set(TypingEngine.shared.isSoundEnabled, forKey: kSound)
    }

    @objc private func toggleExcludeCurrentApp(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        if TypingEngine.shared.excludedBundleIDs.contains(bid) {
            TypingEngine.shared.excludedBundleIDs.remove(bid)
        } else {
            TypingEngine.shared.excludedBundleIDs.insert(bid)
        }
        UserDefaults.standard.set(Array(TypingEngine.shared.excludedBundleIDs), forKey: kExcluded)
    }

    @objc private func toggleLaunchAtLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: launchAgentPath) {
            try? fm.removeItem(atPath: launchAgentPath)
        } else {
            let execPath = Bundle.main.executablePath ?? "/Applications/SwiftSwitch.app/Contents/MacOS/SwiftSwitch"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.swiftswitch.app</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(execPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
            let dir = (launchAgentPath as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Preferences & Permissions

    private func loadPreferences() {
        let ud = UserDefaults.standard
        if ud.object(forKey: kAutoSwitch) != nil {
            TypingEngine.shared.isAutoSwitchEnabled = ud.bool(forKey: kAutoSwitch)
        }
        if ud.object(forKey: kOnTheFly) != nil {
            TypingEngine.shared.isOnTheFlyEnabled = ud.bool(forKey: kOnTheFly)
        }
        if ud.object(forKey: kDoubleShift) != nil {
            TypingEngine.shared.isDoubleRightShiftEnabled = ud.bool(forKey: kDoubleShift)
        }
        if ud.object(forKey: kOptionSpace) != nil {
            TypingEngine.shared.isOptionSpaceEnabled = ud.bool(forKey: kOptionSpace)
        }
        if ud.object(forKey: kSound) != nil {
            TypingEngine.shared.isSoundEnabled = ud.bool(forKey: kSound)
        }
        if let arr = ud.stringArray(forKey: kExcluded) {
            TypingEngine.shared.excludedBundleIDs = Set(arr)
        }
    }

    private func requestAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func startPermissionWatcher() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.permissionTimer = nil
                TypingEngine.shared.start()
                self?.updateBadge()
            }
        }
    }
}
