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
        let bundle = Bundle.providerLimits
        if let url = bundle.url(forResource: name, withExtension: "png") {
            return url
        }
        return bundle.url(
            forResource: name,
            withExtension: "png",
            subdirectory: "Media.xcassets/\(name).imageset"
        )
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
