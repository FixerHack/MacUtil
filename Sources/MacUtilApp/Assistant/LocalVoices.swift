import AVFoundation
import CleanerCore
import CryptoKit
import Foundation
import Observation

/// Which model a voice runs on, all through sherpa-onnx's command-line tool.
enum VoiceModel: String {
    /// Piper's VITS voices: small, one voice per package.
    case piper
    /// Supertone's Supertonic 3: ten voices, Ukrainian and English among 31 languages.
    case supertonic
    /// Kokoro: natural English voices, many in one package.
    case kokoro
}

/// One download of voices: a package in sherpa-onnx's `tts-models` release.
struct VoicePackage: Equatable {
    /// Its name, without `.tar.bz2`; also the folder it unpacks into.
    let package: String
    let digest: String
    let bytes: Int64
}

/// One voice that can be downloaded and run on this Mac: a light version and, for some,
/// a full one that sounds better and takes more room and memory.
struct LocalVoice: Identifiable, Equatable {
    enum Gender { case female, male }

    let id: String
    let name: String
    let gender: Gender
    /// "uk" and/or "en".
    let languages: Set<String>
    let model: VoiceModel
    let detail: String
    let light: VoicePackage
    let full: VoicePackage?
    /// Which of the package's speakers.
    var speaker = 0
    /// A sample to hear before downloading, where the project publishes one.
    var sample: URL?

    var packages: [VoicePackage] { [light] + (full.map { [$0] } ?? []) }
}

/// Voices that speak on this Mac, without any account or key, run by sherpa-onnx's
/// command-line tool. The tool and the voices are downloaded only when the person asks for
/// a voice, from the projects' own GitHub releases, checked against the checksums GitHub
/// publishes for them, and deleted again on request; the tool goes with the last voice.
@MainActor
@Observable
final class LocalVoices {
    static let shared = LocalVoices()

    static let release = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
    #if arch(arm64)
        static let engine = (name: "sherpa-onnx-v2.0.1-osx-arm64-shared", digest: "5e874d3c9b3d6b8c71f7c09e3a9fb9ae846c3009129d302b398d1f7aedb69f84", bytes: Int64(20_348_241))
    #else
        static let engine = (name: "sherpa-onnx-v2.0.1-osx-x64-shared", digest: "100315fbb174de2d7fec92b67d28c4128499daf3a6f47b4da6350252680d178f", bytes: Int64(22_897_549))
    #endif

    // MARK: - The catalogue

    private nonisolated static func piperSample(_ path: String, speaker: Int = 0) -> URL? {
        URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/main/\(path)/samples/speaker_\(speaker).mp3")
    }

    static let catalogue: [LocalVoice] = supertonic + kokoro + piper

    /// Supertonic 3: one package, ten voices that speak both Ukrainian and English.
    static let supertonic: [LocalVoice] = {
        let package = VoicePackage(
            package: "sherpa-onnx-supertonic-3-tts-int8-2026-05-11",
            digest: "82fa96f91c4ef8abaae3a14a3f4153facf88bed821d1f7331cec2700f432c427", bytes: 128_774_318
        )
        // voice.bin holds the styles in name order: F1…F5, then M1…M5.
        return (1 ... 5).map { number in
            LocalVoice(id: "supertonic-F\(number)", name: "Supertonic F\(number)", gender: .female, languages: ["uk", "en"],
                       model: .supertonic, detail: "Supertonic 3", light: package, full: nil, speaker: number - 1)
        } + (1 ... 5).map { number in
            LocalVoice(id: "supertonic-M\(number)", name: "Supertonic M\(number)", gender: .male, languages: ["uk", "en"],
                       model: .supertonic, detail: "Supertonic 3", light: package, full: nil, speaker: number + 4)
        }
    }()

