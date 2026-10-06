import AppKit
import Foundation

struct AgentToolCall {
    let id: String?
    let name: String
    let arguments: [String: Any]
}

struct AgentToolResponse {
    let id: String?
    let name: String
    let result: String
}

struct PendingFileWrite: Identifiable {
    let id = UUID()
    let call: AgentToolCall
    let relativePath: String
    let content: String
    let replacesExistingFile: Bool
}

struct PendingTerminalCommand: Identifiable {
    let id = UUID()
    let call: AgentToolCall
    let command: String
    let workingDirectory: String
}

enum PendingToolApproval: Identifiable {
    case fileWrite(PendingFileWrite)
    case terminalCommand(PendingTerminalCommand)

    var id: UUID {
        switch self {
        case .fileWrite(let request): request.id
        case .terminalCommand(let request): request.id
        }
    }
}

enum AgentToolCatalog {
    static let declarations: [[String: Any]] = [
        [
            "name": "list_files",
            "description": "List files and folders in the selected working folder or a relative subfolder. Hidden and secret files are excluded.",
            "behavior": "NON_BLOCKING",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "directory": ["type": "STRING", "description": "Relative directory path. Use . for the working folder."],
                ],
            ],
        ],
        [
            "name": "search_files",
            "description": "Search file names and text contents within the selected working folder. Hidden and secret files are excluded.",
            "behavior": "NON_BLOCKING",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "query": ["type": "STRING", "description": "Text to find in file names or contents."],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "read_file",
            "description": "Read a text file inside the selected working folder. Use a relative path. Hidden and secret files are not accessible.",
            "behavior": "NON_BLOCKING",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "path": ["type": "STRING", "description": "Relative path to the text file."],
                ],
                "required": ["path"],
            ],
        ],
        [
            "name": "write_file",
            "description": "Create or replace a text file inside the selected working folder. The user must approve each write in the app before it happens. Use a relative path.",
            "behavior": "NON_BLOCKING",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "path": ["type": "STRING", "description": "Relative destination path."],
                    "content": ["type": "STRING", "description": "Complete text content to write."],
                ],
                "required": ["path", "content"],
            ],
        ],
        [
            "name": "open_file",
            "description": "Open a non-executable file from the selected working folder in its default Mac app.",
            "behavior": "NON_BLOCKING",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "path": ["type": "STRING", "description": "Relative path to the file."],
                ],
                "required": ["path"],
            ],
        ],
        [
            "name": "open_application",
            "description": "Launch a Mac application by its name, such as Finder, Notes, or Safari.",
            "behavior": "NON_BLOCKING",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "name": ["type": "STRING", "description": "Application name."],
                ],
                "required": ["name"],
            ],
        ],
        [
            "name": "run_terminal_command",
            "description": "Propose a shell command to run in the selected working folder. The app will show the exact command and wait for the user to approve before executing it. Never try to bypass this approval.",
            "behavior": "NON_BLOCKING",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "command": ["type": "STRING", "description": "Exact shell command to run."],
                ],
                "required": ["command"],
            ],
        ],
    ]
}

@MainActor
enum AgentToolExecutor {
    private static let maxReadCharacters = 24_000
    private static let maxWriteBytes = 500_000
    private static let maxSearchFiles = 400
    private static let maxSearchResults = 30
    private static let blockedExtensions: Set<String> = ["app", "command", "key", "pem", "p12", "pfx", "sh", "scpt", "workflow"]

