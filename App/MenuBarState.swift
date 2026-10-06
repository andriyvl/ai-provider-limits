import Observation
import SwiftUI
import ProviderLimitsCore

@MainActor
@Observable
final class MenuBarState {
    private let defaults: UserDefaults
    private let store: AppGroupStore

    var providerOrder: [ProviderType] {
        didSet {
            guard providerOrder != oldValue else { return }
            store.saveProviderOrder(providerOrder)
        }
    }

    var showAntigravity: Bool {
        didSet {
            guard showAntigravity != oldValue else { return }
            defaults.set(showAntigravity, forKey: "showAntigravity")
        }
    }

    var showCodex: Bool {
        didSet {
            guard showCodex != oldValue else { return }
            defaults.set(showCodex, forKey: "showCodex")
        }
    }

    var showCursor: Bool {
        didSet {
            guard showCursor != oldValue else { return }
            defaults.set(showCursor, forKey: "showCursor")
        }
    }

    var showClaude: Bool {
        didSet {
            guard showClaude != oldValue else { return }
            defaults.set(showClaude, forKey: "showClaude")
        }
    }

    var showOpenRouter: Bool {
        didSet {
            guard showOpenRouter != oldValue else { return }
            defaults.set(showOpenRouter, forKey: "showOpenRouter")
        }
    }

    var snapshots: [ProviderType: ProviderUsageSnapshot]
    var isRefreshing = false

    init(defaults: UserDefaults = .standard, store: AppGroupStore = .shared) {
        self.defaults = defaults
        self.store = store
        providerOrder = store.loadProviderOrder()
        showAntigravity = defaults.object(forKey: "showAntigravity") as? Bool ?? true
        showCodex = defaults.object(forKey: "showCodex") as? Bool ?? true
        showCursor = defaults.object(forKey: "showCursor") as? Bool ?? true
        showClaude = defaults.object(forKey: "showClaude") as? Bool ?? false
        showOpenRouter = defaults.object(forKey: "showOpenRouter") as? Bool ?? false
        snapshots = [:]
    }

    func loadCachedSnapshots() async {
        let store = store
        let cached = await Task.detached {
            store.loadSnapshots()
        }.value
        if snapshots.isEmpty {
            snapshots = cached
        }
    }
}

@MainActor
struct MenuBarPanelRoot: View {
    let state: MenuBarState
    let onOpenSettings: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        MenuBarContentView(
            snapshots: state.snapshots,
            isRefreshing: state.isRefreshing,
            providerOrder: state.providerOrder,
            showAntigravity: state.showAntigravity,
            showCodex: state.showCodex,
            showCursor: state.showCursor,
            showClaude: state.showClaude,
            showOpenRouter: state.showOpenRouter,
            onOpenSettings: onOpenSettings,
            onRefresh: onRefresh
        )
    }
}

@MainActor
struct SettingsRoot: View {
    @Bindable var state: MenuBarState
    let openExternalURL: (URL) -> Bool

    var body: some View {
        SettingsView(
            providerOrder: $state.providerOrder,
            showAntigravity: $state.showAntigravity,
            showCodex: $state.showCodex,
            showCursor: $state.showCursor,
            showClaude: $state.showClaude,
            showOpenRouter: $state.showOpenRouter,
            openExternalURL: openExternalURL
        )
    }
}
