import AppKit
import ProviderLimitsCore

@main
struct MenuBarHostApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let engine = SyncEngine()
        let controller = MenuBarController(
            state: MenuBarState(),
            refreshSnapshots: { await engine.refreshAll() }
        )
        app.delegate = controller
        withExtendedLifetime(controller) {
            app.run()
        }
    }
}
