import Foundation

public enum SnippetLanguage: String, CaseIterable, Identifiable, Sendable {
    case curl, http, swift, javascriptFetch, javascriptAxios, python, go, javaOkHttp, kotlinOkHttp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .curl: "cURL"
        case .http: "HTTP"
        case .swift: "Swift - URLSession"
        case .javascriptFetch: "JavaScript - Fetch"
        case .javascriptAxios: "NodeJS - Axios"
        case .python: "Python - Requests"
        case .go: "Go - net/http"
        case .javaOkHttp: "Java - OkHttp"
        case .kotlinOkHttp: "Kotlin - OkHttp"
        }
    }
}

public enum CodeGenerator {
    public static func generate(_ request: SnippetRequest, language: SnippetLanguage) -> String {
        switch language {
        case .curl: curl(request)
        case .http: http(request)
        case .swift: swift(request)
        case .javascriptFetch: fetch(request)
        case .javascriptAxios: axios(request)
        case .python: python(request)
        case .go: go(request)
        case .javaOkHttp: okHttp(request, kotlin: false)
        case .kotlinOkHttp: okHttp(request, kotlin: true)
        }
    }

    // MARK: Escaping

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Double-quoted string literal valid in Swift, JS, Python, Go, Java and Kotlin.
    static func quoted(_ value: String, escapeDollar: Bool = false) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "$" where escapeDollar: result += "\\$"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    static func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }

    static func formEncoded(_ pairs: [SnippetRequest.Pair]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.map { "\($0.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.name)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }

    // MARK: cURL

    static func curl(_ r: SnippetRequest) -> String {
        var lines = ["curl --location --request \(r.method) \(shellQuoted(r.url))"]
        for header in r.headers { lines.append("--header \(shellQuoted("\(header.name): \(header.value)"))") }
        switch r.body {
        case .none: break
        case .text(let text): lines.append("--data-raw \(shellQuoted(text))")
        case .urlEncoded(let pairs): lines += pairs.map { "--data-urlencode \(shellQuoted("\($0.name)=\($0.value)"))" }
        case .formData(let parts):
            lines += parts.map { part in
                if let path = part.filePath { return "--form \(shellQuoted("\(part.name)=@\"\(path)\"" + (part.contentType.map { ";type=\($0)" } ?? "")))" }
                return "--form \(shellQuoted("\(part.name)=\"\(part.value ?? "")\""))"
            }
        case .file(let path): lines.append("--data-binary \(shellQuoted("@" + path))")
        }
        return lines.joined(separator: " \\\n")
    }

    // MARK: HTTP

    static func http(_ r: SnippetRequest) -> String {
        let components = URLComponents(string: r.url)
        var target = components?.percentEncodedPath ?? "/"
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery { target += "?" + query }
        var host = components?.host ?? ""
        if let port = components?.port { host += ":\(port)" }
        var lines = ["\(r.method) \(target) HTTP/1.1", "Host: \(host)"] + r.headers.map { "\($0.name): \($0.value)" }
        var body = ""
        switch r.body {
        case .none: break
        case .text(let text): body = text
        case .urlEncoded(let pairs): body = formEncoded(pairs)
        case .formData(let parts):
            let boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
            lines.append("Content-Type: multipart/form-data; boundary=\(boundary)")
            body = parts.map { part in
                if let path = part.filePath {
                    return "--\(boundary)\nContent-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(fileName(path))\"\nContent-Type: \(part.contentType ?? "<Content-Type header here>")\n\n(data)"
                }
                return "--\(boundary)\nContent-Disposition: form-data; name=\"\(part.name)\"\n\n\(part.value ?? "")"
            }.joined(separator: "\n") + "\n--\(boundary)--"
        case .file(let path): body = "<file contents here: \(fileName(path))>"
        }
        if !body.isEmpty { lines.append("Content-Length: \(body.utf8.count)") }
        return lines.joined(separator: "\n") + (body.isEmpty ? "" : "\n\n" + body)
    }

    // MARK: Swift

    static func swift(_ r: SnippetRequest) -> String {
        var lines = ["import Foundation", ""]
        switch r.body {
        case .formData(let parts):
            lines += [
                "let boundary = \"Boundary-\\(UUID().uuidString)\"",
                "var body = Data()",
            ]
            for part in parts {
                lines.append("body.append(Data(\"--\\(boundary)\\r\\n\".utf8))")
                if let path = part.filePath {
                    lines.append("body.append(Data(\(quoted("Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(fileName(path))\"\r\nContent-Type: \(part.contentType ?? "application/octet-stream")\r\n\r\n")).utf8))")
                    lines.append("body.append(try Data(contentsOf: URL(fileURLWithPath: \(quoted(path)))))")
                    lines.append("body.append(Data(\"\\r\\n\".utf8))")
                } else {
                    lines.append("body.append(Data(\(quoted("Content-Disposition: form-data; name=\"\(part.name)\"\r\n\r\n\(part.value ?? "")\r\n")).utf8))")
                }
            }
            lines += ["body.append(Data(\"--\\(boundary)--\\r\\n\".utf8))", ""]
        default: break
        }
        lines += [
            "var request = URLRequest(url: URL(string: \(quoted(r.url)))!, timeoutInterval: 30)",
            "request.httpMethod = \(quoted(r.method))",
        ]
        lines += r.headers.map { "request.setValue(\(quoted($0.value)), forHTTPHeaderField: \(quoted($0.name)))" }
        switch r.body {
        case .none: break
        case .text(let text): lines.append("request.httpBody = Data(\(quoted(text)).utf8)")
        case .urlEncoded(let pairs): lines.append("request.httpBody = Data(\(quoted(formEncoded(pairs))).utf8)")
        case .formData:
            lines.append("request.setValue(\"multipart/form-data; boundary=\\(boundary)\", forHTTPHeaderField: \"Content-Type\")")
            lines.append("request.httpBody = body")
        case .file(let path): lines.append("request.httpBody = try Data(contentsOf: URL(fileURLWithPath: \(quoted(path))))")
        }
        lines += [
            "",
            "let (data, response) = try await URLSession.shared.data(for: request)",
            "print((response as? HTTPURLResponse)?.statusCode ?? 0)",
            "print(String(decoding: data, as: UTF8.self))",
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: JavaScript

    static func fetch(_ r: SnippetRequest) -> String {
        var lines: [String] = []
        if !r.headers.isEmpty {
            lines.append("const myHeaders = new Headers();")
            lines += r.headers.map { "myHeaders.append(\(quoted($0.name)), \(quoted($0.value)));" }
            lines.append("")
        }
        var bodyName: String?
        switch r.body {
        case .none: break
        case .text(let text):
            lines += ["const raw = \(quoted(text));", ""]
            bodyName = "raw"
        case .urlEncoded(let pairs):
            lines.append("const urlencoded = new URLSearchParams();")
            lines += pairs.map { "urlencoded.append(\(quoted($0.name)), \(quoted($0.value)));" }
            lines.append("")
            bodyName = "urlencoded"
        case .formData(let parts):
            lines.append("const formdata = new FormData();")
            lines += parts.map { part in
                part.filePath != nil
                    ? "formdata.append(\(quoted(part.name)), fileInput.files[0], \(quoted(fileName(part.filePath!))));"
                    : "formdata.append(\(quoted(part.name)), \(quoted(part.value ?? "")));"
            }
            lines.append("")
            bodyName = "formdata"
        case .file:
            lines += ["const file = fileInput.files[0];", ""]
            bodyName = "file"
        }
        lines.append("const requestOptions = {")
        var options = ["  method: \(quoted(r.method))"]
        if !r.headers.isEmpty { options.append("  headers: myHeaders") }
        if let bodyName { options.append("  body: \(bodyName)") }
        options.append("  redirect: \"follow\"")
        lines.append(options.joined(separator: ",\n"))
        lines += [
            "};",
            "",
            "fetch(\(quoted(r.url)), requestOptions)",
            "  .then((response) => response.text())",
            "  .then((result) => console.log(result))",
            "  .catch((error) => console.error(error));",
        ]
        return lines.joined(separator: "\n")
    }

    static func axios(_ r: SnippetRequest) -> String {
        var lines = ["const axios = require('axios');"]
        var dataName: String?
        switch r.body {
        case .none: break
        case .text(let text):
            lines.append("let data = \(quoted(text));")
            dataName = "data"
        case .urlEncoded(let pairs):
            lines.append("const qs = require('qs');")
            lines.append("let data = qs.stringify({")
            lines.append(pairs.map { "  \(quoted($0.name)): \(quoted($0.value))" }.joined(separator: ",\n"))
            lines.append("});")
            dataName = "data"
        case .formData(let parts):
            lines += ["const FormData = require('form-data');", "const fs = require('fs');", "let data = new FormData();"]
            lines += parts.map { part in
                part.filePath != nil
                    ? "data.append(\(quoted(part.name)), fs.createReadStream(\(quoted(part.filePath!))));"
                    : "data.append(\(quoted(part.name)), \(quoted(part.value ?? "")));"
            }
            dataName = "data"
        case .file(let path):
            lines += ["const fs = require('fs');", "let data = fs.readFileSync(\(quoted(path)));"]
            dataName = "data"
        }
        lines += ["", "let config = {", "  method: \(quoted(r.method.lowercased())),", "  maxBodyLength: Infinity,", "  url: \(quoted(r.url)),"]
        if !r.headers.isEmpty || { if case .formData = r.body { true } else { false } }() {
            lines.append("  headers: {")
            var headerLines = r.headers.map { "    \(quoted($0.name)): \(quoted($0.value))" }
            if case .formData = r.body { headerLines.append("    ...data.getHeaders()") }
            lines.append(headerLines.joined(separator: ",\n"))
            lines.append("  },")
        }
        if let dataName { lines.append("  data: \(dataName)") }
        lines += [
            "};",
            "",
            "axios.request(config)",
            "  .then((response) => console.log(JSON.stringify(response.data)))",
            "  .catch((error) => console.log(error));",
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: Python

    static func python(_ r: SnippetRequest) -> String {
        var lines = ["import requests", "", "url = \(quoted(r.url))", ""]
        var arguments = "headers=headers"
        switch r.body {
        case .none:
            lines.append("payload = {}")
            arguments += ", data=payload"
        case .text(let text):
            lines.append("payload = \(quoted(text))")
            arguments += ", data=payload"
        case .urlEncoded(let pairs):
            lines.append("payload = " + quoted(formEncoded(pairs)))
            arguments += ", data=payload"
        case .formData(let parts):
            let texts = parts.filter { $0.filePath == nil }
            let files = parts.filter { $0.filePath != nil }
            lines.append("payload = {" + texts.map { "\(quoted($0.name)): \(quoted($0.value ?? ""))" }.joined(separator: ", ") + "}")
            lines.append("files = [")
            lines += files.map { "  (\(quoted($0.name)), (\(quoted(fileName($0.filePath!))), open(\(quoted($0.filePath!)), 'rb'), \(quoted($0.contentType ?? "application/octet-stream")))),"}
            lines.append("]")
            arguments += ", data=payload, files=files"
        case .file(let path):
            lines.append("payload = open(\(quoted(path)), 'rb')")
            arguments += ", data=payload"
        }
        lines.append("headers = {" + (r.headers.isEmpty ? "" : "\n" + r.headers.map { "  \(quoted($0.name)): \(quoted($0.value))" }.joined(separator: ",\n") + "\n") + "}")
        lines += ["", "response = requests.request(\(quoted(r.method)), url, \(arguments))", "", "print(response.text)"]
        return lines.joined(separator: "\n")
    }

    // MARK: Go

    static func go(_ r: SnippetRequest) -> String {
        var imports = ["\"fmt\"", "\"io\"", "\"net/http\""]
        var setup: [String] = []
        var bodyExpression = "nil"
        switch r.body {
        case .none: break
        case .text(let text):
            imports.append("\"strings\"")
            setup.append("  payload := strings.NewReader(\(quoted(text)))")
            bodyExpression = "payload"
        case .urlEncoded(let pairs):
            imports.append("\"strings\"")
            setup.append("  payload := strings.NewReader(\(quoted(formEncoded(pairs))))")
            bodyExpression = "payload"
        case .formData(let parts):
            imports += ["\"bytes\"", "\"mime/multipart\"", "\"os\"", "\"path/filepath\""]
            setup += ["  payload := &bytes.Buffer{}", "  writer := multipart.NewWriter(payload)"]
            for part in parts {
                if let path = part.filePath {
                    setup += [
                        "  file, errFile := os.Open(\(quoted(path)))",
                        "  if errFile != nil { fmt.Println(errFile); return }",
                        "  defer file.Close()",
                        "  part, _ := writer.CreateFormFile(\(quoted(part.name)), filepath.Base(\(quoted(path))))",
                        "  io.Copy(part, file)",
                    ]
                } else {
                    setup.append("  _ = writer.WriteField(\(quoted(part.name)), \(quoted(part.value ?? "")))")
                }
            }
            setup.append("  writer.Close()")
            bodyExpression = "payload"
        case .file(let path):
            imports.append("\"os\"")
            setup += ["  payload, err := os.Open(\(quoted(path)))", "  if err != nil { fmt.Println(err); return }", "  defer payload.Close()"]
            bodyExpression = "payload"
        }
        var lines = ["package main", "", "import (", imports.sorted().map { "  " + $0 }.joined(separator: "\n"), ")", "", "func main() {", "  url := \(quoted(r.url))", "  method := \(quoted(r.method))", ""]
        lines += setup
        lines += [
            "  client := &http.Client{}",
            "  req, err := http.NewRequest(method, url, \(bodyExpression))",
            "  if err != nil {", "    fmt.Println(err)", "    return", "  }",
        ]
        lines += r.headers.map { "  req.Header.Add(\(quoted($0.name)), \(quoted($0.value)))" }
        if case .formData = r.body { lines.append("  req.Header.Set(\"Content-Type\", writer.FormDataContentType())") }
        lines += [
            "",
            "  res, err := client.Do(req)",
            "  if err != nil {", "    fmt.Println(err)", "    return", "  }",
            "  defer res.Body.Close()",
            "",
            "  body, err := io.ReadAll(res.Body)",
            "  if err != nil {", "    fmt.Println(err)", "    return", "  }",
            "  fmt.Println(string(body))",
            "}",
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: OkHttp

    static func okHttp(_ r: SnippetRequest, kotlin: Bool) -> String {
        let q: (String) -> String = { quoted($0, escapeDollar: kotlin) }
        let contentType = r.headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        var lines: [String] = []
        func variable(_ type: String, _ name: String, _ value: String) -> String {
            kotlin ? "val \(name) = \(value)" : "\(type) \(name) = \(value);"
        }
        lines.append(kotlin ? "val client = OkHttpClient()" : "OkHttpClient client = new OkHttpClient().newBuilder().build();")
        var bodyName = "null"
        switch r.body {
        case .none:
            if ["POST", "PUT", "PATCH"].contains(r.method) {
                lines.append(kotlin ? "val body = \"\".toRequestBody(null)" : "RequestBody body = RequestBody.create(\"\", null);")
                bodyName = "body"
            }
        case .text(let text):
            let mediaType = kotlin ? "\(q(contentType ?? "text/plain")).toMediaType()" : "MediaType.parse(\(q(contentType ?? "text/plain")))"
            lines.append(variable("MediaType", "mediaType", mediaType))
            lines.append(kotlin ? "val body = \(q(text)).toRequestBody(mediaType)" : "RequestBody body = RequestBody.create(\(q(text)), mediaType);")
            bodyName = "body"
        case .urlEncoded(let pairs):
            lines.append(kotlin ? "val body = FormBody.Builder()" : "RequestBody body = new FormBody.Builder()")
            lines += pairs.map { "  .add(\(q($0.name)), \(q($0.value)))" }
            lines.append(kotlin ? "  .build()" : "  .build();")
            bodyName = "body"
        case .formData(let parts):
            lines.append(kotlin ? "val body = MultipartBody.Builder().setType(MultipartBody.FORM)" : "RequestBody body = new MultipartBody.Builder().setType(MultipartBody.FORM)")
            for part in parts {
                if let path = part.filePath {
                    let type = q(part.contentType ?? "application/octet-stream")
                    lines.append(kotlin
                        ? "  .addFormDataPart(\(q(part.name)), \(q(fileName(path))), File(\(q(path))).asRequestBody(\(type).toMediaType()))"
                        : "  .addFormDataPart(\(q(part.name)), \(q(fileName(path))), RequestBody.create(new File(\(q(path))), MediaType.parse(\(type))))")
                } else {
                    lines.append("  .addFormDataPart(\(q(part.name)), \(q(part.value ?? "")))")
                }
            }
            lines.append(kotlin ? "  .build()" : "  .build();")
            bodyName = "body"
        case .file(let path):
            lines.append(kotlin
                ? "val body = File(\(q(path))).asRequestBody(\(q(contentType ?? "application/octet-stream")).toMediaType())"
                : "RequestBody body = RequestBody.create(new File(\(q(path))), MediaType.parse(\(q(contentType ?? "application/octet-stream"))));")
            bodyName = "body"
        }
        lines.append(kotlin ? "val request = Request.Builder()" : "Request request = new Request.Builder()")
        lines.append("  .url(\(q(r.url)))")
        lines.append("  .method(\(q(r.method)), \(bodyName))")
        lines += r.headers.map { "  .addHeader(\(q($0.name)), \(q($0.value)))" }
        lines.append(kotlin ? "  .build()" : "  .build();")
        lines.append(kotlin ? "val response = client.newCall(request).execute()" : "Response response = client.newCall(request).execute();")
        return lines.joined(separator: "\n")
    }
}