    static func execute(_ call: AgentToolCall, workspace: URL?) -> AgentToolResponse {
        do {
            let result: String
            switch call.name {
            case "list_files":
                guard let workspace else { throw ToolError("Choose a working folder first.") }
                let relative = call.arguments["directory"] as? String ?? "."
                let directory = try resolve(relative, in: workspace)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw ToolError("That folder does not exist.")
                }
                let urls = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                    options: [.skipsHiddenFiles]
                )
                let entries = urls.compactMap { url -> String? in
                    guard !isBlocked(url) else { return nil }
                    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    return url.lastPathComponent + (isDirectory ? "/" : "")
                }.sorted()
                result = entries.isEmpty ? "This folder is empty." : entries.prefix(100).joined(separator: "\n")

            case "search_files":
                guard let workspace else { throw ToolError("Choose a working folder first.") }
                guard let query = call.arguments["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ToolError("Provide a search query.")
                }
                result = try search(query, in: workspace)

            case "read_file":
                guard let workspace else { throw ToolError("Choose a working folder first.") }
                guard let path = call.arguments["path"] as? String else { throw ToolError("Provide a relative file path.") }
                let url = try resolve(path, in: workspace)
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) else { throw ToolError("That file is not UTF-8 text.") }
                result = String(text.prefix(maxReadCharacters)) + (text.count > maxReadCharacters ? "\n\n[Truncated]" : "")

            case "open_file":
                guard let workspace else { throw ToolError("Choose a working folder first.") }
                guard let path = call.arguments["path"] as? String else { throw ToolError("Provide a relative file path.") }
                let url = try resolve(path, in: workspace)
                guard !blockedExtensions.contains(url.pathExtension.lowercased()) else {
                    throw ToolError("Opening executable or automation files is not allowed.")
                }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    throw ToolError("That file does not exist.")
                }
                guard NSWorkspace.shared.open(url) else { throw ToolError("macOS could not open that file.") }
                result = "Opened \(path) in its default app."

            case "open_application":
                guard let name = call.arguments["name"] as? String, !name.isEmpty else { throw ToolError("Provide an application name.") }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", name]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw ToolError("macOS could not find or launch \(name).") }
                result = "Launched \(name)."

            default:
                throw ToolError("Unknown tool: \(call.name).")
            }
            return AgentToolResponse(id: call.id, name: call.name, result: result)
        } catch {
            return AgentToolResponse(id: call.id, name: call.name, result: "Error: \(error.localizedDescription)")
        }
    }

    static func makeWriteApproval(_ call: AgentToolCall, workspace: URL?) throws -> PendingFileWrite {
        guard let workspace else { throw ToolError("Choose a working folder first.") }
        guard let path = call.arguments["path"] as? String, let content = call.arguments["content"] as? String else {
            throw ToolError("Provide both a relative path and file content.")
        }
        guard content.utf8.count <= maxWriteBytes else { throw ToolError("The file is too large to write (maximum 500 KB).") }
        let url = try resolve(path, in: workspace)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else { throw ToolError("The destination is a folder, not a file.") }
        return PendingFileWrite(call: call, relativePath: path, content: content, replacesExistingFile: exists)
    }

    static func makeTerminalCommandApproval(_ call: AgentToolCall, workspace: URL?) throws -> PendingTerminalCommand {
        guard let workspace else { throw ToolError("Choose a working folder first.") }
        guard let command = call.arguments["command"] as? String else { throw ToolError("Provide the command to run.") }
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { throw ToolError("The command is empty.") }
        guard trimmedCommand.utf8.count <= 4_000 else { throw ToolError("The command is too long to review (maximum 4 KB).") }
        guard !trimmedCommand.unicodeScalars.contains(where: { $0.value == 0 }) else { throw ToolError("The command contains an invalid character.") }
        return PendingTerminalCommand(call: call, command: trimmedCommand, workingDirectory: workspace.path)
    }

    static func writeApprovedFile(_ request: PendingFileWrite, workspace: URL?) -> AgentToolResponse {
        do {
            guard let workspace else { throw ToolError("Choose a working folder first.") }
            let url = try resolve(request.relativePath, in: workspace)
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data(request.content.utf8).write(to: url, options: .atomic)
            return AgentToolResponse(
                id: request.call.id,
                name: request.call.name,
                result: request.replacesExistingFile ? "Updated \(request.relativePath)." : "Created \(request.relativePath)."
            )
        } catch {
            return AgentToolResponse(id: request.call.id, name: request.call.name, result: "Error: \(error.localizedDescription)")
        }
    }

    private static func search(_ query: String, in workspace: URL) throws -> String {
        let enumerator = FileManager.default.enumerator(
            at: workspace,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var results: [String] = []
        var inspected = 0
        while let url = enumerator?.nextObject() as? URL, inspected < maxSearchFiles, results.count < maxSearchResults {
            guard !isBlocked(url) else {
                if url.lastPathComponent.hasPrefix(".") { enumerator?.skipDescendants() }
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard values?.isDirectory != true else { continue }
            inspected += 1
            let relativePath = url.path.replacingOccurrences(of: workspace.path + "/", with: "")
            if relativePath.localizedCaseInsensitiveContains(query) {
                results.append(relativePath)
                continue
            }
            guard (values?.fileSize ?? 0) <= 1_000_000,
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let start = text.index(range.lowerBound, offsetBy: -min(80, text.distance(from: text.startIndex, to: range.lowerBound)), limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: min(120, text.distance(from: range.upperBound, to: text.endIndex)), limitedBy: text.endIndex) ?? text.endIndex
            let excerpt = text[start..<end].replacingOccurrences(of: "\n", with: " ")
            results.append("\(relativePath): …\(excerpt)…")
        }
        if results.isEmpty { return "No matching files found." }
        let capped = inspected >= maxSearchFiles ? "\n\n[Search limited to the first \(maxSearchFiles) files.]" : ""
        return results.joined(separator: "\n") + capped
    }

    private static func resolve(_ path: String, in workspace: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/") else { throw ToolError("Use a relative path inside the selected working folder.") }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains(".."), !components.contains(where: { $0 != "." && $0.hasPrefix(".") }) else {
            throw ToolError("Hidden files and parent-folder paths are not accessible.")
        }
        let url = workspace.appendingPathComponent(path).standardizedFileURL
        let rootPath = workspace.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") else {
            throw ToolError("That path is outside the selected working folder.")
        }
        guard !isBlocked(url) else { throw ToolError("That file is hidden or may contain secrets, so it is not accessible.") }
        return url
    }

    private static func isBlocked(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let sensitiveNames = ["id_rsa", "id_ed25519", "credentials", "secrets", "passwords"]
        return url.pathComponents.contains(where: { $0.hasPrefix(".") })
            || url.pathComponents.contains(where: { sensitiveNames.contains($0.lowercased()) })
            || [".env", ".pem", ".key", ".p12", ".pfx"].contains(where: { name.hasSuffix($0) })
    }
}

