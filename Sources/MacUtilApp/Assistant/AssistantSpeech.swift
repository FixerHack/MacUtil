import AVFoundation
import CleanerCore
import Speech

/// A copy of the microphone's sound, handed once from the audio thread to the main one.
private struct SoundChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

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
    /// What happened while listening, for the assistant's step-by-step log: pauses in the
    /// person's speech, how listening ended, macOS starting its transcript afresh.
    var onEvent: ((String) -> Void)?

    static let log = AppPaths.file("assistant-speech.log")

    /// What happened, for finding out later why listening stopped.
    static func note(_ text: String) {
        let line = "\(Date().formatted(date: .numeric, time: .standard)) \(text.replacingOccurrences(of: "\n", with: " "))\n"
        if let handle = try? FileHandle(forWritingTo: log) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: log)
        }
    }

    private var language = "uk"
    /// What was heard before macOS started its transcript over after a pause.
    private var committed = ""
    private var hints: [String] = []
    private var allowServer = false
    private var startedAt = Date()
    private var usedServer = false
    private(set) var isListening = false

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?
    private var latest = ""
    /// Counts each listening, so a late answer from an earlier one is ignored.
    private var generation = 0
    /// The sound heard so far, to give Apple's servers when this Mac made out nothing.
    private var recorded: [AVAudioPCMBuffer] = []
    private var recordedFrames: AVAudioFramePosition = 0
    /// The loudest the microphone got, 0…1: above about 0.45 someone spoke.
    private var peak: Double = 0
    /// Above this the microphone hears a voice rather than the room.
    private static let voiceLevel = 0.45
    /// When the voice was last heard, and since when it has been quiet.
    private var lastVoice: Date?
    private var quietSince: Date?
    private var pauses: [Double] = []
    /// When macOS last sent words, new or revised.
    private var lastWords = Date()
    private var listenStarted = Date()
    private var format: AVAudioFormat?

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

    func start(language: String, allowServer: Bool, server: Bool = false, hints: [String] = []) throws {
        self.hints = hints
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
        request.contextualStrings = hints
        request.addsPunctuation = true
        self.request = request
        latest = ""
        committed = ""

        recorded = []
        recordedFrames = 0
        peak = 0
        lastVoice = nil
        quietSince = nil
        pauses = []
        listenStarted = Date()
        generation += 1
        let current = generation

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw Problem.noMicrophone }
        self.format = format
        nonisolated(unsafe) let feed = request
        let report: @Sendable (Double, SoundChunk?) -> Void = { [weak self] level, chunk in
            Task { @MainActor in self?.measured(level, chunk?.buffer, generation: current) }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            feed.append(buffer)
            let copy = Self.copy(buffer).map(SoundChunk.init)
            // Loudness for the animation: the buffer's RMS, on a scale that suits speech.
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0 ..< Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            let decibels = 20 * log10(max(rms, 0.000_01))
            report(Double(max(0, min(1, (decibels + 55) / 45))), copy)
        }
        engine.prepare()
        try engine.start()
        isListening = true

        task = recogniser.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? (error != nil)
            let problem = error.map { ($0 as NSError).domain + " \(($0 as NSError).code): " + $0.localizedDescription }
            Task { @MainActor in
                guard self?.generation == current else { return }
                self?.heard(text, final: final, problem: problem)
            }
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
        generation += 1
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

    /// The level for the animation, and the sound kept for a second try.
    private func measured(_ level: Double, _ buffer: AVAudioPCMBuffer?, generation current: Int) {
        guard current == generation, isListening else { return }
        peak = max(peak, level)
        // Pauses within what the person says, a second or longer: logged with where they fell,
        // to see which pauses end a request too soon.
        let now = Date()
        if level > Self.voiceLevel {
            if let quietSince, lastVoice != nil {
                let gap = now.timeIntervalSince(quietSince)
                if gap >= 1 {
                    pauses.append(gap)
                    onEvent?(String(format: "pause %.1f s, then went on; heard so far: \"%@\"", gap, String(latest.suffix(80))))
                }
            }
            lastVoice = now
            quietSince = nil
        } else if lastVoice != nil, quietSince == nil {
            quietSince = now
        }
        // The voice has stopped: the turn ends without waiting for macOS, which keeps revising
        // its words for seconds after. Pauses inside a sentence run up to about a second and a
        // half, so two seconds of quiet, more for a long request.
        if let quietSince, !latest.trimmingCharacters(in: .whitespaces).isEmpty,
           now.timeIntervalSince(lastWords) > 0.5 {
            let enough = latest.count > 60 ? 2.5 : 2.0
            let quiet = now.timeIntervalSince(quietSince)
            if quiet >= enough {
                onEvent?(String(format: "listening ended by the voice stopping: quiet for %.1f s; spoke for %.1f s with %d pauses over a second%@",
                                quiet, now.timeIntervalSince(listenStarted), pauses.count,
                                pauses.isEmpty ? "" : " (" + pauses.map { String(format: "%.1f", $0) }.joined(separator: ", ") + " s)"))
                finish()
            }
        }
        onLevel?(level)
        // Up to half a minute of sound.
        if let buffer, recordedFrames < AVAudioFramePosition((format?.sampleRate ?? 48000) * 30) {
            recorded.append(buffer)
            recordedFrames += AVAudioFramePosition(buffer.frameLength)
        }
    }

    nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        if let from = buffer.floatChannelData, let to = copy.floatChannelData {
            for channel in 0 ..< channels {
                to[channel].update(from: from[channel], count: Int(buffer.frameLength))
            }
            return copy
        }
        return nil
    }

    /// This Mac heard someone speak but made out no words, as with a name it does not know
    /// ("Телеграм"): the same sound goes to Apple's servers once, when that is allowed.
    private func retryOnServer() -> Bool {
        guard allowServer, !usedServer, !recorded.isEmpty, peak > 0.35,
              let recogniser = SFSpeechRecognizer(locale: Self.locale(language)), recogniser.isAvailable
        else { return false }
        Self.note("heard sound (peak \(String(format: "%.2f", peak))) but no words on this Mac: Apple's servers try the same sound")
        usedServer = true
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = false
        request.contextualStrings = hints
        request.addsPunctuation = true
        request.shouldReportPartialResults = false
        for buffer in recorded { request.append(buffer) }
        request.endAudio()
        recorded = []
        generation += 1
        let current = generation
        let started = Date()
        task = recogniser.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString ?? ""
            let final = result?.isFinal ?? (error != nil)
            guard final else { return }
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                Self.note("servers heard: \"\(text)\" in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                self.task = nil
                self.onText?(text.trimmingCharacters(in: .whitespaces), true)
            }
        }
        return true
    }

    private func heard(_ text: String?, final: Bool, problem: String? = nil) {
        if let text {
            lastWords = Date()
            // macOS revises its transcript as it goes and, after a pause, may start it afresh
            // with only the new words: a revision replaces, a fresh start is kept after.
            let before = committed
            (committed, latest) = Transcript.merge(committed: committed, latest: latest, incoming: text)
            if committed != before {
                onEvent?("macOS started its transcript afresh; kept before it: \"\(committed.suffix(80))\"")
            }
        }
        if final {
            let said = Transcript.collapseRepeats(latest.trimmingCharacters(in: .whitespaces))
            stop()
            Self.note("heard \(usedServer ? "via Apple's servers" : "on this Mac"): \"\(said)\" (loudest \(String(format: "%.2f", peak)))\(problem.map { " (\($0))" } ?? "")")
            if said.isEmpty, retryOnServer() { return }
            if let problem, said.isEmpty {
                Self.note("ended: \(problem)")
                // On this Mac it failed straight away: Apple's servers, if allowed, try instead;
                // not when Dictation is off, which stops both.
                // Only when no voice was heard yet: a voice heard went to the servers above.
                if !usedServer, allowServer, peak < 0.35, Date().timeIntervalSince(startedAt) < 3, !problem.contains("kLSRErrorDomain 201") {
                    Self.note("trying Apple's servers")
                    if (try? start(language: language, allowServer: true, server: true, hints: hints)) != nil { return }
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
            // Six seconds for a first word; then a pause of over two seconds ends the turn,
            // so a breath in the middle of a sentence does not.
            let heard = self?.latest.count ?? 0
            let wait = heard == 0 ? 6 : heard > 60 ? 3 : 2.3
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            let quiet = self.lastVoice.map { Date().timeIntervalSince($0) }
            self.onEvent?(String(format: "listening ended by silence: no new words for %.1f s%@; spoke for %.1f s with %d pauses over a second%@",
                                 wait, quiet.map { String(format: ", voice last heard %.1f s ago", $0) } ?? ", no voice heard",
                                 Date().timeIntervalSince(self.listenStarted), self.pauses.count,
                                 self.pauses.isEmpty ? "" : " (" + self.pauses.map { String(format: "%.1f", $0) }.joined(separator: ", ") + " s)"))
            self.finish()
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
