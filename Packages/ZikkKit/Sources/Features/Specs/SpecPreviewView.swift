import SwiftUI
import APICore
import DesignSystem
import SpecKit

/// Native, Swagger UI–style rendering of an API description.
struct SpecPreviewView: View {
    let document: SpecDocument

    private var groups: [(String, [SpecDocument.Operation])] {
        var order: [String] = document.root["tags"]?.items.compactMap { $0["name"]?.string } ?? []
        var grouped: [String: [SpecDocument.Operation]] = [:]
        for operation in document.operations {
            let tag = operation.tags.first ?? L("default")
            if !order.contains(tag) { order.append(tag) }
            grouped[tag, default: []].append(operation)
        }
        return order.compactMap { tag in grouped[tag].map { (tag, $0) } }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(document.title).font(.largeTitle.bold())
                    if !document.apiVersion.isEmpty {
                        Text(document.apiVersion).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                    if let version = document.version {
                        Text(version == .swagger2 ? "Swagger 2.0" : "OpenAPI \(version.rawValue)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !document.description.isEmpty {
                    Text(MarkdownDescriptionEditor.render(document.description)).textSelection(.enabled)
                }
                if !document.baseURL.isEmpty {
                    LabeledContent(L("Server"), value: document.baseURL).font(.system(.body, design: .monospaced))
                }
                ForEach(groups, id: \.0) { tag, operations in
                    Text(tag).font(.title2.bold()).padding(.top, 8)
                    ForEach(operations, id: \.line) { operation in
                        OperationCard(operation: operation, document: document)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OperationCard: View {
    let operation: SpecDocument.Operation
    let document: SpecDocument
    @State private var isExpanded = false

    var body: some View {
        let method = HTTPMethod(rawValue: operation.method)
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if let description = operation.node["description"]?.string {
                    Text(MarkdownDescriptionEditor.render(description)).textSelection(.enabled)
                }
                let parameters = document.parameters(of: operation)
                if !parameters.isEmpty {
                    SectionHeader(L("Parameters"))
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        ForEach(Array(parameters.enumerated()), id: \.offset) { _, parameter in
                            GridRow {
                                HStack(spacing: 2) {
                                    Text(parameter["name"]?.string ?? "").font(.system(.body, design: .monospaced).bold())
                                    if parameter["required"]?.bool == true { Text(verbatim: "*").foregroundStyle(.red) }
                                }
                                Text(parameter["in"]?.string ?? "").foregroundStyle(.secondary)
                                Text(typeLabel(parameter["schema"] ?? parameter)).foregroundStyle(.teal).font(.system(.body, design: .monospaced))
                                Text(parameter["description"]?.string ?? "").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let body = document.resolve(operation.node["requestBody"]), let content = body["content"] {
                    SectionHeader(L("Request Body"))
                    ForEach(content.entries, id: \.key) { media in
                        MediaView(mediaType: media.key, media: media.value, document: document)
                    }
                }
                SectionHeader(L("Responses"))
                ForEach(operation.node["responses"]?.entries ?? [], id: \.key) { response in
                    let resolved = document.resolve(response.value)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(response.key).font(.system(.body, design: .monospaced).bold())
                                .foregroundStyle(Int(response.key).map { StatusBadge.color(for: $0) } ?? .secondary)
                            Text(resolved?["description"]?.string ?? "").foregroundStyle(.secondary)
                        }
                        ForEach(resolved?["content"]?.entries ?? [], id: \.key) { media in
                            MediaView(mediaType: media.key, media: media.value, document: document)
                        }
                        if let schema = resolved?["schema"] {
                            MediaView(mediaType: "application/json", media: SpecNode(.object([SpecEntry(key: "schema", keyLine: 0, value: schema)])), document: document)
                        }
                    }
                    .padding(.leading, 8)
                }
            }
            .padding(.vertical, 8)
        } label: {
            HStack(spacing: 10) {
                Text(method.rawValue)
                    .font(.system(.callout, design: .monospaced).bold())
                    .foregroundStyle(.white)
                    .frame(width: 70)
                    .padding(.vertical, 4)
                    .background(method.tint, in: .rect(cornerRadius: 4))
                Text(operation.path).font(.system(.body, design: .monospaced).bold())
                Text(operation.summary ?? "").foregroundStyle(.secondary).lineLimit(1)
                if operation.node["deprecated"]?.bool == true {
                    Text(L("Deprecated")).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(10)
        .background(method.tint.opacity(0.07), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(method.tint.opacity(0.35)))
    }

    private func typeLabel(_ node: SpecNode) -> String {
        let resolved = document.resolve(node) ?? node
        let type = resolved["type"]?.string ?? (node["$ref"]?.string.map { String($0.split(separator: "/").last ?? "") } ?? "")
        if let format = resolved["format"]?.string { return "\(type) (\(format))" }
        return type
    }
}

private struct MediaView: View {
    let mediaType: String
    let media: SpecNode
    let document: SpecDocument
    @State private var showsSchema = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(mediaType).font(.caption.monospaced()).foregroundStyle(.secondary)
                Picker("", selection: $showsSchema) {
                    Text(L("Example")).tag(false)
                    Text(L("Schema")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            if showsSchema {
                SchemaTree(schema: media["schema"], document: document, depth: 0)
                    .padding(8)
                    .background(.background.secondary, in: .rect(cornerRadius: 6))
            } else if let example = SchemaExample.example(forMediaType: media, in: document) {
                Text(example as? String ?? SchemaExample.json(example))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: .rect(cornerRadius: 6))
            }
        }
    }
}

private struct SchemaTree: View {
    let schema: SpecNode?
    let document: SpecDocument
    let depth: Int

    var body: some View {
        let resolved = document.resolve(schema)
        let refName = schema?["$ref"]?.string.map { String($0.split(separator: "/").last ?? "") }
        VStack(alignment: .leading, spacing: 4) {
            if let resolved {
                let type = resolved["type"]?.string ?? (resolved["properties"] != nil ? "object" : resolved["allOf"] != nil ? "allOf" : "")
                Text((refName.map { "\($0) " } ?? "") + type).font(.system(.callout, design: .monospaced)).foregroundStyle(.teal)
                if depth < 6 {
                    let required = Set(resolved["required"]?.items.compactMap(\.string) ?? [])
                    ForEach(resolved["properties"]?.entries ?? [], id: \.key) { property in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(property.key + (required.contains(property.key) ? "*" : ""))
                                .font(.system(.callout, design: .monospaced).bold())
                            SchemaTree(schema: property.value, document: document, depth: depth + 1)
                        }
                        .padding(.leading, 12)
                    }
                    if let items = resolved["items"] {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: "[ ]").foregroundStyle(.secondary)
                            SchemaTree(schema: items, document: document, depth: depth + 1)
                        }
                        .padding(.leading, 12)
                    }
                    ForEach(Array((resolved["allOf"]?.items ?? []).enumerated()), id: \.offset) { _, part in
                        SchemaTree(schema: part, document: document, depth: depth + 1).padding(.leading, 12)
                    }
                }
                if let description = resolved["description"]?.string {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
