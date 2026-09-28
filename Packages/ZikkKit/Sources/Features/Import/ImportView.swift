import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import APICore
import APIStore
import Interop
import SpecKit

/// What an import payload turned out to be.
enum ImportPayload {
    case collection(InteropCollection)
    case environment(InteropEnvironment)
    case curl(RequestSpecBox)
    /// OpenAPI / Swagger document text (JSON or YAML).
    case openAPI(text: String, format: SpecFormat, title: String)

    /// Detects the format of pasted text or file contents.
    static func detect(_ data: Data) throws -> ImportPayload {
        let text = String(decoding: data, as: UTF8.self)
        if CurlParser.looksLikeCurl(text) {
            return .curl(RequestSpecBox(spec: try CurlParser.parse(text)))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // YAML: only OpenAPI/Swagger documents are supported.
            if let document = try? SpecDocument(text: text), document.version != nil {
                return .openAPI(text: text, format: .yaml, title: document.title)
            }
            throw ImportError.unrecognized
        }
        if object["openapi"] != nil || object["swagger"] != nil {
            let document = try SpecDocument(text: text)
            return .openAPI(text: text, format: .json, title: document.title)
        }
        if PostmanCollection.detect(object) { return .collection(try PostmanCollection.decode(data)) }
        if PostmanEnvironment.detect(object) { return .environment(try PostmanEnvironment.decode(data)) }
        throw ImportError.unrecognized
    }
}

struct RequestSpecBox {
    var spec: RequestSpec
}

enum ImportError: LocalizedError {
    case unrecognized
    var errorDescription: String? {
        L("Unrecognized format. Supported: Postman Collection v2.0/v2.1, Postman Environment, OpenAPI 3.x, Swagger 2.0, cURL.")
    }
}

struct ImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let workspace: Workspace
    @State private var text = ""
    @State private var isPickingFile = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Import")).font(.title2.bold())
            Text(L("Import a Postman collection or environment, an OpenAPI/Swagger spec, or paste a cURL command."))
                .foregroundStyle(.secondary)
            Button {
                isPickingFile = true
            } label: {
                Label(L("Choose Files…"), systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(.bordered)
            .dropDestination(for: URL.self) { urls, _ in
                importFiles(urls)
                return true
            }
            Text(L("Or paste raw text")).font(.headline)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Import")) { importData(Data(text.utf8)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.json, .yaml, .plainText, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                errorMessage = L("Could not read the selected file.")
                return
            }
            guard importData(data, dismissOnSuccess: false) else { return }
        }
        dismiss()
    }

    @discardableResult
    private func importData(_ data: Data, dismissOnSuccess: Bool = true) -> Bool {
        do {
            switch try ImportPayload.detect(data) {
            case .collection(let collection):
                InteropMapper.insert(collection, into: workspace, context: context, secrets: model.services.secrets)
                model.section = .collections
            case .environment(let environment):
                let inserted = InteropMapper.insert(environment, into: workspace, context: context, secrets: model.services.secrets)
                model.section = .environments
                model.open(.environment(inserted.id), title: inserted.name)
            case .curl(let box):
                model.openDraft(spec: box.spec, name: box.spec.url)
            case .openAPI(let text, let format, let title):
                let spec = APISpec(name: title, format: format, content: text)
                spec.workspace = workspace
                context.insert(spec)
                let collection = try SpecServices.generateCollection(from: spec, workspace: workspace, context: context, secrets: model.services.secrets)
                model.section = .collections
                model.open(.collection(collection.id), title: collection.name)
            }
            errorMessage = nil
            if dismissOnSuccess { dismiss() }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// Exported file for `fileExporter` (JSON, CSV or XML payloads).
struct JSONFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    static let writableContentTypes: [UTType] = [.json, .commaSeparatedText, .xml, .yaml, .html, .data, .plainText, .image, .pdf]
    var data: Data
    var contentType: UTType

    init(data: Data, contentType: UTType = .json) {
        self.data = data
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = .json
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
