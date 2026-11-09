import AppKit
import SwiftUI

/// The assistant in the opened island: the conversation, what is being heard, a question
/// waiting for "yes", and a field to type into.
struct AssistantPage: View {
    @Bindable var assistant: AssistantModel
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

    private var conversation: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if assistant.lines.isEmpty, assistant.hearing.isEmpty {
                        Text("Ask by voice or by typing. \(AssistantModel.hotKeyLabel) opens this from anywhere.")
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
