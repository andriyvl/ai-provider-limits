import AppKit
import SwiftUI
import ProviderLimitsCore

@main
struct MenuBarHostApp: App {
    @State private var engine = SyncEngine()
    @State private var snapshots: [ProviderType: ProviderUsageSnapshot] = AppGroupStore.shared.loadSnapshots()
    @State private var isRefreshing = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                snapshots: snapshots,
                isRefreshing: isRefreshing,
                onRefresh: {
                    Task {
                        await refreshAll()
                    }
                }
            )
            .task {
                await refreshAll()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    await refreshAll()
                }
            }
        } label: {
            Self.menuBarIcon
                .accessibilityLabel("AI Limits")
        }
        .menuBarExtraStyle(.window)
    }

    private static let menuBarIcon: Image = {
        if let icon = Bundle.main.image(forResource: "MenuBarIcon") {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true
            return Image(nsImage: icon)
        }

        let candidates = [
            Bundle.main.url(forResource: "MenuBarIcon", withExtension: "tiff"),
            Bundle.main.url(forResource: "MenuBarIcon@2x", withExtension: "png"),
            Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png")
        ]

        for case let url? in candidates {
            if let icon = NSImage(contentsOf: url) {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = true
                return Image(nsImage: icon)
            }
        }

        return Image(systemName: "circle")
    }()

    private func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let results = await engine.refreshAll()
        if !results.isEmpty {
            snapshots = results
        }
        isRefreshing = false
    }
}
