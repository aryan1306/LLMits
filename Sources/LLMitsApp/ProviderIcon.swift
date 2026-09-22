import AppKit
import SwiftUI
import LLMitsCore

extension ProviderID {
    var iconResourceName: String {
        switch self {
        case .claude: "claude"
        case .codex: "chatgpt"
        case .antigravity: "antigravity"
        }
    }

    var iconImage: NSImage? {
        Bundle.module.url(forResource: iconResourceName, withExtension: "svg").flatMap(NSImage.init(contentsOf:))
    }
}

struct ProviderIcon: View {
    let provider: ProviderID
    var size: CGFloat = 22

    var body: some View {
        if let image = provider.iconImage {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
                .padding(provider == .antigravity ? size * 0.06 : 0)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private var tint: AnyShapeStyle {
        switch provider {
        case .claude:
            AnyShapeStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
        case .codex:
            AnyShapeStyle(Color(red: 0.06, green: 0.64, blue: 0.50))
        case .antigravity:
            AnyShapeStyle(LinearGradient(
                colors: [
                    Color(red: 0.19, green: 0.53, blue: 1.00),
                    Color(red: 0.00, green: 0.73, blue: 0.36),
                    Color(red: 1.00, green: 0.80, blue: 0.00),
                    Color(red: 1.00, green: 0.27, blue: 0.25),
                ],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            ))
        }
    }
}
