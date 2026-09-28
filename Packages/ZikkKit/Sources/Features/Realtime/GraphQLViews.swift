import SwiftUI
import APICore
import DesignSystem
import RealtimeEngine

struct GraphQLQueryEditor: View {
    @Binding var graphQL: GraphQLBody

    var body: some View {
        ResizableHSplit(id: "graphql-editor", initialFraction: 0.6, minLeft: 200, minRight: 160) {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(L("Query"))
                CodeEditor(text: $graphQL.query, language: .graphQL, identifier: "graphql-query")
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
            .frame(minWidth: 240)
        } right: {            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SectionHeader(L("GraphQL Variables"))
                    Spacer()
                    TextField(L("Operation name"), text: $graphQL.operationName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                }
                CodeEditor(text: $graphQL.variables, language: .json)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
            .frame(minWidth: 180)
        }
    }
}

/// Browses the schema from introspection and inserts sample operations.
struct GraphQLSchemaExplorer: View {
    @Bindable var document: RequestDocument
    let fetch: () async throws -> GraphQLSchema
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedType: String?
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(document.graphQLSchema == nil ? L("Fetch Schema") : L("Refresh Schema")) { load() }
                    .disabled(isLoading || document.spec.url.isEmpty)
                if isLoading { ProgressView().controlSize(.small) }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption).lineLimit(2) }
                Spacer()
                if document.graphQLSchema != nil {
                    TextField(L("Search types and fields"), text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
            }
            if let schema = document.graphQLSchema {
                ResizableHSplit(id: "graphql-schema", initialFraction: 0.35, minLeft: 160, minRight: 220) {
                    List(selection: $selectedType) {
                        ForEach(roots(schema), id: \.0) { title, name in
                            Label(title, systemImage: "arrow.right.circle").tag(Optional(name))
                        }
                        Section(L("Types")) {
                            ForEach(schema.visibleTypes.filter(matches)) { type in
                                HStack {
                                    Text(type.name)
                                    Spacer()
                                    Text(type.kind.lowercased()).font(.caption).foregroundStyle(.secondary)
                                }
                                .tag(Optional(type.name))
                            }
                        }
                    }
                    .frame(minWidth: 180, idealWidth: 220)
                } right: {                    typeDetail(schema)
                        .frame(minWidth: 260)
                }
            } else {
                ContentUnavailableView(L("No Schema"), systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text(L("Fetch the schema via introspection to browse types and insert queries.")))
            }
        }
    }

    private func roots(_ schema: GraphQLSchema) -> [(String, String)] {
        [("Query", schema.queryType), ("Mutation", schema.mutationType), ("Subscription", schema.subscriptionType)]
            .compactMap { title, name in name.map { (title, $0) } }
    }

    private func matches(_ type: GraphQLSchema.NamedType) -> Bool {
        search.isEmpty || type.name.localizedCaseInsensitiveContains(search) || type.fields.contains { $0.name.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder
    private func typeDetail(_ schema: GraphQLSchema) -> some View {
        if let type = schema.type(named: selectedType) {
            let operation = type.name == schema.mutationType ? "mutation" : (type.name == schema.subscriptionType ? "subscription" : "query")
            let isRoot = [schema.queryType, schema.mutationType, schema.subscriptionType].contains(type.name)
            List {
                Section(type.name) {
                    if let description = type.description { Text(description).foregroundStyle(.secondary) }
                    ForEach(type.fields) { field in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(field.name + (field.arguments.isEmpty ? "" : "(" + field.arguments.map { "\($0.name): \($0.type.display)" }.joined(separator: ", ") + ")"))
                                    .font(.system(.body, design: .monospaced))
                                    .strikethrough(field.isDeprecated)
                                if let description = field.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button(field.type.display) { selectedType = field.type.namedType }
                                .buttonStyle(.link)
                                .font(.system(.callout, design: .monospaced))
                            if isRoot {
                                Button(L("Insert")) { document.spec.body.graphQL.query = schema.sampleOperation(for: field, operation: operation) }
                                    .controlSize(.small)
                            }
                        }
                    }
                    ForEach(type.inputFields, id: \.name) { field in
                        Text("\(field.name): \(field.type.display)").font(.system(.body, design: .monospaced))
                    }
                    ForEach(type.enumValues, id: \.self) { Text($0).font(.system(.body, design: .monospaced)) }
                }
            }
        } else {
            Text(L("Select a type")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let schema = try await fetch()
                document.graphQLSchema = schema
                selectedType = schema.queryType
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