enum TerminalCommandRunner {
    static func run(_ request: PendingTerminalCommand) async -> AgentToolResponse {
        let command = request.command
        let workingDirectory = request.workingDirectory
        let result = await Task.detached(priority: .userInitiated) {
            runSynchronously(command, workingDirectory: workingDirectory)
        }.value
        return AgentToolResponse(id: request.call.id, name: request.call.name, result: result)
    }

    private static func runSynchronously(_ command: String, workingDirectory: String) -> String {
        let process = Process()
        let outputPipe = Pipe()
        let timeoutFlag = CommandTimeoutFlag()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return "Could not start the command: \(error.localizedDescription)"
        }

        let timeoutWork = DispatchWorkItem {
            guard process.isRunning else { return }
            timeoutFlag.set()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeoutWork)

        var output = Data()
        var truncated = false
        let outputHandle = outputPipe.fileHandleForReading
        while true {
            let chunk = outputHandle.readData(ofLength: 4_096)
            if chunk.isEmpty { break }
            let remaining = max(0, 32_000 - output.count)
            if remaining > 0 {
                output.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining { truncated = true }
        }
        process.waitUntilExit()
        timeoutWork.cancel()

        var result = String(decoding: output, as: UTF8.self)
        if truncated { result += "\n[Output truncated at 32 KB.]" }
        if timeoutFlag.value { result += "\n[Command stopped after 45 seconds.]" }
        result += "\n[Exit code: \(process.terminationStatus)]"
        return result
    }
}

private final class CommandTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func set() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }
}

private struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
