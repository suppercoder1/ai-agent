import AVFoundation
import Foundation

final class GeminiLiveSession: NSObject {
    enum Event {
        case inputTranscript(String)
        case outputTranscript(String)
        case audio(Data)
        case turnComplete
        case failure(String)
    }

    private let apiKey: String
    private let model: VoiceModel
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
    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let audioQueue = DispatchQueue(label: "voiceagent.audio")
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    init(apiKey: String, model: VoiceModel) {
        self.apiKey = apiKey
        self.model = model
        super.init()
    }

    func connect(onEvent: @escaping (Event) -> Void) async throws {
        self.onEvent = onEvent
        let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? apiKey)")!
        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        urlSession = session
        let task = session.webSocketTask(with: url)
        socket = task

        let setup: [String: Any] = [
            "setup": [
                "model": "models/\(model.rawValue)",
                "generationConfig": ["responseModalities": ["AUDIO"]],
                "inputAudioTranscription": [:],
                "outputAudioTranscription": [:],
                "systemInstruction": ["parts": [["text": "You are a helpful voice assistant. Keep replies natural and concise."]]]
            ]
        ]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            openContinuation = continuation
            task.resume()
        }
        listen()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if setupCompleteReceived {
                continuation.resume()
            } else {
                setupContinuation = continuation
                Task {
                    do { try await sendJSON(setup) }
                    catch { finishSetup(.failure(error)) }
                }
            }
        }
    }

    func close() async {
        stopMicrophone()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    func startMicrophone(onAudio: @escaping (Data) -> Void) throws {
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        guard permission == .authorized else {
            throw NSError(domain: "VoiceAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow microphone access in System Settings > Privacy & Security > Microphone."])
        }
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: format, to: pcmFormat) else {
            throw NSError(domain: "VoiceAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not prepare the microphone audio converter."])
        }
        inputPCMFormat = pcmFormat
        inputConverter = converter
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            guard let converted = self.convertToPCM16(buffer) else { return }
            onAudio(converted)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    func stopMicrophone() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
    }

    func sendAudio(_ data: Data) {
        let message: [String: Any] = ["realtimeInput": ["audio": ["mimeType": "audio/pcm;rate=16000", "data": data.base64EncodedString()]]]
        enqueueJSON(message)
    }

    func endAudioTurn() {
        enqueueJSON(["realtimeInput": ["audioStreamEnd": true]])
    }

    func playAudio(_ data: Data) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            guard !samples.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channels = buffer.floatChannelData else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for (index, sample) in samples.enumerated() { channels[0][index] = Float(sample) / Float(Int16.max) }
            if !self.audioEngine.isRunning {
                self.audioEngine.attach(self.player)
                self.audioEngine.connect(self.player, to: self.audioEngine.mainMixerNode, format: self.outputFormat)
                try? self.audioEngine.start()
            }
            if !self.player.isPlaying { self.player.play() }
            self.player.scheduleBuffer(buffer)
        }
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
            catch { self?.onEvent?(.failure("Could not send audio to Gemini: \(error.localizedDescription)")) }
        }
        sendLock.unlock()
    }

    private func listen() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.onEvent?(.failure(error.localizedDescription))
            case .success(let message):
                do {
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
    }

    private func consume(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
            finishSetup(.failure(NSError(domain: "GeminiLive", code: 4, userInfo: [NSLocalizedDescriptionKey: message])))
            onEvent?(.failure(message)); return
        }
        if root["setupComplete"] != nil {
            setupCompleteReceived = true
            finishSetup(.success(()))
        }
        guard let content = root["serverContent"] as? [String: Any] else { return }
        if let transcription = content["inputTranscription"] as? [String: Any], let text = transcription["text"] as? String { onEvent?(.inputTranscript(text)) }
        if let transcription = content["outputTranscription"] as? [String: Any], let text = transcription["text"] as? String { onEvent?(.outputTranscript(text)) }
        if let modelTurn = content["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                guard let inline = part["inlineData"] as? [String: Any],
                      let encoded = inline["data"] as? String,
                      let audio = Data(base64Encoded: encoded) else { continue }
                onEvent?(.audio(audio))
            }
        }
        if content["turnComplete"] as? Bool == true { onEvent?(.turnComplete) }
    }

    private func finishSetup(_ result: Result<Void, Error>) {
        guard let continuation = setupContinuation else { return }
        setupContinuation = nil
        continuation.resume(with: result)
    }

    private func convertToPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
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
        var result = Data(capacity: Int(converted.frameLength) * 2)
        for index in 0..<Int(converted.frameLength) {
            let sample = max(-1, min(1, channel[index]))
            var value = Int16(sample * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        return result
    }
}

extension GeminiLiveSession: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let continuation = openContinuation
        openContinuation = nil
        continuation?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let open = openContinuation
        openContinuation = nil
        open?.resume(throwing: error)
        finishSetup(.failure(error))
        onEvent?(.failure(error.localizedDescription))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let message = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "Gemini closed the connection (\(closeCode.rawValue))."
        let error = NSError(domain: "GeminiLive", code: Int(closeCode.rawValue), userInfo: [NSLocalizedDescriptionKey: message])
        finishSetup(.failure(error))
        onEvent?(.failure(message))
    }
}
