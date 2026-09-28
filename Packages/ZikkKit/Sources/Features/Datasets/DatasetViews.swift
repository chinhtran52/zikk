import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import APIStore
import Runner

struct DatasetsSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    let workspace: Workspace
    @State private var renaming: Dataset?
    @State private var isImporting = false
    @State private var errorMessage: String?

    private var datasets: [Dataset] {
        workspace.datasets.filter { $0.deletedAt == nil }.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        List {
            ForEach(datasets) { dataset in
                Button {
                    model.open(.dataset(dataset.id), title: dataset.name)
                } label: {
                    HStack {
                        Label(dataset.name, systemImage: "tablecells")
                        Spacer()
                        Text(verbatim: "\(dataset.rows.count)").foregroundStyle(.secondary).font(.caption.monospacedDigit())
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(L("Rename…")) { renaming = dataset }
                    Button(L("Export CSV…")) { model.export(dataset) }
                    Divider()
                    Button(L("Delete"), role: .destructive) {
                        model.closeTabs { $0.content == .dataset(dataset.id) }
                        context.delete(dataset)
                        try? context.save()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if datasets.isEmpty {
                ContentUnavailableView(L("No Datasets"), systemImage: "tablecells",
                                       description: Text(L("Datasets are CSV or JSON tables used as iteration data in the Collection Runner.")))
            }
        }
        .safeAreaBar(edge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.caption).padding([.horizontal, .top], 8)
                }
                SidebarBottomBar(title: L("New Dataset"), action: add) {
                    SidebarIconButton(systemImage: "square.and.arrow.down", help: L("Import CSV/JSON…")) { isImporting = true }
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText, .json, .plainText]) { result in
            guard case .success(let url) = result else { return }
            importFile(url)
        }
        .renameAlert(item: $renaming, name: \.name) { dataset, name in
            dataset.name = name
            try? context.save()
        }
    }

    private func add() {
        let dataset = Dataset(name: L("New Dataset"), columns: ["key"], rows: [["key": ""]])
        dataset.workspace = workspace
        context.insert(dataset)
        try? context.save()
        model.open(.dataset(dataset.id), title: dataset.name)
    }

    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let table = try DatasetParser.parse(text)
            let format: DatasetFormat = url.pathExtension.lowercased() == "json" ? .json : .csv
            let dataset = Dataset(name: url.deletingPathExtension().lastPathComponent, format: format, columns: table.columns, rows: table.rows)
            dataset.workspace = workspace
            context.insert(dataset)
            try context.save()
            errorMessage = nil
            model.open(.dataset(dataset.id), title: dataset.name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Spreadsheet-style editor for a dataset.
struct DatasetEditorView: View {
    @Environment(\.modelContext) private var context
    @Bindable var dataset: Dataset
    @State private var columns: [String] = []
    @State private var rows: [EditableRow] = []
    @State private var loaded = false
    @State private var newColumn = ""

    struct EditableRow: Identifiable, Equatable {
        let id = UUID()
        var values: [String: String]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(L("Name"), text: $dataset.name)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                Spacer()
                Text(String(format: L("%lld rows"), rows.count)).foregroundStyle(.secondary)
            }
            HStack {
                TextField(L("New column"), text: $newColumn)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit(addColumn)
                Button(L("Add Column"), action: addColumn).disabled(newColumn.isEmpty || columns.contains(newColumn))
                Button(L("Add Row")) { rows.append(EditableRow(values: [:])) }
                Spacer()
                Text(L("Use {{column}} in requests; values change every iteration."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
                    GridRow {
                        Text(verbatim: "#").foregroundStyle(.secondary)
                        ForEach(columns, id: \.self) { column in
                            HStack(spacing: 2) {
                                Text(column).bold()
                                Button {
                                    columns.removeAll { $0 == column }
                                } label: {
                                    Image(systemName: "xmark").font(.caption2)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(L("Remove column"))
                            }
                            .frame(width: 160, alignment: .leading)
                        }
                        Text(verbatim: "")
                    }
                    ForEach($rows) { $row in
                        GridRow {
                            Text(verbatim: "\((rows.firstIndex(of: row) ?? 0) + 1)").foregroundStyle(.secondary).monospacedDigit()
                            ForEach(columns, id: \.self) { column in
                                TextField("", text: Binding(get: { row.values[column] ?? "" }, set: { row.values[column] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 160)
                            }
                            Button {
                                rows.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L("Remove row"))
                        }
                    }
                }
                .font(.system(.body, design: .monospaced))
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .onAppear {
            columns = dataset.columns
            rows = dataset.rows.map { EditableRow(values: $0) }
            loaded = true
        }
        .onChange(of: columns) { persist() }
        .onChange(of: rows) { persist() }
        .onChange(of: dataset.name) { try? context.save() }
    }

    private func addColumn() {
        let name = newColumn.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !columns.contains(name) else { return }
        columns.append(name)
        newColumn = ""
    }

    private func persist() {
        guard loaded else { return }
        dataset.columns = columns
        dataset.rows = rows.map { row in row.values.filter { columns.contains($0.key) } }
        try? context.save()
    }
}
