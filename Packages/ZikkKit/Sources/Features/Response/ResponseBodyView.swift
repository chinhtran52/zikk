import SwiftUI
import AppKit
import UniformTypeIdentifiers
import APICore
import DesignSystem

enum BodyDisplayMode: String, CaseIterable, Hashable {
    case pretty, raw, preview

    var title: String {
        switch self {
        case .pretty: L("Pretty")
        case .raw: L("Raw")
        case .preview: L("Preview")
        }
    }
}

struct ResponseBodyView: View {
    @Environment(AppModel.self) private var model
    let response: ResponseSnapshot
    /// Bodies above this size are shown truncated to keep the editor responsive.
    static let displayLimit = 2 * 1024 * 1024
    @State private var mode: BodyDisplayMode = .pretty
    @State private var wraps = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $mode) {
                    ForEach(BodyDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(language.rawValue.uppercased())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: $wraps) { Image(systemName: "text.word.spacing") }
                    .toggleStyle(.button)
                    .help(L("Wrap lines"))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(response.bodyText ?? "", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help(L("Copy response body"))
                Button {
                    let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "txt"
                    model.exportReport(response.body, fileName: "response.\(ext)", contentType: UTType(mimeType: mimeType) ?? .data)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help(L("Save response to file"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            if isTruncated {
                Label(String(format: L("Showing the first %@ of %@. Save the response to see all of it."),
                             Self.displayLimit.formatted(.byteCount(style: .file)), response.body.count.formatted(.byteCount(style: .file))),
                      systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
            }

            switch mode {
            case .pretty:
                CodeEditor(text: .constant(prettyText), language: language, isEditable: false, wrapsLines: wraps)
            case .raw:
                CodeEditor(text: .constant(displayText ?? L("<binary data>")), language: .plain, isEditable: false, wrapsLines: wraps)
            case .preview:
                WebPreview(data: response.body, mimeType: mimeType, baseURL: URL(string: response.url))
            }
        }
        .onAppear {
            if isBinaryPreviewable { mode = .preview }
        }
    }

    private var mimeType: String {
        (response.contentType ?? "text/plain").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
    }

    private var isBinaryPreviewable: Bool {
        mimeType.hasPrefix("image/") || mimeType == "application/pdf"
    }

    private var language: CodeLanguage {
        let type = mimeType
        if type.contains("json") { return .json }
        if type.contains("html") { return .html }
        if type.contains("xml") { return .xml }
        if type.contains("javascript") { return .javascript }
        if type.contains("yaml") { return .yaml }
        if let text = response.bodyText?.trimmingCharacters(in: .whitespaces), text.hasPrefix("{") || text.hasPrefix("[") { return .json }
        return .plain
    }

    private var isTruncated: Bool { response.body.count > Self.displayLimit }

    private var displayText: String? {
        guard isTruncated else { return response.bodyText }
        return String(decoding: response.body.prefix(Self.displayLimit), as: UTF8.self)
    }

    private var prettyText: String {
        guard let text = displayText else { return L("<binary data>") }
        if !isTruncated, language == .json, let pretty = JSONFormatter.prettyPrinted(text) { return pretty }
        return text
    }
}
