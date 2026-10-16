import AppKit
import SwiftUI
import ProviderLimitsCore

struct SettingsView: View {
    @Binding var providerOrder: [ProviderType]
    @Binding var showAntigravity: Bool
    @Binding var showCodex: Bool
    @Binding var showCursor: Bool
    @Binding var showClaude: Bool
    @Binding var showOpenRouter: Bool
    var state: MenuBarState
    var openExternalURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    @State private var selection: SettingsSection? = .providers

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selection ?? .providers {
                case .providers:
                    ProvidersSettingsSection(
                        providerOrder: $providerOrder,
                        visibility: binding(for:),
                        state: state
                    )
                case .about:
                    AboutSettingsSection(openExternalURL: openExternalURL)
                }
            }
            .navigationTitle((selection ?? .providers).title)
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private func binding(for provider: ProviderType) -> Binding<Bool> {
        switch provider {
        case .antigravity: return $showAntigravity
        case .codex: return $showCodex
        case .cursor: return $showCursor
        case .claude: return $showClaude
        case .openRouter: return $showOpenRouter
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case providers
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .providers: return "Providers"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .providers: return "square.stack.3d.up"
        case .about: return "info.circle"
        }
    }
}

private struct ProvidersSettingsSection: View {
    @Binding var providerOrder: [ProviderType]
    let visibility: (ProviderType) -> Binding<Bool>
    var state: MenuBarState

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Credential Discovery")
                            .font(.headline)
                        Text("Detect local tools, files, and environment keys without network requests.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task {
                            await state.rescan()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if state.isScanning {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("Rescan")
                        }
                    }
                    .accessibilityIdentifier("rescan-button")
                    .disabled(state.isScanning)
                }
                .padding(.vertical, 4)
            }

            Section {
                ForEach(providerOrder, id: \.self) { provider in
                    ProviderSettingsRow(
                        provider: provider,
                        isEnabled: visibility(provider),
                        canMoveUp: provider != providerOrder.first,
                        canMoveDown: provider != providerOrder.last,
                        onMoveUp: { move(provider, offset: -1) },
                        onMoveDown: { move(provider, offset: 1) },
                        state: state
                    )
                }
            } header: {
                Text("Menu bar cards")
            } footer: {
                Text(
                    "Choose which providers appear and arrange their order. "
                    + "Cards appear only when a provider is active."
                )
            }
        }
        .formStyle(.grouped)
        .task {
            if state.discoveries.isEmpty {
                await state.rescan()
            }
        }
    }

    private func move(_ provider: ProviderType, offset: Int) {
        guard let index = providerOrder.firstIndex(of: provider) else { return }
        let destination = index + offset
        guard providerOrder.indices.contains(destination) else { return }
        providerOrder.swapAt(index, destination)
    }
}

private struct ProviderSettingsRow: View {
    let provider: ProviderType
    @Binding var isEnabled: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    var state: MenuBarState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack {
                    Button("Move \(provider.displayName) up", systemImage: "chevron.up", action: onMoveUp)
                        .labelStyle(.iconOnly)
                        .disabled(!canMoveUp)
                        .accessibilityLabel("Move \(provider.displayName) up")
                        .help("Move \(provider.displayName) up")

                    Button("Move \(provider.displayName) down", systemImage: "chevron.down", action: onMoveDown)
                        .labelStyle(.iconOnly)
                        .disabled(!canMoveDown)
                        .accessibilityLabel("Move \(provider.displayName) down")
                        .help("Move \(provider.displayName) down")
                }
                .buttonStyle(.borderless)

                Toggle(isOn: $isEnabled) {
                    HStack {
                        ProviderLogoView(
                            provider: provider,
                            size: 20,
                            renderingMode: provider == .openRouter ? .template : nil
                        )
                        .foregroundStyle(provider == .openRouter ? LiquidGlassTheme.openRouterBrand : .primary)
                        Text(provider.displayName)
                            .foregroundStyle(isEnabled ? .primary : .secondary)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityLabel("Show \(provider.displayName)")
            }

            Divider()
                .padding(.vertical, 2)
            ProviderSourceControlsView(provider: provider, state: state)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-row-\(provider.rawValue)")
    }
}

private struct ProviderSourceControlsView: View {
    let provider: ProviderType
    let state: MenuBarState

    private var currentSelection: CredentialSelection {
        state.currentSelection(for: provider)
    }

    private var discovery: CredentialDiscovery? {
        state.discovery(for: provider)
    }

    private var selectedSourceID: String? {
        switch currentSelection {
        case .automatic:
            return nil
        case .source(let sourceID, _):
            return sourceID
        }
    }

    private var selectedAccountID: String? {
        switch currentSelection {
        case .automatic:
            return nil
        case .source(_, let accountID):
            return accountID
        }
    }

    private var selectedSourceDescriptor: CredentialSourceDescriptor? {
        guard let selectedSourceID else { return nil }
        return discovery?.sources.first { $0.id == selectedSourceID }
    }

    private var isMissingSource: Bool {
        if case .source(let sourceID, _) = currentSelection {
            if let discovery {
                return !discovery.sources.contains { $0.id == sourceID }
            }
        }
        return false
    }