    /// Kokoro 1.0: its English voices, in the order of its voices.bin.
    static let kokoro: [LocalVoice] = {
        let light = VoicePackage(package: "kokoro-int8-multi-lang-v1_0", digest: "72c347230107ef8a31098ec4d468a605244beef5f1ed00db97efa13518800653", bytes: 132_353_410)
        let full = VoicePackage(package: "kokoro-multi-lang-v1_0", digest: "60703707bc05ccd48d60e1eb723f38b07d6e474795a0b6a588d7220400e0f7a4", bytes: 349_886_476)
        let names = [
            "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river",
            "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx",
            "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable",
            "bm_george", "bm_lewis",
        ]
        return names.enumerated().map { index, code in
            let parts = code.split(separator: "_")
            let accent = parts[0].hasPrefix("a") ? "US" : "GB"
            return LocalVoice(
                id: "kokoro-\(code)", name: parts[1].capitalized, gender: parts[0].hasSuffix("f") ? .female : .male,
                languages: ["en"], model: .kokoro, detail: "Kokoro · \(accent)", light: light, full: full, speaker: index
            )
        }
    }()

    static let piper: [LocalVoice] = {
        let ukrainianLight = VoicePackage(package: "vits-piper-uk_UA-ukrainian_tts-medium-int8", digest: "9e3e20f311e3c486d989c3d481d9537741deb7beaeed1aa63c737574498b1e75", bytes: 22_767_075)
        let ukrainianFull = VoicePackage(package: "vits-piper-uk_UA-ukrainian_tts-medium", digest: "92be6ff21ebb1cbcc0c71121a6437db8d060cee5785287aaa6a19a2548f59c03", bytes: 80_355_083)
        func voice(_ id: String, _ name: String, _ gender: LocalVoice.Gender, _ language: String, _ detail: String,
                   _ light: (String, String, Int64), _ full: (String, String, Int64)?, sample: String) -> LocalVoice {
            LocalVoice(
                id: id, name: name, gender: gender, languages: [language], model: .piper, detail: "Piper · " + detail,
                light: VoicePackage(package: light.0, digest: light.1, bytes: light.2),
                full: full.map { VoicePackage(package: $0.0, digest: $0.1, bytes: $0.2) },
                sample: piperSample(sample)
            )
        }
        return [
            voice("uk-lada", "Лада", .female, "uk", "x_low",
                  ("vits-piper-uk_UA-lada-x_low-int8", "5ba331ec01c811d605951c30ad7f9f57dfe87aaaefb9295c83012867db14a91a", 13_332_976),
                  ("vits-piper-uk_UA-lada-x_low", "7a2228f249299d19016cd6ca170bf6916f8664231bcbd9e61f447b861a039cf5", 26_520_908),
                  sample: "uk/uk_UA/lada/x_low"),
            LocalVoice(id: "uk-tts-0", name: "Ukrainian TTS 1", gender: .female, languages: ["uk"], model: .piper, detail: "Piper · medium",
                       light: ukrainianLight, full: ukrainianFull, speaker: 0, sample: piperSample("uk/uk_UA/ukrainian_tts/medium", speaker: 0)),
            LocalVoice(id: "uk-tts-1", name: "Ukrainian TTS 2", gender: .male, languages: ["uk"], model: .piper, detail: "Piper · medium",
                       light: ukrainianLight, full: ukrainianFull, speaker: 1, sample: piperSample("uk/uk_UA/ukrainian_tts/medium", speaker: 1)),
            LocalVoice(id: "uk-tts-2", name: "Ukrainian TTS 3", gender: .female, languages: ["uk"], model: .piper, detail: "Piper · medium",
                       light: ukrainianLight, full: ukrainianFull, speaker: 2, sample: piperSample("uk/uk_UA/ukrainian_tts/medium", speaker: 2)),
            voice("en-amy", "Amy", .female, "en", "US",
                  ("vits-piper-en_US-amy-medium-int8", "bd23c0aa629eb3719448582f45ede49e8fa6a679061fed5eab16a6a6fd8e7e82", 21_028_122),
                  ("vits-piper-en_US-amy-medium", "9a5d1fc497f85e8022b785bff5f8105203b1e33099ee6265203efc70b0cb0264", 67_223_746),
                  sample: "en/en_US/amy/medium"),
            voice("en-lessac", "Lessac", .female, "en", "US",
                  ("vits-piper-en_US-lessac-medium-int8", "f1c6d0295cf16087b05f80fdca5b44daca5cd78e2c425d419a42ba34929805f9", 20_969_179),
                  ("vits-piper-en_US-lessac-high", "8619d204c7005866fe4f420181dfa79622af6a6222389f0b0818d2af31e0db0e", 115_545_841),
                  sample: "en/en_US/lessac/medium"),
            voice("en-ryan", "Ryan", .male, "en", "US",
                  ("vits-piper-en_US-ryan-medium-int8", "376eb489d42e98cb49f0e13a633e8d88580bd247ed8aacc298a733210404f771", 21_083_446),
                  ("vits-piper-en_US-ryan-high", "6a71edf4d308b9cb2eaeadc8d1f3c6bf96120ecb7fe52c29a2b6e139c59760ed", 115_630_708),
                  sample: "en/en_US/ryan/medium"),
            voice("en-joe", "Joe", .male, "en", "US",
                  ("vits-piper-en_US-joe-medium-int8", "644527f29eca0ada5595d7b6e4daf6388f5ac0c4870b4d42996a6687fcefeb37", 21_230_019),
                  ("vits-piper-en_US-joe-medium", "261b903a1fb2ce621e2b5b14233cd41223c3b9f9590f896c11daee4df22d9bd3", 67_169_394),
                  sample: "en/en_US/joe/medium"),
            voice("en-alba", "Alba", .female, "en", "GB",
                  ("vits-piper-en_GB-alba-medium-int8", "f7581d123ae977f64f3032bb247d4deeac8440e881d918d36fdd36d8f1030fb7", 21_104_326),
                  ("vits-piper-en_GB-alba-medium", "fcd45962906933eec4431d3688f7d74aaac8713c87c6717f91fd3b23463aa1a1", 67_212_349),
                  sample: "en/en_GB/alba/medium"),
            voice("en-northern", "Northern English", .male, "en", "GB",
                  ("vits-piper-en_GB-northern_english_male-medium-int8", "9b2afdc8f35426f6b2739f255e67841679a52b56d19ece874a1eae208cb88ad1", 21_100_291),
                  ("vits-piper-en_GB-northern_english_male-medium", "2bb2c1e709f58c11f17c693b3b38f500e110e7f54f2651774ec48b8d41f12c55", 67_210_490),
                  sample: "en/en_GB/northern_english_male/medium"),
        ]
    }()

