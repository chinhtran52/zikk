import SwiftUI

/// Item shown in a `TabStrip`.
public struct TabStripItem: Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var leading: String?
    public var leadingColor: Color
    public var isDirty: Bool

    public init(id: UUID, title: String, leading: String? = nil, leadingColor: Color = .secondary, isDirty: Bool = false) {
        self.id = id
        self.title = title
        self.leading = leading
        self.leadingColor = leadingColor
        self.isDirty = isDirty
    }
}

/// Document tab bar in the style of Finder and Safari: tabs share the full width equally, titles are centered,
/// the close button sits on the leading edge and appears on hover, and the selected tab is a raised rounded tile.
/// When the tabs would get narrower than `minTabWidth` the bar scrolls horizontally instead.
public struct TabStrip<NewMenu: View>: View {
    let items: [TabStripItem]
    @Binding var selection: UUID?
    let onClose: (UUID) -> Void
    let onNew: () -> Void
    let newMenu: NewMenu
    @State private var hovered: UUID?

    static var minTabWidth: CGFloat { 160 }
    static var spacing: CGFloat { 2 }

    public init(items: [TabStripItem], selection: Binding<UUID?>, onClose: @escaping (UUID) -> Void, onNew: @escaping () -> Void,
                @ViewBuilder newMenu: () -> NewMenu) {
        self.items = items
        _selection = selection
        self.onClose = onClose
        self.onNew = onNew
        self.newMenu = newMenu()
    }

    /// Equal share of `available` for each of `count` tabs, never below `minTabWidth`.
    static func tabWidth(available: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let share = (available - spacing * CGFloat(count - 1)) / CGFloat(count)
        return max(minTabWidth, share.rounded(.down))
    }

    public var body: some View {
        HStack(spacing: 4) {
            GeometryReader { proxy in
                let width = Self.tabWidth(available: proxy.size.width, count: items.count)
                ScrollViewReader { scroller in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Self.spacing) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                TabStripButton(item: item, isSelected: selection == item.id, showsSeparator: showsSeparator(after: index),
                                               isHovering: hovered == item.id) {
                                    selection = item.id
                                } onClose: {
                                    onClose(item.id)
                                }
                                .frame(width: width)
                                .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
                                .id(item.id)
                            }
                        }
                        .frame(height: proxy.size.height)
                    }
                    .scrollDisabled(width * CGFloat(items.count) <= proxy.size.width)
                    .onChange(of: selection) { _, id in
                        guard let id else { return }
                        withAnimation(.snappy(duration: 0.2)) { scroller.scrollTo(id) }
                    }
                }
            }
            Menu {
                newMenu
            } label: {
                Image(systemName: "plus")
            } primaryAction: {
                onNew()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 26, height: 22)
            .contentShape(.rect)
            .help(L("New Tab"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(height: 34)
        .background(Color.primary.opacity(0.045))
    }

    /// Thin separators only between two tabs that are neither selected nor hovered (as in Finder).
    private func showsSeparator(after index: Int) -> Bool {
        guard index + 1 < items.count else { return false }
        let pair = [items[index].id, items[index + 1].id]
        return !pair.contains { $0 == selection || $0 == hovered }
    }
}

private struct TabStripButton: View {
    let item: TabStripItem
    let isSelected: Bool
    let showsSeparator: Bool
    let isHovering: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let leading = item.leading {
                Text(leading)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(item.leadingColor)
            }
            Text(item.title)
                .lineLimit(1)
                .font(.callout)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        // Keep the title clear of the close button on the leading edge and the dirty dot on the trailing one.
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .leading) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(TabCloseButtonStyle())
            .opacity(isHovering ? 1 : 0)
            .padding(.leading, 6)
            .accessibilityLabel(L("Close tab"))
            .help(L("Close Tab"))
        }
        .overlay(alignment: .trailing) {
            if item.isDirty {
                Circle().fill(.secondary).frame(width: 7, height: 7).padding(.trailing, 10)
                    .accessibilityLabel(L("Unsaved changes"))
            }
        }
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .selectedTabBackground))
                    .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
                    .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            } else if isHovering {
                RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06))
            }
        }
        .overlay(alignment: .trailing) {
            if showsSeparator {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14).offset(x: 1.5)
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        // Middle-click (scroll-wheel button) closes the tab, as in Safari and Finder.
        .overlay(MiddleClickCatcher(action: onClose))
        .contextMenu {
            Button(L("Close"), action: onClose)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityLabel(item.title)
    }
}

/// Small square close button that highlights on hover, like Safari's tab close button.
private struct TabCloseButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.18 : (isHovering ? 0.1 : 0)), in: .rect(cornerRadius: 4))
            .onHover { isHovering = $0 }
    }
}

private extension NSColor {
    /// Raised tile of the selected tab: white in light mode, a lighter gray than the bar in dark mode (as in Finder).
    static let selectedTabBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.13) : .white
    }
}

/// Transparent view that reacts only to the middle mouse button; every other event falls through to the views below.
struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?
        /// The event being dispatched; replaceable in tests.
        var currentEvent: () -> NSEvent? = { NSApp.currentEvent }
        private var isTracking = false

        static func isMiddleButton(_ event: NSEvent?) -> Bool {
            guard let event, [.otherMouseDown, .otherMouseUp, .otherMouseDragged].contains(event.type) else { return false }
            return event.buttonNumber == 2
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Claim the point only while a middle-button event is being dispatched.
            Self.isMiddleButton(currentEvent()) ? super.hitTest(point) : nil
        }

        override func otherMouseDown(with event: NSEvent) {
            guard Self.isMiddleButton(event) else { return super.otherMouseDown(with: event) }
            isTracking = true
        }

        override func otherMouseUp(with event: NSEvent) {
            guard Self.isMiddleButton(event), isTracking else { return super.otherMouseUp(with: event) }
            isTracking = false
            // Like a regular button: releasing outside the tab cancels.
            if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
        }
    }
}
