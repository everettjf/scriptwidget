import Foundation
import CryptoKit
import Darwin

let cliVersion = "0.2.1"
let maximumSnapshotBytes = 64 * 1024 * 1024

struct CLIError: Error, LocalizedError {
    var code: String
    var message: String
    var exitCode: Int32 = 1
    var errorDescription: String? { message }
}
struct SnapshotFile: Codable {
    let path: String
    let data: Data
}
struct ValidationRequest: Codable {
    var command: String
    var files: [SnapshotFile] = []
    var family: String = "medium"
    var appearance: String = "light"
    var parameter: String = ""
    var fixtures: Data = Data("{}".utf8)
    var scale: Int = 2
    var probePath: String? = nil
}
func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func appendField(_ data: Data, to target: inout Data) {
    var count = UInt64(data.count).bigEndian
    withUnsafeBytes(of: &count) { target.append(contentsOf: $0) }
    target.append(data)
}
func sourceHash(_ files: [SnapshotFile]) -> String {
    var result = Data("ScriptWidgetSource/v1\n".utf8)
    var count = UInt64(files.count).bigEndian
    withUnsafeBytes(of: &count) { result.append(contentsOf: $0) }
    for file in files.sorted(by: { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }) {
        appendField(Data(file.path.utf8), to: &result); appendField(file.data, to: &result)
    }
    return sha256(result)
}
func validateFiles(_ files: [SnapshotFile]) throws {
    guard !files.isEmpty, files.count <= 500 else { throw CLIError(code:"package.limit",message:"Package must contain 1–500 files.") }
    var names = Set<String>(), total = 0
    for file in files {
        let parts = file.path.split(separator:"/", omittingEmptySubsequences:false)
        guard !file.path.hasPrefix("/"), !file.path.contains("\\"), !file.path.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}),
              parts.count <= 16, parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}),
              names.insert(file.path.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX")).precomposedStringWithCanonicalMapping).inserted,
              file.data.count <= 25 * 1024 * 1024 else { throw CLIError(code:"package.path",message:"Unsafe, duplicate or oversized package file: \(file.path)") }
        total += file.data.count
        guard total <= maximumSnapshotBytes else { throw CLIError(code:"package.limit",message:"Package exceeds 64 MiB.") }
    }
}
func jsonData(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed]) }
func writeJSON(_ value: Any, to handle: FileHandle = .standardOutput) {
    if let data = try? jsonData(value) { handle.write(data); handle.write(Data([10])) }
}
