import SwiftUI
import DesignSystem
import APICore
import ScriptEngine

/// Console window listing requests and script logs.
public struct ConsoleView: View {
    let store: ConsoleStore
    @State private var filter = ""
    @State private var showsLogsOnly = false

    public init(store: ConsoleStore) {
        self.store = store
    }

    private var entries: [ConsoleStore.Entry] {
        store.entries.filter { entry in
            if showsLogsOnly, case .request = entry.kind { return false }
            guard !filter.isEmpty else { return true }
            switch entry.kind {
            case .request(_, let url, _, _, _): return url.localizedCaseInsensitiveContains(filter)
            case .log(_, let message): return message.localizedCaseInsensitiveContains(filter)
            }
        }
    }

    public var body: some View {
        ScrollViewReader { proxy in
            List(entries) { entry in
                ConsoleRow(entry: entry).id(entry.id)
            }
            .listStyle(.plain)
            .font(.system(.callout, design: .monospaced))
            .onChange(of: store.entries.count) {
                if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .overlay {
            if store.entries.isEmpty {
                ContentUnavailableView(L("Console"), systemImage: "terminal", description: Text(L("Requests and console.log output from scripts appear here.")))
            }
        }
        .searchable(text: $filter, prompt: L("Filter"))
        .toolbar {
            Toggle(L("Logs only"), isOn: $showsLogsOnly)
            Button(L("Clear"), systemImage: "trash") { store.clear() }
        }
        .frame(minWidth: 520, minHeight: 280)
    }
}

private struct ConsoleRow: View {
    let entry: ConsoleStore.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date.formatted(date: .omitted, time: .standard))
                .foregroundStyle(.tertiary)
            switch entry.kind {
            case .request(let method, let url, let status, let duration, let error):
                Text(method).bold().foregroundStyle(HTTPMethod(rawValue: method).tint)
                Text(url).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                if let status {
                    Text(verbatim: "\(status)").foregroundStyle(StatusBadge.color(for: status))
                    Text(ResponseStatusBar.duration(duration)).foregroundStyle(.secondary)
                } else if let error {
                    Text(error).foregroundStyle(.red).lineLimit(1)
                }
            case .log(let level, let message):
                Image(systemName: icon(level)).foregroundStyle(color(level))
                Text(message).textSelection(.enabled).foregroundStyle(level == .error ? .red : .primary)
                Spacer()
            }
        }
    }

    private func icon(_ level: ConsoleEntry.Level) -> String {
        switch level {
        case .error: "xmark.octagon"
        case .warn: "exclamationmark.triangle"
        case .info: "info.circle"
        default: "chevron.right"
        }
    }

    private func color(_ level: ConsoleEntry.Level) -> Color {
        switch level {
        case .error: .red
        case .warn: .orange
        case .info: .blue
        default: .secondary
        }
    }
}
