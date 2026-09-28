import SwiftUI
import SwiftData
import Charts
import APICore
import APIStore
import DesignSystem
import Runner
import ScriptEngine

struct RunnerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Bindable var runner: RunnerModel
    let workspace: Workspace

    private var collection: APICollection? { CollectionQueries.collection(runner.collectionID, in: context) }

    var body: some View {
        ResizableHSplit(id: "runner", initialFraction: 0.32, minLeft: 260, minRight: 320) {
            configuration
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
        } right: {            Group {
                switch runner.mode {
                case .functional: RunResultsView(runner: runner, collectionName: collection?.name ?? "")
                case .performance: PerformanceResultsView(runner: runner)
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity)
        }
        .onAppear { runner.load(context: context) }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Runner")).font(.caption).foregroundStyle(.secondary)
                Text(title).font(.title3.bold()).lineLimit(1)
                Picker("", selection: $runner.mode) {
                    Text(L("Functional")).tag(RunnerModel.Mode.functional)
                    Text(L("Performance")).tag(RunnerModel.Mode.performance)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(12)
            Form {
                if runner.mode == .functional {
                    Stepper(value: $runner.iterations, in: 1...10_000) {
                        LabeledContent(L("Iterations"), value: "\(runner.iterations)")
                    }
                    TextField(L("Delay (ms)"), value: $runner.delayMilliseconds, format: .number)
                    Picker(L("Data"), selection: $runner.datasetID) {
                        Text(L("None")).tag(UUID?.none)
                        ForEach(workspace.datasets.filter { $0.deletedAt == nil }) { dataset in
                            Text(dataset.name).tag(UUID?.some(dataset.id))
                        }
                    }
                    Toggle(L("Stop run if an error occurs"), isOn: $runner.stopOnFailure)
                    Toggle(L("Persist variable changes"), isOn: $runner.persistVariables)
                    Toggle(L("Keep responses"), isOn: $runner.keepResponses)
                } else {
                    Stepper(value: $runner.virtualUsers, in: 1...200) {
                        LabeledContent(L("Virtual users"), value: "\(runner.virtualUsers)")
                    }
                    Stepper(value: $runner.durationSeconds, in: 1...3600, step: 5) {
                        LabeledContent(L("Duration"), value: "\(runner.durationSeconds) s")
                    }
                    Stepper(value: $runner.rampUpSeconds, in: 0...600, step: 5) {
                        LabeledContent(L("Ramp up"), value: "\(runner.rampUpSeconds) s")
                    }
                }
                Section(L("Requests")) {
                    List {
                        ForEach($runner.selections) { $selection in
                            Toggle(isOn: $selection.isSelected) {
                                HStack(spacing: 6) {
                                    MethodBadge(selection.method, kind: selection.kind)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(selection.name).lineLimit(1)
                                        if !selection.path.isEmpty {
                                            Text(selection.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                        .onMove(perform: runner.move)
                    }
                    .frame(minHeight: 160)
                    HStack {
                        Button(L("Select All")) { for index in runner.selections.indices { runner.selections[index].isSelected = true } }
                        Button(L("Deselect All")) { for index in runner.selections.indices { runner.selections[index].isSelected = false } }
                    }
                    .buttonStyle(.link)
                }
            }
            .formStyle(.grouped)
            .disabled(runner.isRunning)
            HStack {
                if runner.isRunning {
                    Button(L("Stop"), role: .destructive) { runner.stop() }
                        .controlSize(.large)
                } else {
                    Button(runner.mode == .functional ? L("Run") : L("Start Load Test")) {
                        if runner.mode == .functional {
                            runner.run(workspace: workspace, context: context, services: model.services)
                        } else {
                            runner.runPerformance(workspace: workspace, context: context, services: model.services)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!runner.selections.contains(where: \.isSelected))
                    .accessibilityIdentifier("run-button")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(12)
        }
    }

    private var title: String {
        guard let collection else { return "" }
        if let folderID = runner.folderID, let folder = CollectionQueries.node(folderID, in: context) {
            return collection.name + " / " + folder.name
        }
        return collection.name
    }
}

private struct RunResultsView: View {
    @Environment(AppModel.self) private var model
    let runner: RunnerModel
    let collectionName: String
    @State private var filter: Filter = .all
    @State private var selected: RunItemResult.ID?

    enum Filter: Hashable { case all, passed, failed }

    private var filtered: [RunItemResult] {
        runner.results.filter { result in
            switch filter {
            case .all: true
            case .passed: !result.failed
            case .failed: result.failed
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if runner.state == .idle {
                ContentUnavailableView(L("Run your collection"), systemImage: "play.circle",
                                       description: Text(L("Choose iterations, data and requests, then click Run.")))
            } else {
                summaryHeader
                Divider()
                ResizableHSplit(id: "runner-results", initialFraction: 0.55, minLeft: 240, minRight: 220, showsRight: runner.results.contains(where: { $0.id == selected })) {
                    List(selection: $selected) {
                        ForEach(groupedIterations, id: \.0) { iteration, results in
                            Section(String(format: L("Iteration %lld"), iteration + 1)) {
                                ForEach(results) { result in
                                    RunResultRow(result: result).tag(result.id)
                                }
                            }
                        }
                    }
                    .frame(minWidth: 280)
                } right: {                    if let result = runner.results.first(where: { $0.id == selected }) {
                        RunResultDetail(result: result)
                            .frame(minWidth: 260)
                    }
                }
            }
        }
    }

    private var groupedIterations: [(Int, [RunItemResult])] {
        Dictionary(grouping: filtered, by: \.iteration).sorted { $0.key < $1.key }
    }

    private var summaryHeader: some View {
        let passed = runner.results.flatMap(\.tests).filter { $0.passed && !$0.skipped }.count
        let failed = runner.results.flatMap(\.tests).filter { !$0.passed }.count
        let errors = runner.results.filter { $0.errorMessage != nil }.count
        let durations = runner.results.compactMap { $0.statusCode == nil ? nil : $0.duration }
        let average = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                if runner.isRunning {
                    ProgressView().controlSize(.small)
                    Text(String(format: L("Running iteration %lld…"), runner.currentIteration + 1))
                } else if runner.summary?.cancelled == true {
                    Label(L("Stopped"), systemImage: "stop.circle").foregroundStyle(.orange)
                } else {
                    Label(L("Completed"), systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                Spacer()
                Menu(L("Export Results")) {
                    Button(L("JSON")) { export(json: true) }
                    Button(L("JUnit XML")) { export(json: false) }
                }
                .fixedSize()
                .disabled(runner.summary == nil)
            }
            HStack(spacing: 18) {
                Metric(title: L("Requests"), value: "\(runner.results.filter { !$0.skipped }.count)")
                Metric(title: L("Passed"), value: "\(passed)", color: .green)
                Metric(title: L("Failed"), value: "\(failed)", color: failed > 0 ? .red : .secondary)
                Metric(title: L("Errors"), value: "\(errors)", color: errors > 0 ? .red : .secondary)
                Metric(title: L("Avg. Response Time"), value: ResponseStatusBar.duration(average))
                if let summary = runner.summary {
                    Metric(title: L("Duration"), value: String(format: "%.1f s", summary.totalDuration))
                }
            }
            Picker("", selection: $filter) {
                Text(L("All")).tag(Filter.all)
                Text(L("Passed")).tag(Filter.passed)
                Text(L("Failed")).tag(Filter.failed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(12)
    }

    private func export(json: Bool) {
        guard let data = runner.report(json: json, collectionName: collectionName) else { return }
        model.exportReport(data, fileName: "\(collectionName)-run.\(json ? "json" : "xml")", contentType: json ? .json : .xml)
    }
}

struct Metric: View {
    let title: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(color)
        }
    }
}

private struct RunResultRow: View {
    let result: RunItemResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: result.failed ? "xmark.circle.fill" : (result.skipped ? "forward.circle" : "checkmark.circle.fill"))
                .foregroundStyle(result.failed ? .red : (result.skipped ? .secondary : .green))
            MethodBadge(HTTPMethod(rawValue: result.method))
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name).lineLimit(1)
                Text(result.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let status = result.statusCode {
                Text(verbatim: "\(status)").foregroundStyle(StatusBadge.color(for: status)).monospacedDigit()
                Text(ResponseStatusBar.duration(result.duration)).foregroundStyle(.secondary).monospacedDigit()
            } else if result.skipped {
                Text(L("Skipped")).foregroundStyle(.secondary)
            } else {
                Text(L("Error")).foregroundStyle(.red)
            }
        }
        .accessibilityIdentifier("run-result")
    }
}

private struct RunResultDetail: View {
    let result: RunItemResult
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.name).font(.headline).padding([.horizontal, .top], 12)
            if let error = result.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding(.horizontal, 12)
            }
            ForEach(result.scriptErrors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding(.horizontal, 12)
            }
            Picker("", selection: $tab) {
                Text(L("Test Results")).tag(0)
                Text(L("Response")).tag(1)
                Text(L("Request")).tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.horizontal, 12)
            switch tab {
            case 0:
                TestResultsView(results: result.tests)
            case 1:
                if let response = result.response {
                    ResponseBodyView(response: response)
                } else {
                    ContentUnavailableView(L("No Response"), systemImage: "tray", description: Text(L("Enable “Keep responses” to inspect response bodies.")))
                }
            default:
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "\(result.method) \(result.url)").font(.system(.body, design: .monospaced).bold()).textSelection(.enabled)
                        ForEach(result.request.headers.active) { header in
                            Text(verbatim: "\(header.key): \(header.value)").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            }
        }
    }
}

private struct PerformanceResultsView: View {
    let runner: RunnerModel

    var body: some View {
        if runner.state == .idle {
            ContentUnavailableView(L("Performance Test"), systemImage: "speedometer",
                                   description: Text(L("Simulate virtual users sending the selected requests in a loop and measure latency and throughput.")))
        } else {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let metrics = runner.liveMetrics
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 18) {
                            if runner.isRunning { ProgressView().controlSize(.small) }
                            Metric(title: L("Requests"), value: "\(metrics.totalRequests)")
                            Metric(title: L("Throughput"), value: String(format: "%.1f req/s", metrics.throughput))
                            Metric(title: L("Avg."), value: ResponseStatusBar.duration(metrics.average))
                            Metric(title: "P90", value: ResponseStatusBar.duration(metrics.percentile(90)))
                            Metric(title: "P95", value: ResponseStatusBar.duration(metrics.percentile(95)))
                            Metric(title: "P99", value: ResponseStatusBar.duration(metrics.percentile(99)))
                            Metric(title: L("Error rate"), value: String(format: "%.1f%%", metrics.errorRate * 100), color: metrics.errorRate > 0 ? .red : .green)
                        }
                        Chart(bucketed(metrics.samples), id: \.second) { bucket in
                            LineMark(x: .value(L("Time (s)"), bucket.second), y: .value(L("Avg. response time (ms)"), bucket.average))
                                .foregroundStyle(by: .value(L("Series"), L("Response time")))
                            BarMark(x: .value(L("Time (s)"), bucket.second), y: .value(L("Errors"), bucket.errors))
                                .foregroundStyle(by: .value(L("Series"), L("Errors")))
                        }
                        .chartForegroundStyleScale([L("Response time"): Color.accentColor, L("Errors"): Color.red])
                        .frame(minHeight: 260)
                    }
                    .padding(16)
                }
            }
        }
    }

    private struct Bucket { let second: Int; let average: Double; let errors: Int }

    private func bucketed(_ samples: [PerformanceSample]) -> [Bucket] {
        Dictionary(grouping: samples) { Int($0.time) }
            .map { second, items in
                Bucket(second: second, average: items.map(\.responseTime).reduce(0, +) / Double(items.count), errors: items.filter(\.failed).count)
            }
            .sorted { $0.second < $1.second }
    }
}
