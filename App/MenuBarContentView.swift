import SwiftUI
import ProviderLimitsCore
#if os(macOS)
import AppKit
#endif

public struct MenuBarContentView: View {
    public let snapshots: [ProviderType: ProviderUsageSnapshot]
    public let isRefreshing: Bool
    public let onRefresh: () -> Void
    public let providerOrder: [ProviderType]
    public let showAntigravity: Bool
    public let showCodex: Bool
    public let showCursor: Bool
    public let showClaude: Bool
    public let showOpenRouter: Bool
    public let onOpenSettings: () -> Void
    public init(
        snapshots: [ProviderType: ProviderUsageSnapshot],
        isRefreshing: Bool,
        providerOrder: [ProviderType],
        showAntigravity: Bool,
        showCodex: Bool,
        showCursor: Bool,
        showClaude: Bool,
        showOpenRouter: Bool,
        onOpenSettings: @escaping () -> Void,
        onRefresh: @escaping () -> Void
    ) {
        self.snapshots = snapshots
        self.isRefreshing = isRefreshing
        self.onRefresh = onRefresh
        self.providerOrder = providerOrder
        self.showAntigravity = showAntigravity
        self.showCodex = showCodex
        self.showCursor = showCursor
        self.showClaude = showClaude
        self.showOpenRouter = showOpenRouter
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            mainCardList
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

    private var maxScrollHeight: CGFloat {
        #if os(macOS)
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return min(640, max(300, screenHeight - 100))
        #else
        return 640
        #endif
    }

    private func isProviderEnabled(_ provider: ProviderType) -> Bool {
        switch provider {
        case .antigravity: return showAntigravity
        case .codex: return showCodex
        case .cursor: return showCursor
        case .claude: return showClaude
        case .openRouter: return showOpenRouter
        }
    }

    private var visibleSnapshots: [ProviderUsageSnapshot] {
        providerOrder.compactMap { provider in
            guard isProviderEnabled(provider) else { return nil }
            let snapshot = snapshots[provider] ?? ProviderUsageSnapshot.empty(for: provider)
            return snapshot.isActive ? snapshot : nil
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Spacer()

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LiquidGlassTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .help("Settings")

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
