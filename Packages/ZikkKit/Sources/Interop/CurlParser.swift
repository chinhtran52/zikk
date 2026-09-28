import Foundation
import APICore

/// Parses `curl` command lines (as copied from browsers, docs and Postman) into a `RequestSpec`.
public enum CurlParser {
    public static func looksLikeCurl(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("curl ")
    }

    public static func parse(_ command: String) throws -> RequestSpec {
        var tokens = try tokenize(command)
        guard tokens.first?.lowercased() == "curl" else { throw InteropError.invalidCurl("command must start with curl") }
        tokens.removeFirst()

        var method: String?
        var url: String?
        var headers: [KeyValue] = []
        var dataParts: [String] = []
        var urlEncodedParts: [String] = []
        var formFields: [FormDataField] = []
        var jsonBody = false
        var useGet = false
        var settings = RequestSettings()
        settings.followRedirects = false
        var auth = AuthConfig.inherit

        var index = 0
        func next(_ flag: String) throws -> String {
            index += 1
            guard index < tokens.count else { throw InteropError.invalidCurl("missing value for \(flag)") }
            return tokens[index]
        }

        while index < tokens.count {
            var token = tokens[index]
            var inlineValue: String?
            if token.hasPrefix("--"), let equals = token.firstIndex(of: "=") {
                inlineValue = String(token[token.index(after: equals)...])
                token = String(token[..<equals])
            }
            func value() throws -> String { try inlineValue ?? next(token) }
            // Short flags may carry their value attached, e.g. -XPOST or -H'X: y'.
            if token.count > 2, token.hasPrefix("-"), !token.hasPrefix("--"), "XHdFuAbe".contains(token[token.index(token.startIndex, offsetBy: 1)]) {
                inlineValue = String(token.dropFirst(2))
                token = String(token.prefix(2))
            }
            switch token {
            case "-X", "--request":
                method = try value().uppercased()
            case "-H", "--header":
                let header = try value()
                if let colon = header.firstIndex(of: ":") {
                    headers.append(KeyValue(key: header[..<colon].trimmingCharacters(in: .whitespaces), value: header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
                }
            case "-d", "--data", "--data-raw", "--data-binary", "--data-ascii":
                dataParts.append(try value())
            case "--data-urlencode":
                urlEncodedParts.append(try value())
            case "--json":
                dataParts.append(try value())
                jsonBody = true
            case "-F", "--form", "--form-string":
                let field = try value()
                let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                if parts[1].hasPrefix("@"), token != "--form-string" {
                    var path = String(parts[1].dropFirst())
                    var contentType = ""
                    if let typeRange = path.range(of: ";type=") {
                        contentType = String(path[typeRange.upperBound...])
                        path = String(path[..<typeRange.lowerBound])
                    }
                    formFields.append(FormDataField(key: parts[0], kind: .file, file: FileReference(path: path), contentType: contentType))
                } else {
                    formFields.append(FormDataField(key: parts[0], value: parts[1]))
                }
            case "-u", "--user":
                let credentials = try value()
                let parts = credentials.split(separator: ":", maxSplits: 1).map(String.init)
                auth = AuthConfig(type: .basic)
                auth.basic = BasicAuth(username: parts.first ?? "", password: parts.count > 1 ? parts[1] : "")
            case "-A", "--user-agent":
                headers.append(KeyValue(key: "User-Agent", value: try value()))
            case "-b", "--cookie":
                headers.append(KeyValue(key: "Cookie", value: try value()))
            case "-e", "--referer":
                headers.append(KeyValue(key: "Referer", value: try value()))
            case "--url":
                url = try value()
            case "-G", "--get":
                useGet = true
            case "-I", "--head":
                method = "HEAD"
            case "-k", "--insecure":
                settings.verifySSL = false
            case "-L", "--location":
                settings.followRedirects = true
            case "--max-time", "-m", "--connect-timeout":
                if let seconds = Double(try value()) { settings.timeoutMilliseconds = Int(seconds * 1000) }
            case "-o", "--output", "-w", "--write-out", "--retry", "-x", "--proxy", "-c", "--cookie-jar", "-T", "--upload-file", "--cacert", "--cert", "--key":
                _ = try value()
            default:
                if token.hasPrefix("-") {
                    // Flags without values (--compressed, -s, -v, -i, …) are ignored.
                } else if url == nil {
                    url = token
                }
            }
            index += 1
        }

        guard let url, !url.isEmpty else { throw InteropError.invalidCurl("no URL found") }
        var spec = RequestSpec(url: url, headers: headers, auth: auth, settings: settings)

        let contentType = headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value.lowercased() ?? ""
        let hasData = !dataParts.isEmpty || !urlEncodedParts.isEmpty
        if useGet, hasData {
            let query = (dataParts + urlEncodedParts.map(encodeURLEncodedPart)).joined(separator: "&")
            spec.url += (spec.url.contains("?") ? "&" : "?") + query
        } else if !formFields.isEmpty {
            spec.body = RequestBody(mode: .formData, formData: formFields)
        } else if hasData {
            let joined = dataParts.joined(separator: "&")
            let looksJSON = ["{", "["].contains(where: joined.trimmingCharacters(in: .whitespaces).hasPrefix)
            if jsonBody || contentType.contains("json") || (contentType.isEmpty && looksJSON && urlEncodedParts.isEmpty) {
                spec.body = RequestBody(mode: .raw, raw: joined, rawLanguage: .json)
                if jsonBody, contentType.isEmpty { spec.headers.append(KeyValue(key: "Content-Type", value: "application/json")) }
            } else if contentType.isEmpty || contentType.contains("x-www-form-urlencoded") {
                let pairs = (dataParts.flatMap { $0.split(separator: "&").map(String.init) } + urlEncodedParts.map(encodeURLEncodedPart))
                spec.body = RequestBody(mode: .urlEncoded, urlEncoded: pairs.map { pair in
                    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    return KeyValue(key: parts[0].removingPercentEncoding ?? parts[0], value: parts.count > 1 ? (parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[1]) : "")
                })
                // The body mode sets Content-Type automatically.
                spec.headers.removeAll { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }
            } else {
                let language: RawLanguage = contentType.contains("xml") ? .xml : contentType.contains("html") ? .html : .text
                spec.body = RequestBody(mode: .raw, raw: joined, rawLanguage: language)
            }
        }

        spec.method = HTTPMethod(rawValue: method ?? (useGet ? "GET" : (hasData || !formFields.isEmpty ? "POST" : "GET")))
        spec.params = RawURL.queryParams(of: spec.url)
        spec.pathVariables = RawURL.syncPathVariables(url: spec.url, existing: [])
        return spec
    }

    private static func encodeURLEncodedPart(_ part: String) -> String {
        guard let equals = part.firstIndex(of: "=") else {
            return part.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? part
        }
        let name = part[..<equals]
        let value = part[part.index(after: equals)...]
        return "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? String(value))"
    }

    /// POSIX-shell-like tokenizer: single/double quotes, backslash escapes, `$'…'` strings and line continuations.
    static func tokenize(_ input: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var chars = Array(input.replacingOccurrences(of: "\\\r\n", with: " ").replacingOccurrences(of: "\\\n", with: " ").replacingOccurrences(of: "^\r\n", with: " ").replacingOccurrences(of: "^\n", with: " "))
        var i = 0
        func flush() {
            if hasToken { tokens.append(current) }
            current = ""
            hasToken = false
        }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ", "\t", "\n", "\r":
                flush()
            case "'":
                hasToken = true
                i += 1
                while i < chars.count, chars[i] != "'" { current.append(chars[i]); i += 1 }
                guard i < chars.count else { throw InteropError.invalidCurl("unterminated quote") }
            case "$" where i + 1 < chars.count && chars[i + 1] == "'":
                hasToken = true
                i += 2
                while i < chars.count, chars[i] != "'" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        i += 1
                        switch chars[i] {
                        case "n": current.append("\n")
                        case "t": current.append("\t")
                        case "r": current.append("\r")
                        default: current.append(chars[i])
                        }
                    } else {
                        current.append(chars[i])
                    }
                    i += 1
                }
                guard i < chars.count else { throw InteropError.invalidCurl("unterminated quote") }
            case "\"":
                hasToken = true
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) { i += 1 }
                    current.append(chars[i])
                    i += 1
                }
                guard i < chars.count else { throw InteropError.invalidCurl("unterminated quote") }
            case "\\":
                hasToken = true
                if i + 1 < chars.count { i += 1; current.append(chars[i]) }
            default:
                hasToken = true
                current.append(c)
            }
            i += 1
        }
        flush()
        chars.removeAll()
        return tokens
    }
}
