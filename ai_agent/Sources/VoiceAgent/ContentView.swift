import SwiftUI

struct ContentView: View {
    @ObservedObject var model: VoiceAgentModel

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice Agent").font(.largeTitle.bold())
                    Text(model.status).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Model", selection: $model.selectedModel) {
                    ForEach(VoiceModel.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .disabled(model.isConnected)
            }

            transcript

            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button {
                    model.isRecording ? model.stopTalking() : model.startTalking()
                } label: {
                    Label(model.isRecording ? "Stop talking" : "Start talking", systemImage: model.isRecording ? "stop.fill" : "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isConnected)

                Spacer()
                Button("Clear") { model.clearTranscript() }
                    .buttonStyle(.borderless)
            }

            Text("Set GEMINI_API_KEY in .env, then restart the app.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .task {
            await model.connectFromEnv()
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.transcript.isEmpty {
                        Text("Your conversation will appear here.")
                            .foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 250)
                    }
                    ForEach(model.transcript) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.role).font(.caption.bold()).foregroundStyle(.secondary)
                            Text(entry.text).textSelection(.enabled)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(entry.isUser ? Color.accentColor.opacity(0.09) : Color.gray.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                        .id(entry.id)
                    }
                }
            }
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            .onChange(of: model.transcript.count) {
                if let last = model.transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}
