import SwiftUI
import APICore

/// Timing breakdown bars plus the request as actually sent.
struct ResponseTimelineView: View {
    let response: ResponseSnapshot

    private var phases: [(String, Double?, Color)] {
        let t = response.timings
        return [
            (L("DNS Lookup"), t.dns, .teal),
            (L("TCP Handshake"), t.connect, .orange),
            (L("SSL Handshake"), t.tls, .purple),
            (L("Request Sent"), t.request, .gray),
            (L("Waiting (TTFB)"), t.firstByte, .green),
            (L("Content Download"), t.download, .blue),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    let total = max(response.timings.total, 1)
                    ForEach(phases, id: \.0) { name, value, color in
                        GridRow {
                            Text(name).foregroundStyle(.secondary)
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(color.gradient)
                                    .frame(width: max(2, proxy.size.width * CGFloat((value ?? 0) / total)))
                                    .opacity(value == nil ? 0.2 : 1)
                            }
                            .frame(height: 10)
                            Text(value.map { ResponseStatusBar.duration($0) } ?? "—")
                                .monospacedDigit()
                                .frame(minWidth: 70, alignment: .trailing)
                        }
                    }
                    Divider()
                    GridRow {
                        Text(L("Total")).bold()
                        Color.clear.frame(height: 1)
                        Text(ResponseStatusBar.duration(response.timings.total)).bold().monospacedDigit()
                    }
                }
                LabeledContent(L("HTTP Version"), value: response.httpVersion)
                if let sent = response.sentRequest {
                    Divider()
                    Text(verbatim: "\(sent.method) \(sent.url)")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    SectionHeader(L("Request Headers"))
                    ForEach(sent.headers) { header in
                        Text(verbatim: "\(header.key): \(header.value)")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Divider()
                SectionHeader(L("Response Headers"))
                ForEach(response.headers) { header in
                    Text(verbatim: "\(header.key): \(header.value)")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(14)
        }
    }
}
