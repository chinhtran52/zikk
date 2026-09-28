import SwiftUI
import SwiftData
import APICore
import APIStore
import DesignSystem
import RealtimeEngine

enum RequestEditorTab: String, CaseIterable, Hashable {
    case query, params, auth, headers, body, scripts, settings, schema, docs

    static func tabs(for kind: RequestKind) -> [RequestEditorTab] {
        kind == .graphQL ? [.query, .headers, .auth, .scripts, .settings, .schema, .docs] : [.params, .auth, .headers, .body, .scripts, .settings, .docs]
    }

    var title: String {
        switch self {
        case .query: L("Query")
        case .schema: L("Schema")
        case .params: L("Params")
        case .auth: L("Authorization")
        case .headers: L("Headers")
        case .body: L("Body")
        case .scripts: L("Scripts")
        case .settings: L("Settings")
        case .docs: L("Docs")
        }
    }
}

/// Request tab: URL bar and request sections on top, response below.
struct RequestEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Bindable var document: RequestDocument
    let workspace: Workspace
    @State private var tab: RequestEditorTab = .params

    private var node: CollectionNode? {
        document.nodeID.flatMap { CollectionQueries.node($0, in: context) }
    }

    private func requestContext() -> RequestContext {
        RequestContext(spec: document.spec, node: node, workspace: workspace, secrets: model.services.secrets)
    }

    var body: some View {
        ResizableVSplit(id: "request") {
            editorPane
        } bottom: {
            responsePane
        }
    }

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            RequestTitleBar(document: document)
            URLBar(document: document, variables: VariableLookup(workspace: workspace, node: node))
            UnderlineTabs(RequestEditorTab.tabs(for: document.spec.kind), selection: $tab, title: \.title, badge: badge)
            Divider()
            ScrollView {
                tabContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
            }
            .scrollDisabled(tab == .body || tab == .scripts || tab == .docs || tab == .query || tab == .schema)
        }
        .padding([.horizontal, .top], 14)
        .frame(maxWidth: .infinity, minHeight: 220, idealHeight: 340, alignment: .topLeading)
        .onAppear { if !RequestEditorTab.tabs(for: document.spec.kind).contains(tab) { tab = RequestEditorTab.tabs(for: document.spec.kind)[0] } }
    }

    private var responsePane: some View {
        let saveAction: (() -> Void)? = node == nil ? nil : { saveExample() }
        return ResponseView(document: document, onSaveExample: saveAction)
            .frame(minHeight: 160)
    }

    /// Runs an introspection query with the request's URL, headers and auth.
    private func fetchSchema() async throws -> GraphQLSchema {
        var spec = document.spec
        spec.method = .post
        spec.body = RequestBody(mode: .graphQL, graphQL: GraphQLBody(query: GraphQLSchema.introspectionQuery))
        let requestContext = requestContext()
        let prepared = try requestContext.builder(for: spec).build(spec)
        let response = try await model.services.httpClient.send(prepared)
        return try GraphQLSchema.parse(response.body)
    }

    private func saveExample() {
        guard let node, let response = document.response else { return }
        let example = SavedExample(name: document.name + " – \(response.statusCode)", request: document.spec, response: response)
        example.node = node
        context.insert(example)
        try? context.save()
        model.open(.example(example.id), title: example.name)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .query:
            GraphQLQueryEditor(graphQL: $document.spec.body.graphQL)
                .frame(minHeight: 200)
        case .schema:
            GraphQLSchemaExplorer(document: document, fetch: fetchSchema)
                .frame(minHeight: 200)
        case .params:
            ParamsTab(document: document)
        case .auth:
            AuthEditor(auth: $document.spec.auth, allowsInherit: true, resolver: { requestContext().resolver })
        case .headers:
            HeadersTab(document: document)
        case .body:
            BodyEditor(requestBody: $document.spec.body)
        case .scripts:
            ScriptsEditor(preRequest: $document.spec.preRequestScript, tests: $document.spec.testScript)
        case .settings:
            RequestSettingsForm(settings: $document.spec.settings)
        case .docs:
            if let node {
                MarkdownDescriptionEditor(text: Binding(get: { node.descriptionMD }, set: { node.descriptionMD = $0; try? context.save() }))
                    .frame(minHeight: 240)
            } else {
                Text(L("Save the request to a collection to document it."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func badge(_ tab: RequestEditorTab) -> String? {
        let spec = document.spec
        switch tab {
        case .params:
            let count = spec.params.active.count + spec.pathVariables.count
            return count > 0 ? "\(count)" : nil
        case .headers:
            let count = spec.headers.active.count
            return count > 0 ? "\(count)" : nil
        case .body:
            return spec.body.mode == .none ? nil : "●"
        case .auth:
            return spec.auth.type == .inherit || spec.auth.type == .none ? nil : "●"
        case .scripts:
            return spec.preRequestScript.isEmpty && spec.testScript.isEmpty ? nil : "●"
        case .settings, .schema:
            return nil
        case .query:
            return spec.body.graphQL.query.isEmpty ? nil : "●"
        case .docs:
            return (node?.descriptionMD.isEmpty ?? true) ? nil : "●"
        }
    }
}

struct RequestTitleBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Bindable var document: RequestDocument

    private var examples: [SavedExample] {
        guard let id = document.nodeID, let node = CollectionQueries.node(id, in: context) else { return [] }
        return node.examples.filter { $0.deletedAt == nil }.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        HStack {
            if let breadcrumb {
                Text(breadcrumb + " /").foregroundStyle(.secondary).lineLimit(1)
            }
            TextField(L("Request name"), text: $document.name)
                .textFieldStyle(.plain)
                .font(.headline)
            Spacer()
            let examples = examples
            if !examples.isEmpty {
                Menu {
                    ForEach(examples) { example in
                        Button(example.name) { model.open(.example(example.id), title: example.name) }
                    }
                } label: {
                    Label(L("Examples") + " (\(examples.count))", systemImage: "doc.text.image")
                }
                .fixedSize()
            }
            Button {
                model.requestSave(document)
            } label: {
                Label(L("Save"), systemImage: "square.and.arrow.down")
            }
            .disabled(!document.isDirty && !document.isDraft)
            .help(L("Save (⌘S)"))
        }
    }

    private var breadcrumb: String? {
        guard let id = document.nodeID, let node = CollectionQueries.node(id, in: context), let collection = node.collection else { return nil }
        return ([collection.name] + node.ancestors.map(\.name)).joined(separator: " / ")
    }
}

struct URLBar: View {
    @Environment(AppModel.self) private var model
    @Bindable var document: RequestDocument
    let variables: VariableLookup
    @State private var customMethod = ""
    @State private var isEditingCustomMethod = false

    var body: some View {
        HStack(spacing: 8) {
            if document.spec.kind == .graphQL {
                Text("GQL")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.pink)
                    .frame(minWidth: 44)
            } else {
            Menu {
                ForEach(HTTPMethod.standard, id: \.self) { method in
                    Button(method.rawValue) { document.spec.method = method }
                }
                Divider()
                Button(L("Custom…")) { isEditingCustomMethod = true }
            } label: {
                Text(document.spec.method.rawValue)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(document.spec.method.tint)
            }
            .menuStyle(.button)
            .fixedSize()
            .popover(isPresented: $isEditingCustomMethod) {
                TextField(L("Method"), text: $customMethod)
                    .onSubmit {
                        if !customMethod.isEmpty { document.spec.method = HTTPMethod(rawValue: customMethod) }
                        isEditingCustomMethod = false
                    }
                    .frame(width: 160)
                    .padding()
            }
            }

            VariableTextField(L("Enter URL or paste text"), text: Binding(get: { document.spec.url }, set: document.setURL),
                              identifier: "url-field", lookup: variables.info) { model.send(document) }

            if document.isSending {
                Button(L("Cancel"), role: .cancel) { document.cancel() }
                    .controlSize(.large)
            } else {
                Button(L("Send")) { model.send(document) }
                    .accessibilityIdentifier("send-button")
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }
}

private struct ParamsTab: View {
    @Bindable var document: RequestDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(L("Query Params"))
            KeyValueTable(rows: Binding(get: { document.spec.params }, set: document.setParams))
            if !document.spec.pathVariables.isEmpty {
                SectionHeader(L("Path Variables"))
                KeyValueTable(rows: $document.spec.pathVariables, allowsAdding: false)
            }
        }
    }
}

private struct HeadersTab: View {
    @Bindable var document: RequestDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyValueTable(rows: $document.spec.headers)
            Text(L("User-Agent, Accept, Content-Type and auth headers are added automatically unless set here."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct RequestSettingsForm: View {
    @Binding var settings: RequestSettings

    var body: some View {
        Form {
            Toggle(L("Follow redirects"), isOn: $settings.followRedirects)
            Stepper(value: $settings.maxRedirects, in: 1...50) {
                LabeledContent(L("Maximum redirects"), value: "\(settings.maxRedirects)")
            }
            .disabled(!settings.followRedirects)
            Toggle(L("Verify SSL certificates"), isOn: $settings.verifySSL)
            Toggle(L("Encode URL automatically"), isOn: $settings.encodeURL)
            Toggle(L("Disable cookie jar"), isOn: $settings.disableCookieJar)
            TextField(L("Timeout (ms, 0 = default)"), value: $settings.timeoutMilliseconds, format: .number)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

struct ScriptsEditor: View {
    @Binding var preRequest: String
    @Binding var tests: String
    @State private var selection = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $selection) {
                    Text(L("Pre-request")).tag(0)
                    Text(L("Post-response")).tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("script-phase")
                Spacer()
                Menu(L("Snippets")) {
                    ForEach(selection == 0 ? ScriptSnippet.preRequest : ScriptSnippet.tests) { snippet in
                        Button(snippet.title) { insert(snippet.code) }
                    }
                }
                .fixedSize()
            }
            Group {
                if selection == 0 {
                    CodeEditor(text: $preRequest, language: .javascript, identifier: "pre-request-editor")
                } else {
                    CodeEditor(text: $tests, language: .javascript, identifier: "test-script-editor")
                }
            }
            .frame(minHeight: 160)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
    }

    private func insert(_ code: String) {
        if selection == 0 {
            preRequest += (preRequest.isEmpty || preRequest.hasSuffix("\n") ? "" : "\n") + code + "\n"
        } else {
            tests += (tests.isEmpty || tests.hasSuffix("\n") ? "" : "\n") + code + "\n"
        }
    }
}

struct ScriptSnippet: Identifiable {
    let id = UUID()
    let title: String
    let code: String

    static let preRequest: [ScriptSnippet] = [
        ScriptSnippet(title: L("Set an environment variable"), code: #"pm.environment.set("variable_key", "variable_value");"#),
        ScriptSnippet(title: L("Set a global variable"), code: #"pm.globals.set("variable_key", "variable_value");"#),
        ScriptSnippet(title: L("Set a collection variable"), code: #"pm.collectionVariables.set("variable_key", "variable_value");"#),
        ScriptSnippet(title: L("Get a variable"), code: #"pm.variables.get("variable_key");"#),
        ScriptSnippet(title: L("Add a header"), code: #"pm.request.headers.add({ key: "X-Custom", value: "value" });"#),
        ScriptSnippet(title: L("Add a timestamp query param"), code: #"pm.request.url.query.add({ key: "ts", value: Date.now().toString() });"#),
        ScriptSnippet(title: L("Send a request"), code: """
        pm.sendRequest("https://postman-echo.com/get", (error, response) => {
          console.log(error ? error : response.json());
        });
        """),
        ScriptSnippet(title: L("HMAC signature (CryptoJS)"), code: """
        const signature = CryptoJS.HmacSHA256(pm.request.url.toString(), pm.environment.get("secret")).toString();
        pm.request.headers.upsert({ key: "X-Signature", value: signature });
        """),
    ]

    static let tests: [ScriptSnippet] = [
        ScriptSnippet(title: L("Status code is 200"), code: """
        pm.test("Status code is 200", function () {
          pm.response.to.have.status(200);
        });
        """),
        ScriptSnippet(title: L("Response time is less than 200ms"), code: """
        pm.test("Response time is less than 200ms", function () {
          pm.expect(pm.response.responseTime).to.be.below(200);
        });
        """),
        ScriptSnippet(title: L("Response body: JSON value check"), code: """
        pm.test("Your test name", function () {
          const jsonData = pm.response.json();
          pm.expect(jsonData.value).to.eql(100);
        });
        """),
        ScriptSnippet(title: L("Response body: contains string"), code: """
        pm.test("Body matches string", function () {
          pm.expect(pm.response.text()).to.include("string_you_want_to_search");
        });
        """),
        ScriptSnippet(title: L("Content-Type header is present"), code: """
        pm.test("Content-Type is present", function () {
          pm.response.to.have.header("Content-Type");
        });
        """),
        ScriptSnippet(title: L("Save a response value to environment"), code: """
        const jsonData = pm.response.json();
        pm.environment.set("token", jsonData.token);
        """),
        ScriptSnippet(title: L("Set next request (runner)"), code: #"postman.setNextRequest("request_name");"#),
    ]
}
