import SwiftUI
import UniformTypeIdentifiers
import APICore
import DesignSystem
import HTTPEngine

extension BodyMode {
    var title: String {
        switch self {
        case .none: L("none")
        case .formData: "form-data"
        case .urlEncoded: "x-www-form-urlencoded"
        case .raw: "raw"
        case .binary: "binary"
        case .graphQL: "GraphQL"
        }
    }
}

extension RawLanguage {
    var title: String {
        switch self {
        case .text: "Text"
        case .json: "JSON"
        case .xml: "XML"
        case .html: "HTML"
        case .javascript: "JavaScript"
        }
    }

    var codeLanguage: CodeLanguage {
        switch self {
        case .text: .plain
        case .json: .json
        case .xml: .xml
        case .html: .html
        case .javascript: .javascript
        }
    }
}

struct BodyEditor: View {
    @Binding var requestBody: RequestBody

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("", selection: $requestBody.mode) {
                    ForEach(BodyMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                if requestBody.mode == .raw {
                    Picker("", selection: $requestBody.rawLanguage) {
                        ForEach(RawLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if requestBody.rawLanguage == .json {
                        Button(L("Beautify")) {
                            if let pretty = JSONFormatter.prettyPrinted(requestBody.raw) { requestBody.raw = pretty }
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch requestBody.mode {
        case .none:
            Text(L("This request does not have a body"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        case .raw:
            CodeEditor(text: $requestBody.raw, language: requestBody.rawLanguage.codeLanguage)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        case .urlEncoded:
            ScrollView { KeyValueTable(rows: $requestBody.urlEncoded) }
        case .formData:
            ScrollView { FormDataTable(fields: $requestBody.formData) }
        case .binary:
            FilePickerRow(file: $requestBody.binary)
            Spacer()
        case .graphQL:
            ResizableHSplit(id: "graphql-body", initialFraction: 0.6, minLeft: 200, minRight: 160) {
                VStack(alignment: .leading) {
                    SectionHeader(L("Query"))
                    CodeEditor(text: $requestBody.graphQL.query, language: .graphQL)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                }
                .frame(minWidth: 200)
            } right: {                VStack(alignment: .leading) {
                    SectionHeader(L("GraphQL Variables"))
                    CodeEditor(text: $requestBody.graphQL.variables, language: .json)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                }
                .frame(minWidth: 160)
            }
            .frame(minHeight: 140)
        }
    }
}

struct FilePickerRow: View {
    @Binding var file: FileReference?
    @State private var isImporting = false

    var body: some View {
        HStack {
            Button(file == nil ? L("Select File") : L("Change File")) { isImporting = true }
            if let file {
                Label(file.fileName, systemImage: "doc")
                    .help(file.path)
                Button {
                    self.file = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("Remove file"))
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                file = FileAccess.reference(for: url)
            }
        }
    }
}

struct FormDataTable: View {
    @Binding var fields: [FormDataField]
    @State private var placeholder = FormDataField()

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach([L("Key"), L("Type"), L("Value"), L("Content-Type"), L("Notes")], id: \.self) { title in
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
            ForEach(fields + [placeholder]) { field in
                let isPlaceholder = field.id == placeholder.id
                GridRow {
                    Toggle("", isOn: binding(field, \.isEnabled))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .opacity(isPlaceholder ? 0 : 1)
                    TextField(L("Key"), text: binding(field, \.key))
                    Picker("", selection: binding(field, \.kind)) {
                        Text(L("Text")).tag(FormDataField.Kind.text)
                        Text(L("File")).tag(FormDataField.Kind.file)
                    }
                    .labelsHidden()
                    .fixedSize()
                    if field.kind == .text {
                        TextField(L("Value"), text: binding(field, \.value))
                    } else {
                        FilePickerRow(file: binding(field, \.file))
                    }
                    TextField(L("Content-Type"), text: binding(field, \.contentType))
                        .frame(maxWidth: 140)
                    TextField(L("Notes"), text: binding(field, \.notes))
                        // Long notes scroll inside the field; the tooltip shows them in full.
                        .help(field.notes.isEmpty ? L("Notes about this field, e.g. what it is for or which values are allowed") : field.notes)
                        .accessibilityIdentifier("form-field-notes")
                    Button {
                        fields.removeAll { $0.id == field.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .opacity(isPlaceholder ? 0 : 1)
                    .disabled(isPlaceholder)
                    .accessibilityLabel(L("Remove row"))
                }
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func binding<Value>(_ field: FormDataField, _ keyPath: WritableKeyPath<FormDataField, Value>) -> Binding<Value> {
        Binding {
            fields.first { $0.id == field.id }?[keyPath: keyPath] ?? placeholder[keyPath: keyPath]
        } set: { newValue in
            if let index = fields.firstIndex(where: { $0.id == field.id }) {
                fields[index][keyPath: keyPath] = newValue
            } else {
                var created = placeholder
                created[keyPath: keyPath] = newValue
                fields.append(created)
                placeholder = FormDataField()
            }
        }
    }
}
