import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

public struct ProviderLogoView: View {
    public let provider: ProviderType
    public let size: CGFloat

    public init(provider: ProviderType, size: CGFloat = 16) {
        self.provider = provider
        self.size = size
    }

    public var body: some View {
        logoImage
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var logoImage: Image {
        if let url = Self.imageURL(named: provider.logoAssetName) {
            #if os(macOS)
            if let image = NSImage(contentsOf: url) {
                return Image(nsImage: image)
            }
            #else
            if let image = UIImage(contentsOfFile: url.path) {
                return Image(uiImage: image)
            }
            #endif
        }
        return Image(systemName: provider.systemIconName)
    }

    private static func imageURL(named name: String) -> URL? {
        let candidateBundles: [Bundle] = [
            Bundle.providerLimits,
            Bundle.main,
            Bundle(for: AppGroupStore.self),
            Bundle.main.url(forResource: "ProviderLimitsCore_ProviderLimitsCore", withExtension: "bundle").flatMap { Bundle(url: $0) },
            Bundle(for: AppGroupStore.self).url(forResource: "ProviderLimitsCore_ProviderLimitsCore", withExtension: "bundle").flatMap { Bundle(url: $0) }
        ].compactMap { $0 }

        for bundle in candidateBundles {
            if let url = bundle.url(forResource: name, withExtension: "png") {
                return url
            }
            if let url = bundle.url(
                forResource: name,
                withExtension: "png",
                subdirectory: "Media.xcassets/\(name).imageset"
            ) {
                return url
            }
        }
        return nil
    }
}

extension Bundle {
    static var providerLimits: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        Bundle(for: AppGroupStore.self)
        #endif
    }
}
