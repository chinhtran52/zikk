import SwiftUI
import AppKit

/// Horizontal split with a draggable divider, implemented in SwiftUI.
/// Replaces `HSplitView`: its AppKit split view, nested inside `NavigationSplitView` and inspectors, fed changing
/// min/max sizes back into the window and caused runaway window growth and "too many Update Constraints passes" crashes.
public struct ResizableHSplit<Left: View, Right: View>: View {
    let left: Left
    let right: Right
    let showsRight: Bool
    let minLeft: CGFloat
    let minRight: CGFloat
    @AppStorage private var fraction: Double
    @State private var dragStartFraction: Double?

    /// - Parameters:
    ///   - id: key under which the divider position is remembered.
    ///   - showsRight: when false the left pane takes the full width (e.g. no selection to show details for).
    public init(id: String, initialFraction: Double = 0.4, minLeft: CGFloat = 160, minRight: CGFloat = 160, showsRight: Bool = true,
                @ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.left = left()
        self.right = right()
        self.showsRight = showsRight
        self.minLeft = minLeft
        self.minRight = minRight
        _fraction = AppStorage(wrappedValue: initialFraction, "hsplit.\(id)")
    }

    public var body: some View {
        GeometryReader { proxy in
            if showsRight {
                let dividerWidth: CGFloat = 7
                let available = max(proxy.size.width - dividerWidth, 1)
                // When the space is smaller than both minimums, split proportionally instead of overflowing.
                let leftWidth = available >= minLeft + minRight
                    ? min(max(available * fraction, minLeft), available - minRight)
                    : available * fraction
                HStack(spacing: 0) {
                    left
                        .frame(width: leftWidth, height: proxy.size.height)
                        .clipped()
                    ZStack {
                        Color.clear
                        Divider()
                    }
                    .frame(width: dividerWidth)
                    .contentShape(.rect)
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = dragStartFraction ?? fraction
                                dragStartFraction = start
                                fraction = min(max((available * start + value.translation.width) / available, 0.1), 0.9)
                            }
                            .onEnded { _ in dragStartFraction = nil }
                    )
                    .accessibilityLabel(L("Resize"))
                    right
                        .frame(width: max(available - leftWidth, 0), height: proxy.size.height)
                        .clipped()
                }
            } else {
                left
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
        }
    }
}
