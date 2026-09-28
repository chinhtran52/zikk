import SwiftUI
import SwiftData
import APICore
import APIStore
import DesignSystem

struct HistorySidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    let workspace: Workspace
    @State private var search = ""

    private var groups: [(Date, [HistoryEntry])] {
        let filtered = workspace.history.filter { search.isEmpty || $0.url.localizedCaseInsensitiveContains(search) }
        let grouped = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.map { ($0.key, $0.value.sorted { $0.date > $1.date }) }.sorted { $0.0 > $1.0 }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.0) { day, entries in
                Section(day.formatted(date: .abbreviated, time: .omitted)) {
                    ForEach(entries) { entry in
                        Button {
                            model.openDraft(spec: entry.request, name: entry.url, response: entry.response)
                        } label: {
                            HistoryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(L("Delete"), role: .destructive) {
                                context.delete(entry)
                                try? context.save()
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: L("Search history"))
        .overlay {
            if workspace.history.isEmpty {
                ContentUnavailableView(L("No History"), systemImage: "clock", description: Text(L("Requests you send will appear here.")))
            }
        }
        .safeAreaBar(edge: .bottom) {
            SidebarBottomBar(title: L("Clear All"), systemImage: "trash", role: .destructive, isDisabled: workspace.history.isEmpty) {
                workspace.history.forEach(context.delete)
                try? context.save()
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 6) {
            MethodBadge(HTTPMethod(rawValue: entry.method))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.url)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let status = entry.statusCode {
                        Text(verbatim: "\(status)").foregroundStyle(StatusBadge.color(for: status))
                    } else {
                        Text(L("Error")).foregroundStyle(.red)
                    }
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .contentShape(.rect)
    }
}
