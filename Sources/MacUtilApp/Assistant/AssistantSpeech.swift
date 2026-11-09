import AVFoundation
import CleanerCore
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
    /// How loud the microphone is, 0…1, about twenty times a second, for the animation.
    var onLevel: ((Double) -> Void)?
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
        let report: @Sendable (Double) -> Void = { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            feed.append(buffer)
            // Loudness for the animation: the buffer's RMS, on a scale that suits speech.
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0 ..< Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            let decibels = 20 * log10(max(rms, 0.000_01))
            report(Double(max(0, min(1, (decibels + 55) / 45))))
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

/// Who speaks the answers.
enum VoiceEngine: String, CaseIterable, Identifiable {
    /// macOS's own voices.
    case system
    /// A Piper voice downloaded to this Mac (see `LocalVoices`).
    case local
    var id: String { rawValue }
}

/// Speaks the answers in a macOS voice or a downloaded one, falling back to macOS's when
/// the downloaded one cannot speak.
@MainActor
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var making: Task<Void, Never>?
    var onFinished: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking || player?.isPlaying == true || making != nil }

    static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    func speak(_ text: String, language: String, engine: VoiceEngine, voiceID: String?, rate: Float) {
        stop()
        guard engine == .local, let voiceID, let voice = LocalVoices.shared.voice(withID: voiceID),
              LocalVoices.shared.isInstalled(voice)
        else {
            speakWithSystem(text, language: language, voiceID: engine == .system ? voiceID : nil, rate: rate)
            return
        }
        making = Task { [weak self] in
            let file = await LocalVoices.shared.synthesize(text, voice: voice, rate: Double(rate), language: language)
            guard let self, !Task.isCancelled else { return }
            self.making = nil
            if let file, let player = try? AVAudioPlayer(contentsOf: file) {
                try? FileManager.default.removeItem(at: file)
                player.delegate = self
                self.player = player
                player.play()
            } else {
                self.speakWithSystem(text, language: language, voiceID: nil, rate: rate)
            }
        }
    }

    private func speakWithSystem(_ text: String, language: String, voiceID: String?, rate: Float) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? Self.voices(for: language).first
            ?? AVSpeechSynthesisVoice(language: SpeechInput.locale(language).identifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * rate
        synthesizer.speak(utterance)
    }

    func stop() {
        making?.cancel()
        making = nil
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinished?() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinished?() }
    }
}
