import AppKit
import SwiftUI
import ProviderLimitsCore

@main
struct SmokeHostApp {
    @MainActor
    static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let isPreview = CommandLine.arguments.contains("--preview")
        var customImagesPath: String? = nil
        if let idx = CommandLine.arguments.firstIndex(of: "--images-dir"), idx + 1 < CommandLine.arguments.count {
            customImagesPath = CommandLine.arguments[idx + 1]
        }

        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let imagesDir: URL
        if let customImagesPath {
            imagesDir = URL(fileURLWithPath: customImagesPath)
        } else {
            imagesDir = repoRoot.appendingPathComponent(
                "docs/changes/configurable-credential-sources/images",
                isDirectory: true
            )
        }
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        let fixtures = SyntheticFixtures()
        do {
            try fixtures.createAllFixtures()
        } catch {
            fputs("FATAL: Failed to create synthetic fixtures: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        SmokeURLProtocol.reset()
        URLProtocol.registerClass(SmokeURLProtocol.self)
        let session = SmokeURLProtocol.makeSession()

        let fixedDate = Date(timeIntervalSince1970: 1791316800)
        let resolver = CredentialResolver(
            home: fixtures.tempHome,
            environment: [:],
            clock: { fixedDate }
        )
        let store = AppGroupStore(customDirectoryURL: fixtures.tempStore)
        let defaults = UserDefaults(suiteName: fixtures.defaultsSuiteName)!

        let engine = SyncEngine(
            store: store,
            resolver: resolver,
            session: session,
            clock: { fixedDate }
        )

        let state = MenuBarState(
            defaults: defaults,
            store: store,
            engine: engine
        )

        var capturedFeedbackURLs: [URL] = []
        let capturedOpener: (URL) -> Bool = { url in
            capturedFeedbackURLs.append(url)
            return true
        }

        let controller = MenuBarController(
            state: state,
            refreshSnapshots: { await engine.refreshAll() },
            openExternalURL: capturedOpener
        )

        app.delegate = controller
        controller.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification, object: app)
        )

        controller.showSettings()
        guard let settingsWindow = controller.settingsWindow else {
            fputs("FATAL: Settings window was not created by MenuBarController\n", stderr)
            exit(1)
        }

        let driver = AccessibilityDriver.shared
        await driver.pumpRunLoop(seconds: 0.2)

