import Foundation
import SwiftUI
import AppKit
import AVFoundation

enum VoiceModel: String, CaseIterable, Identifiable {
    case live = "gemini-3.8-live"
    case extended = "gemini-3.8-live-extended-thinking"
    var id: String { rawValue }
    var title: String { self == .live ? "Live" : "Extended Thinking" }
}

enum ThinkingLevel: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct AgentBot: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let specialty: String
    let systemInstruction: String
    let defaultAvatarType: String

    var rawValue: String { id }

    private static let commonInstruction = "You are a helpful Mac agent. Use available tools to search, read, write, or open files in the selected working folder, launch Mac apps, or propose terminal commands when asked. Use relative file paths. Hidden and secret files are off-limits. Never claim an action succeeded until its tool returns success. File writes require approval in the app; wait for that result before saying a file changed. Every terminal command requires the user to approve the exact command in the app; never bypass or imply that approval. Reply clearly and concisely in text."

    static let clover = AgentBot(
        id: "clover",
        name: "Clover",
        specialty: "Everyday assistant",
        systemInstruction: commonInstruction + " Your name is Clover. You are a friendly general-purpose assistant.",
        defaultAvatarType: "clover"
    )
    static let droid = AgentBot(
        id: "droid",
        name: "Droid",
        specialty: "Mac and coding",
        systemInstruction: commonInstruction + " Your name is Droid. Focus on software development, debugging, and practical Mac workflows.",
        defaultAvatarType: "droid"
    )
    static let star = AgentBot(
        id: "star",
        name: "Star",
        specialty: "Research and ideas",
        systemInstruction: commonInstruction + " Your name is Star. Focus on research, explanations, and careful reasoning.",
        defaultAvatarType: "star"
    )
    static let starterBots = [clover, droid, star]

    static func make(name: String, specialty: String, avatarType: String) -> AgentBot {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSpecialty = specialty.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = commonInstruction + " Your name is \(cleanName). Focus on \(cleanSpecialty)."
        return AgentBot(
            id: UUID().uuidString,
            name: cleanName,
            specialty: cleanSpecialty,
            systemInstruction: prompt,
            defaultAvatarType: avatarType
        )
    }
}

struct AgentBotProfile: Codable, Equatable {
    var systemPrompt: String
    var avatarType: String
    var face: String
    var colorHex: String?
    var shading: String

    static func defaults(for bot: AgentBot) -> AgentBotProfile {
        AgentBotProfile(
            systemPrompt: bot.systemInstruction,
            avatarType: bot.defaultAvatarType,
            face: "eyes",
            colorHex: nil,
            shading: "plastic"
        )
    }
}

struct TranscriptEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let role: String
    let text: String
    let isUser: Bool

    init(id: UUID = UUID(), role: String, text: String, isUser: Bool) {
        self.id = id
        self.role = role
        self.text = text
        self.isUser = isUser
    }
}

@MainActor
final class VoiceAgentModel: ObservableObject {
    @Published var selectedModel: VoiceModel = .live
    @Published var selectedThinkingLevel: ThinkingLevel = .medium
    @Published var bots: [AgentBot] = AgentBot.starterBots
    @Published var selectedBot: AgentBot = AgentBot.clover
    @Published private var botProfiles: [String: AgentBotProfile] = [:]
    @Published var transcript: [TranscriptEntry] = [] {
        didSet { saveCurrentConversation() }
    }
    @Published var status = "Disconnected"
    @Published var errorMessage: String?
    @Published var isConnected = false
    @Published var isRecording = false
    @Published var isCallMode = false
    @Published var isAssistantSpeaking = false
    @Published var audioLevel: Float = 0
    @Published var workspaceName: String?
    @Published var pendingToolApproval: PendingToolApproval?
    private var session: GeminiLiveSession?
    private var workspaceURL: URL?
    private var isAccessingWorkspace = false
    private var hasStarted = false
    private var activeUserText = ""
    private var activeUserMessageID: UUID?
    private var activeAssistantText = ""
    private var activeAssistantMessageID: UUID?
    private var thinkingTimeoutTask: Task<Void, Never>?
    private var queuedToolCalls: [AgentToolCall] = []
    private var pendingToolResponses: [AgentToolResponse] = []
    private var terminalCommandTask: Task<Void, Never>?
    private var pendingProfileReconnect: AgentBot?
    private let botProfilesKey = "AgentBotProfilesV1"
    private let botsKey = "AgentBotsV1"
    private let selectedBotKey = "SelectedAgentBotV1"

