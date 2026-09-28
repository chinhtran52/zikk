import Foundation
import APICore

/// Reads user-selected files, resolving security-scoped bookmarks inside the sandbox.
public enum FileAccess {
    public enum Failure: LocalizedError {
        case unreadable(String)
        public var errorDescription: String? {
            switch self { case .unreadable(let path): "Cannot read file at \(path)" }
        }
    }

    public static func read(_ reference: FileReference) throws -> Data {
        if let bookmark = reference.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { return data }
            }
        }
        guard let data = FileManager.default.contents(atPath: reference.path) else { throw Failure.unreadable(reference.path) }
        return data
    }

    /// Creates a reference with a security-scoped bookmark for a URL the user just picked.
    public static func reference(for url: URL) -> FileReference {
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return FileReference(path: url.path, bookmark: bookmark)
    }

    public static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "json": "application/json"
        case "xml": "application/xml"
        case "txt": "text/plain"
        case "html", "htm": "text/html"
        case "csv": "text/csv"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "pdf": "application/pdf"
        case "zip": "application/zip"
        default: "application/octet-stream"
        }
    }
}
