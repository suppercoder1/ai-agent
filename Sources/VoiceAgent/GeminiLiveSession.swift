import AVFoundation
import Foundation

final class GeminiLiveSession: NSObject {
    enum Event {
        case inputTranscript(String)
        case outputTranscript(String)
        case audio(Data, Int)
        case interrupted
        case goAway
        case voiceActivity(String)
        case toolCalls([AgentToolCall])
        case interactionStatus(String)
        case turnComplete
        case failure(String)
        case sendFailure(String)
        case socketClosed(String)
    }

    private let apiKey: String
    private let model: VoiceModel
    private let thinkingLevel: ThinkingLevel
    private let systemInstruction: String
    private let automaticActivityDetection: Bool
    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var onEvent: ((Event) -> Void)?
    private var inputConverter: AVAudioConverter?
    private var inputPCMFormat: AVAudioFormat?
    private let sendLock = NSLock()
    private var outgoingTask: Task<Void, Never>?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var setupContinuation: CheckedContinuation<Void, Error>?
    private var setupCompleteReceived = false
    private let continuationLock = NSLock()
    private var didReportReceiveFailure = false
    private var microphoneTapInstalled = false
    private let diagnosticLock = NSLock()
    private var sentAudioChunkCount = 0
    private var microphoneBufferCount = 0
    private let echoControlLock = NSLock()
    private var suppressMicDuringAssistantPlayback = false
    private var assistantAudioActive = false
    private var assistantResponseComplete = true
    private var pendingAssistantAudioBuffers = 0
    private var playbackGeneration = 0
    private var echoReleaseGeneration = 0
    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let audioQueue = DispatchQueue(label: "voiceagent.audio")
    private let audioQueueKey = DispatchSpecificKey<Bool>()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    init(apiKey: String, model: VoiceModel, thinkingLevel: ThinkingLevel, systemInstruction: String, automaticActivityDetection: Bool = false) {
        self.apiKey = apiKey
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.systemInstruction = systemInstruction
        self.automaticActivityDetection = automaticActivityDetection
        super.init()
        audioQueue.setSpecific(key: audioQueueKey, value: true)
        audioQueue.sync {
            audioEngine.attach(player)
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: outputFormat)
        }
    }

    func connect(onEvent: @escaping (Event) -> Void) async throws {
        self.onEvent = onEvent
        let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? apiKey)")!
        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        urlSession = session
        let task = session.webSocketTask(with: url)
        socket = task

        var generationConfig: [String: Any] = ["responseModalities": ["AUDIO"]]
        if model == .extended {
            generationConfig["thinkingConfig"] = ["thinkingLevel": thinkingLevel.rawValue]
        }

        var activityDetection: [String: Any] = ["disabled": !automaticActivityDetection]
        if automaticActivityDetection {
            activityDetection["silenceDurationMs"] = 500
        }

        let setup: [String: Any] = [
            "setup": [
                "model": "models/\(model.rawValue)",
                "generationConfig": generationConfig,
                "tools": [["functionDeclarations": AgentToolCatalog.declarations]],
                "realtimeInputConfig": ["automaticActivityDetection": activityDetection],
                "inputAudioTranscription": [:],
                "outputAudioTranscription": [:],
                "systemInstruction": ["parts": [["text": systemInstruction]]]
            ]
        ]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuationLock.lock()
            openContinuation = continuation
            continuationLock.unlock()
            task.resume()
        }
        listen()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuationLock.lock()
            let isComplete = setupCompleteReceived
            if !isComplete { setupContinuation = continuation }
            continuationLock.unlock()
            if isComplete {
                continuation.resume()
            } else {
                Task {
                    do { try await sendJSON(setup) }
                    catch { finishSetup(.failure(error)) }
                }
            }
        }
    }

    func close() async {
        stopMicrophone()
        audioQueue.sync {
            if audioEngine.isRunning { audioEngine.stop() }
            player.stop()
        }
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    func startMicrophone(enableVoiceProcessing: Bool = false, onAudio: @escaping (Data, Float) -> Void) throws {
        try onAudioQueue {
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        guard permission == .authorized else {
            throw NSError(domain: "VoiceAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow microphone access in System Settings > Privacy & Security > Microphone."])
        }
        let input = audioEngine.inputNode
        if enableVoiceProcessing, !audioEngine.isRunning, !input.isVoiceProcessingEnabled {
            do { try input.setVoiceProcessingEnabled(true) }
            catch { print("Voice processing unavailable: \(error.localizedDescription)") }
        }
        let format = input.outputFormat(forBus: 0)
        let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: format, to: pcmFormat) else {
            throw NSError(domain: "VoiceAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not prepare the microphone audio converter."])
        }
        inputPCMFormat = pcmFormat
        inputConverter = converter
        if microphoneTapInstalled {
            input.removeTap(onBus: 0)
            microphoneTapInstalled = false
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let converted = self.convertToInt16PCM(buffer) else { return }
            let peak = Self.peakAmplitude(inPCM16: converted)
            self.logMicrophonePeak(peak)
            onAudio(converted, peak)
        }
        microphoneTapInstalled = true
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
        echoControlLock.lock()
        suppressMicDuringAssistantPlayback = enableVoiceProcessing && !input.isVoiceProcessingEnabled
        assistantAudioActive = false
        assistantResponseComplete = true
        pendingAssistantAudioBuffers = 0
        playbackGeneration += 1
        echoReleaseGeneration += 1
        let usesEchoFallback = suppressMicDuringAssistantPlayback
        echoControlLock.unlock()
        print("Microphone capture active (\(Int(format.sampleRate)) Hz, \(format.channelCount) channel(s), voice processing: \(input.isVoiceProcessingEnabled))")
        if usesEchoFallback {
            print("Echo cancellation unavailable; microphone audio will pause during Gemini playback")
        }
        }
    }

    func stopMicrophone() {
        onAudioQueue {
        if microphoneTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            microphoneTapInstalled = false
        }
        echoControlLock.lock()
        assistantAudioActive = false
        assistantResponseComplete = true
        pendingAssistantAudioBuffers = 0
        playbackGeneration += 1
        echoReleaseGeneration += 1
        suppressMicDuringAssistantPlayback = false
        echoControlLock.unlock()
        }
    }

    func sendAudio(_ data: Data) {
        echoControlLock.lock()
        let shouldSuppress = suppressMicDuringAssistantPlayback && assistantAudioActive
        echoControlLock.unlock()
        guard !shouldSuppress else { return }

        diagnosticLock.lock()
        sentAudioChunkCount += 1
        let chunkNumber = sentAudioChunkCount
        diagnosticLock.unlock()
        if chunkNumber == 1 { print("first audio chunk bytes: \(data.count)") }
        if chunkNumber.isMultiple(of: 20) { print("sent audio chunks: \(chunkNumber)") }

        let message: [String: Any] = ["realtimeInput": ["audio": ["mimeType": "audio/pcm;rate=16000", "data": data.base64EncodedString()]]]
        enqueueJSON(message)
    }

    func assistantResponseDidComplete() {
        echoControlLock.lock()
        assistantResponseComplete = true
        let shouldRelease = pendingAssistantAudioBuffers == 0 && assistantAudioActive
        echoControlLock.unlock()
        if shouldRelease { scheduleEchoGateRelease() }
    }

    private func reserveAssistantAudioBuffer() -> Int {
        echoControlLock.lock()
        let wasInactive = !assistantAudioActive
        assistantAudioActive = true
        assistantResponseComplete = false
        pendingAssistantAudioBuffers += 1
        echoReleaseGeneration += 1
        let generation = playbackGeneration
        let shouldLog = wasInactive && suppressMicDuringAssistantPlayback
        echoControlLock.unlock()
        if shouldLog { print("Microphone uplink paused to prevent Gemini audio echo") }
        return generation
    }

    private func markAssistantAudioBufferPlayed(generation: Int) {
        echoControlLock.lock()
        var shouldRelease = false
        if playbackGeneration == generation {
            pendingAssistantAudioBuffers = max(0, pendingAssistantAudioBuffers - 1)
            shouldRelease = assistantResponseComplete && pendingAssistantAudioBuffers == 0 && assistantAudioActive
        }
        echoControlLock.unlock()
        if shouldRelease { scheduleEchoGateRelease() }
    }

    private func scheduleEchoGateRelease() {
        echoControlLock.lock()
        guard assistantResponseComplete, pendingAssistantAudioBuffers == 0, assistantAudioActive else {
            echoControlLock.unlock()
            return
        }
        echoReleaseGeneration += 1
        let releaseGeneration = echoReleaseGeneration
        let isUsingFallback = suppressMicDuringAssistantPlayback
        echoControlLock.unlock()

        guard isUsingFallback else {
            echoControlLock.lock()
            if echoReleaseGeneration == releaseGeneration { assistantAudioActive = false }
            echoControlLock.unlock()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.echoControlLock.lock()
            if self.echoReleaseGeneration == releaseGeneration,
               self.assistantResponseComplete,
               self.pendingAssistantAudioBuffers == 0 {
                self.assistantAudioActive = false
            }
            self.echoControlLock.unlock()
        }
    }

    private func resetAssistantPlaybackState() {
        echoControlLock.lock()
        playbackGeneration += 1
        pendingAssistantAudioBuffers = 0
        assistantAudioActive = false
        assistantResponseComplete = true
        echoReleaseGeneration += 1
        echoControlLock.unlock()
    }

    func sendText(_ text: String) {
        enqueueJSON([
            "clientContent": [
                "turns": [["role": "user", "parts": [["text": text]]]],
                "turnComplete": true
            ]
        ])
    }

    func restoreContext(_ transcript: [TranscriptEntry]) {
        let turns: [[String: Any]] = transcript.compactMap { entry in
            guard !entry.text.isEmpty else { return nil }
            return [
                "role": entry.isUser ? "user" : "model",
                "parts": [["text": entry.text]]
            ]
        }
        guard !turns.isEmpty else { return }
        enqueueJSON(["clientContent": ["turns": turns, "turnComplete": false]])
    }

    func startActivity() {
        enqueueJSON(["realtimeInput": ["activityStart": [:]]])
        print("activityStart sent")
    }

    func endActivity() {
        enqueueJSON(["realtimeInput": ["activityEnd": [:]]])
        print("activityEnd sent")
    }

    func sendToolResponses(_ responses: [AgentToolResponse]) {
        let functionResponses: [[String: Any]] = responses.map { response in
            var functionResponse: [String: Any] = [
                "name": response.name,
                "response": ["result": response.result],
            ]
            if let id = response.id { functionResponse["id"] = id }
            if model == .live {
                functionResponse["response"] = ["result": response.result, "scheduling": "INTERRUPT"]
            }
            return functionResponse
        }
        enqueueJSON(["toolResponse": ["functionResponses": functionResponses]])
    }

    func playAudio(_ data: Data, generation: Int) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let sampleCount = data.count / MemoryLayout<Int16>.size
            guard sampleCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
                  let channels = buffer.floatChannelData else {
                self.markAssistantAudioBufferPlayed(generation: generation)
                return
            }
            buffer.frameLength = AVAudioFrameCount(sampleCount)
            data.withUnsafeBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                for index in 0..<sampleCount {
                    let offset = index * 2
                    let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                    let sample = Int16(bitPattern: bits)
                    channels[0][index] = Float(sample) / Float(Int16.max)
                }
            }
            if !self.audioEngine.isRunning {
                do { try self.audioEngine.start() }
                catch {
                    print("Audio playback engine failed to start: \(error.localizedDescription)")
                    self.markAssistantAudioBufferPlayed(generation: generation)
                    return
                }
            }
            let shouldStartPlayer = !self.player.isPlaying
            self.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.markAssistantAudioBufferPlayed(generation: generation)
            }
            if shouldStartPlayer { self.player.play() }
        }
    }

    func stopPlayback() {
        onAudioQueue {
            self.player.stop()
            self.resetAssistantPlaybackState()
        }
    }

    private func onAudioQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: audioQueueKey) == true { return try operation() }
        return try audioQueue.sync(execute: operation)
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let socket else {
            throw NSError(domain: "VoiceAgent", code: 3, userInfo: [NSLocalizedDescriptionKey: "Gemini socket is not connected."])
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "VoiceAgent", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not encode the Gemini message as UTF-8."])
        }
        try await socket.send(.string(json))
    }

    private func enqueueJSON(_ object: [String: Any]) {
        sendLock.lock()
        let previous = outgoingTask
        outgoingTask = Task { [weak self] in
            await previous?.value
            do { try await self?.sendJSON(object) }
            catch { self?.onEvent?(.sendFailure("Could not send a message to Gemini: \(error.localizedDescription)")) }
        }
        sendLock.unlock()
    }

    private func listen() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.continuationLock.lock()
                let shouldReport = !self.didReportReceiveFailure
                self.didReportReceiveFailure = true
                self.continuationLock.unlock()
                if shouldReport { self.onEvent?(.failure(error.localizedDescription)) }
            case .success(let message):
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: data = Data()
                }
                self.consume(data)
                self.listen()
            }
        }
    }

    private func consume(_ data: Data) {
        print("[Gemini Live <-] \(String(decoding: data.prefix(300), as: UTF8.self))")
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
            let error = NSError(domain: "GeminiLive", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
            finishSetup(.failure(error))
            onEvent?(.failure(message)); return
        }
        if root["setupComplete"] != nil {
            print("setupComplete received")
            continuationLock.lock()
            setupCompleteReceived = true
            continuationLock.unlock()
            finishSetup(.success(()))
        }
        if root["goAway"] != nil { onEvent?(.goAway) }
        if let toolCall = root["toolCall"] as? [String: Any],
           let functionCalls = toolCall["functionCalls"] as? [[String: Any]] {
            let calls = functionCalls.compactMap { function -> AgentToolCall? in
                guard let name = function["name"] as? String else { return nil }
                return AgentToolCall(
                    id: function["id"] as? String,
                    name: name,
                    arguments: function["args"] as? [String: Any] ?? [:]
                )
            }
            if !calls.isEmpty {
                print("Gemini requested tools: \(calls.map(\.name).joined(separator: ", "))")
                onEvent?(.toolCalls(calls))
            }
        }
        if let activity = root["voiceActivity"] as? [String: Any],
           let type = activity["type"] as? String {
            onEvent?(.voiceActivity(type))
        }
        let serverContent = root["serverContent"] as? [String: Any]
        let interactionStatus = (root["interactionStatus"] as? String)
            ?? (root["interaction_status"] as? String)
            ?? (serverContent?["interactionStatus"] as? String)
            ?? (serverContent?["interaction_status"] as? String)
        guard let content = serverContent else {
            if let interactionStatus { onEvent?(.interactionStatus(interactionStatus)) }
            return
        }
        if content["interrupted"] as? Bool == true { onEvent?(.interrupted) }
        if let transcription = content["inputTranscription"] as? [String: Any], let text = transcription["text"] as? String { onEvent?(.inputTranscript(text)) }
        if let transcription = content["outputTranscription"] as? [String: Any], let text = transcription["text"] as? String { onEvent?(.outputTranscript(text)) }
        if let modelTurn = content["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                guard let inline = part["inlineData"] as? [String: Any],
                      let encoded = inline["data"] as? String,
                      let audio = Data(base64Encoded: encoded) else { continue }
                let generation = reserveAssistantAudioBuffer()
                onEvent?(.audio(audio, generation))
            }
        }
        if content["turnComplete"] as? Bool == true { onEvent?(.turnComplete) }
        if let interactionStatus { onEvent?(.interactionStatus(interactionStatus)) }
    }

    private func finishSetup(_ result: Result<Void, Error>) {
        continuationLock.lock()
        let continuation = setupContinuation
        setupContinuation = nil
        continuationLock.unlock()
        continuation?.resume(with: result)
    }

    private func logMicrophonePeak(_ peak: Float) {
        diagnosticLock.lock()
        microphoneBufferCount += 1
        let bufferNumber = microphoneBufferCount
        diagnosticLock.unlock()
        if bufferNumber == 1 { print("First microphone buffer received") }
        if bufferNumber.isMultiple(of: 20) {
            print(String(format: "mic peak amplitude (buffer %d): %.4f", bufferNumber, peak))
        }
    }

    private static func peakAmplitude(inPCM16 data: Data) -> Float {
        data.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            var peak: Int32 = 0
            for sample in samples {
                peak = max(peak, abs(Int32(sample)))
            }
            return Float(peak) / Float(Int16.max)
        }
    }

    private func convertToInt16PCM(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converter = inputConverter, let format = inputPCMFormat else { return nil }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate)) + 8
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, status != .error,
              let channel = converted.floatChannelData?[0], converted.frameLength > 0 else { return nil }
        let sampleCount = Int(converted.frameLength)
        var result = Data(count: sampleCount * 2)
        result.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for index in 0..<sampleCount {
                let sample = max(-1, min(1, channel[index]))
                let bits = UInt16(bitPattern: Int16(sample * Float(Int16.max)).littleEndian)
                let offset = index * 2
                bytes[offset] = UInt8(truncatingIfNeeded: bits)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: bits >> 8)
            }
        }
        return result
    }
}

extension GeminiLiveSession: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        continuationLock.lock()
        let continuation = openContinuation
        openContinuation = nil
        continuationLock.unlock()
        continuation?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        print("WebSocket error: \(error.localizedDescription)")
        continuationLock.lock()
        let open = openContinuation
        openContinuation = nil
        continuationLock.unlock()
        open?.resume(throwing: error)
        finishSetup(.failure(error))
        onEvent?(.socketClosed(error.localizedDescription))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let message = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "Gemini closed the connection (\(closeCode.rawValue))."
        print("WebSocket closed: \(message)")
        let error = NSError(domain: "GeminiLive", code: Int(closeCode.rawValue), userInfo: [NSLocalizedDescriptionKey: message])
        finishSetup(.failure(error))
        onEvent?(.socketClosed(message))
    }
}
