import AppKit
import SwiftUI
import ProviderLimitsCore

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let state: MenuBarState
    private(set) var statusItem: NSStatusItem?
    let popover = NSPopover()
    private(set) var settingsWindow: NSWindow?
    private let refreshSnapshots: () async -> [ProviderType: ProviderUsageSnapshot]
    private let openExternalURL: (URL) -> Bool
    private let statusImage: NSImage?
    private let title: String
    private var refreshTask: Task<Void, Never>?
    private var contextMenu: NSMenu?

    init(
        state: MenuBarState,
        refreshSnapshots: @escaping () async -> [ProviderType: ProviderUsageSnapshot],
        openExternalURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        statusImage: NSImage? = nil,
        title: String = "AI Limits"
    ) {
        self.state = state
        self.refreshSnapshots = refreshSnapshots
        self.openExternalURL = openExternalURL
        self.statusImage = statusImage
        self.title = title
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            let image = statusImage ?? Self.menuBarIcon()
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            button.image = image
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseDown])
        }

        popover.behavior = .transient
        popover.delegate = self
        let panel = NSHostingController(rootView: MenuBarPanelRoot(
            state: state,
            onOpenSettings: { [weak self] in self?.showSettings() },
            onRefresh: { [weak self] in
                Task { await self?.refresh() }
            }
        ))
        panel.sizingOptions = [.preferredContentSize]
        popover.contentViewController = panel

        contextMenu = makeAppMenu()
        let menuBar = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = makeAppMenu()
        menuBar.addItem(appItem)
        NSApplication.shared.mainMenu = menuBar
        Task { [weak self] in
            await self?.state.loadCachedSnapshots()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    @objc func showSettings(_ sender: Any? = nil) {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            let hosting = NSHostingController(rootView: SettingsRoot(
                state: state,
                openExternalURL: openExternalURL
            ))
            hosting.sizingOptions = [.minSize]
            window.contentViewController = hosting
            window.contentMinSize = NSSize(width: 640, height: 480)
            window.setContentSize(NSSize(width: 800, height: 600))
            window.center()
            settingsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func popoverDidShow(_ notification: Notification) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard popover.isShown else { return }
                await refresh()
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        refreshTask?.cancel()
        refreshTask = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApplication.shared.currentEvent?.type == .rightMouseDown {
            popover.performClose(nil)
            if let contextMenu, let event = NSApplication.shared.currentEvent {
                NSMenu.popUpContextMenu(contextMenu, with: event, for: sender)
            }
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func makeAppMenu() -> NSMenu {
        let menu = NSMenu(title: title)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit \(title)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApplication.shared
        menu.addItem(quit)
        return menu
    }

    private func refresh() async {
        guard !state.isRefreshing else { return }
        state.isRefreshing = true
        defer { state.isRefreshing = false }
        let snapshots = await refreshSnapshots()
        if !snapshots.isEmpty {
            state.snapshots = snapshots
        }
    }

    private static func menuBarIcon() -> NSImage {
        if let icon = Bundle.main.image(forResource: "MenuBarIcon") {
            return icon
        }
        let candidates = [
            Bundle.main.url(forResource: "MenuBarIcon", withExtension: "tiff"),
            Bundle.main.url(forResource: "MenuBarIcon@2x", withExtension: "png"),
            Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png")
        ]
        for case let url? in candidates {
            if let icon = NSImage(contentsOf: url) {
                return icon
            }
        }
        return NSImage(systemSymbolName: "circle", accessibilityDescription: "AI Limits")!
    }
}
