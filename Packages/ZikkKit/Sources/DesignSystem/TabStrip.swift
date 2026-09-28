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

/// Horizontal document tab bar (Postman style) with close buttons and dirty indicators.
public struct TabStrip<NewMenu: View>: View {
    let items: [TabStripItem]
    @Binding var selection: UUID?
    let onClose: (UUID) -> Void
    let onNew: () -> Void
    let newMenu: NewMenu

    public init(items: [TabStripItem], selection: Binding<UUID?>, onClose: @escaping (UUID) -> Void, onNew: @escaping () -> Void,
                @ViewBuilder newMenu: () -> NewMenu) {
        self.items = items
        _selection = selection
        self.onClose = onClose
        self.onNew = onNew
        self.newMenu = newMenu()
    }

    public var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(items) { item in
                        TabStripButton(item: item, isSelected: selection == item.id) {
                            selection = item.id
                        } onClose: {
                            onClose(item.id)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            Menu {
                newMenu
            } label: {
                Image(systemName: "plus")
            } primaryAction: {
                onNew()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 8)
            .help(L("New Tab"))
        }
        .frame(height: 32)
    }
}

private struct TabStripButton: View {
    let item: TabStripItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

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
            ZStack {
                if item.isDirty && !isHovering {
                    Circle().fill(.orange).frame(width: 7, height: 7)
                } else {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .opacity(isHovering || isSelected ? 1 : 0)
                    .accessibilityLabel(L("Close tab"))
                }
            }
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 220)
        .background(isSelected ? AnyShapeStyle(.selection.opacity(0.25)) : (isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear)), in: .rect(cornerRadius: 7))
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(L("Close"), action: onClose)
        }
    }
}