    init() {
        restoreBotRoster()
        restoreConversations()
        restoreBotProfiles()
        restoreWorkspace()
    }

    func botProfile(for bot: AgentBot) -> AgentBotProfile {
        botProfiles[bot.id] ?? .defaults(for: bot)
    }

    func saveBotProfile(_ profile: AgentBotProfile, for bot: AgentBot) {
        let previous = botProfile(for: bot)
        guard previous != profile else { return }
        botProfiles[bot.id] = profile
        persistBotProfiles()

        guard previous.systemPrompt != profile.systemPrompt,
              bot == selectedBot,
              (isConnected || status == "Connecting…") else { return }
        pendingProfileReconnect = bot
        reconnectForProfileIfReady()
    }

    private func restoreBotProfiles() {
        guard let data = UserDefaults.standard.data(forKey: botProfilesKey),
              let saved = try? JSONDecoder().decode([String: AgentBotProfile].self, from: data) else { return }
        botProfiles = saved
    }

    private func persistBotProfiles() {
        guard let data = try? JSONEncoder().encode(botProfiles) else { return }
        UserDefaults.standard.set(data, forKey: botProfilesKey)
    }

    private func restoreBotRoster() {
        if let data = UserDefaults.standard.data(forKey: botsKey),
           let saved = try? JSONDecoder().decode([AgentBot].self, from: data),
           !saved.isEmpty {
            bots = saved
        }
        let selectedID = UserDefaults.standard.string(forKey: selectedBotKey)
        selectedBot = bots.first(where: { $0.id == selectedID }) ?? bots[0]
    }

    private func persistBotRoster() {
        guard let data = try? JSONEncoder().encode(bots) else { return }
        UserDefaults.standard.set(data, forKey: botsKey)
        UserDefaults.standard.set(selectedBot.id, forKey: selectedBotKey)
    }

    private func persistConversations() {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        UserDefaults.standard.set(data, forKey: conversationsKey)
    }

    func createBot(name: String, specialty: String, avatarType: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let specialty = specialty.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !specialty.isEmpty else { return }
        let bot = AgentBot.make(name: name, specialty: specialty, avatarType: avatarType)
        bots.append(bot)
        botProfiles[bot.id] = .defaults(for: bot)
        conversations[bot.id] = []
        persistBotProfiles()
        persistBotRoster()
        persistConversations()
        selectBot(bot)
    }

    func deleteBot(_ bot: AgentBot) {
        guard bots.count > 1, bots.contains(where: { $0.id == bot.id }) else { return }
        let wasSelected = selectedBot.id == bot.id
        let nextBot = bots.first(where: { $0.id != bot.id })!
        let shouldReconnect = isConnected || session != nil || status == "Connecting…"

        if wasSelected && shouldReconnect {
            Task {
                await disconnect()
                removeBotData(bot)
                activateBot(nextBot)
                await connectFromEnv()
            }
        } else {
            removeBotData(bot)
            if wasSelected { activateBot(nextBot) }
        }
    }

    private func removeBotData(_ bot: AgentBot) {
        bots.removeAll { $0.id == bot.id }
        botProfiles.removeValue(forKey: bot.id)
        conversations.removeValue(forKey: bot.id)
        persistBotRoster()
        persistBotProfiles()
        persistConversations()
    }

    private func activateBot(_ bot: AgentBot) {
        selectedBot = bot
        UserDefaults.standard.set(bot.id, forKey: selectedBotKey)
        transcript = conversations[bot.id] ?? []
        errorMessage = nil
        status = isConnected ? connectedStatus : "Disconnected"
    }