    private var isMissingAccount: Bool {
        if case .source(let sourceID, let accountID) = currentSelection, let accountID {
            if let source = discovery?.sources.first(where: { $0.id == sourceID }) {
                return !source.accounts.contains { $0.reference.accountID == accountID }
            }
            return true
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text("Credential Source")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)

                Picker("", selection: Binding<String?>(
                    get: { selectedSourceID },
                    set: { newSourceID in
                        let selection: CredentialSelection
                        if let newSourceID {
                            selection = .source(newSourceID, accountID: nil)
                        } else {
                            selection = .automatic
                        }
                        let epoch = state.selectCredentialSelection(selection, for: provider)
                        Task {
                            await state.completeCredentialSelection(selection, for: provider, epoch: epoch)
                        }
                    }
                )) {
                    Text("Automatic").tag(nil as String?)

                    if let sources = discovery?.sources {
                        ForEach(sources, id: \.id) { source in
                            Text(source.label).tag(source.id as String?)
                        }
                    }

                    if isMissingSource, case .source(let missingID, _) = currentSelection {
                        Text(safeMissingSourceLabel(missingID)).tag(missingID as String?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityIdentifier("source-picker-\(provider.rawValue)")
            }

            if case .source(let sourceID, let pinnedAccountID) = currentSelection {
                let sourceDesc = discovery?.sources.first(where: { $0.id == sourceID })
                let accounts = sourceDesc?.accounts ?? []

                if !accounts.isEmpty || pinnedAccountID != nil {
                    HStack(alignment: .center, spacing: 12) {
                        Text("Account")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .leading)

                        Picker("", selection: Binding<String?>(
                            get: { selectedAccountID },
                            set: { newAccountID in
                                let selection = CredentialSelection.source(sourceID, accountID: newAccountID)
                                let epoch = state.selectCredentialSelection(selection, for: provider)
                                Task {
                                    await state.completeCredentialSelection(selection, for: provider, epoch: epoch)
                                }
                            }
                        )) {
                            Text("Automatic account").tag(nil as String?)
                            ForEach(accounts, id: \.reference.accountID) { account in
                                Text(account.label).tag(account.reference.accountID as String?)
                            }
                            if isMissingAccount, let missingAccID = pinnedAccountID {
                                Text(safeMissingAccountLabel(missingAccID)).tag(missingAccID as String?)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityIdentifier("account-picker-\(provider.rawValue)")
                    }
                }
            }

            if isMissingSource || isMissingAccount {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(LiquidGlassTheme.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Configured credential source or account is not currently found.")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(LiquidGlassTheme.warning)
                        Text("Sign in through the owning tool or switch back to Automatic.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityIdentifier("missing-selection-\(provider.rawValue)")
            }

            if let sourceDesc = selectedSourceDescriptor {
                HStack(alignment: .center, spacing: 12) {
                    Text("Location")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text(sourceDesc.location)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("source-location-\(provider.rawValue)")
                }

                HStack(alignment: .center, spacing: 12) {
                    Text("Local Status")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor(sourceDesc.status))
                            .frame(width: 7, height: 7)
                        Text(statusDescription(sourceDesc.status))
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    .accessibilityIdentifier("source-status-\(provider.rawValue)")
                }

                if sourceDesc.accounts.isEmpty && sourceDesc.status == .availableLocally {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Source provides transient usage without stable saved account identity.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
            } else if selectedSourceID == nil, let discovery, !discovery.sources.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Discovered Local Sources")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    ForEach(discovery.sources, id: \.id) { source in
                        HStack(alignment: .center, spacing: 8) {
                            Circle()
                                .fill(statusColor(source.status))
                                .frame(width: 6, height: 6)
                            Text(source.label)
                                .font(.caption.weight(.medium))
                            Text(source.location)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(statusDescription(source.status))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("source-status-\(provider.rawValue)")
            }

            let lastProvenance = state.snapshots[provider]?.provenance ?? state.lastSuccessfulProvenances[provider]
            if let lastProvenance {
                HStack(alignment: .center, spacing: 12) {
                    Text("Last successful data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    HStack(spacing: 6) {
                        Text(lastProvenance.displayLabel)
                            .font(.caption.weight(.medium))
                        Text("(\(lastProvenance.origin.rawValue))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("last-provenance-\(provider.rawValue)")
                }
            }
        }
        .padding(.leading, 32)
        .padding(.vertical, 4)
    }

    private func statusColor(_ status: CredentialSourceStatus) -> Color {
        switch status {
        case .availableLocally:
            return LiquidGlassTheme.accent
        case .missing:
            return LiquidGlassTheme.textMuted
        case .unreadable, .unsupportedFormat:
            return LiquidGlassTheme.danger
        case .expired:
            return LiquidGlassTheme.warning
        case .disabled:
            return LiquidGlassTheme.textDim
        }
    }

    private func statusDescription(_ status: CredentialSourceStatus) -> String {
        switch status {
        case .availableLocally:
            return "Available locally"
        case .missing:
            return "Missing"
        case .unreadable:
            return "Unreadable (permission / I/O)"
        case .unsupportedFormat:
            return "Unsupported format"
        case .expired:
            return "Expired"
        case .disabled:
            return "Disabled"
        }
    }

    private func safeMissingSourceLabel(_ id: String) -> String {
        let knownSources = [
            "native.antigravity-ide": "Native Antigravity IDE",
            "omp.agent-db": "Oh My Pi SQLite",
            "native.codex-auth": "Native Codex Auth",
            "pi.auth-json": "Pi Auth JSON",
            "native.claude-credentials": "Native Claude Credentials",
            "native.cursor-state": "Native Cursor State",
            "process.openrouter-key": "Environment Variable"
        ]
        if let known = knownSources[id] {
            return "\(known) (Missing)"
        }
        return "Configured source (Unavailable)"
    }

    private func safeMissingAccountLabel(_ id: String) -> String {
        if id.count > 64 || id.contains("\n") || id.contains(" ") {
            return "Configured account (Unavailable)"
        }
        return "\(id) (Missing)"
    }
}
