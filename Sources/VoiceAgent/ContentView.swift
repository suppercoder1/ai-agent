import SwiftUI
import BotAvatarsKit
import ThinkingOrbsKit

struct ContentView: View {
    @ObservedObject var model: VoiceAgentModel
    @State private var editingBot: AgentBot?
    @State private var isCreatingBot = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 740
            VStack(spacing: 0) {
                header(compact: compact)
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.top, 12)
                    .padding(.bottom, compact ? 10 : 0)

                if compact {
                    compactBotPicker
                    chatPane(compact: true)
                } else {
                    HStack(spacing: 0) {
                        botSidebar
                            .frame(width: min(230, max(185, geometry.size.width * 0.23)))
                        Rectangle()
                            .fill(.white.opacity(0.08))
                            .frame(width: 1)
                        chatPane(compact: false)
                    }
                }
            }
            .padding(.horizontal, compact ? 14 : 22)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .background(Color(red: 0.045, green: 0.047, blue: 0.05).ignoresSafeArea())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 540, minHeight: 420)
        .task { await model.connect() }
        .sheet(item: $model.pendingToolApproval) { approval in
            switch approval {
            case .fileWrite(let request):
                FileWriteApprovalSheet(request: request) { approved in
                    model.resolveToolApproval(approved: approved)
                }
            case .terminalCommand(let request):
                TerminalCommandApprovalSheet(request: request) { approved in
                    model.resolveToolApproval(approved: approved)
                }
            case .computerAction(let request):
                ComputerActionApprovalSheet(request: request) { approved in
                    model.resolveToolApproval(approved: approved)
                }
            }
        }
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
            Text("Agent Chats")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
            Circle()
                .fill(model.isConnected ? Color.green.opacity(0.9) : Color.white.opacity(0.28))
                .frame(width: 6, height: 6)
            Text(model.status)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
                .frame(maxWidth: compact ? 120 : 210, alignment: .leading)

            Spacer(minLength: 8)

            modelControls(compact: compact)

            Button {
                Task {
                    if model.isConnected { await model.disconnect() }
                    else { await model.connect() }
                }
            } label: {
                Text(model.isConnected ? "Disconnect" : "Connect")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .liquidGlass(in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.status == "Connecting…")

            Button(action: model.chooseWorkspaceFolder) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    if !compact {
                        Text(model.workspaceName ?? "Choose folder")
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, compact ? 9 : 11)
                .frame(height: 32)
                .liquidGlass(in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Choose the folder Gemini can work in")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func modelControls(compact: Bool) -> some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(VoiceModel.allCases) { voiceModel in
                    Button {
                        model.selectModel(voiceModel)
                    } label: {
                        if model.selectedModel == voiceModel {
                            Label(voiceModel.title, systemImage: "checkmark")
                        } else {
                            Text(voiceModel.title)
                        }
                    }
                }
            } label: {
                capsuleLabel(compact ? model.selectedModel.title : "Model · \(model.selectedModel.title)")
            }
            .menuStyle(.borderlessButton)
            .disabled(model.isConnected)

            if model.needsAPIKey {
                SecureField("Gemini API key", text: $model.apiKeyInput)
                    .textFieldStyle(.plain)
                    .frame(width: compact ? 115 : 150)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .liquidGlass(in: Capsule())
                Button("Save key") { Task { await model.saveAPIKeyAndConnect() } }
                    .buttonStyle(.plain)
                    .disabled(model.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if model.selectedModel == .extended {
                Menu {
                    ForEach(ThinkingLevel.allCases) { level in
                        Button {
                            model.selectThinkingLevel(level)
                        } label: {
                            if model.selectedThinkingLevel == level {
                                Label(level.title, systemImage: "checkmark")
                            } else {
                                Text(level.title)
                            }
                        }
                    }
                } label: {
                    capsuleLabel(compact ? model.selectedThinkingLevel.title : "Thinking · \(model.selectedThinkingLevel.title)")
                }
                .menuStyle(.borderlessButton)
                .disabled(model.isConnected)
                .help("Thinking level")
            }
        }
    }

    private func capsuleLabel(_ title: String) -> some View {
        HStack(spacing: 5) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.82))
        .padding(.horizontal, 9)
        .frame(height: 30)
        .liquidGlass(in: Capsule())
    }

    private var botSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YOUR BOTS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                createBotButton
            }
            .padding(.horizontal, 10)
            .padding(.top, 19)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.bots) { bot in
                        botRow(bot, compact: false)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.trailing, 12)
        .padding(.bottom, 8)
    }

    private var compactBotPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.bots) { bot in
                    botRow(bot, compact: true)
                }
                createBotButton
            }
            .padding(.vertical, 4)
        }
    }

    private func botRow(_ bot: AgentBot, compact: Bool) -> some View {
        let selected = model.selectedBot == bot
        return Button {
            model.selectBot(bot)
        } label: {
            HStack(spacing: 10) {
                AgentAvatar(bot: bot, profile: model.botProfile(for: bot), size: compact ? 29 : 38, working: selected && model.isWorking)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bot.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(compact ? model.preview(for: bot) : bot.specialty)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }
                if compact && selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, compact ? 10 : 9)
            .padding(.vertical, compact ? 7 : 9)
            .frame(maxWidth: compact ? 210 : .infinity, alignment: .leading)
            .background(selected ? .white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 13))
            .liquidGlass(in: RoundedRectangle(cornerRadius: 13, style: .continuous), enabled: selected)
        }
        .buttonStyle(.plain)
        .help("Open \(bot.name)'s separate conversation")
    }

    private var createBotButton: some View {
        Button { isCreatingBot = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.76))
                .frame(width: 29, height: 29)
                .liquidGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .help("Create a bot")
        .sheet(isPresented: $isCreatingBot) {
            NewBotSheet { name, specialty, avatarType in
                model.createBot(name: name, specialty: specialty, avatarType: avatarType)
            }
        }
    }

    private func chatPane(compact: Bool) -> some View {
        VStack(spacing: 0) {
            chatHeader
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        if model.transcript.isEmpty {
                            emptyConversation
                                .padding(.top, 48)
                        } else {
                            ForEach(model.transcript) { entry in
                                ChatMessageRow(
                                    entry: entry,
                                    bot: model.selectedBot,
                                    profile: model.botProfile(for: model.selectedBot),
                                    working: entry.isUser
                                        ? model.isRecording
                                        : model.isWorking && entry.id == model.transcript.last?.id
                                )
                                .id(entry.id)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 22)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.transcript.map(\.text)) { _, _ in
                    guard let lastID = model.transcript.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 1, green: 0.38, blue: 0.42))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            callBox(compact: compact)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatHeader: some View {
        HStack(spacing: 11) {
            AgentAvatar(bot: model.selectedBot, profile: model.botProfile(for: model.selectedBot), size: 38, working: model.isWorking)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.selectedBot.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            Text(model.selectedBot.specialty)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.48))
            }
            Spacer()
            Button {
                editingBot = model.selectedBot
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Customize \(model.selectedBot.name)")
            Button {
                model.clearTranscript()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Clear this bot's conversation")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .sheet(item: $editingBot) { bot in
            BotProfileSheet(
                bot: bot,
                profile: model.botProfile(for: bot),
                isConnected: bot == model.selectedBot && model.isConnected,
                isWorking: bot == model.selectedBot && (model.isWorking || model.isRecording),
                canDelete: model.bots.count > 1,
                onDelete: { model.deleteBot(bot) }
            ) { profile in
                model.saveBotProfile(profile, for: bot)
            }
        }
    }

    private var emptyConversation: some View {
        VStack(spacing: 10) {
            AgentAvatar(bot: model.selectedBot, profile: model.botProfile(for: model.selectedBot), size: 70, working: false)
                .padding(.bottom, 4)
            Text("Chat with \(model.selectedBot.name)")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
            Text("\(model.selectedBot.specialty) · This bot keeps its own chat history.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.46))
                .multilineTextAlignment(.center)
        }
    }

    private func callBox(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            HStack(spacing: 11) {
                AgentAvatar(bot: model.selectedBot, profile: model.botProfile(for: model.selectedBot), size: compact ? 34 : 40, working: model.isWorking)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(callTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                        if model.isWorking && !model.isAssistantSpeaking {
                            ThinkingOrb(state: .breathing, size: .px20, theme: .dark)
                                .accessibilityHidden(true)
                        }
                    }
                    if !compact {
                        Text(callSubtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, compact ? 10 : 14)

            Spacer(minLength: 4)

            if model.isConnected {
                if model.isCallMode {
                    Button(action: model.endCall) {
                        Label("End call", systemImage: "phone.down.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, compact ? 13 : 16)
                            .frame(height: 38)
                            .liquidGlass(in: Capsule(), tint: Color.red.opacity(0.78))
                    }
                    .buttonStyle(.plain)
                    .help("End the hands-free call and return to voice messages")
                } else {
                    Button {
                        if model.isRecording {
                            model.stopTalking()
                        } else {
                            Task { await model.startTalking() }
                        }
                    } label: {
                        Label {
                            Text(model.isRecording ? "Stop talking" : "Start talking")
                        } icon: {
                            Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, compact ? 13 : 16)
                        .frame(height: 38)
                        .liquidGlass(in: Capsule(), tint: model.isRecording ? .red : .blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.isRecording && model.isWorking)
                    .opacity(!model.isRecording && model.isWorking ? 0.45 : 1)
                    .help(model.isRecording ? "Stop listening and send this turn" : "Start talking")

                    Button {
                        Task { await model.startCall() }
                    } label: {
                        Label("Call", systemImage: "phone.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, compact ? 12 : 15)
                            .frame(height: 38)
                            .liquidGlass(in: Capsule(), tint: Color.green.opacity(0.72))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isWorking || model.isRecording)
                    .opacity(model.isWorking || model.isRecording ? 0.45 : 1)
                    .help("Start a hands-free call with \(model.selectedBot.name)")

                    Button {
                        Task { await model.disconnect() }
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.84))
                            .frame(width: 36, height: 36)
                            .liquidGlass(in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Disconnect from Gemini")
                }
            } else {
                Button {
                    Task { await model.reconnect() }
                } label: {
                    Label(compact ? "Connect" : "Reconnect", systemImage: "phone.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .liquidGlass(in: Capsule(), tint: .blue)
                }
                .buttonStyle(.plain)
                .disabled(model.status == "Connecting…")
                .help("Connect to Gemini Live")
            }
        }
        .padding(.trailing, compact ? 9 : 13)
        .frame(minHeight: 76)
        .background {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            ZStack {
                shape.fill(Color.white.opacity(0.055))
                CallBoxGlow(
                    level: model.audioLevel,
                    active: model.isRecording || model.isWorking,
                    processing: model.isWorking && !model.isAssistantSpeaking
                )
                    .clipShape(shape)
                shape.stroke(.white.opacity(0.075), lineWidth: 1)
            }
        }
        .liquidGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var callTitle: String {
        if model.isCallMode {
            if model.isAssistantSpeaking { return "Speaking…" }
            if model.status == "Listening…" { return "Listening…" }
            if model.isWorking { return model.status }
            return "Call with \(model.selectedBot.name)"
        }
        if model.isRecording { return "Listening…" }
        if model.isAssistantSpeaking { return "Speaking…" }
        if model.isWorking { return model.status }
        return model.isConnected ? "Ready to talk with \(model.selectedBot.name)" : "Call disconnected"
    }

    private var callSubtitle: String {
        if model.isCallMode {
            if model.isAssistantSpeaking { return "Speak naturally; Gemini listens for your next turn" }
            if model.status == "Listening…" { return "Mic active · Gemini responds when you pause" }
            if model.isWorking { return "Waiting for \(model.selectedBot.name)’s reply" }
            return "Speak naturally; Gemini responds when you pause"
        }
        if model.isRecording { return "Click Stop talking when you’re done" }
        if model.isWorking { return "Waiting for \(model.selectedBot.name)’s reply" }
        return model.isConnected ? "Your voice conversation stays in this chat" : "Reconnect to continue this conversation"
    }
}

private struct CallBoxGlow: View {
    let level: Float
    let active: Bool
    let processing: Bool
    @State private var phase = false

    var body: some View {
        GeometryReader { geometry in
            let energy = min(max(CGFloat(level) * 2.2, 0), 1)
            let travel: CGFloat = phase ? 1 : -1
            ZStack(alignment: .bottom) {
                if processing {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [.clear, .mint.opacity(0.8), .cyan.opacity(0.9), .purple.opacity(0.8), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: geometry.size.width * 0.48, height: 16)
                        .blur(radius: 8)
                        .offset(x: travel * geometry.size.width * 0.25, y: 8)
                } else {
                    lobe(
                        color: .mint,
                        opacity: 0.36 + Double(energy) * 0.4,
                        width: geometry.size.width * 0.48,
                        height: 45 + energy * 26,
                        offsetX: -geometry.size.width * 0.22 + travel * geometry.size.width * 0.08,
                        blur: 23
                    )
                    lobe(
                        color: .cyan,
                        opacity: 0.3 + Double(energy) * 0.45,
                        width: geometry.size.width * 0.42,
                        height: 42 + energy * 28,
                        offsetX: travel * geometry.size.width * 0.05,
                        blur: 24
                    )
                    lobe(
                        color: .purple,
                        opacity: 0.32 + Double(energy) * 0.38,
                        width: geometry.size.width * 0.44,
                        height: 45 + energy * 26,
                        offsetX: geometry.size.width * 0.23 - travel * geometry.size.width * 0.08,
                        blur: 24
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .opacity(active ? 0.9 : 0.42)
            .onAppear { phase = true }
            .animation(.easeInOut(duration: active ? 1.5 : 4).repeatForever(autoreverses: true), value: phase)
            .animation(.easeOut(duration: 0.15), value: level)
        }
        .allowsHitTesting(false)
    }

    private func lobe(color: Color, opacity: Double, width: CGFloat, height: CGFloat, offsetX: CGFloat, blur: CGFloat) -> some View {
        Ellipse()
            .fill(color.opacity(opacity))
            .frame(width: width, height: height)
            .blur(radius: blur)
        .offset(x: offsetX, y: 22)
    }
}

private struct NewBotSheet: View {
    let onCreate: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var specialty = "General-purpose assistant"
    @State private var avatarType = "blob"

    private var selectedType: BotAvatarType { BotAvatarType(rawValue: avatarType) ?? .blob }
    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !specialty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                BotAvatar(type: selectedType, state: .default, size: 68, interactive: false)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create a bot")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.94))
                    Text("Give it a name and a job. You can tune its prompt after.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("NAME")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.48))
                TextField("e.g. Nova", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("WHAT SHOULD IT FOCUS ON?")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.48))
                TextField("e.g. Meal planning and recipes", text: $specialty)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("STARTING AVATAR")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.48))
                Menu {
                    ForEach(BotAvatarType.allCases) { type in
                        Button {
                            avatarType = type.rawValue
                        } label: {
                            if avatarType == type.rawValue {
                                Label(type.preset.label, systemImage: "checkmark")
                            } else {
                                Text(type.preset.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 9) {
                        BotAvatar(type: selectedType, state: .default, size: 34, interactive: false)
                        Text(selectedType.preset.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.84))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 48)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
                }
                .menuStyle(.borderlessButton)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    onCreate(name, specialty, avatarType)
                    dismiss()
                } label: {
                    Label("Create bot", systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(Color.blue.opacity(0.86), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canCreate)
                .opacity(canCreate ? 1 : 0.45)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460, height: 430)
        .background(Color(red: 0.075, green: 0.078, blue: 0.09))
        .preferredColorScheme(.dark)
    }
}

private struct BotProfileSheet: View {
    let bot: AgentBot
    let startingProfile: AgentBotProfile
    let isConnected: Bool
    let isWorking: Bool
    let canDelete: Bool
    let onDelete: () -> Void
    let onSave: (AgentBotProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentBotProfile
    @State private var showingDeleteConfirmation = false

    init(
        bot: AgentBot,
        profile: AgentBotProfile,
        isConnected: Bool,
        isWorking: Bool,
        canDelete: Bool,
        onDelete: @escaping () -> Void,
        onSave: @escaping (AgentBotProfile) -> Void
    ) {
        self.bot = bot
        self.startingProfile = profile
        self.isConnected = isConnected
        self.isWorking = isWorking
        self.canDelete = canDelete
        self.onDelete = onDelete
        self.onSave = onSave
        _draft = State(initialValue: profile)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)
    private var selectedType: BotAvatarType { BotAvatarType(rawValue: draft.avatarType) ?? .clover }
    private var selectedFace: BotAvatarFace { BotAvatarFace(rawValue: draft.face) ?? .eyes }
    private var selectedShading: BotAvatarShading { BotAvatarShading(rawValue: draft.shading) ?? .plastic }
    private var selectedColor: BotColor? { draft.colorHex.flatMap { BotColor($0) } }
    private var promptChanged: Bool { draft.systemPrompt != startingProfile.systemPrompt }
    private var canSave: Bool { !draft.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
                .padding(.horizontal, 22)
                .padding(.vertical, 17)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    appearanceCard
                    promptCard
                }
                .padding(20)
            }

            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            sheetFooter
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
        .frame(width: 650, height: 770)
        .background(Color(red: 0.075, green: 0.078, blue: 0.09))
        .preferredColorScheme(.dark)
        .alert("Delete \(bot.name)?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete Bot", role: .destructive) {
                onDelete()
                dismiss()
            }
        } message: {
            Text("This permanently removes the bot, its prompt, and its chat history.")
        }
    }

    private var sheetHeader: some View {
        HStack(spacing: 14) {
            avatar(size: 66, working: false)
            VStack(alignment: .leading, spacing: 4) {
                Text("Customize \(bot.name)")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
                Text("Shape their look and tune how they behave.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close bot settings")
        }
    }

    private var appearanceCard: some View {
        settingsCard(title: "AVATAR", subtitle: "Make this bot recognizable in the roster and chat.") {
            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(BotAvatarType.allCases) { type in
                    Button {
                        draft.avatarType = type.rawValue
                    } label: {
                        VStack(spacing: 1) {
                            BotAvatar(
                                type: type,
                                state: .default,
                                size: 39,
                                color: selectedColor,
                                shading: selectedShading,
                                interactive: false
                            )
                            Text(type.preset.label)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.67))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(draft.avatarType == type.rawValue ? Color.blue.opacity(0.2) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(draft.avatarType == type.rawValue ? Color.blue.opacity(0.8) : .white.opacity(0.04), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(type.preset.label) avatar")
                    .accessibilityAddTraits(draft.avatarType == type.rawValue ? .isSelected : [])
                }
            }

            Divider().overlay(.white.opacity(0.08))

            HStack(spacing: 9) {
                Text("Color")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                Button {
                    draft.colorHex = nil
                } label: {
                    ZStack {
                        Circle().fill(selectedType.paletteColor.color)
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 23, height: 23)
                    .overlay(Circle().stroke(draft.colorHex == nil ? .white : .white.opacity(0.18), lineWidth: draft.colorHex == nil ? 2 : 1))
                }
                .buttonStyle(.plain)
                .help("Use the shape's default color")

                ForEach(AvatarColorChoice.palette) { choice in
                    Button {
                        draft.colorHex = choice.hex
                    } label: {
                        Circle()
                            .fill(BotColor(choice.hex)?.color ?? .white)
                            .frame(width: 23, height: 23)
                            .overlay {
                                if draft.colorHex == choice.hex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay(Circle().stroke(draft.colorHex == choice.hex ? .white : .white.opacity(0.16), lineWidth: draft.colorHex == choice.hex ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(choice.name)
                    .accessibilityLabel(choice.name)
                }
                Spacer(minLength: 2)
                ColorPicker("Custom", selection: customColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 28)
                    .help("Choose a custom avatar color")
            }
            .padding(.vertical, 2)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FACE")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.44))
                    Picker("Face", selection: $draft.face) {
                        Text("Eyes").tag("eyes")
                        Text("Mouth").tag("mouth")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("MATERIAL")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.44))
                    Picker("Material", selection: $draft.shading) {
                        Text("Plastic").tag("plastic")
                        Text("Fabric").tag("fabric")
                        Text("Crisp").tag("crisp")
                        Text("Smooth").tag("smooth")
                        Text("Flat").tag("flat")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            HStack {
                Spacer()
                Button("Reset look") {
                    let defaults = AgentBotProfile.defaults(for: bot)
                    draft.avatarType = defaults.avatarType
                    draft.face = defaults.face
                    draft.colorHex = defaults.colorHex
                    draft.shading = defaults.shading
                }
                .font(.system(size: 10, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var promptCard: some View {
        settingsCard(title: "SYSTEM PROMPT", subtitle: "Set this bot's role, tone, and working instructions.") {
            TextEditor(text: $draft.systemPrompt)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .scrollContentBackground(.hidden)
                .padding(9)
                .frame(minHeight: 145)
                .background(.black.opacity(0.23), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.07), lineWidth: 1))

            HStack(alignment: .center) {
                Text(promptNotice)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.44))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Reset prompt") {
                    draft.systemPrompt = bot.systemInstruction
                }
                .font(.system(size: 10, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    private var promptNotice: String {
        guard promptChanged, isConnected else { return "Each bot keeps its own prompt and conversation." }
        return isWorking
            ? "The new prompt takes effect after the current turn."
            : "Saving reconnects this bot; its chat history stays here."
    }

    private var sheetFooter: some View {
        HStack {
            if canDelete {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete bot", systemImage: "trash")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.red.opacity(0.9))
            }
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button {
                draft.systemPrompt = draft.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                onSave(draft)
                dismiss()
            } label: {
                Text("Save changes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 17)
                    .frame(height: 34)
                    .background(Color.blue.opacity(0.85), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.45)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { selectedColor?.color ?? selectedType.paletteColor.color },
            set: { color in
                let botColor = BotColor(color)
                draft.colorHex = String(format: "#%02X%02X%02X", Int(botColor.r.rounded()), Int(botColor.g.rounded()), Int(botColor.b.rounded()))
            }
        )
    }

    private func avatar(size: Double, working: Bool) -> some View {
        BotAvatar(type: selectedType, face: selectedFace, state: working ? .working : .default, size: size, color: selectedColor, shading: selectedShading, interactive: false)
    }

    private func settingsCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.3)
                    .foregroundStyle(.white.opacity(0.55))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.43))
            }
            content()
        }
        .padding(15)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.06), lineWidth: 1))
    }
}

private struct AvatarColorChoice: Identifiable {
    let name: String
    let hex: String
    var id: String { hex }

    static let palette = [
        AvatarColorChoice(name: "Ocean", hex: "#35B8FF"),
        AvatarColorChoice(name: "Violet", hex: "#9A62FF"),
        AvatarColorChoice(name: "Rose", hex: "#FF7AB8"),
        AvatarColorChoice(name: "Mint", hex: "#2FCB7A"),
        AvatarColorChoice(name: "Amber", hex: "#FF8C42"),
        AvatarColorChoice(name: "Gold", hex: "#EFDB8E"),
        AvatarColorChoice(name: "Pearl", hex: "#D5DBEA")
    ]
}

private struct ChatMessageRow: View {
    let entry: TranscriptEntry
    let bot: AgentBot
    let profile: AgentBotProfile
    let working: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            if !entry.isUser {
                AgentAvatar(bot: bot, profile: profile, size: 27, working: working)
                    .padding(.bottom, 2)
            } else {
                Spacer(minLength: 50)
            }

            VStack(alignment: entry.isUser ? .trailing : .leading, spacing: 4) {
                if !entry.isUser {
                    Text(entry.role)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                        .padding(.leading, 3)
                }
                Group {
                    if entry.text.isEmpty && entry.isUser {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small).tint(.white.opacity(0.65))
                            Text(working ? "Listening…" : "Transcribing…")
                        }
                    } else if entry.text.isEmpty && working {
                        HStack(spacing: 5) {
                            ThinkingOrb(state: .breathing, size: .px20, theme: .dark)
                                .accessibilityHidden(true)
                            Text("Thinking…")
                        }
                    } else {
                        Text(entry.text)
                            .textSelection(.enabled)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(entry.isUser ? Color.blue.opacity(0.78) : Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .frame(maxWidth: 560, alignment: entry.isUser ? .trailing : .leading)

            if entry.isUser {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: entry.isUser ? .trailing : .leading)
    }
}

private struct AgentAvatar: View {
    let bot: AgentBot
    let profile: AgentBotProfile
    let size: CGFloat
    let working: Bool

    private var avatarType: BotAvatarType {
        BotAvatarType(rawValue: profile.avatarType) ?? BotAvatarType(rawValue: bot.rawValue) ?? .clover
    }

    private var avatarFace: BotAvatarFace? { BotAvatarFace(rawValue: profile.face) }
    private var avatarShading: BotAvatarShading { BotAvatarShading(rawValue: profile.shading) ?? .plastic }
    private var avatarColor: BotColor? { profile.colorHex.flatMap { BotColor($0) } }

    var body: some View {
        BotAvatar(type: avatarType, face: avatarFace, state: working ? .working : .default, size: Double(size), color: avatarColor, shading: avatarShading, interactive: false)
    }
}

private struct FileWriteApprovalSheet: View {
    let request: PendingFileWrite
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.replacesExistingFile ? "Replace this file?" : "Create this file?")
                .font(.system(size: 18, weight: .semibold))
            Text(request.relativePath)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(request.replacesExistingFile
                 ? "Gemini wants to replace the existing file."
                 : "Gemini wants to create a new file in the selected folder.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(String(request.content.prefix(8_000)))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if request.content.count > 8_000 {
                    Text("Preview truncated")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Decline", role: .cancel) { decide(false) }
                Spacer()
                Button(request.replacesExistingFile ? "Replace file" : "Create file") { decide(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480, height: 420)
        .preferredColorScheme(.dark)
    }
}

private struct TerminalCommandApprovalSheet: View {
    let request: PendingTerminalCommand
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Run this terminal command?")
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text("WORKING FOLDER")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(request.workingDirectory)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
            }
            ScrollView {
                Text(request.command)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            Text("Nothing runs until you approve. It runs with this app's permissions.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { decide(false) }
                Spacer()
                Button("Run command") { decide(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520, height: 380)
        .preferredColorScheme(.dark)
    }
}

private struct ComputerActionApprovalSheet: View {
    let request: PendingComputerAction
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow this computer action?")
                .font(.system(size: 18, weight: .semibold))
            Text("Only this action will run. The agent must ask again before its next interaction.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(request.summary)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Decline", role: .cancel) { decide(false) }
                Spacer()
                Button("Allow action") { decide(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 500, height: 320)
        .preferredColorScheme(.dark)
    }
}

private struct LiquidGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var enabled = true
    var tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            if #available(macOS 26.0, *) {
                if let tint {
                    content.glassEffect(.regular.tint(tint).interactive(), in: shape)
                } else {
                    content.glassEffect(.regular.interactive(), in: shape)
                }
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.stroke(.white.opacity(0.13), lineWidth: 1))
            }
        } else {
            content
        }
    }
}

private extension View {
    func liquidGlass<S: Shape>(in shape: S, enabled: Bool = true, tint: Color? = nil) -> some View {
        modifier(LiquidGlassSurface(shape: shape, enabled: enabled, tint: tint))
    }
}