    private func reconnectForProfileIfReady() {
        guard let bot = pendingProfileReconnect,
              bot == selectedBot,
              isConnected,
              (!isRecording || isCallMode),
              !isWorking else { return }
        pendingProfileReconnect = nil
        Task { await reconnect() }
    }

    func connectFromEnv() async {
        guard !hasStarted else { return }
        hasStarted = true
        guard let key = EnvironmentFile.geminiAPIKey(), !key.isEmpty else {
            status = "Missing API key"
            errorMessage = "Add GEMINI_API_KEY=your_key to .env in the project folder, then restart."
            return
        }
        errorMessage = nil
        status = "Connecting…"
        do {
            let newSession = GeminiLiveSession(
                apiKey: key,
                model: selectedModel,
                thinkingLevel: selectedThinkingLevel,
                systemInstruction: botProfile(for: selectedBot).systemPrompt,
                automaticActivityDetection: isCallMode
            )
            session = newSession
            try await newSession.connect { [weak self, weak newSession] event in
                Task { @MainActor in
                    guard let self, let newSession, self.session === newSession else { return }
                    self.handle(event)
                }
            }
            isConnected = true
            status = connectedStatus
            newSession.restoreContext(transcript.filter { !$0.text.isEmpty })
            if isCallMode {
                do {
                    try startCallMicrophone()
                } catch {
                    let message = "Microphone error: \(error.localizedDescription)"
                    isCallMode = false
                    await disconnect()
                    errorMessage = message
                    return
                }
            }
            reconnectForProfileIfReady()
        } catch {
            status = "Disconnected"
            errorMessage = error.localizedDescription
            session = nil
        }
    }

    func disconnect() async {
        thinkingTimeoutTask?.cancel()
        thinkingTimeoutTask = nil
        pendingProfileReconnect = nil
        if let userID = activeUserMessageID {
            transcript.removeAll { $0.id == userID && $0.text.isEmpty }
        }
        if let replyID = activeAssistantMessageID {
            transcript.removeAll { $0.id == replyID && $0.text.isEmpty }
        }
        activeAssistantMessageID = nil
        activeAssistantText = ""
        activeUserText = ""
        activeUserMessageID = nil
        isRecording = false
        isAssistantSpeaking = false
        audioLevel = 0
        pendingToolApproval = nil
        terminalCommandTask?.cancel()
        terminalCommandTask = nil
        queuedToolCalls.removeAll()
        pendingToolResponses.removeAll()
        await session?.close()
        session = nil
        isConnected = false
        status = "Disconnected"
        hasStarted = false
    }

    func reconnect() async {
        await disconnect()
        await connectFromEnv()
    }

    func selectModel(_ model: VoiceModel) {
        guard selectedModel != model else { return }
        selectedModel = model
        guard isConnected else { return }
        isConnected = false
        status = "Connecting…"
        Task {
            await disconnect()
            await connectFromEnv()
        }
    }

    func selectThinkingLevel(_ level: ThinkingLevel) {
        guard selectedThinkingLevel != level else { return }
        selectedThinkingLevel = level
        guard isConnected, selectedModel == .extended else { return }
        isConnected = false
        status = "Connecting…"
        Task {
            await disconnect()
            await connectFromEnv()
        }
    }

    func selectBot(_ bot: AgentBot) {
        guard selectedBot.id != bot.id else { return }
        pendingProfileReconnect = nil
        let shouldReconnect = isConnected || session != nil || status == "Connecting…"
        if shouldReconnect {
            Task {
                await disconnect()
                activateBot(bot)
                await connectFromEnv()
            }
        } else {
            activateBot(bot)
        }
    }

    func startTalking() async {
        guard isConnected, !isCallMode, !isRecording, !isWorking else { return }
        guard await requestMicrophonePermission() else { return }
        guard let session else {
            errorMessage = "Gemini is not connected yet."
            return
        }
        errorMessage = nil
        activeUserText = ""
        let userID = UUID()
        activeUserMessageID = userID
        transcript.append(TranscriptEntry(id: userID, role: "You", text: "", isUser: true))
        activeAssistantText = ""
        activeAssistantMessageID = nil
        audioLevel = 0
        session.beginAudioTurn()
        do {
            try installMicrophoneTap(for: session)
            isRecording = true
            status = "Listening…"
        } catch {
            session.endAudioTurn()
            transcript.removeAll { $0.id == userID && $0.text.isEmpty }
            activeUserMessageID = nil
            errorMessage = "Microphone error: \(error.localizedDescription)"
            status = connectedStatus
        }
    }

