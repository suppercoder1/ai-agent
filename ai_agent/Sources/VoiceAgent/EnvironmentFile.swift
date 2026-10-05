import Foundation

enum EnvironmentFile {
    static func geminiAPIKey() -> String? {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env")
        guard let contents = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        for line in contents.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !value.hasPrefix("#"), let separator = value.firstIndex(of: "=") else { continue }
            let name = value[..<separator].trimmingCharacters(in: .whitespaces)
            guard name == "GEMINI_API_KEY" else { continue }
            var key = value[value.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if key.count >= 2, (key.first == "\"" && key.last == "\"") || (key.first == "'" && key.last == "'") {
                key.removeFirst()
                key.removeLast()
            }
            return key.isEmpty ? nil : key
        }
        return nil
    }
}
