import AVFoundation
import Speech

/// Hears the person: the microphone through macOS's speech recognition, on this Mac when it
/// can do the language itself, through Apple's servers only when that is allowed.
@MainActor
final class SpeechInput {
    enum Problem: Error {
        case notAllowed, noMicrophone, unavailable, needsServer
    }

    /// Partial text as it is heard, then the final text once the person stops.
    var onText: ((String, _ final: Bool) -> Void)?
    private(set) var isListening = false

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?
    private var latest = ""

    static func authorise() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        return speech && microphone
    }

    static var isAuthorised: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Whether this Mac recognises the language by itself, without Apple's servers.
    static func worksOnDevice(_ language: String) -> Bool {
        SFSpeechRecognizer(locale: locale(language))?.supportsOnDeviceRecognition ?? false
    }

    static func locale(_ language: String) -> Locale {
        Locale(identifier: language == "uk" ? "uk-UA" : "en-US")
    }

    func start(language: String, allowServer: Bool) throws {
        guard Self.isAuthorised else { throw Problem.notAllowed }
        guard let recogniser = SFSpeechRecognizer(locale: Self.locale(language)), recogniser.isAvailable else {
            throw Problem.unavailable
        }
        let onDevice = recogniser.supportsOnDeviceRecognition
        guard onDevice || allowServer else { throw Problem.needsServer }
        stop()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        self.request = request
        latest = ""

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw Problem.noMicrophone }
        nonisolated(unsafe) let feed = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            feed.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isListening = true

        task = recogniser.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? (error != nil)
            Task { @MainActor in self?.heard(text, final: final) }
        }
        waitForSilence()
    }

    /// Ends listening; the final text follows through `onText`.
    func finish() {
        guard isListening else { return }
        silence?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isListening = false
    }

    /// Stops without waiting for what was said.
    func stop() {
        silence?.cancel()
        task?.cancel()
        task = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request = nil
        isListening = false
    }

    private func heard(_ text: String?, final: Bool) {
        if let text { latest = text }
        if final {
            let said = latest
            stop()
            onText?(said, true)
        } else {
            onText?(latest, false)
            waitForSilence()
        }
    }

    /// A pause of a second and a half after speech ends the turn.
    private func waitForSilence() {
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.latest.isEmpty == true ? 6 : 1.5))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }
}

/// Speaks the answers in a system voice.
@MainActor
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var onFinished: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    func speak(_ text: String, language: String, voiceID: String?, rate: Float) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? Self.voices(for: language).first
            ?? AVSpeechSynthesisVoice(language: SpeechInput.locale(language).identifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * rate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinished?() }
    }
}