    static func voices(for language: String) -> [LocalVoice] {
        catalogue.filter { $0.languages.contains(language) }
    }

    // MARK: - State

    /// Packages on disk.
    private(set) var installed: Set<String> = []
    /// Downloads in progress, 0…1, by package.
    private(set) var progress: [String: Double] = [:]
    private(set) var problem: String?
    private(set) var isPlaying = false
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var samplePlayer: AVPlayer?
    @ObservationIgnored private var previewPlayer: AVAudioPlayer?

    static var folder: URL { AppPaths.support.appending(path: "Voices") }
    static var engineFolder: URL { folder.appending(path: engine.name) }
    static var tool: URL { engineFolder.appending(path: "bin/sherpa-onnx-offline-tts") }

    init() {
        refresh()
    }

    func refresh() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.folder.path)) ?? []
        installed = Set(names.filter { $0 != Self.engine.name && !$0.hasPrefix(".") })
    }

    /// The package of the voice on disk, the full one when both are.
    func installedPackage(_ voice: LocalVoice) -> VoicePackage? {
        voice.packages.reversed().first { installed.contains($0.package) }
    }

    func isInstalled(_ voice: LocalVoice) -> Bool { installedPackage(voice) != nil }

    func isFull(_ voice: LocalVoice) -> Bool { voice.full != nil && installedPackage(voice) == voice.full }

    func progress(of voice: LocalVoice) -> Double? {
        voice.packages.lazy.compactMap { self.progress[$0.package] }.first
    }

    // MARK: - Listening

    /// The voice saying a line: itself when downloaded, else the project's sample.
    func listen(_ voice: LocalVoice, language: String, rate: Double) {
        stopPlaying()
        if isInstalled(voice) {
            isPlaying = true
            Task {
                let line = language == "uk" ? "Привіт! Я асистент UniMacHub. Так звучить цей голос." : "Hi! I'm UniMacHub's assistant. This is how this voice sounds."
                guard let file = await synthesize(line, voice: voice, rate: rate, language: language),
                      let player = try? AVAudioPlayer(contentsOf: file)
                else {
                    isPlaying = false
                    return
                }
                try? FileManager.default.removeItem(at: file)
                previewPlayer = player
                player.play()
                try? await Task.sleep(for: .seconds(player.duration + 0.2))
                if previewPlayer === player { isPlaying = false }
            }
        } else if let sample = voice.sample {
            samplePlayer = AVPlayer(url: sample)
            samplePlayer?.play()
            isPlaying = true
            Task {
                try? await Task.sleep(for: .seconds(12))
                isPlaying = false
            }
        }
    }

    func canListen(_ voice: LocalVoice) -> Bool { isInstalled(voice) || voice.sample != nil }

    func stopPlaying() {
        samplePlayer?.pause()
        samplePlayer = nil
        previewPlayer?.stop()
        previewPlayer = nil
        isPlaying = false
    }

    // MARK: - Downloading and deleting

    /// Downloads the light version, or the full one, which then replaces the light.
    func download(_ voice: LocalVoice, full: Bool = false) {
        guard let package = full ? voice.full : voice.light, progress(of: voice) == nil else { return }
        problem = nil
        progress[package.package] = 0
        downloads[package.package] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.progress[package.package] = nil
                self.downloads[package.package] = nil
                self.refresh()
            }
            do {
                try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                if !FileManager.default.isExecutableFile(atPath: Self.tool.path) {
                    try await self.fetch(
                        "\(Self.release)/v2.0.1/\(Self.engine.name).tar.bz2", digest: Self.engine.digest,
                        share: 0.15, for: package.package
                    )
                }
                try await self.fetch(
                    "\(Self.release)/tts-models/\(package.package).tar.bz2", digest: package.digest,
                    share: 1, for: package.package
                )
                if full { try? FileManager.default.removeItem(at: Self.folder.appending(path: voice.light.package)) }
            } catch is CancellationError {
                self.problem = nil
            } catch let error as URLError where error.code == .cancelled {
                self.problem = nil
            } catch {
                self.problem = error.localizedDescription
            }
        }
    }

    /// Stops a download of the voice.
    func cancelDownload(_ voice: LocalVoice) {
        for package in voice.packages { downloads[package.package]?.cancel() }
    }

    enum Failure: LocalizedError {
        case checksum, unpack
        var errorDescription: String? {
            switch self {
            case .checksum: String(localized: "The download did not match its published checksum, so it was thrown away.")
            case .unpack: String(localized: "The download could not be unpacked.")
            }
        }
    }

    /// Downloads, checks and unpacks one archive into the voices folder.
    private func fetch(_ address: String, digest: String, share: Double, for package: String) async throws {
        guard let url = URL(string: address) else { return }
        let start = progress[package] ?? 0
        let tracker = DownloadTracker { [weak self] fraction in
            Task { @MainActor in
                guard self?.progress[package] != nil else { return }
                self?.progress[package] = start + (share - start) * fraction
            }
        }
        let (file, _) = try await URLSession.shared.download(from: url, delegate: tracker)
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard try await Task.detached(operation: { try Self.sha256(of: file) }).value == digest else { throw Failure.checksum }
        let output = await Command.run("/usr/bin/tar", ["-xjf", file.path, "-C", Self.folder.path], timeout: .seconds(600))
        guard output?.status == 0 else { throw Failure.unpack }
    }

    private nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Deletes the voice's package, and with it every other voice in the same package.
    func delete(_ voice: LocalVoice) {
        for package in voice.packages {
            try? FileManager.default.removeItem(at: Self.folder.appending(path: package.package))
        }
        refresh()
        // The tool goes with the last voice.
        if installed.isEmpty { try? FileManager.default.removeItem(at: Self.engineFolder) }
    }

    /// Other voices that come and go with this one's package.
    func sharing(_ voice: LocalVoice) -> Int {
        Self.catalogue.filter { $0.id != voice.id && $0.light == voice.light }.count
    }

    var usedBytes: Int64 {
        let walker = FileManager.default.enumerator(at: Self.folder, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = walker?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: - Speaking

    /// The text as a WAV file in this voice, or nil when it cannot be made.
    func synthesize(_ text: String, voice: LocalVoice, rate: Double, language: String = "uk") async -> URL? {
        guard let package = installedPackage(voice) else { return nil }
        let folder = Self.folder.appending(path: package.package)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        func file(_ prefix: String, _ suffix: String) -> String? {
            files.first { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }.map { folder.appending(path: $0).path }
        }
        let output = FileManager.default.temporaryDirectory.appending(path: "unimachub-voice-\(UUID().uuidString).wav")
        let slower = String(format: "%.2f", 1 / max(rate, 0.3))
        var arguments: [String]
        switch voice.model {
        case .piper:
            guard let model = file("", ".onnx") else { return nil }
            arguments = [
                "--vits-model=\(model)", "--vits-tokens=\(folder.appending(path: "tokens.txt").path)",
                "--vits-data-dir=\(folder.appending(path: "espeak-ng-data").path)", "--vits-length-scale=\(slower)",
            ]
        case .supertonic:
            guard let duration = file("duration_predictor", ".onnx"), let encoder = file("text_encoder", ".onnx"),
                  let estimator = file("vector_estimator", ".onnx"), let vocoder = file("vocoder", ".onnx")
            else { return nil }
            arguments = [
                "--supertonic-duration-predictor=\(duration)", "--supertonic-text-encoder=\(encoder)",
                "--supertonic-vector-estimator=\(estimator)", "--supertonic-vocoder=\(vocoder)",
                "--supertonic-tts-json=\(folder.appending(path: "tts.json").path)",
                "--supertonic-unicode-indexer=\(folder.appending(path: "unicode_indexer.bin").path)",
                "--supertonic-voice-style=\(folder.appending(path: "voice.bin").path)",
                "--lang=\(language == "uk" ? "uk" : "en")", "--num-steps=8",
            ]
        case .kokoro:
            guard let model = file("model", ".onnx") else { return nil }
            let british = voice.detail.hasSuffix("GB")
            let lexicon = [british ? "lexicon-gb-en.txt" : "lexicon-us-en.txt", "lexicon-zh.txt"]
                .filter { files.contains($0) }.map { folder.appending(path: $0).path }
            arguments = [
                "--kokoro-model=\(model)", "--kokoro-voices=\(folder.appending(path: "voices.bin").path)",
                "--kokoro-tokens=\(folder.appending(path: "tokens.txt").path)",
                "--kokoro-data-dir=\(folder.appending(path: "espeak-ng-data").path)",
                "--kokoro-length-scale=\(slower)",
            ]
            if files.contains("dict") { arguments.append("--kokoro-dict-dir=\(folder.appending(path: "dict").path)") }
            if !lexicon.isEmpty { arguments.append("--kokoro-lexicon=\(lexicon.joined(separator: ","))") }
        }
        arguments += ["--sid=\(voice.speaker)", "--num-threads=4", "--output-filename=\(output.path)", text]
        let result = await Command.run(Self.tool.path, arguments, timeout: .seconds(90))
        guard result?.status == 0, FileManager.default.fileExists(atPath: output.path) else {
            problem = result.map { String($0.text.suffix(300)) } ?? String(localized: "The voice did not answer in time.")
            return nil
        }
        return output
    }
}

/// Passes a download's progress on.
private final class DownloadTracker: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
