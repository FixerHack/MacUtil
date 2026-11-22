import AVFoundation
import CleanerCore
import Foundation
import Observation

/// Speech recognition on this Mac with Whisper, through sherpa-onnx's command-line tool (the
/// same one the downloaded voices use). macOS's own recogniser leaves out words it does not
/// know, such as Telegram or FACEIT after "відкрий"; Whisper, trained on many languages at once,
/// hears them. It runs on what macOS has already heard to the end, so it only adds a second or
/// two, and nothing leaves the Mac.
@MainActor
@Observable
final class WhisperEngine {
    static let shared = WhisperEngine()

    /// Whisper large-v3 turbo, as sherpa-onnx publishes it. GitHub gives no checksum for it, so
    /// the download is checked by its size.
    nonisolated static let model = (name: "sherpa-onnx-whisper-turbo", bytes: Int64(563_790_207))
    nonisolated static let address = "\(LocalVoices.release)/asr-models/\(model.name).tar.bz2"

    nonisolated static var folder: URL { AppPaths.support.appending(path: "Speech") }
    nonisolated static var modelFolder: URL { folder.appending(path: model.name) }
    nonisolated static var tool: URL { LocalVoices.engineFolder.appending(path: "bin/sherpa-onnx-offline") }

    /// From 0 to 1 while it downloads.
    private(set) var progress: Double?
    private(set) var problem: String?
    private(set) var isInstalled = false
    @ObservationIgnored private var download: Task<Void, Never>?

    init() {
        refresh()
    }

    func refresh() {
        isInstalled = Self.files() != nil && FileManager.default.isExecutableFile(atPath: Self.tool.path)
    }

    /// The model's three files, smaller int8 ones where there are both.
    nonisolated static func files() -> (encoder: URL, decoder: URL, tokens: URL)? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: modelFolder.path)) ?? []
        func pick(_ part: String) -> URL? {
            let int8 = names.first { $0.hasSuffix("\(part).int8.onnx") }
            let plain = names.first { $0.hasSuffix("\(part).onnx") }
            return (int8 ?? plain).map { modelFolder.appending(path: $0) }
        }
        guard let encoder = pick("encoder"), let decoder = pick("decoder"),
              let tokens = names.first(where: { $0.hasSuffix("tokens.txt") }).map({ modelFolder.appending(path: $0) })
        else { return nil }
        return (encoder, decoder, tokens)
    }

    var usedBytes: Int64 {
        let enumerator = FileManager.default.enumerator(at: Self.modelFolder, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func install() {
        guard progress == nil else { return }
        problem = nil
        progress = 0
        download = Task { [weak self] in
            defer {
                self?.progress = nil
                self?.download = nil
                self?.refresh()
            }
            do {
                if !FileManager.default.isExecutableFile(atPath: Self.tool.path) {
                    try await LocalVoices.fetchArchive(
                        "\(LocalVoices.release)/v2.0.1/\(LocalVoices.engine.name).tar.bz2",
                        digest: LocalVoices.engine.digest, bytes: nil, into: LocalVoices.folder
                    ) { _ in }
                }
                try await LocalVoices.fetchArchive(Self.address, digest: nil, bytes: Self.model.bytes, into: Self.folder) { fraction in
                    Task { @MainActor in WhisperEngine.shared.downloaded(fraction) }
                }
                // The archive holds full-size copies too; the int8 ones are used, the rest go.
                let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.modelFolder.path)) ?? []
                for name in names where (name.hasSuffix(".onnx") && !name.contains(".int8.")) || name.hasSuffix(".weights") {
                    try? FileManager.default.removeItem(at: Self.modelFolder.appending(path: name))
                }
                LocalVoices.shared.refresh()
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                self?.problem = error.localizedDescription
            }
        }
    }

    private func downloaded(_ fraction: Double) {
        guard progress != nil else { return }
        progress = fraction * 0.95
    }

    func cancel() {
        download?.cancel()
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.modelFolder)
        refresh()
    }

    // MARK: - Hearing

    /// What Whisper hears in a recording, and how long it took; nil when it could not run.
    nonisolated static func transcribe(_ wave: URL, language: String) async -> (text: String, seconds: Double)? {
        guard let files = files(), FileManager.default.isExecutableFile(atPath: tool.path) else { return nil }
        let started = Date()
        let output = await Command.run(tool.path, [
            "--whisper-encoder=\(files.encoder.path)", "--whisper-decoder=\(files.decoder.path)",
            "--tokens=\(files.tokens.path)", "--whisper-language=\(language)", "--whisper-task=transcribe",
            "--num-threads=\(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))",
            wave.path,
        ], timeout: .seconds(60))
        guard let output else { return nil }
        // The result is a JSON line with "text" among the tool's other output.
        for line in output.text.components(separatedBy: "\n") where line.hasPrefix("{") && line.contains("\"text\"") {
            if let json = JSONValue.parse(line), let text = json["text"]?.string {
                return (text.trimmingCharacters(in: .whitespacesAndNewlines), Date().timeIntervalSince(started))
            }
        }
        return nil
    }

    /// The microphone's sound as a 16 kHz mono WAV, the form Whisper takes.
    nonisolated static func writeWave(_ buffers: [AVAudioPCMBuffer], to file: URL) -> Bool {
        guard let first = buffers.first,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: first.format, to: target)
        else { return false }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        guard let output = try? AVAudioFile(forWriting: file, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        else { return false }
        let frames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        let capacity = AVAudioFrameCount(Double(frames) * 16000 / first.format.sampleRate) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return false }
        var index = 0
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            guard index < buffers.count else {
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            defer { index += 1 }
            return buffers[index]
        }
        guard error == nil, converted.frameLength > 0 else { return false }
        return (try? output.write(from: converted)) != nil
    }
}

/// Recordings of what the person said, with what each recogniser heard, kept on this Mac when
/// the person turns it on, to find out why a word was missed.
enum SpeechRecordings {
    static var folder: URL { AppPaths.support.appending(path: "Recordings") }
    static let keep = 100

    /// Keeps a recording and a note of what was heard, dropping the oldest past `keep`.
    static func keep(_ wave: URL, apple: String, whisper: String?) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        try? fileManager.copyItem(at: wave, to: folder.appending(path: "\(stamp).wav"))
        let note = "Apple: \(apple)\nWhisper: \(whisper ?? "(not run)")\n"
        try? Data(note.utf8).write(to: folder.appending(path: "\(stamp).txt"))
        let all = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".wav") }.sorted()
        for old in all.dropLast(keep) {
            try? fileManager.removeItem(at: folder.appending(path: old))
            try? fileManager.removeItem(at: folder.appending(path: old.replacingOccurrences(of: ".wav", with: ".txt")))
        }
    }
}
