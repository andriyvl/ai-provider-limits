import SwiftUI
import ProviderLimitsCore
#if os(macOS)
import AppKit
#endif

public struct MenuBarContentView: View {
    public let snapshots: [ProviderType: ProviderUsageSnapshot]
    public let isRefreshing: Bool
    public let onRefresh: () -> Void
    @State private var showingSettings = false
    @AppStorage("showAntigravity") private var showAntigravity = true
    @AppStorage("showCodex") private var showCodex = true
    @AppStorage("showCursor") private var showCursor = true
    @AppStorage("showClaude") private var showClaude = false
    @State private var providerOrder: [ProviderType] = AppGroupStore.shared.loadProviderOrder()
    @State private var isAttributionHovered = false
    public init(
        snapshots: [ProviderType: ProviderUsageSnapshot],
        isRefreshing: Bool,
        onRefresh: @escaping () -> Void
    ) {
        self.snapshots = snapshots
        self.isRefreshing = isRefreshing
        self.onRefresh = onRefresh
    }

    public var body: some View {
        Group {
            if showingSettings {
                settingsView
            } else {
                VStack(spacing: 0) {
                    headerBar
                    mainCardList
                }
            }
        }
        .frame(width: 360, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(LiquidGlassTheme.panelBackground)
        .preferredColorScheme(.dark)
        .background(MenuBarWindowChrome())
    }

    private var mainCardList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                if visibleSnapshots.isEmpty {
                    VStack(spacing: 8) {
                        Text("No Active Providers")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LiquidGlassTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 140)
                } else {
                    ForEach(visibleSnapshots, id: \.id) { snapshot in
                        ProviderWidgetView(snapshot: snapshot, size: .medium, isCard: true)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 14)
        }
        .frame(maxHeight: maxScrollHeight)
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage Providers")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LiquidGlassTheme.textPrimary)

                    Text("Toggle cards and arrange their order.")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(LiquidGlassTheme.textSecondary)
                }

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showingSettings = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LiquidGlassTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 2)

            VStack(spacing: 7) {
                ForEach(Array(providerOrder.enumerated()), id: \.element) { index, provider in
                    providerSettingsRow(provider: provider, index: index, totalCount: providerOrder.count)
                }
            }

            HStack(spacing: 4) {
                Spacer()
                Text("Created by")
                    .foregroundStyle(LiquidGlassTheme.textDim)
                Link(destination: URL(string: "https://github.com/andriyvl")!) {
                    HStack(spacing: 2) {
                        Text("Andriy Viychuk (@andriyvl)")
                            .foregroundStyle(
                                isAttributionHovered ? LiquidGlassTheme.textPrimary : LiquidGlassTheme.textSecondary
                            )
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(
                                isAttributionHovered ? LiquidGlassTheme.accent : LiquidGlassTheme.textDim
                            )
                    }
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isAttributionHovered = hovering
                    }
                }
                Spacer()
            }
            .font(.system(size: 10, weight: .regular))
            .padding(.top, 4)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    private var maxScrollHeight: CGFloat {
        #if os(macOS)
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return min(640, max(300, screenHeight - 100))
        #else
        return 640
        #endif
    }

    private func providerSettingsRow(provider: ProviderType, index: Int, totalCount: Int) -> some View {
        let canMoveUp = index > 0
        let canMoveDown = index < totalCount - 1
        let isEnabled = isProviderEnabled(provider)

        return HStack(spacing: 9) {
            reorderButtons(provider: provider, canMoveUp: canMoveUp, canMoveDown: canMoveDown)
            ProviderLogoView(provider: provider, size: 15)
            Text(provider.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? LiquidGlassTheme.textPrimary : LiquidGlassTheme.textDim)
            Spacer()
            Toggle("", isOn: binding(for: provider))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(LiquidGlassTheme.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .liquidGlassRow(cornerRadius: 8, fill: LiquidGlassTheme.rowBackground(for: provider))
    }

    private func reorderButtons(provider: ProviderType, canMoveUp: Bool, canMoveDown: Bool) -> some View {
        HStack(spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    moveProvider(provider, moveUp: true)
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(canMoveUp ? LiquidGlassTheme.textSecondary : LiquidGlassTheme.textDim.opacity(0.2))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(canMoveUp ? 0.06 : 0.01)))
            }
            .buttonStyle(.plain)
            .disabled(!canMoveUp)

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    moveProvider(provider, moveUp: false)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(
                        canMoveDown ? LiquidGlassTheme.textSecondary : LiquidGlassTheme.textDim.opacity(0.2)
                    )
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(canMoveDown ? 0.06 : 0.01)))
            }
            .buttonStyle(.plain)
            .disabled(!canMoveDown)
        }
    }

    private func isProviderEnabled(_ provider: ProviderType) -> Bool {
        switch provider {
        case .antigravity: return showAntigravity
        case .codex: return showCodex
        case .cursor: return showCursor
        case .claude: return showClaude
        }
    }

    private func binding(for provider: ProviderType) -> Binding<Bool> {
        switch provider {
        case .antigravity: return $showAntigravity
        case .codex: return $showCodex
        case .cursor: return $showCursor
        case .claude: return $showClaude
        }
    }

    private func moveProvider(_ provider: ProviderType, moveUp: Bool) {
        var list = providerOrder
        guard let index = list.firstIndex(of: provider) else { return }
        let newIndex = moveUp ? index - 1 : index + 1
        guard newIndex >= 0 && newIndex < list.count else { return }
        list.swapAt(index, newIndex)
        providerOrder = list
        AppGroupStore.shared.saveProviderOrder(list)
    }

    private var visibleSnapshots: [ProviderUsageSnapshot] {
        var list: [ProviderUsageSnapshot] = []
        for provider in providerOrder {
            guard isProviderEnabled(provider) else { continue }
            let snap = snapshots[provider] ?? ProviderUsageSnapshot.empty(for: provider)
            if snap.isActive {
                list.append(snap)
            }
        }
        return list
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Spacer()

            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: showingSettings ? "xmark" : "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(showingSettings ? LiquidGlassTheme.textPrimary : LiquidGlassTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(showingSettings ? 0.12 : 0.06))
                    )
            }
            .buttonStyle(.plain)

            Button(action: onRefresh) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isRefreshing)) { context in
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LiquidGlassTheme.textSecondary)
                        .rotationEffect(.degrees(isRefreshing ? refreshAngle(at: context.date) : 0))
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.06))
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)

            Button {
                #if os(macOS)
                NSApplication.shared.terminate(nil)
                #endif
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LiquidGlassTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func refreshAngle(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0) * 360.0
    }
}

