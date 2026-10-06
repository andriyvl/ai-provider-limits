import AppKit
import SwiftUI

struct AboutAppMetadata {
    let name: String
    let version: String?
    let build: String?
    let macOSVersion: String

    init(bundle: Bundle = .main) {
        name = Self.nonEmpty(bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? Self.nonEmpty(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "AI Limits"
        version = Self.nonEmpty(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        build = Self.nonEmpty(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersion
        macOSVersion = "\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)"
    }

    init(name: String = "AI Limits", version: String?, build: String?, macOSVersion: String) {
        self.name = name
        self.version = Self.nonEmpty(version)
        self.build = Self.nonEmpty(build)
        self.macOSVersion = macOSVersion
    }

    var versionLines: [String] {
        var lines: [String] = []
        if let version {
            lines.append("App version: \(version)")
        }
        if let build {
            lines.append("Build: \(build)")
        }
        lines.append("macOS: \(macOSVersion)")
        return lines
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum AboutFeedbackDraft: CaseIterable {
    case bug
    case feature

    var title: String {
        switch self {
        case .bug: "Bug report"
        case .feature: "Feature request"
        }
    }

    func url(metadata: AboutAppMetadata) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/andriyvl/ai-provider-limits/issues/new"
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: metadata.versionLines.joined(separator: "\n"))
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

struct AboutExternalLink: Identifiable {
    let title: String
    let symbol: String
    let url: URL

    var id: URL { url }

    static let support: [AboutExternalLink] = [
        AboutExternalLink(
            title: "Buy Me a Coffee",
            symbol: "cup.and.saucer",
            url: URL(string: "https://buymeacoffee.com/andriy.viy")!
        ),
        AboutExternalLink(
            title: "Monobank jar",
            symbol: "heart",
            url: URL(string: "https://send.monobank.ua/jar/94A6k6Qget")!
        )
    ]

    static let creator: [AboutExternalLink] = [
        AboutExternalLink(title: "Website", symbol: "globe", url: URL(string: "https://devviy.com")!),
        AboutExternalLink(
            title: "GitHub",
            symbol: "chevron.left.forwardslash.chevron.right",
            url: URL(string: "https://github.com/andriyvl")!
        ),
        AboutExternalLink(title: "Telegram", symbol: "paperplane", url: URL(string: "https://telegram.me/andriyviy")!),
        AboutExternalLink(title: "Instagram", symbol: "camera", url: URL(string: "https://instagram.com/andriy.viy")!),
        AboutExternalLink(title: "Threads", symbol: "at", url: URL(string: "https://threads.com/@andriy.viy")!),
        AboutExternalLink(title: "X", symbol: "bubble.left", url: URL(string: "https://x.com/andriyviy")!)
    ]
}

struct AboutSettingsSection: View {
    private let metadata: AboutAppMetadata
    private let appIcon: NSImage?
    private let feedbackLinks: [AboutExternalLink]
    private let openExternalURL: (URL) -> Bool
    @State private var failedLinkTitle = ""
    @State private var isShowingOpenFailure = false

    init(openExternalURL: @escaping (URL) -> Bool) {
        let metadata = AboutAppMetadata()
        self.metadata = metadata
        let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "AppIcon"
        appIcon = Bundle.main.image(forResource: NSImage.Name(iconName))
        feedbackLinks = [
            AboutExternalLink(
                title: "Report a bug",
                symbol: "ladybug",
                url: AboutFeedbackDraft.bug.url(metadata: metadata)
            ),
            AboutExternalLink(
                title: "Suggest a feature",
                symbol: "lightbulb",
                url: AboutFeedbackDraft.feature.url(metadata: metadata)
            )
        ]
        self.openExternalURL = openExternalURL
    }

    var body: some View {
        Form {
            Section {
                AboutIdentityView(metadata: metadata, appIcon: appIcon)
            }

            Section {
                ForEach(feedbackLinks) { link in
                    AboutExternalLinkRow(link: link) { openLink(link) }
                }
            } header: {
                Text("Feedback")
            } footer: {
                Text(
                    "Opens an editable GitHub draft with only available app, build, and macOS versions. "
                    + "Nothing is submitted until you submit it on GitHub."
                )
            }

            Section {
                ForEach(AboutExternalLink.support) { link in
                    AboutExternalLinkRow(link: link) { openLink(link) }
                }
            } header: {
                Text("Support")
            } footer: {
                Text("Support is voluntary. Donations are handled by the selected website, not by AI Limits.")
            }

            Section {
                Text("Andriy Viychuk (@andriyvl)")
                ForEach(AboutExternalLink.creator) { link in
                    AboutExternalLinkRow(link: link) { openLink(link) }
                }
            } header: {
                Text("Creator")
            }
        }
        .formStyle(.grouped)
        .alert("Could Not Open Link", isPresented: $isShowingOpenFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The system could not open \(failedLinkTitle).")
        }
    }

    private func openLink(_ link: AboutExternalLink) {
        if !openExternalURL(link.url) {
            failedLinkTitle = link.title
            isShowingOpenFailure = true
        }
    }
}

private struct AboutIdentityView: View {
    let metadata: AboutAppMetadata
    let appIcon: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(metadata.name)
                    .font(.title2.weight(.semibold))
                if let version = metadata.version {
                    Text("Version \(version)")
                        .foregroundStyle(.secondary)
                }
                if let build = metadata.build {
                    Text("Build \(build)")
                        .foregroundStyle(.secondary)
                }
                Text("Monitor usage limits and remaining capacity across your AI providers from the macOS menu bar.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct AboutExternalLinkRow: View {
    let link: AboutExternalLink
    let action: () -> Void

    var body: some View {
        Button(link.title, systemImage: link.symbol, action: action)
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(.primary)
            .overlay(alignment: .trailing) {
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel(link.title)
            .accessibilityHint("Opens in your default browser")
    }
}
