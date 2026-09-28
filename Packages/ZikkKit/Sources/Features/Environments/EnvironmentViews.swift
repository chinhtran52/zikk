import SwiftUI
import SwiftData
import APICore
import APIStore
import DesignSystem

struct EnvironmentsSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    let workspace: Workspace
    @State private var renaming: APIEnvironment?

    private var environments: [APIEnvironment] {
        workspace.environments.filter { $0.deletedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }
    }

    var body: some View {
        List {
            Button {
                model.open(.globals, title: L("Globals"))
            } label: {
                Label(L("Globals"), systemImage: "globe")
            }
            .buttonStyle(.plain)
            Section(L("Environments")) {
                ForEach(environments) { environment in
                    Button {
                        model.open(.environment(environment.id), title: environment.name)
                    } label: {
                        HStack {
                            Label(environment.name, systemImage: "square.stack.3d.up")
                            Spacer()
                            if workspace.activeEnvironmentID == environment.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    .help(L("Active environment"))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(L("Set Active")) { workspace.activeEnvironmentID = environment.id }
                        Button(L("Rename…")) { renaming = environment }
                        Button(L("Duplicate")) { duplicate(environment) }
                        Button(L("Export…")) { model.export(environment) }
                        Divider()
                        Button(L("Delete"), role: .destructive) { delete(environment) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaBar(edge: .bottom) {
            SidebarBottomBar(title: L("New Environment"), action: add)
        }
        .renameAlert(item: $renaming, name: \.name) { environment, name in
            environment.name = name
            model.closeTabs { $0.content == .environment(environment.id) }
            try? context.save()
        }
    }

    private func add() {
        let environment = APIEnvironment(name: L("New Environment"), sortIndex: environments.count)
        environment.workspace = workspace
        context.insert(environment)
        try? context.save()
        model.open(.environment(environment.id), title: environment.name)
    }

    private func duplicate(_ environment: APIEnvironment) {
        let variables = SecretVariables.load(environment.variables, scope: environment.id, store: model.services.secrets)
            .map { Variable(key: $0.key, value: $0.value, isEnabled: $0.isEnabled, isSecret: $0.isSecret) }
        let copy = APIEnvironment(name: environment.name + " " + L("Copy"), sortIndex: environments.count)
        copy.variables = SecretVariables.save(variables, previous: [], scope: copy.id, store: model.services.secrets)
        copy.workspace = workspace
        context.insert(copy)
        try? context.save()
    }

    private func delete(_ environment: APIEnvironment) {
        _ = SecretVariables.save([], previous: environment.variables, scope: environment.id, store: model.services.secrets)
        if workspace.activeEnvironmentID == environment.id { workspace.activeEnvironmentID = nil }
        model.closeTabs { $0.content == .environment(environment.id) }
        context.delete(environment)
        try? context.save()
    }
}

/// Edits an environment's or the globals' variables; changes are saved immediately.
struct VariablesEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    let title: String
    let scope: UUID
    let load: () -> [Variable]
    let store: ([Variable]) -> Void
    @State private var variables: [Variable] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title2.bold())
                Text(L("Reference variables with {{name}} in URLs, headers, bodies and auth. Secret values are stored in the Keychain."))
                    .foregroundStyle(.secondary)
                VariableTable(variables: $variables)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            variables = SecretVariables.load(load(), scope: scope, store: model.services.secrets)
            loaded = true
        }
        .onChange(of: variables) { _, newValue in
            guard loaded else { return }
            store(SecretVariables.save(newValue, previous: load(), scope: scope, store: model.services.secrets))
            try? context.save()
        }
    }
}

/// Toolbar picker for the active environment.
struct EnvironmentPicker: View {
    @Environment(AppModel.self) private var model
    @Bindable var workspace: Workspace

    var body: some View {
        let environments = workspace.environments.filter { $0.deletedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }
        HStack(spacing: 4) {
            Picker(L("Environment"), selection: $workspace.activeEnvironmentID) {
                Text(L("No Environment")).tag(UUID?.none)
                ForEach(environments) { environment in
                    Text(environment.name).tag(UUID?.some(environment.id))
                }
            }
            .frame(minWidth: 160)
            Button {
                if let active = workspace.activeEnvironment {
                    model.open(.environment(active.id), title: active.name)
                } else {
                    model.open(.globals, title: L("Globals"))
                }
            } label: {
                Image(systemName: "eye")
            }
            .help(L("View environment variables"))
        }
    }
}

extension View {
    /// Alert with a text field for renaming an object.
    func renameAlert<Item: AnyObject>(item: Binding<Item?>, name: KeyPath<Item, String>, onCommit: @escaping (Item, String) -> Void) -> some View {
        modifier(RenameAlert(item: item, name: name, onCommit: onCommit))
    }
}

private struct RenameAlert<Item: AnyObject>: ViewModifier {
    @Binding var item: Item?
    let name: KeyPath<Item, String>
    let onCommit: (Item, String) -> Void
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert(L("Rename"), isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } })) {
                TextField(L("Name"), text: $text)
                Button(L("Rename")) {
                    if let item, !text.trimmingCharacters(in: .whitespaces).isEmpty { onCommit(item, text) }
                    item = nil
                }
                Button(L("Cancel"), role: .cancel) { item = nil }
            }
            .onChange(of: item.map(ObjectIdentifier.init)) { _, _ in
                if let item { text = item[keyPath: name] }
            }
    }
}
