import Foundation
import SwiftUI

enum VoiceModel: String, CaseIterable, Identifiable {
    case live = "gemini-3.8-live"
    case extended = "gemini-3.8-live-extended-thinking"
    var id: String { rawValue }
    var title: String { self == .live ? "Live" : "Extended Thinking" }
}

struct TranscriptEntry: Identifiable {
    let id = UUID()
    let role: String
    let text: String
    let isUser: Bool
}

@MainActor
final class VoiceAgentModel: ObservableObject {
    @Published var selectedModel: VoiceModel = .live
    @Published var transcript: [TranscriptEntry] = []
    @Published var status = "Disconnected"
    @Published var errorMessage: String?
    @Published var isConnected = false
    @Published var isRecording = false
    private var session: GeminiLiveSession?
    private var hasStarted = false
    private var activeUserText = ""
    private var activeAssistantText = ""

    init() {}

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
            let newSession = GeminiLiveSession(apiKey: key, model: selectedModel)
            session = newSession
            try await newSession.connect { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            isConnected = true
            status = "Connected · \(selectedModel.title)"
        } catch {
            status = "Disconnected"
            errorMessage = error.localizedDescription
            session = nil
        }
    }

    func disconnect() async {
        stopTalking()
        await session?.close()
        session = nil
        isConnected = false
        status = "Disconnected"
    }

    func startTalking() {
        guard isConnected, !isRecording else { return }
        isRecording = true
        activeUserText = ""
        do {
            try session?.startMicrophone { [weak self] data in
                self?.session?.sendAudio(data)
            }
            status = "Listening…"
        } catch {
            isRecording = false
            errorMessage = "Microphone error: \(error.localizedDescription)"
        }
    }

    func stopTalking() {
        guard isRecording else { return }
        isRecording = false
        session?.stopMicrophone()
        session?.endAudioTurn()
        status = "Thinking…"
    }

    func clearTranscript() { transcript.removeAll() }

    private func handle(_ event: GeminiLiveSession.Event) {
        switch event {
        case .inputTranscript(let text):
            status = "Heard you · waiting for reply…"
            activeUserText += text
            replaceStreamingEntry(role: "You", text: activeUserText, isUser: true)
        case .outputTranscript(let text):
            status = "Replying…"
            activeAssistantText += text
            replaceStreamingEntry(role: "Gemini", text: activeAssistantText, isUser: false)
        case .audio(let data):
            status = "Speaking…"
            session?.playAudio(data)
        case .turnComplete:
            activeUserText = ""
            activeAssistantText = ""
            status = "Connected · \(selectedModel.title)"
        case .failure(let message):
            errorMessage = message
            status = "Connection error"
            isConnected = false
        }
    }

    private func replaceStreamingEntry(role: String, text: String, isUser: Bool) {
        guard !text.isEmpty else { return }
        if let last = transcript.last, last.isUser == isUser {
            transcript[transcript.count - 1] = TranscriptEntry(role: role, text: text, isUser: isUser)
        } else {
            transcript.append(TranscriptEntry(role: role, text: text, isUser: isUser))
        }
    }
}
