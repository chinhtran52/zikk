import SwiftUI
import APICore

/// Editable key/value grid in Postman style: a trailing blank row is always present and becomes a real
/// row as soon as the user types in it.
public struct KeyValueTable: View {
    @Binding var rows: [KeyValue]
    var keyPlaceholder: String
    var valuePlaceholder: String
    var showsDescription: Bool
    var allowsAdding: Bool

    public init(rows: Binding<[KeyValue]>, keyPlaceholder: String? = nil, valuePlaceholder: String? = nil, showsDescription: Bool = true, allowsAdding: Bool = true) {
        _rows = rows
        self.keyPlaceholder = keyPlaceholder ?? L("Key")
        self.valuePlaceholder = valuePlaceholder ?? L("Value")
        self.showsDescription = showsDescription
        self.allowsAdding = allowsAdding
    }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
            ForEach(displayRows) { row in
                GridRow {
                    let isPlaceholder = !rows.contains { $0.id == row.id }
                    Toggle("", isOn: binding(for: row, \.isEnabled))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .disabled(isPlaceholder)
                        .opacity(isPlaceholder ? 0 : 1)
                    TextField(keyPlaceholder, text: binding(for: row, \.key))
                    TextField(valuePlaceholder, text: binding(for: row, \.value))
                    if showsDescription {
                        TextField(L("Description"), text: binding(for: row, \.description))
                    }
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .opacity(isPlaceholder ? 0 : 1)
                    .disabled(isPlaceholder)
                    .accessibilityLabel(L("Remove row"))
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            }
        }
        .padding(.vertical, 4)
    }

    @State private var placeholder = KeyValue()

    private var displayRows: [KeyValue] {
        allowsAdding ? rows + [placeholder] : rows
    }

    private func binding<Value>(for row: KeyValue, _ keyPath: WritableKeyPath<KeyValue, Value>) -> Binding<Value> {
        Binding {
            rows.first { $0.id == row.id }?[keyPath: keyPath] ?? placeholder[keyPath: keyPath]
        } set: { newValue in
            if let index = rows.firstIndex(where: { $0.id == row.id }) {
                rows[index][keyPath: keyPath] = newValue
            } else {
                var created = placeholder
                created[keyPath: keyPath] = newValue
                rows.append(created)
                placeholder = KeyValue()
            }
        }
    }
}
