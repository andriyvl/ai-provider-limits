import AppKit
import ProviderLimitsCore

@main
struct MenuBarHostApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let engine = SyncEngine()
        let state = MenuBarState(engine: engine)
        let controller = MenuBarController(
            state: state,
            refreshSnapshots: { await engine.refreshAll() }
        )
        app.delegate = controller
        withExtendedLifetime(controller) {
            app.run()
        }
    }
}
