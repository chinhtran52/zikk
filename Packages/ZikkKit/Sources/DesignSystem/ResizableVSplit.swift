import SwiftUI
import AppKit

/// Vertical split with a draggable divider, implemented in SwiftUI.
/// Used instead of `VSplitView`, whose AppKit split view picks up the toolbar's scroll-edge effect on macOS 26.
public struct ResizableVSplit<Top: View, Bottom: View>: View {
    let top: Top
    let bottom: Bottom
    let minTop: CGFloat
    let minBottom: CGFloat
    @AppStorage private var fraction: Double
    @State private var dragStartFraction: Double?

    /// - Parameter id: key under which the divider position is remembered.
    public init(id: String, initialFraction: Double = 0.55, minTop: CGFloat = 160, minBottom: CGFloat = 120,
                @ViewBuilder top: () -> Top, @ViewBuilder bottom: () -> Bottom) {
        self.top = top()
        self.bottom = bottom()
        self.minTop = minTop
        self.minBottom = minBottom
        _fraction = AppStorage(wrappedValue: initialFraction, "split.\(id)")
    }

    public var body: some View {
        GeometryReader { proxy in
            let dividerHeight: CGFloat = 7
            let available = max(proxy.size.height - dividerHeight, 1)
            let topHeight = min(max(available * fraction, minTop), max(available - minBottom, minTop))
            VStack(spacing: 0) {
                top
                    .frame(width: proxy.size.width, height: topHeight)
                    .clipped()
                ZStack {
                    Color.clear
                    Divider()
                }
                .frame(height: dividerHeight)
                .contentShape(.rect)
                .onHover { inside in
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let start = dragStartFraction ?? fraction
                            dragStartFraction = start
                            fraction = min(max((available * start + value.translation.height) / available, 0.1), 0.9)
                        }
                        .onEnded { _ in dragStartFraction = nil }
                )
                .accessibilityLabel(L("Resize"))
                bottom
                    .frame(width: proxy.size.width, height: max(available - topHeight, 0))
                    .clipped()
            }
        }
    }
}
