import SwiftUI

/// Postman-style text tabs with an underline on the selected item and optional count badges.
public struct UnderlineTabs<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    let badge: (Item) -> String?

    public init(_ items: [Item], selection: Binding<Item>, title: @escaping (Item) -> String, badge: @escaping (Item) -> String? = { _ in nil }) {
        self.items = items
        _selection = selection
        self.title = title
        self.badge = badge
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            tabs
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private var tabs: some View {
        HStack(spacing: 16) {
            ForEach(items, id: \.self) { item in
                Button {
                    selection = item
                } label: {
                    HStack(spacing: 4) {
                        Text(title(item))
                            .lineLimit(1)
                            .fixedSize()
                        if let badge = badge(item) {
                            Text(badge)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(item == selection ? Color.accentColor : .secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .foregroundStyle(item == selection ? .primary : .secondary)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(item == selection ? Color.accentColor : .clear)
                            .frame(height: 2)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout.weight(.medium))
    }
}