#if os(macOS)
private struct MenuBarWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.applyChrome(on: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.applyChrome(on: nsView.window)
        }
    }

    private static let panelColor = NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.15, alpha: 1)

    private static func applyChrome(on window: NSWindow?) {
        guard let window else { return }

        window.isOpaque = true
        window.hasShadow = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = panelColor
        window.appearance = NSAppearance(named: .darkAqua)

        guard let content = window.contentView else { return }
        content.wantsLayer = true
        content.layer?.borderWidth = 0
        content.layer?.borderColor = NSColor.clear.cgColor

        var ancestor = content.superview
        while let view = ancestor {
            strip(view)
            for sibling in view.subviews where sibling !== content {
                stripDescendants(sibling)
            }
            ancestor = view.superview
        }
    }

    private static func strip(_ view: NSView) {
        view.wantsLayer = true
        if let visual = view as? NSVisualEffectView {
            visual.material = .contentBackground
            visual.blendingMode = .behindWindow
            visual.state = .active
            visual.isEmphasized = false
        }
        let className = NSStringFromClass(type(of: view))
        if className.contains("Titlebar") || className.contains("Decoration") {
            view.isHidden = true
        }
        stripLayer(view.layer)
    }

    private static func stripDescendants(_ view: NSView) {
        strip(view)
        for subview in view.subviews {
            stripDescendants(subview)
        }
    }

    private static func stripLayer(_ layer: CALayer?) {
        guard let layer else { return }
        layer.borderWidth = 0
        layer.borderColor = NSColor.clear.cgColor
        if let shape = layer as? CAShapeLayer {
            shape.strokeColor = NSColor.clear.cgColor
            shape.lineWidth = 0
        }
        for sublayer in layer.sublayers ?? [] {
            stripLayer(sublayer)
        }
    }
}
#else
private struct MenuBarWindowChrome: View {
    var body: some View { EmptyView() }
}
#endif
