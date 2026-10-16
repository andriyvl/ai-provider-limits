import Foundation

public final class AppGroupStore: Sendable {
    public static let shared = AppGroupStore()
    public static let appGroupID = "group.com.andriyvl.ai-provider-limits"
    private let customDirectoryURL: URL?
    private let lock = NSLock()

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

    private var credentialSelectionsFileURL: URL {
        containerDirectory.appendingPathComponent("credential_selections.json")
    }

    private func snapshotKey(for provider: ProviderType, reference: CredentialReference) throws -> String {
        String(
            decoding: try JSONEncoder().encode([provider.rawValue, reference.sourceID, reference.accountID]),
            as: UTF8.self
        )
    }

    public func loadCredentialSelections() -> [ProviderType: CredentialSelection] {
        lock.lock()
        defer { lock.unlock() }
        let fileURL = credentialSelectionsFileURL
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: CredentialSelection].self, from: data) else {
            return [:]
        }
        var result: [ProviderType: CredentialSelection] = [:]
        for (key, val) in dict {
            if let provider = ProviderType(rawValue: key) {
                result[provider] = val
            }
        }
        return result
    }

    public func saveCredentialSelections(_ selections: [ProviderType: CredentialSelection]) {
        lock.lock()
        defer { lock.unlock() }
        var serializable: [String: CredentialSelection] = [:]
        for (provider, selection) in selections {
            serializable[provider.rawValue] = selection
        }
        if let data = try? JSONEncoder().encode(serializable) {
            try? data.write(to: credentialSelectionsFileURL, options: .atomic)
        }
    }

    public func loadSnapshots(for provider: ProviderType) -> [CredentialReference: ProviderUsageSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        let fileURL = snapshotsFileURL
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: ProviderUsageSnapshot].self, from: data) else {
            return [:]
        }
        var result: [CredentialReference: ProviderUsageSnapshot] = [:]
        for (_, snapshot) in dict {
            if snapshot.provider == provider, let provenance = snapshot.provenance,
               let ref = provenance.reference, provenance.sourceID == ref.sourceID {
                result[ref] = snapshot
            }
        }
        return result
    }

    public func loadSnapshot(for provider: ProviderType, reference: CredentialReference) -> ProviderUsageSnapshot? {
        loadSnapshots(for: provider)[reference]
    }

    public func saveSnapshot(_ snapshot: ProviderUsageSnapshot) throws {
        guard let provenance = snapshot.provenance, let reference = provenance.reference,
              provenance.sourceID == reference.sourceID else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        let fileURL = snapshotsFileURL
        var dict: [String: ProviderUsageSnapshot] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([String: ProviderUsageSnapshot].self, from: data) {
            dict = loaded
        }
        let key = try snapshotKey(for: snapshot.provider, reference: reference)
        dict[key] = snapshot
        let data = try JSONEncoder().encode(dict)
        try data.write(to: fileURL, options: .atomic)
    }


    public func loadProviderOrder() -> [ProviderType] {
        lock.lock()
        defer { lock.unlock() }
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
        lock.lock()
        defer { lock.unlock() }
        let rawList = order.map(\.rawValue)
        if let data = try? JSONEncoder().encode(rawList) {
            try? data.write(to: providerOrderFileURL, options: .atomic)
        }
    }
}
