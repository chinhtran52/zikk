import SwiftUI

/// Icon-only button without a glass or bezel background: just the symbol, with a subtle rounded highlight
/// on hover and press so it still reads as clickable (like Finder's and Mail's plain toolbar icons).
public struct PlainIconButtonStyle: ButtonStyle {
    var size: CGFloat

    public init(size: CGFloat = 28) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        PlainIconButton(configuration: configuration, size: size)
    }

    private struct PlainIconButton: View {
        let configuration: Configuration
        let size: CGFloat
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 15, weight: .regular))
                .imageScale(.medium)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(Color.primary.opacity(configuration.isPressed ? 0.14 : (isHovering && isEnabled ? 0.07 : 0)), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovering = $0 }
        }
    }
}
