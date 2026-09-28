import SwiftUI
import SwiftData
import HTTPEngine

/// Sheet listing cookie-jar contents by domain, with deletion.
struct CookieManagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var cookies: [HTTPCookie] = []

    private var domains: [(String, [HTTPCookie])] {
        Dictionary(grouping: cookies, by: \.domain).sorted { $0.key < $1.key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Manage Cookies")).font(.title2.bold())
                Spacer()
                Button(L("Clear All"), role: .destructive) {
                    model.services.cookieJar.replaceAll([])
                    persist()
                }
                .disabled(cookies.isEmpty)
            }
            .padding()
            List {
                ForEach(domains, id: \.0) { domain, items in
                    Section(domain) {
                        ForEach(items, id: \.self) { cookie in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(verbatim: "\(cookie.name)=\(cookie.value)")
                                        .font(.system(.body, design: .monospaced))
                                        .lineLimit(1)
                                    Text(verbatim: "Path=\(cookie.path)" + (cookie.expiresDate.map { "; Expires=\($0.formatted())" } ?? ""))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    model.services.cookieJar.remove(cookie)
                                    persist()
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(L("Delete cookie"))
                            }
                        }
                    }
                }
            }
            .overlay {
                if cookies.isEmpty {
                    ContentUnavailableView(L("No Cookies"), systemImage: "birthday.cake", description: Text(L("Cookies set by responses are stored here and sent with matching requests.")))
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(L("Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 460)
        .onAppear { cookies = model.services.cookieJar.all }
    }

    private func persist() {
        CookieStore.save(model.services.cookieJar, context: context)
        cookies = model.services.cookieJar.all
    }
}
