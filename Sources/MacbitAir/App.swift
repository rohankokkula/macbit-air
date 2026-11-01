import AppKit

@main
enum MacbitAirMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar menu
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: HealthStore!
    private var notch: NotchController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppConfig.ensureTemplate()
        let auth = GoogleAuth()
        store = HealthStore(auth: auth)

        guard let current = NotchGeometry.current() else { return }
        let model = NotchModel(geometry: current.1)
        notch = NotchController(model: model, store: store)
        notch.show()
        store.start()
    }
}
