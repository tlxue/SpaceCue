import AppKit

@main
enum Launcher {
    static func main() {
        SpaceCueLog.write("main start")

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        SpaceCueLog.write("app run")
        app.run()

        _ = delegate
    }
}
