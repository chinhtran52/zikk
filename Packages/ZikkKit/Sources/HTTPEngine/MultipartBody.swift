import Foundation

struct MultipartBody {
    let boundary = "----FormBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var data = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(name: String, value: String, contentType: String? = nil) {
        var head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(escape(name))\"\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        data.append(Data((head + "\r\n").utf8))
        data.append(Data(value.utf8))
        data.append(Data("\r\n".utf8))
    }

    mutating func addFile(name: String, fileName: String, data fileData: Data, contentType: String) {
        let head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(escape(name))\"; filename=\"\(escape(fileName))\"\r\nContent-Type: \(contentType)\r\n\r\n"
        data.append(Data(head.utf8))
        data.append(fileData)
        data.append(Data("\r\n".utf8))
    }

    func finalize() -> Data {
        data + Data("--\(boundary)--\r\n".utf8)
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r\n", with: " ")
    }
}