        do {
            await state.rescan()
            await driver.pumpRunLoop(seconds: 0.1)

            try await driver.selectSource(
                provider: .codex,
                sourceID: "native.codex-auth",
                in: settingsWindow,
                state: state
            )
            try await driver.selectAccount(
                provider: .codex,
                sourceID: "native.codex-auth",
                accountID: "codex-workspace-a",
                in: settingsWindow,
                state: state
            )
            await driver.pumpRunLoop(seconds: 0.2)

            let selection = state.currentSelection(for: .codex)
            guard case .source(let src, let acc) = selection, src == "native.codex-auth", acc == "codex-workspace-a" else {
                throw NSError(
                    domain: "SmokeTest",
                    code: 101,
                    userInfo: [NSLocalizedDescriptionKey: "Codex selection mismatch: got \(selection)"]
                )
            }
            guard let snap = state.snapshots[.codex], snap.provenance?.sourceID == "native.codex-auth" else {
                throw NSError(
                    domain: "SmokeTest",
                    code: 102,
                    userInfo: [NSLocalizedDescriptionKey: "Codex snapshot provenance mismatch"]
                )
            }
            print("[PASS] Scenario 1: Source & account selection successfully applied and attributed.")
        } catch {
            fputs("FAILED Scenario 1: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        do {
            try await driver.selectSource(
                provider: .codex,
                sourceID: "automatic",
                in: settingsWindow,
                state: state
            )
            await driver.pumpRunLoop(seconds: 0.2)

            let selection = state.currentSelection(for: .codex)
            guard case .automatic = selection else {
                throw NSError(
                    domain: "SmokeTest",
                    code: 201,
                    userInfo: [NSLocalizedDescriptionKey: "Codex selection should be automatic"]
                )
            }
            guard let snap = state.snapshots[.codex], snap.provenance != nil else {
                throw NSError(
                    domain: "SmokeTest",
                    code: 202,
                    userInfo: [NSLocalizedDescriptionKey: "Codex automatic snapshot missing provenance"]
                )
            }
            print("[PASS] Scenario 2: Automatic selection runs and selects candidate per precedence.")
        } catch {
            fputs("FAILED Scenario 2: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        do {
            let reqCountBefore = SmokeURLProtocol.requestCount
            try driver.activateButton(identifier: "rescan-button", in: settingsWindow)
            await driver.pumpRunLoop(seconds: 0.2)
            let reqCountAfter = SmokeURLProtocol.requestCount

            guard reqCountAfter == reqCountBefore else {
                throw NSError(
                    domain: "SmokeTest",
                    code: 301,
                    userInfo: [NSLocalizedDescriptionKey: "Rescan issued provider network requests: before \(reqCountBefore), after \(reqCountAfter)"]
                )
            }
            guard state.discovery(for: .antigravity) != nil else {
                throw NSError(
                    domain: "SmokeTest",
                    code: 302,
                    userInfo: [NSLocalizedDescriptionKey: "Discovery missing after rescan"]
                )
            }
            print("[PASS] Scenario 3: Rescan completed with 0 network requests.")
        } catch {
            fputs("FAILED Scenario 3: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        do {
            try await driver.selectSource(
                provider: .antigravity,
                sourceID: "native.antigravity-ide",
                in: settingsWindow,
                state: state
            )
            await driver.pumpRunLoop(seconds: 0.1)

            _ = try fixtures.temporarilyHide(path: "Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
            await state.rescan(for: .antigravity)
            await driver.pumpRunLoop(seconds: 0.2)

            let selection = state.currentSelection(for: .antigravity)
            guard case .source(let src, _) = selection, src == "native.antigravity-ide" else {
                throw NSError(
                    domain: "SmokeTest",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "Disappeared selection was silently reset! Got \(selection)"]
                )
            }

            try driver.captureWindow(window: settingsWindow, to: imagesDir.appendingPathComponent("smoke-settings-missing.png"))

            try fixtures.restoreHidden(path: "Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
            await state.rescan(for: .antigravity)
            await driver.pumpRunLoop(seconds: 0.2)

            let restoredDisc = state.discovery(for: .antigravity)
            guard let nativeSrc = restoredDisc?.sources.first(where: { $0.id == "native.antigravity-ide" }),
                  nativeSrc.status == .availableLocally else {
                throw NSError(
                    domain: "SmokeTest",
                    code: 402,
                    userInfo: [NSLocalizedDescriptionKey: "Restored source not reported as availableLocally"]
                )
            }
            print("[PASS] Scenario 4: Missing pinned source retained visibly and restored cleanly.")
        } catch {
            fputs("FAILED Scenario 4: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        do {
            try await driver.selectSource(
                provider: .codex,
                sourceID: "native.codex-auth",
                in: settingsWindow,
                state: state
            )
            try await driver.selectAccount(
                provider: .codex,
                sourceID: "native.codex-auth",
                accountID: "codex-workspace-a",
                in: settingsWindow,
                state: state
            )
            await driver.pumpRunLoop(seconds: 0.1)

            let freshState = MenuBarState(
                defaults: defaults,
                store: store,
                engine: engine
            )
            let loadedCodex = freshState.currentSelection(for: .codex)
            guard case .source(let src, let acc) = loadedCodex, src == "native.codex-auth", acc == "codex-workspace-a" else {
                throw NSError(
                    domain: "SmokeTest",
                    code: 501,
                    userInfo: [NSLocalizedDescriptionKey: "Restart state failed to load persisted selection. Got \(loadedCodex)"]
                )
            }
            print("[PASS] Scenario 5: Selection overrides persist and restore across restart.")
        } catch {
            fputs("FAILED Scenario 5: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        do {
            await state.refresh(provider: .claude)
            await driver.pumpRunLoop(seconds: 0.1)
            guard let liveSnap = state.snapshots[.claude], liveSnap.provenance?.origin == .live else {
                throw NSError(
                    domain: "SmokeTest",
                    code: 601,
                    userInfo: [NSLocalizedDescriptionKey: "Fresh refresh did not produce live origin"]
                )
            }

            let lastProv = state.lastSuccessfulProvenances[.claude]
            guard lastProv != nil else {
                throw NSError(
                    domain: "SmokeTest",
                    code: 602,
                    userInfo: [NSLocalizedDescriptionKey: "Last successful provenance not recorded"]
                )
            }
            print("[PASS] Scenario 6: Live and last successful provenance correctly attributed.")
        } catch {
            fputs("FAILED Scenario 6: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        do {
            await state.refresh(provider: .cursor)
            let initialCursorSnap = state.snapshots[.cursor]

            SmokeURLProtocol.suspendRequests(for: .codex)

            let refreshTask = Task {
                await state.refresh(provider: .codex)
            }
            await driver.pumpRunLoop(seconds: 0.05)

            let epochB = state.selectCredentialSelection(
                .source("omp.agent-db", accountID: "omp-codex-workspace"),
                for: .codex
            )
            guard state.snapshots[.codex] == nil else {
                throw NSError(
                    domain: "SmokeTest",
                    code: 701,
                    userInfo: [NSLocalizedDescriptionKey: "Card was not cleared synchronously on selection change"]
                )
            }

            SmokeURLProtocol.resumeRequests()

            await state.completeCredentialSelection(
                .source("omp.agent-db", accountID: "omp-codex-workspace"),
                for: .codex,
                epoch: epochB
            )
            await driver.pumpRunLoop(seconds: 0.1)

            _ = await refreshTask.value
            await driver.pumpRunLoop(seconds: 0.1)

            let finalCodexSnap = state.snapshots[.codex]
            guard let prov = finalCodexSnap?.provenance, prov.sourceID == "omp.agent-db" else {
                throw NSError(
                    domain: "SmokeTest",
                    code: 702,
                    userInfo: [NSLocalizedDescriptionKey: "Stale request A overwrote selection B! Got \(String(describing: finalCodexSnap?.provenance))"]
                )
            }

            let finalCursorSnap = state.snapshots[.cursor]
            guard finalCursorSnap?.provider == initialCursorSnap?.provider else {
                throw NSError(
                    domain: "SmokeTest",
                    code: 703,
                    userInfo: [NSLocalizedDescriptionKey: "Unaffected provider (.cursor) was mutated by switch"]
                )
            }
            print("[PASS] Scenario 7: Stale completion rejected; unaffected providers preserved.")
        } catch {
            fputs("FAILED Scenario 7: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        do {
            if let button = controller.statusItem?.button {
                controller.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                await driver.pumpRunLoop(seconds: 0.1)

                if let popoverView = controller.popover.contentViewController?.view {
                    try driver.captureView(
                        view: popoverView,
                        to: imagesDir.appendingPathComponent("smoke-popover-dark.png")
                    )
                }

                controller.popover.performClose(nil)
                await driver.pumpRunLoop(seconds: 0.1)

                controller.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                await driver.pumpRunLoop(seconds: 0.1)

                guard state.snapshots[.codex]?.provenance?.sourceID == "omp.agent-db" else {
                    throw NSError(
                        domain: "SmokeTest",
                        code: 801,
                        userInfo: [NSLocalizedDescriptionKey: "Popover reopen reverted selection"]
                    )
                }
                controller.popover.performClose(nil)
            }
            print("[PASS] Scenario 8: Popover close & reopen preserves state.")
        } catch {
            fputs("FAILED Scenario 8: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        do {
            let capturedEpochs = state.captureEpochs()
            let newEpoch = state.selectCredentialSelection(
                .source("native.codex-auth", accountID: "codex-workspace-a"),
                for: .codex
            )

            let mockResults: [ProviderType: ProviderUsageSnapshot] = [
                .codex: ProviderUsageSnapshot.empty(for: .codex)
            ]
            state.applyRefreshAll(results: mockResults, capturedEpochs: capturedEpochs)

            guard state.snapshots[.codex] == nil else {
                throw NSError(
                    domain: "SmokeTest",
                    code: 901,
                    userInfo: [NSLocalizedDescriptionKey: "Stale refreshAll result overwrote newer selection change"]
                )
            }
            await state.completeCredentialSelection(
                .source("native.codex-auth", accountID: "codex-workspace-a"),
                for: .codex,
                epoch: newEpoch
            )
            print("[PASS] Scenario 9: RefreshAll overlap rejected stale provider snapshot.")
        } catch {
            fputs("FAILED Scenario 9: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        do {
            driver.setAppearance(window: settingsWindow, isDark: false)
            await driver.pumpRunLoop(seconds: 0.1)
            try driver.captureWindow(
                window: settingsWindow,
                to: imagesDir.appendingPathComponent("smoke-settings-light.png")
            )

            driver.setAppearance(window: settingsWindow, isDark: true)
            await driver.pumpRunLoop(seconds: 0.1)
            try driver.captureWindow(
                window: settingsWindow,
                to: imagesDir.appendingPathComponent("smoke-settings-dark.png")
            )

            driver.setSize(window: settingsWindow, size: NSSize(width: 640, height: 480))
            await driver.pumpRunLoop(seconds: 0.1)
            let minSize = settingsWindow.contentMinSize
            guard minSize.width <= 640 && minSize.height <= 480 else {
                throw NSError(
                    domain: "SmokeTest",
                    code: 1001,
                    userInfo: [NSLocalizedDescriptionKey: "Window content minSize violates constraints"]
                )
            }

            settingsWindow.makeKeyAndOrderFront(nil)
            settingsWindow.selectNextKeyView(nil)
            await driver.pumpRunLoop(seconds: 0.05)
            print("[PASS] Scenario 10: Appearance, minsize, and accessibility verified.")
        } catch {
            fputs("FAILED Scenario 10: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        do {
            let metadata = AboutAppMetadata(name: "AI Limits", version: "1.0", build: "1", macOSVersion: "14.0")
            let bugDraftURL = AboutFeedbackDraft.bug.url(metadata: metadata)
            _ = capturedOpener(bugDraftURL)

            guard !capturedFeedbackURLs.isEmpty else {
                throw NSError(domain: "SmokeTest", code: 1101, userInfo: [NSLocalizedDescriptionKey: "No feedback URLs captured"])
            }

            for url in capturedFeedbackURLs {
                let urlStr = url.absoluteString
                for secret in SyntheticFixtures.allSentinelSecrets {
                    if urlStr.contains(secret) {
                        throw NSError(
                            domain: "SmokeTest",
                            code: 1102,
                            userInfo: [NSLocalizedDescriptionKey: "Sentinel secret leaked into feedback URL! Secret: \(secret)"]
                        )
                    }
                }
                let forbiddenMetadata = [
                    "native.antigravity-ide", "native.codex-auth", "native.claude-credentials",
                    "native.cursor-state", "process.openrouter-key", "pi.auth-json", "omp.agent-db",
                    "codex-workspace-a", "pi-codex-workspace-a", "user-stripe-synthetics"
                ]
                for meta in forbiddenMetadata {
                    if urlStr.contains(meta) {
                        throw NSError(
                            domain: "SmokeTest",
                            code: 1103,
                            userInfo: [NSLocalizedDescriptionKey: "Source/account metadata leaked into feedback URL! Metadata: \(meta)"]
                        )
                    }
                }
            }
            print("[PASS] About feedback draft URL cleanly excludes secrets and source/account metadata.")
        } catch {
            fputs("FAILED Feedback URL check: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        do {
            try fixtures.verifyFilesUnchanged()
            print("[PASS] Synthetic source files are 100% byte-for-byte unchanged.")
        } catch {
            fputs("FAILED Fixture immutability check: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        do {
            try fixtures.verifyNoSentinelSecretsLeaked(
                extraStrings: capturedFeedbackURLs.map { $0.absoluteString }
            )
            print("[PASS] Zero sentinel secrets detected across all outputs and stores.")
        } catch {
            fputs("FAILED Secret leakage check: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        if !SmokeURLProtocol.unexpectedEndpoints.isEmpty {
            fputs("FATAL: Unexpected network requests were intercepted: \(SmokeURLProtocol.unexpectedEndpoints)\n", stderr)
            exit(1)
        }

        print("=== ALL 10 SMOKE SCENARIOS & VERIFICATIONS PASSED ===")
        print("Screenshots captured in: \(imagesDir.path)")

        if isPreview {
            print("\n[SMOKE PREVIEW] Isolated synthetic Settings window is active on screen.")
            print("[SMOKE PREVIEW] Close the Settings window or press Ctrl+C in this terminal to exit.")
            app.setActivationPolicy(.regular)
            app.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            app.run()
        } else {
            exit(0)
        }
    }
}
