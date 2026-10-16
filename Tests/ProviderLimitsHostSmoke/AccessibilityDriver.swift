import AppKit
import SwiftUI
import ProviderLimitsCore

enum SmokeAccessibilityError: Error {
    case windowHasNoContentView
    case buttonNotFound(String)
    case pickerNotFound(String)
    case pickerItemNotFound(pickerIdentifier: String, displayLabel: String)
    case stateDidNotUpdateAfterControlActivation(
        pickerIdentifier: String,
        expected: CredentialSelection,
        actual: CredentialSelection
    )
    case bitmapRepCreationFailed
    case pngEncodingFailed
}

@MainActor
final class AccessibilityDriver {
    static let shared = AccessibilityDriver()

    init() {}

    func pumpRunLoop(seconds: TimeInterval = 0.1) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            processEvents()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func processEvents() {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }

    func findView(identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier {
            return root
        }
        for subview in root.subviews {
            if let found = findView(identifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    func findPopUpButton(in root: NSView) -> NSPopUpButton? {
        if let popUp = root as? NSPopUpButton {
            return popUp
        }
        for subview in root.subviews {
            if let found = findPopUpButton(in: subview) {
                return found
            }
        }
        return nil
    }

    func findAccessibilityObject(identifier: String, in root: Any) -> Any? {
        if let element = root as? NSAccessibilityProtocol {
            if let id = element.accessibilityIdentifier(), id == identifier {
                return element
            }
        }

        if let view = root as? NSView {
            if view.accessibilityIdentifier() == identifier {
                return view
            }
            if let children = view.accessibilityChildren() {
                for child in children {
                    if let found = findAccessibilityObject(identifier: identifier, in: child) {
                        return found
                    }
                }
            }
            for subview in view.subviews {
                if let found = findAccessibilityObject(identifier: identifier, in: subview) {
                    return found
                }
            }
        } else if let element = root as? NSAccessibilityElement {
            if element.accessibilityIdentifier() == identifier {
                return element
            }
            if let children = element.accessibilityChildren() {
                for child in children {
                    if let found = findAccessibilityObject(identifier: identifier, in: child) {
                        return found
                    }
                }
            }
        }
        return nil
    }

    func activateButton(identifier: String, in window: NSWindow) throws {
        guard let contentView = window.contentView else {
            throw SmokeAccessibilityError.windowHasNoContentView
        }

        if let view = findView(identifier: identifier, in: contentView) {
            if let button = view as? NSButton {
                button.performClick(nil)
                return
            }
            if let control = view as? NSControl {
                control.performClick(nil)
                return
            }
            if view.accessibilityPerformPress() {
                return
            }
            sendSyntheticClick(to: view, in: window)
            return
        }

        if let element = findAccessibilityObject(identifier: identifier, in: contentView) {
            if let accObj = element as? NSAccessibilityProtocol, accObj.accessibilityPerformPress() == true {
                return
            }
            if let accElem = element as? NSAccessibilityElement, accElem.accessibilityPerformPress() {
                return
            }
        }

        throw SmokeAccessibilityError.buttonNotFound(identifier)
    }

    private func sendSyntheticClick(to view: NSView, in window: NSWindow) {
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let now = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: center,
            modifierFlags: [],
            timestamp: now,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: center,
            modifierFlags: [],
            timestamp: now + 0.05,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1.0
        )
        if let down { window.sendEvent(down) }
        if let up { window.sendEvent(up) }
    }

    func selectSource(
        provider: ProviderType,
        sourceID: String,
        in window: NSWindow,
        state: MenuBarState
    ) async throws {
        let identifier = "source-picker-\(provider.rawValue)"
        guard let contentView = window.contentView else {
            throw SmokeAccessibilityError.windowHasNoContentView
        }

        let displayLabel: String
        let expectedSelection: CredentialSelection
        if sourceID == "automatic" {
            displayLabel = "Automatic"
            expectedSelection = .automatic
        } else {
            let disc = state.discovery(for: provider)
            if let matchingSource = disc?.sources.first(where: { $0.id == sourceID }) {
                displayLabel = matchingSource.label
            } else {
                displayLabel = "\(sourceID) (Missing)"
            }
            expectedSelection = .source(sourceID, accountID: nil)
        }

        var controlActivated = false

        if let view = findView(identifier: identifier, in: contentView) {
            if let popUp = (view as? NSPopUpButton) ?? findPopUpButton(in: view) {
                if let item = popUp.itemArray.first(where: { $0.title == displayLabel || $0.title.hasPrefix(displayLabel) }) {
                    popUp.select(item)
                    if let action = popUp.action {
                        popUp.sendAction(action, to: popUp.target)
                    } else if let menu = popUp.menu {
                        let idx = popUp.index(of: item)
                        menu.performActionForItem(at: idx)
                    }
                    controlActivated = true
                }
            }
        }

        if !controlActivated, let element = findAccessibilityObject(identifier: identifier, in: contentView) {
            if let accObj = element as? NSAccessibilityProtocol, let children = accObj.accessibilityChildren() as? [Any] {
                for child in children {
                    if let childObj = child as? NSAccessibilityProtocol,
                       let title = childObj.accessibilityTitle() ?? childObj.accessibilityLabel(),
                       title == displayLabel || title.hasPrefix(displayLabel) {
                        if childObj.accessibilityPerformPress() == true {
                            controlActivated = true
                            break
                        }
                    }
                }
            }
            if !controlActivated, let accElem = element as? NSAccessibilityElement, let children = accElem.accessibilityChildren() {
                for child in children {
                    if let childElem = child as? NSAccessibilityElement {
                        let title = childElem.accessibilityTitle() ?? childElem.accessibilityLabel()
                        if let title, title == displayLabel || title.hasPrefix(displayLabel) {
                            if childElem.accessibilityPerformPress() {
                                controlActivated = true
                                break
                            }
                        }
                    }
                }
            }
            if !controlActivated {
                if let element = element as? NSAccessibilityProtocol {
                    element.setAccessibilityValue(displayLabel)
                    controlActivated = element.accessibilityPerformPress()
                }
            }
        }

        guard controlActivated else {
            throw SmokeAccessibilityError.pickerItemNotFound(
                pickerIdentifier: identifier,
                displayLabel: displayLabel
            )
        }

        let deadline = Date().addingTimeInterval(2.0)
        var didUpdate = false
        while Date() < deadline {
            await pumpRunLoop(seconds: 0.05)
            let current = state.currentSelection(for: provider)
            if current == expectedSelection {
                didUpdate = true
                break
            }
        }

        guard didUpdate else {
            throw SmokeAccessibilityError.stateDidNotUpdateAfterControlActivation(
                pickerIdentifier: identifier,
                expected: expectedSelection,
                actual: state.currentSelection(for: provider)
            )
        }
    }

    func selectAccount(
        provider: ProviderType,
        sourceID: String,
        accountID: String?,
        in window: NSWindow,
        state: MenuBarState
    ) async throws {
        let identifier = "account-picker-\(provider.rawValue)"
        guard let contentView = window.contentView else {
            throw SmokeAccessibilityError.windowHasNoContentView
        }

        let displayLabel: String
        if let accountID {
            let disc = state.discovery(for: provider)
            let source = disc?.sources.first(where: { $0.id == sourceID })
            if let account = source?.accounts.first(where: { $0.reference.accountID == accountID }) {
                displayLabel = account.label
            } else {
                displayLabel = "\(accountID) (Missing)"
            }
        } else {
            displayLabel = "Automatic account"
        }
        let expectedSelection: CredentialSelection = .source(sourceID, accountID: accountID)

        var controlActivated = false

        if let view = findView(identifier: identifier, in: contentView) {
            if let popUp = (view as? NSPopUpButton) ?? findPopUpButton(in: view) {
                if let item = popUp.itemArray.first(where: { $0.title == displayLabel || $0.title.hasPrefix(displayLabel) }) {
                    popUp.select(item)
                    if let action = popUp.action {
                        popUp.sendAction(action, to: popUp.target)
                    } else if let menu = popUp.menu {
                        let idx = popUp.index(of: item)
                        menu.performActionForItem(at: idx)
                    }
                    controlActivated = true
                }
            }
        }

        if !controlActivated, let element = findAccessibilityObject(identifier: identifier, in: contentView) {
            if let accObj = element as? NSAccessibilityProtocol, let children = accObj.accessibilityChildren() as? [Any] {
                for child in children {
                    if let childObj = child as? NSAccessibilityProtocol,
                       let title = childObj.accessibilityTitle() ?? childObj.accessibilityLabel(),
                       title == displayLabel || title.hasPrefix(displayLabel) {
                        if childObj.accessibilityPerformPress() == true {
                            controlActivated = true
                            break
                        }
                    }
                }
            }
            if !controlActivated, let accElem = element as? NSAccessibilityElement, let children = accElem.accessibilityChildren() {
                for child in children {
                    if let childElem = child as? NSAccessibilityElement {
                        let title = childElem.accessibilityTitle() ?? childElem.accessibilityLabel()
                        if let title, title == displayLabel || title.hasPrefix(displayLabel) {
                            if childElem.accessibilityPerformPress() {
                                controlActivated = true
                                break
                            }
                        }
                    }
                }
            }
            if !controlActivated {
                if let element = element as? NSAccessibilityProtocol {
                    element.setAccessibilityValue(displayLabel)
                    controlActivated = element.accessibilityPerformPress()
                }
            }
        }

        guard controlActivated else {
            throw SmokeAccessibilityError.pickerItemNotFound(
                pickerIdentifier: identifier,
                displayLabel: displayLabel
            )
        }

        let deadline = Date().addingTimeInterval(2.0)
        var didUpdate = false
        while Date() < deadline {
            await pumpRunLoop(seconds: 0.05)
            let current = state.currentSelection(for: provider)
            if current == expectedSelection {
                didUpdate = true
                break
            }
        }

        guard didUpdate else {
            throw SmokeAccessibilityError.stateDidNotUpdateAfterControlActivation(
                pickerIdentifier: identifier,
                expected: expectedSelection,
                actual: state.currentSelection(for: provider)
            )
        }
    }

    func readText(identifier: String, in window: NSWindow) -> String? {
        guard let contentView = window.contentView else { return nil }

        if let view = findView(identifier: identifier, in: contentView) {
            if let textField = view as? NSTextField {
                return textField.stringValue
            }
            if let button = view as? NSButton {
                return button.title
            }
            if let label = view.accessibilityLabel() {
                return label
            }
            if let value = view.accessibilityValue() as? String {
                return value
            }
        }

        if let element = findAccessibilityObject(identifier: identifier, in: contentView) {
            if let accObj = element as? NSAccessibilityProtocol {
                if let val = accObj.accessibilityValue() as? String {
                    return val
                }
                if let label = accObj.accessibilityLabel() {
                    return label
                }
            }
            if let accElem = element as? NSAccessibilityElement {
                if let val = accElem.accessibilityValue() as? String {
                    return val
                }
                if let label = accElem.accessibilityLabel() {
                    return label
                }
            }
        }
        return nil
    }

    func containsIdentifier(identifier: String, in window: NSWindow) -> Bool {
        guard let contentView = window.contentView else { return false }
        return findView(identifier: identifier, in: contentView) != nil
            || findAccessibilityObject(identifier: identifier, in: contentView) != nil
    }

    func setAppearance(window: NSWindow, isDark: Bool) {
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.displayIfNeeded()
    }

    func setSize(window: NSWindow, size: NSSize) {
        window.setContentSize(size)
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    func captureWindow(window: NSWindow, to url: URL) throws {
        guard let contentView = window.contentView else {
            throw SmokeAccessibilityError.windowHasNoContentView
        }
        try captureView(view: contentView, to: url)
    }

    func captureView(view: NSView, to url: URL) throws {
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw SmokeAccessibilityError.bitmapRepCreationFailed
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw SmokeAccessibilityError.pngEncodingFailed
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pngData.write(to: url)
    }
}
