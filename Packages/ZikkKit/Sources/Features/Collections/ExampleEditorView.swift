import SwiftUI
import SwiftData
import APICore
import APIStore
import DesignSystem

/// Edits a saved example response (used by documentation and mock servers).
struct ExampleEditorView: View {
    @Environment(\.modelContext) private var context
    @Bindable var example: SavedExample
    @State private var response = ResponseSnapshot(statusCode: 200)
    @State private var bodyText = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.text.image")
                TextField(L("Example name"), text: $example.name)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
            }
            let request = example.request
            HStack {
                MethodBadge(request.method, kind: request.kind)
                Text(request.url).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            Form {
                TextField(L("Status code"), value: $response.statusCode, format: .number.grouping(.never))
                LabeledContent(L("Status")) { StatusBadge(response.statusCode) }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(maxHeight: 110)
            SectionHeader(L("Response Headers"))
            KeyValueTable(rows: $response.headers, showsDescription: false)
            SectionHeader(L("Response Body"))
            CodeEditor(text: $bodyText, language: (response.contentType ?? "").contains("json") ? .json : .plain)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
        .padding(16)
        .onAppear {
            response = example.response
            bodyText = response.bodyText ?? ""
            loaded = true
        }
        .onChange(of: response) { persist() }
        .onChange(of: bodyText) { persist() }
        .onChange(of: example.name) { try? context.save() }
    }

    private func persist() {
        guard loaded else { return }
        var updated = response
        updated.body = Data(bodyText.utf8)
        example.response = updated
        try? context.save()
    }
}
