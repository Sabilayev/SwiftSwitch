import Cocoa

if CommandLine.arguments.contains("--e2e-test") {
    SelfTestRunner.run()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // Menu bar only, no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
