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
    /// Listening ended on an error before anything was heard: what macOS said.
    var onFailure: ((String) -> Void)?

    static let log = AppPaths.file("assistant-speech.log")

    /// What happened, for finding out later why listening stopped.
    static func note(_ text: String) {
        let line = "\(Date().formatted(date: .numeric, time: .standard)) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: log) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: log)
        }
    }

    private var language = "uk"
    private var allowServer = false
    private var startedAt = Date()
    private var usedServer = false
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

    func start(language: String, allowServer: Bool, server: Bool = false) throws {
        self.language = language
        self.allowServer = allowServer
        usedServer = server
        startedAt = Date()
        guard Self.isAuthorised else {
            Self.note("not authorised: speech \(SFSpeechRecognizer.authorizationStatus().rawValue), microphone \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
            throw Problem.notAllowed
        }
        guard let recogniser = SFSpeechRecognizer(locale: Self.locale(language)), recogniser.isAvailable else {
            throw Problem.unavailable
        }
        let onDevice = recogniser.supportsOnDeviceRecognition && !server
        guard onDevice || allowServer else { throw Problem.needsServer }
        Self.note("start \(language), on this Mac: \(onDevice)")
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
            let problem = error.map { ($0 as NSError).domain + " \(($0 as NSError).code): " + $0.localizedDescription }
            Task { @MainActor in self?.heard(text, final: final, problem: problem) }
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

    private func heard(_ text: String?, final: Bool, problem: String? = nil) {
        if let text { latest = text }
        if final {
            let said = latest
            stop()
            if let problem, said.isEmpty {
                Self.note("ended: \(problem)")
                // On this Mac it failed straight away: Apple's servers, if allowed, try instead;
                // not when Dictation is off, which stops both.
                if !usedServer, allowServer, Date().timeIntervalSince(startedAt) < 3, !problem.contains("kLSRErrorDomain 201") {
                    Self.note("trying Apple's servers")
                    if (try? start(language: language, allowServer: true, server: true)) != nil { return }
                }
                // Cancelled by us, or nothing said: not worth a message.
                if !problem.contains(" 216:"), !problem.contains(" 301:"), !problem.contains(" 1110:") {
                    onFailure?(problem)
                }
            }
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
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    /// Downloaded voices play through a pitch shifter, which raises the voice without
    /// hurrying it.
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let shifter = AVAudioUnitTimePitch()
    private var playing = false
    private var making: Task<Void, Never>?
    var onFinished: (() -> Void)?
    /// Semitones up (or down) from the voice's own.
    var pitch: Double = 0

    override init() {
        super.init()
        synthesizer.delegate = self
        engine.attach(node)
        engine.attach(shifter)
    }

    var isSpeaking: Bool { synthesizer.isSpeaking || playing || making != nil }

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
            if let file, self.play(file) {
                try? FileManager.default.removeItem(at: file)
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
        utterance.pitchMultiplier = Float(max(0.5, min(2, pow(2, pitch / 12))))
        synthesizer.speak(utterance)
    }

    /// Plays a WAV through the pitch shifter.
    private func play(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil
        else { return false }
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(shifter)
        engine.connect(node, to: shifter, format: buffer.format)
        engine.connect(shifter, to: engine.mainMixerNode, format: buffer.format)
        shifter.pitch = Float(pitch * 100)
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            return false
        }
        playing = true
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playing else { return }
                self.playing = false
                self.onFinished?()
            }
        }
        node.play()
        return true
    }

    func stop() {
        making?.cancel()
        making = nil
        playing = false
        node.stop()
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinished?() }
    }

}
