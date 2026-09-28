import SwiftUI
import AppKit
import APICore
import CodeGen
import DesignSystem

/// Inspector showing the current request as code in several languages.
struct CodeSnippetPanel: View {
    let spec: RequestSpec
    let context: () -> RequestContext
    @AppStorage("codeSnippetLanguage") private var languageRaw = SnippetLanguage.curl.rawValue

    private var language: SnippetLanguage { SnippetLanguage(rawValue: languageRaw) ?? .curl }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(L("Language"), selection: $languageRaw) {
                    ForEach(SnippetLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help(L("Copy snippet"))
            }
            CodeEditor(text: .constant(code), language: highlightLanguage, isEditable: false, fontSize: 11, wrapsLines: false)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
        .padding(10)
    }

    private var code: String {
        let requestContext = context()
        do {
            let snippet = try SnippetRequest(spec: spec, resolver: requestContext.resolver, auth: requestContext.effectiveAuth(for: spec))
            return CodeGenerator.generate(snippet, language: language)
        } catch {
            return error.localizedDescription
        }
    }

    private var highlightLanguage: CodeLanguage {
        switch language {
        case .javascriptFetch, .javascriptAxios, .go, .javaOkHttp, .kotlinOkHttp, .swift: .javascript
        default: .plain
        }
    }
}
