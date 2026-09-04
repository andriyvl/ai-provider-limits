import Foundation

public final class AppGroupStore: Sendable {
    public static let shared = AppGroupStore()
    public static let appGroupID = "group.com.andriyvl.ai-provider-limits"
    private let customDirectoryURL: URL?

    public init(customDirectoryURL: URL? = nil) {
        self.customDirectoryURL = customDirectoryURL
    }

    public var containerDirectory: URL {
        let directory: URL
        if let customDirectoryURL {
            directory = customDirectoryURL
        } else if let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) {
            directory = appGroupURL
        } else {
            let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: "/tmp")
            directory = baseDir.appendingPathComponent("AIProviderLimits", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var snapshotsFileURL: URL {
        containerDirectory.appendingPathComponent("snapshots.json")
    }
    private var providerOrderFileURL: URL {
        containerDirectory.appendingPathComponent("provider_order.json")
    }

    public func loadSnapshots() -> [ProviderType: ProviderUsageSnapshot] {
        let fileURL = snapshotsFileURL
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: ProviderUsageSnapshot].self, from: data) else {
            return [:]
        }
        var result: [ProviderType: ProviderUsageSnapshot] = [:]
        for (key, val) in dict {
            if let provider = ProviderType(rawValue: key) {
                result[provider] = val
            }
        }
        return result
    }

    public func saveSnapshots(_ snapshots: [ProviderType: ProviderUsageSnapshot]) throws {
        var serializable: [String: ProviderUsageSnapshot] = [:]
        for (provider, snapshot) in snapshots {
            serializable[provider.rawValue] = snapshot
        }
        let data = try JSONEncoder().encode(serializable)
        try data.write(to: snapshotsFileURL, options: .atomic)
    }

    public func loadSnapshot(for provider: ProviderType) -> ProviderUsageSnapshot? {
        loadSnapshots()[provider]
    }

    public func saveSnapshot(_ snapshot: ProviderUsageSnapshot) throws {
        var current = loadSnapshots()
        current[snapshot.provider] = snapshot
        try saveSnapshots(current)
    }

    public func loadProviderOrder() -> [ProviderType] {
        let fileURL = providerOrderFileURL
        if let data = try? Data(contentsOf: fileURL),
           let rawList = try? JSONDecoder().decode([String].self, from: data) {
            let loaded = rawList.compactMap { ProviderType(rawValue: $0) }
            var result = loaded
            for provider in ProviderType.allCases where !result.contains(provider) {
                result.append(provider)
            }
            if !result.isEmpty { return result }
        }
        return ProviderType.allCases
    }

    public func saveProviderOrder(_ order: [ProviderType]) {
        let rawList = order.map(\.rawValue)
        if let data = try? JSONEncoder().encode(rawList) {
            try? data.write(to: providerOrderFileURL, options: .atomic)
        }
    }
}
