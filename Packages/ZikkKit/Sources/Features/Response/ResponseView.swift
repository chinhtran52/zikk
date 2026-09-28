import SwiftUI
import APICore
import DesignSystem
import ScriptEngine

enum ResponseTab: String, CaseIterable, Hashable {
    case body, headers, cookies, tests, timeline

    var title: String {
        switch self {
        case .tests: L("Test Results")
        case .body: L("Body")
        case .headers: L("Headers")
        case .cookies: L("Cookies")
        case .timeline: L("Timeline")
        }
    }
}

struct ResponseView: View {
    let document: RequestDocument
    /// Saves the current response as an example; nil for unsaved requests.
    var onSaveExample: (() -> Void)?
    @State private var tab: ResponseTab = .body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if document.isSending {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L("Sending request…")).foregroundStyle(.secondary)
                    Button(L("Cancel")) { document.cancel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = document.errorMessage {
                ContentUnavailableView {
                    Label(L("Could not send request"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error).textSelection(.enabled)
                }
            } else if let response = document.response {
                HStack(spacing: 14) {
                    UnderlineTabs(ResponseTab.allCases, selection: $tab, title: \.title) { tab in
                        switch tab {
                        case .headers: "\(response.headers.count)"
                        case .cookies: cookies(response).isEmpty ? nil : "\(cookies(response).count)"
                        case .tests:
                            document.testResults.isEmpty ? nil : "\(document.testResults.filter(\.passed).count)/\(document.testResults.count)"
                        default: nil
                        }
                    }
                    Spacer()
                    ResponseStatusBar(response: response)
                    if let onSaveExample {
                        Button(L("Save as Example"), systemImage: "square.and.arrow.down", action: onSaveExample)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help(L("Save response as example"))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                Divider()
                ForEach(document.scriptErrors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }
                Group {
                    switch tab {
                    case .tests:
                        TestResultsView(results: document.testResults)
                    case .body:
                        ResponseBodyView(response: response)
                    case .headers:
                        HeaderList(headers: response.headers)
                    case .cookies:
                        CookieList(cookies: cookies(response))
                    case .timeline:
                        ResponseTimelineView(response: response)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(L("Response"), systemImage: "paperplane", description: Text(L("Enter the URL and click Send to get a response")))
            }
        }
    }

    private func cookies(_ response: ResponseSnapshot) -> [HTTPCookie] {
        guard let url = URL(string: response.url) else { return [] }
        let fields = Dictionary(response.headers.map { ($0.key, $0.value) }, uniquingKeysWith: { a, b in a + "," + b })
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
    }
}

struct ResponseStatusBar: View {
    let response: ResponseSnapshot

    var body: some View {
        HStack(spacing: 12) {
            StatusBadge(response.statusCode)
                .accessibilityIdentifier("response-status")
            Text(Self.duration(response.timings.total))
                .foregroundStyle(.secondary)
                .help(L("Response time"))
            Text(response.size.formatted(.byteCount(style: .file)))
                .foregroundStyle(.secondary)
                .help(L("Response size"))
        }
        .font(.callout.monospacedDigit())
    }

    static func duration(_ milliseconds: Double) -> String {
        milliseconds >= 1000 ? String(format: "%.2f s", milliseconds / 1000) : String(format: "%.0f ms", milliseconds)
    }
}

struct HeaderList: View {
    let headers: [KeyValue]

    var body: some View {
        Table(headers) {
            TableColumn(L("Key")) { Text($0.key).textSelection(.enabled) }
                .width(min: 120, ideal: 200)
            TableColumn(L("Value")) { Text($0.value).textSelection(.enabled) }
        }
        .font(.system(.body, design: .monospaced))
    }
}

private struct CookieList: View {
    let cookies: [HTTPCookie]

    var body: some View {
        if cookies.isEmpty {
            ContentUnavailableView(L("No Cookies"), systemImage: "birthday.cake", description: Text(L("The response did not set any cookies.")))
        } else {
            Table(cookies.map(CookieRow.init)) {
                TableColumn(L("Name"), value: \.name)
                TableColumn(L("Value"), value: \.value)
                TableColumn(L("Domain"), value: \.domain)
                TableColumn(L("Path"), value: \.path)
                TableColumn(L("Expires"), value: \.expires)
                TableColumn(L("HttpOnly"), value: \.httpOnly)
                TableColumn(L("Secure"), value: \.secure)
            }
        }
    }
}

struct CookieRow: Identifiable {
    let id = UUID()
    let name, value, domain, path, expires, httpOnly, secure: String

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expires = cookie.expiresDate?.formatted(date: .abbreviated, time: .shortened) ?? L("Session")
        httpOnly = cookie.isHTTPOnly ? "✓" : ""
        secure = cookie.isSecure ? "✓" : ""
    }
}

struct TestResultsView: View {
    let results: [TestResult]
    @State private var filter: Filter = .all

    enum Filter: Hashable { case all, passed, skipped, failed }

    private var filtered: [TestResult] {
        results.filter { result in
            switch filter {
            case .all: true
            case .passed: result.passed && !result.skipped
            case .skipped: result.skipped
            case .failed: !result.passed
            }
        }
    }

    var body: some View {
        if results.isEmpty {
            ContentUnavailableView(L("No Tests"), systemImage: "checkmark.seal", description: Text(L("Write tests in the Scripts tab using pm.test() to validate responses.")))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Picker("", selection: $filter) {
                    Text(L("All")).tag(Filter.all)
                    Text(L("Passed")).tag(Filter.passed)
                    Text(L("Skipped")).tag(Filter.skipped)
                    Text(L("Failed")).tag(Filter.failed)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(10)
                List(filtered) { result in
                    HStack(alignment: .firstTextBaseline) {
                        Text(result.skipped ? L("SKIPPED") : result.passed ? L("PASS") : L("FAIL"))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(result.skipped ? Color.gray : result.passed ? Color.green : Color.red, in: .rect(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name)
                            if let error = result.error, !result.passed {
                                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    .accessibilityIdentifier("test-result")
                }
                .listStyle(.plain)
            }
        }
    }
}