    func startCall() async {
        guard isConnected, !isCallMode, !isRecording, !isWorking else { return }
        guard await requestMicrophonePermission() else { return }
        errorMessage = nil
        isCallMode = true
        status = "Starting call…"
        await reconnect()
    }

    private func requestMicrophonePermission() async -> Bool {
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        if permission == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                errorMessage = "Allow microphone access in System Settings > Privacy & Security > Microphone."
            }
            return granted
        }
        guard permission == .authorized else {
            errorMessage = "Allow microphone access in System Settings > Privacy & Security > Microphone."
            return false
        }
        return true
    }

    private func installMicrophoneTap(for session: GeminiLiveSession, enableVoiceProcessing: Bool = false) throws {
        try session.startMicrophone(enableVoiceProcessing: enableVoiceProcessing) { [weak self, session] data, level in
            session.sendAudio(data)
            Task { @MainActor [weak self] in self?.audioLevel = level }
        }
    }

    private func startCallMicrophone() throws {
        guard let session else {
            throw NSError(domain: "VoiceAgent", code: 6, userInfo: [NSLocalizedDescriptionKey: "Gemini is not connected yet."])
        }
        activeUserText = ""
        activeUserMessageID = nil
        activeAssistantText = ""
        activeAssistantMessageID = nil
        audioLevel = 0
        try installMicrophoneTap(for: session, enableVoiceProcessing: true)
        isRecording = true
        status = "Listening…"
    }

    func stopTalking() {
        guard isRecording, !isCallMode else { return }
        isRecording = false
        audioLevel = 0
        session?.stopMicrophone()
        session?.endAudioTurn()
        let replyID = UUID()
        activeAssistantMessageID = replyID
        activeAssistantText = ""
        transcript.append(TranscriptEntry(id: replyID, role: selectedBot.name, text: "", isUser: false))
        status = "Thinking…"
        startThinkingTimeout()
    }

    func endCall() {
        guard isCallMode else { return }
        isCallMode = false
        status = "Switching to voice messages…"
        Task { await reconnect() }
    }

    func clearTranscript() {
        transcript.removeAll()
        if isConnected {
            isConnected = false
            status = "Connecting…"
            Task { await reconnect() }
        }
    }

    private var connectedStatus: String {
        "\(isCallMode ? "Call active" : "Connected") · \(selectedBot.name) · \(selectedModel.title)"
    }

    private func startThinkingTimeout() {
        thinkingTimeoutTask?.cancel()
        thinkingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled,
                  ["Thinking…", "Replying…"].contains(self.status) else { return }
            self.errorMessage = "No response from Gemini. Check the model name and microphone permission."
            if let replyID = self.activeAssistantMessageID {
                self.transcript.removeAll { $0.id == replyID && $0.text.isEmpty }
            }
            self.activeAssistantMessageID = nil
            self.status = self.isConnected ? self.connectedStatus : "Disconnected"
            self.thinkingTimeoutTask = nil
            self.reconnectForProfileIfReady()
        }
    }

    private var conversations: [String: [TranscriptEntry]] = [:]
    private let conversationsKey = "AgentConversationsV1"

    private func restoreConversations() {
        if let data = UserDefaults.standard.data(forKey: conversationsKey),
           let saved = try? JSONDecoder().decode([String: [TranscriptEntry]].self, from: data) {
            conversations = saved
        }
        transcript = conversations[selectedBot.id] ?? []
    }

    private func saveCurrentConversation() {
        conversations[selectedBot.id] = transcript.filter { !$0.text.isEmpty }
        persistConversations()
    }

    var isWorking: Bool {
        isAssistantSpeaking || ["Thinking…", "Replying…", "Using tools…", "Waiting for approval…", "Running command…"].contains(status)
    }

    func preview(for bot: AgentBot) -> String {
        let entries = bot == selectedBot ? transcript : (conversations[bot.id] ?? [])
        return entries.last(where: { !$0.text.isEmpty })?.text ?? bot.specialty
    }

    func chooseWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the agent's working folder"
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setWorkspace(url)
    }

    func resolveToolApproval(approved: Bool) {
        guard let approval = pendingToolApproval else { return }
        pendingToolApproval = nil
        switch approval {
        case .fileWrite(let request):
            if approved {
                pendingToolResponses.append(AgentToolExecutor.writeApprovedFile(request, workspace: workspaceURL))
            } else {
                pendingToolResponses.append(AgentToolResponse(
                    id: request.call.id,
                    name: request.call.name,
                    result: "The user declined to write \(request.relativePath)."
                ))
            }
            processNextToolCall()

        case .terminalCommand(let request):
            guard approved else {
                pendingToolResponses.append(AgentToolResponse(
                    id: request.call.id,
                    name: request.call.name,
                    result: "The user declined the command. It was not run."
                ))
                processNextToolCall()
                return
            }
            status = "Running command…"
            terminalCommandTask = Task { [weak self] in
                let response = await TerminalCommandRunner.run(request)
                guard let self, !Task.isCancelled else { return }
                self.terminalCommandTask = nil
                self.pendingToolResponses.append(response)
                self.processNextToolCall()
            }
        }
    }

    private func handle(_ event: GeminiLiveSession.Event) {
        switch event {
        case .inputTranscript(let text):
            activeUserText += text
            if let userID = activeUserMessageID,
               let index = transcript.firstIndex(where: { $0.id == userID }) {
                transcript[index] = TranscriptEntry(id: userID, role: "You", text: activeUserText, isUser: true)
            } else {
                let userID = UUID()
                activeUserMessageID = userID
                transcript.append(TranscriptEntry(id: userID, role: "You", text: activeUserText, isUser: true))
            }
        case .outputTranscript(let text):
            thinkingTimeoutTask?.cancel()
            thinkingTimeoutTask = nil
            status = "Replying…"
            activeAssistantText += text
            if let replyID = activeAssistantMessageID,
               let index = transcript.firstIndex(where: { $0.id == replyID }) {
                transcript[index] = TranscriptEntry(id: replyID, role: selectedBot.name, text: activeAssistantText, isUser: false)
            } else {
                let replyID = UUID()
                activeAssistantMessageID = replyID
                transcript.append(TranscriptEntry(id: replyID, role: selectedBot.name, text: text, isUser: false))
                activeAssistantText = text
            }
        case .audio(let data, let generation):
            thinkingTimeoutTask?.cancel()
            thinkingTimeoutTask = nil
            isAssistantSpeaking = true
            session?.playAudio(data, generation: generation)
        case .interrupted:
            thinkingTimeoutTask?.cancel()
            thinkingTimeoutTask = nil
            session?.stopPlayback()
            if let replyID = activeAssistantMessageID, activeAssistantText.isEmpty {
                transcript.removeAll { $0.id == replyID }
            }
            activeAssistantText = ""
            activeAssistantMessageID = nil
            isAssistantSpeaking = false
            if isCallMode { status = "Listening…" }
        case .voiceActivity(let type):
            guard isCallMode else { break }
            switch type.uppercased() {
            case "ACTIVITY_START":
                thinkingTimeoutTask?.cancel()
                thinkingTimeoutTask = nil
                status = "Listening…"
            case "ACTIVITY_END":
                status = "Thinking…"
                startThinkingTimeout()
            default:
                break
            }
        case .toolCalls(let calls):
            thinkingTimeoutTask?.cancel()
            thinkingTimeoutTask = nil
            queuedToolCalls.append(contentsOf: calls)
            status = "Using tools…"
            processNextToolCall()
        case .interactionStatus(let value):
            guard selectedModel == .extended else { break }
            switch value.uppercased() {
            case "IN_PROGRESS":
                if pendingToolApproval != nil {
                    status = "Waiting for approval…"
                } else if terminalCommandTask != nil {
                    status = "Running command…"
                } else if !queuedToolCalls.isEmpty || !pendingToolResponses.isEmpty {
                    status = "Using tools…"
                } else {
                    status = "Thinking…"
                }
            case "IDLE":
                thinkingTimeoutTask?.cancel()
                thinkingTimeoutTask = nil
                session?.assistantResponseDidComplete()
                labelPendingVoiceMessageIfNeeded()
                activeAssistantText = ""
                activeAssistantMessageID = nil
                if isCallMode { activeUserMessageID = nil }
                isAssistantSpeaking = false
                status = isCallMode ? "Listening…" : connectedStatus
            default:
                break
            }
        case .turnComplete:
            thinkingTimeoutTask?.cancel()
            thinkingTimeoutTask = nil
            session?.assistantResponseDidComplete()
            labelPendingVoiceMessageIfNeeded()
            if activeAssistantText.isEmpty, let replyID = activeAssistantMessageID {
                transcript.removeAll { $0.id == replyID }
                errorMessage = "Gemini returned no text transcription. Try sending the message again."
            }
            activeUserText = ""
            activeUserMessageID = nil
            activeAssistantText = ""
            activeAssistantMessageID = nil
            isAssistantSpeaking = false
            status = isCallMode ? "Listening…" : connectedStatus
            reconnectForProfileIfReady()
        case .failure(let message):
            errorMessage = message
            status = "Connection error"
        case .sendFailure(let message):
            errorMessage = message
        case .socketClosed(let message):
            errorMessage = message
            status = "Connection closed"
            isConnected = false
        }
    }

    private func labelPendingVoiceMessageIfNeeded() {
        guard activeUserText.isEmpty,
              let userID = activeUserMessageID,
              let index = transcript.firstIndex(where: { $0.id == userID && $0.text.isEmpty }) else { return }
        transcript[index] = TranscriptEntry(id: userID, role: "You", text: "Voice message", isUser: true)
    }

    private func processNextToolCall() {
        guard isConnected, pendingToolApproval == nil, terminalCommandTask == nil else { return }
        guard !queuedToolCalls.isEmpty else {
            guard !pendingToolResponses.isEmpty else { return }
            let responses = pendingToolResponses
            pendingToolResponses.removeAll()
            session?.sendToolResponses(responses)
            status = "Thinking…"
            return
        }

        let call = queuedToolCalls.removeFirst()
        if call.name == "write_file" {
            do {
                pendingToolApproval = .fileWrite(try AgentToolExecutor.makeWriteApproval(call, workspace: workspaceURL))
                status = "Waiting for approval…"
                return
            } catch {
                pendingToolResponses.append(AgentToolResponse(id: call.id, name: call.name, result: "Error: \(error.localizedDescription)"))
            }
        } else if call.name == "run_terminal_command" {
            do {
                pendingToolApproval = .terminalCommand(try AgentToolExecutor.makeTerminalCommandApproval(call, workspace: workspaceURL))
                status = "Waiting for approval…"
                return
            } catch {
                pendingToolResponses.append(AgentToolResponse(id: call.id, name: call.name, result: "Error: \(error.localizedDescription)"))
            }
        } else {
            pendingToolResponses.append(AgentToolExecutor.execute(call, workspace: workspaceURL))
        }
        processNextToolCall()
    }

    private func restoreWorkspace() {
        let savedPath = UserDefaults.standard.string(forKey: "AgentWorkspacePath")
        let candidate = savedPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return }
        setWorkspace(candidate, save: false)
    }

    private func setWorkspace(_ url: URL, save: Bool = true) {
        if isAccessingWorkspace, let workspaceURL {
            workspaceURL.stopAccessingSecurityScopedResource()
        }
        workspaceURL = url.standardizedFileURL
        isAccessingWorkspace = workspaceURL?.startAccessingSecurityScopedResource() ?? false
        workspaceName = url.lastPathComponent
        if save {
            UserDefaults.standard.set(url.path, forKey: "AgentWorkspacePath")
        }
    }
}
