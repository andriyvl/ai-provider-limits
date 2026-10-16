import Observation
import SwiftUI
import ProviderLimitsCore

@MainActor
@Observable
final class MenuBarState {
    private let defaults: UserDefaults
    private let store: AppGroupStore
    let engine: SyncEngine

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

    var selections: [ProviderType: CredentialSelection] = [:]
    var discoveries: [ProviderType: CredentialDiscovery] = [:]
    var lastSuccessfulProvenances: [ProviderType: UsageProvenance] = [:]
    var isScanning = false

    private var providerEpochs: [ProviderType: UInt64] = [:]
    private var scanGenerations: [ProviderType: UInt64] = [:]

    init(
        defaults: UserDefaults = .standard,
        store: AppGroupStore = .shared,
        engine: SyncEngine
    ) {
        self.defaults = defaults
        self.store = store
        self.engine = engine
        providerOrder = store.loadProviderOrder()
        showAntigravity = defaults.object(forKey: "showAntigravity") as? Bool ?? true
        showCodex = defaults.object(forKey: "showCodex") as? Bool ?? true
        showCursor = defaults.object(forKey: "showCursor") as? Bool ?? true
        showClaude = defaults.object(forKey: "showClaude") as? Bool ?? false
        showOpenRouter = defaults.object(forKey: "showOpenRouter") as? Bool ?? false
        snapshots = [:]

        selections = store.loadCredentialSelections()
        for provider in ProviderType.allCases where selections[provider] == nil {
            selections[provider] = .automatic
        }
    }

    func loadCachedSnapshots() async {
        var preEpochs: [ProviderType: UInt64] = [:]
        for provider in ProviderType.allCases {
            preEpochs[provider] = providerEpochs[provider, default: 0]
        }

        let cached = await engine.allCachedSnapshots()

        for (provider, snap) in cached {
            let preEpoch = preEpochs[provider, default: 0]
            let curEpoch = providerEpochs[provider, default: 0]
            guard preEpoch == curEpoch else { continue }

            if snapshots[provider] == nil {
                snapshots[provider] = snap
            }
            if let prov = snap.provenance, lastSuccessfulProvenances[provider] == nil {
                lastSuccessfulProvenances[provider] = prov
            }
        }
    }

    func currentSelection(for provider: ProviderType) -> CredentialSelection {
        selections[provider] ?? .automatic
    }

    func discovery(for provider: ProviderType) -> CredentialDiscovery? {
        discoveries[provider]
    }

    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        var generations: [ProviderType: UInt64] = [:]
        for provider in ProviderType.allCases {
            scanGenerations[provider, default: 0] += 1
            generations[provider] = scanGenerations[provider, default: 0]
        }

        for provider in ProviderType.allCases {
            let disc = await engine.discoverCredentials(for: provider)
            if scanGenerations[provider, default: 0] == generations[provider] {
                discoveries[provider] = disc
            }
        }
    }

    func rescan(for provider: ProviderType) async {
        scanGenerations[provider, default: 0] += 1
        let curGen = scanGenerations[provider, default: 0]
        let disc = await engine.discoverCredentials(for: provider)
        if scanGenerations[provider, default: 0] == curGen {
            discoveries[provider] = disc
        }
    }

    @discardableResult
    func selectCredentialSelection(_ selection: CredentialSelection, for provider: ProviderType) -> UInt64 {
        snapshots.removeValue(forKey: provider)
        selections[provider] = selection
        providerEpochs[provider, default: 0] += 1
        return providerEpochs[provider, default: 0]
    }

    func setCredentialSelection(_ selection: CredentialSelection, for provider: ProviderType) async {
        let epoch = selectCredentialSelection(selection, for: provider)
        await completeCredentialSelection(selection, for: provider, epoch: epoch)
    }

    func completeCredentialSelection(_ selection: CredentialSelection, for provider: ProviderType, epoch: UInt64) async {
        await engine.setCredentialSelection(selection, for: provider)

        guard providerEpochs[provider, default: 0] == epoch else { return }

        do {
            let snapshot = try await engine.refresh(provider: provider)
            guard providerEpochs[provider, default: 0] == epoch else { return }
            snapshots[provider] = snapshot
            if let prov = snapshot.provenance {
                lastSuccessfulProvenances[provider] = prov
            }
        } catch {
            guard providerEpochs[provider, default: 0] == epoch else { return }
            let cached = await engine.cachedSnapshot(for: provider)
            guard providerEpochs[provider, default: 0] == epoch else { return }
            if let cached {
                snapshots[provider] = cached
                if let prov = cached.provenance {
                    lastSuccessfulProvenances[provider] = prov
                }
            } else {
                snapshots.removeValue(forKey: provider)
            }
        }
    }

    func refresh(provider: ProviderType) async {
        providerEpochs[provider, default: 0] += 1
        let currentEpoch = providerEpochs[provider, default: 0]

        do {
            let snapshot = try await engine.refresh(provider: provider)
            guard providerEpochs[provider, default: 0] == currentEpoch else { return }
            snapshots[provider] = snapshot
            if let prov = snapshot.provenance {
                lastSuccessfulProvenances[provider] = prov
            }
        } catch {
            guard providerEpochs[provider, default: 0] == currentEpoch else { return }
            let cached = await engine.cachedSnapshot(for: provider)
            guard providerEpochs[provider, default: 0] == currentEpoch else { return }
            if let cached {
                snapshots[provider] = cached
                if let prov = cached.provenance {
                    lastSuccessfulProvenances[provider] = prov
                }
            } else {
                snapshots.removeValue(forKey: provider)
            }
        }
    }

    func applyRefreshAll(results: [ProviderType: ProviderUsageSnapshot], capturedEpochs: [ProviderType: UInt64]) {
        for (provider, snapshot) in results {
            let recordedEpoch = capturedEpochs[provider, default: 0]
            let currentEpoch = providerEpochs[provider, default: 0]
            if recordedEpoch == currentEpoch {
                snapshots[provider] = snapshot
                if let prov = snapshot.provenance {
                    lastSuccessfulProvenances[provider] = prov
                }
            }
        }
    }

    func captureEpochs() -> [ProviderType: UInt64] {
        var copy: [ProviderType: UInt64] = [:]
        for provider in ProviderType.allCases {
            copy[provider] = providerEpochs[provider, default: 0]
        }
        return copy
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
            state: state,
            openExternalURL: openExternalURL
        )
    }
}
