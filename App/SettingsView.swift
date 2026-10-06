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
                    ProvidersSettingsSection(providerOrder: $providerOrder, visibility: binding(for:))
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

    var body: some View {
        Form {
            Section {
                ForEach(providerOrder, id: \.self) { provider in
                    ProviderSettingsRow(
                        provider: provider,
                        isEnabled: visibility(provider),
                        canMoveUp: provider != providerOrder.first,
                        canMoveDown: provider != providerOrder.last,
                        onMoveUp: { move(provider, offset: -1) },
                        onMoveDown: { move(provider, offset: 1) }
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

    var body: some View {
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
    }
}
