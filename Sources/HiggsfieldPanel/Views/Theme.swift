#if os(macOS)
import SwiftUI

/// Visual constants. The panel uses Dark Mode to match Final Cut Pro, as
/// Apple's workflow-extension design guidelines recommend.
enum Theme {
    /// Signature lime accent used for the primary action and active tool.
    static let accent = Color(red: 0.80, green: 0.98, blue: 0.20)
    static let accentForeground = Color.black
    static let panelBackground = Color(nsColor: NSColor(calibratedWhite: 0.11, alpha: 1))
    static let cardBackground = Color(nsColor: NSColor(calibratedWhite: 0.16, alpha: 1))
    static let cardStroke = Color.white.opacity(0.08)
    static let secondaryText = Color.white.opacity(0.6)
    static let corner: CGFloat = 8
    static let spacing: CGFloat = 10
}

struct Card<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    trailing
                }
            }
            content
        }
        .padding(10)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cardStroke))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 30)
            .foregroundStyle(isEnabled ? Theme.accentForeground : Color.white.opacity(0.4))
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isEnabled ? Theme.accent.opacity(configuration.isPressed ? 0.75 : 1) : Color.white.opacity(0.1))
            )
    }
}

struct Chip: View {
    var text: String
    var systemImage: String?
    var tint: Color = .white.opacity(0.12)

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint, in: Capsule())
    }
}
#endif
