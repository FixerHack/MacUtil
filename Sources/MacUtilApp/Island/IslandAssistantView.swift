import AppKit
import SwiftUI

/// The assistant in the opened island: the conversation, what is being heard, a question
/// waiting for "yes", and a field to type into.
struct AssistantPage: View {
    @Bindable var assistant: AssistantModel
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if assistant.phase == .listening || assistant.phase == .thinking || assistant.phase == .speaking {
                HStack(spacing: 12) {
                    VoiceWave(level: assistant.level, phase: assistant.phase)
                        .frame(width: 120, height: 34)
                    Text(statusText)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .contentTransition(.opacity)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            conversation
            if case let .confirming(question) = assistant.phase {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                    Text(verbatim: question).font(.callout).lineLimit(2)
                    Spacer(minLength: 8)
                    Button("No") { assistant.answer(false) }
                        .buttonStyle(.bordered)
                    Button("Yes") { assistant.answer(true) }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
                .controlSize(.small)
                .padding(8)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 10))
            }
            inputBar
        }
        .onChange(of: assistant.focusRequest) { focus() }
    }

    private var examples: [String] {
        assistant.language == "uk"
            ? ["Що ти вмієш?", "Скільки вільного місця на диску?", "Відкрий ютуб", "Увімкни ігровий профіль доку",
               "Нагадай через 20 хвилин випити води", "Запам'ятай, що машина на третьому рівні", "Зроби гучність на 30"]
            : ["What can you do?", "How much disk space is free?", "Open YouTube", "Switch the Dock to Games",
               "Remind me in 20 minutes to drink water", "Remember the car is on level 3", "Set the volume to 30"]
    }

    private var statusText: LocalizedStringKey {
        switch assistant.phase {
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        default: "Speaking"
        }
    }

    private var conversation: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if assistant.lines.isEmpty, assistant.hearing.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Press \(assistant.hotKeyLabel) and talk, or type. For example:")
                            ForEach(examples, id: \.self) { example in
                                Text(verbatim: "· " + example)
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.55))
                    }
                    ForEach(assistant.lines.suffix(12)) { line in
                        LineView(line: line)
                    }
                    if !assistant.hearing.isEmpty {
                        Text(verbatim: assistant.hearing)
                            .font(.callout.italic())
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .onChange(of: assistant.lines.count) { reader.scrollTo("end", anchor: .bottom) }
            .onChange(of: assistant.hearing) { reader.scrollTo("end", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask UniMacHub…", text: $assistant.draft)
                .textFieldStyle(.plain)
                .focused($typing)
                .onSubmit { assistant.sendDraft() }
                .onExitCommand { assistant.stop() }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.1), in: .capsule)
                .onTapGesture { focus() }
            status
            Button {
                assistant.activate()
            } label: {
                Image(systemName: assistant.phase == .listening ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(assistant.phase == .listening ? Color.red : .white)
                    .symbolEffect(.variableColor.iterative, isActive: assistant.phase == .listening)
            }
            .buttonStyle(.plain)
            .help(Text(assistant.phase == .listening ? "Done talking" : "Talk"))
            if !assistant.lines.isEmpty, !assistant.isBusy {
                Button {
                    assistant.clearConversation()
                } label: {
                    Image(systemName: "plus.bubble").font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.6))
                .help(Text("New conversation: what it remembers stays"))
            }
            if assistant.isBusy {
                Button {
                    assistant.stop()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .help(Text("Stop"))
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch assistant.phase {
        case .thinking: ProgressView().controlSize(.small).tint(.white)
        case .speaking: Image(systemName: "speaker.wave.2.fill").foregroundStyle(.white.opacity(0.7))
        default: EmptyView()
        }
    }

    /// Typing needs the island's window to take the keyboard, which it otherwise never does.
    private func focus() {
        NSApp.windows.first { $0.contentView is IslandHostingView }?.makeKey()
        typing = true
    }
}

private struct LineView: View {
    let line: AssistantModel.Line

    var body: some View {
        switch line.kind {
        case .person:
            Text(verbatim: line.text)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.35), in: .rect(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            Text(verbatim: line.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .action:
            Text(verbatim: line.text)
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.5))
        case .problem:
            Label { Text(verbatim: line.text) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

/// Bars that move with the voice while listening, ripple while thinking, and sway while speaking.
private struct VoiceWave: View {
    let level: Double
    let phase: AssistantModel.Phase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0 ..< 11, id: \.self) { index in
                    let position = Double(index) / 10
                    // Taller in the middle, as a voice's shape is.
                    let envelope = 0.35 + 0.65 * sin(position * .pi)
                    let height: Double = switch phase {
                    case .listening: 0.12 + envelope * level * (0.7 + 0.3 * sin(time * 9 + Double(index)))
                    case .thinking: 0.15 + 0.25 * (0.5 + 0.5 * sin(time * 4 - Double(index) * 0.6))
                    default: 0.15 + envelope * 0.55 * (0.5 + 0.5 * sin(time * 7 + Double(index) * 1.3))
                    }
                    Capsule()
                        .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.35, blue: 1), Color(red: 0.25, green: 0.9, blue: 0.9)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 5, height: max(4, 34 * height))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

