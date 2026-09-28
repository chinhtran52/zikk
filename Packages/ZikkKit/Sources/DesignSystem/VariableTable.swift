import SwiftUI
import APICore

/// Editable table of variables with enable and secret toggles; a trailing blank row adds new variables.
public struct VariableTable: View {
    @Binding var variables: [Variable]
    @State private var placeholder = Variable()
    @State private var revealed: Set<UUID> = []

    public init(variables: Binding<[Variable]>) {
        _variables = variables
    }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
            GridRow {
                Text(verbatim: "")
                Text(L("Variable")).gridColumnAlignment(.leading)
                Text(L("Value"))
                Text(L("Secret"))
                Text(verbatim: "")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(variables + [placeholder]) { variable in
                let isPlaceholder = variable.id == placeholder.id
                GridRow {
                    Toggle("", isOn: binding(variable, \.isEnabled))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .opacity(isPlaceholder ? 0 : 1)
                        .disabled(isPlaceholder)
                    TextField(L("Add variable"), text: binding(variable, \.key))
                        .frame(minWidth: 140)
                    HStack(spacing: 4) {
                        if variable.isSecret && !revealed.contains(variable.id) {
                            SecureField(L("Value"), text: binding(variable, \.value))
                        } else {
                            TextField(L("Value"), text: binding(variable, \.value))
                        }
                        if variable.isSecret {
                            Button {
                                if revealed.contains(variable.id) { revealed.remove(variable.id) } else { revealed.insert(variable.id) }
                            } label: {
                                Image(systemName: revealed.contains(variable.id) ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L("Reveal value"))
                        }
                    }
                    .frame(minWidth: 200)
                    Toggle("", isOn: binding(variable, \.isSecret))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .opacity(isPlaceholder ? 0 : 1)
                        .disabled(isPlaceholder)
                    Button {
                        variables.removeAll { $0.id == variable.id }
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
    }

    private func binding<Value>(_ variable: Variable, _ keyPath: WritableKeyPath<Variable, Value>) -> Binding<Value> {
        Binding {
            variables.first { $0.id == variable.id }?[keyPath: keyPath] ?? placeholder[keyPath: keyPath]
        } set: { newValue in
            if let index = variables.firstIndex(where: { $0.id == variable.id }) {
                variables[index][keyPath: keyPath] = newValue
            } else {
                var created = placeholder
                created[keyPath: keyPath] = newValue
                variables.append(created)
                placeholder = Variable()
            }
        }
    }
}
