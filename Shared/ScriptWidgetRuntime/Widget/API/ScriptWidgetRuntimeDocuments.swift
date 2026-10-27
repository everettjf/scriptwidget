import Foundation
import Darwin
import JavaScriptCore

/// Bounded RFC-4180-style CSV parser. JSON/CSV are imported as private copies;
/// no bookmark, user pathname or executable document is exposed to scripts.
enum ScriptWidgetDocumentData {
    static func importedFile(_ url: URL) throws -> Data {
        // The security-scoped picker authorizes this exact native URL. Opening
        // the parent directory is unnecessary and can fail in the Mac sandbox.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ScriptWidgetSystemServiceError.unavailable }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= 262144 else { throw ScriptWidgetSystemServiceError.invalidOptions }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, result.count + count <= 262144 else { throw ScriptWidgetSystemServiceError.limitExceeded }
            if count == 0 { break }; result.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(), current = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &current) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, after.st_ino == current.st_ino, after.st_dev == current.st_dev,
              before.st_size == after.st_size, before.st_size == result.count, after.st_nlink == 1, current.st_mode & S_IFMT == S_IFREG,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw ScriptWidgetSystemServiceError.scopeChanged }
        return result
    }
    static func csv(_ data: Data) throws -> [String: Any] {
        guard data.count <= 262144, var text = String(data: data, encoding: .utf8) else { throw ScriptWidgetSystemServiceError.invalidOptions }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false, cursor = text.startIndex
        func finishField() throws {
            guard field.utf8.count <= 8192, row.count < 32 else { throw ScriptWidgetSystemServiceError.limitExceeded }
            row.append(field); field = ""; closed = false
        }
        func finishRow() throws {
            try finishField()
            guard rows.count < 501 else { throw ScriptWidgetSystemServiceError.limitExceeded }
            rows.append(row); row = []
        }
        while cursor < text.endIndex {
            let c = text[cursor]; cursor = text.index(after: cursor)
            if quoted {
                if c == "\"" {
                    if cursor < text.endIndex && text[cursor] == "\"" { field.append("\""); cursor = text.index(after: cursor) }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == "\"" {
                guard field.isEmpty && !closed else { throw ScriptWidgetSystemServiceError.invalidOptions }; quoted = true
            } else if c == "," { try finishField() }
            else if c == "\r\n" || c == "\n" || c == "\r" { try finishRow() }
            else { guard !closed else { throw ScriptWidgetSystemServiceError.invalidOptions }; field.append(c) }
            guard field.utf8.count <= 8192 else { throw ScriptWidgetSystemServiceError.limitExceeded }
        }
        guard !quoted else { throw ScriptWidgetSystemServiceError.invalidOptions }
        if !field.isEmpty || !row.isEmpty || closed { try finishRow() }
        guard let headers = rows.first, !headers.isEmpty, headers.allSatisfy({ !$0.isEmpty }), Set(headers).count == headers.count,
              rows.dropFirst().allSatisfy({ $0.count == headers.count }) else { throw ScriptWidgetSystemServiceError.invalidOptions }
        return ["headers": headers, "rows": Array(rows.dropFirst()), "truncated": false]
    }
    static func json(_ data: Data) throws -> Any {
        guard data.count <= 262144 else { throw ScriptWidgetSystemServiceError.limitExceeded }
        let object = try JSONSerialization.jsonObject(with: data)
        guard object is [String: Any] || object is [Any] else { throw ScriptWidgetSystemServiceError.invalidOptions }; return object
    }
}
@objc protocol ScriptWidgetRuntimeDocumentsExports: JSExport {
    static func list() -> ScriptWidgetRuntimePromise
    static func readJSON(_ id: String) -> ScriptWidgetRuntimePromise
    static func readCSV(_ id: String) -> ScriptWidgetRuntimePromise
}
@objc final class ScriptWidgetRuntimeDocuments: NSObject, ScriptWidgetRuntimeDocumentsExports {
    static func list() -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.documents) { context, finish in
            finish(.success(try context.access.load().documents.map { ["id": $0.id, "name": $0.name, "type": $0.type, "bytes": $0.bytes] as [String: Any] }))
        }
    }
    static func readJSON(_ id: String) -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.documents) { context, finish in finish(.success(try ScriptWidgetDocumentData.json(context.access.readDocument(id, type: "json")))) }
    }
    static func readCSV(_ id: String) -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.documents) { context, finish in finish(.success(try ScriptWidgetDocumentData.csv(context.access.readDocument(id, type: "csv")))) }
    }
}
