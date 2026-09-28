import SwiftUI
import SwiftData
import APIStore
import CodeGen
import Docs

/// Generated API documentation for a collection, with HTML export.
struct DocumentationView: View {
    @Environment(AppModel.self) private var model
    let collection: APICollection
    let workspace: Workspace
    @AppStorage("docsSnippetLanguage") private var languageRaw = SnippetLanguage.curl.rawValue
    @State private var html = ""

    private var language: SnippetLanguage { SnippetLanguage(rawValue: languageRaw) ?? .curl }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L("Documentation"), systemImage: "book").font(.headline)
                Spacer()
                Picker(L("Code samples"), selection: $languageRaw) {
                    ForEach(SnippetLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .fixedSize()
                Button(L("Refresh"), systemImage: "arrow.clockwise", action: regenerate)
                Button(L("Export HTML…"), systemImage: "square.and.arrow.up") {
                    model.exportReport(Data(html.utf8), fileName: "\(collection.name).html", contentType: .html)
                }
            }
            .padding(10)
            Divider()
            WebPreview(data: Data(html.utf8), mimeType: "text/html", baseURL: nil, allowsJavaScript: false)
        }
        .onAppear(perform: regenerate)
        .onChange(of: languageRaw) { regenerate() }
    }

    private func regenerate() {
        let requestContext = RequestContext(spec: .init(), node: collection.rootNodes.first, workspace: workspace, secrets: model.services.secrets)
        let generator = DocumentationGenerator(snippetLanguage: language, resolver: requestContext.resolver)
        html = generator.html(for: InteropMapper.export(collection, secrets: model.services.secrets))
    }
}
