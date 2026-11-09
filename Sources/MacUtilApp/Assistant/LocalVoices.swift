import AVFoundation
import CleanerCore
import CryptoKit
import Foundation
import Observation

/// One download of a voice: a package in sherpa-onnx's `tts-models` release.
struct VoicePackage: Equatable {
    /// Its name, without `.tar.bz2`.
    let package: String
    let digest: String
    let bytes: Int64
}

/// One voice that can be downloaded and run on this Mac, in a light version (8-bit, small
/// and quick) and, for most, a full one that sounds better and takes more room and memory.
struct LocalVoice: Identifiable, Equatable {
    let id: String
    let name: String
    /// "uk" or "en".
    let language: String
    let detail: String
    let light: VoicePackage
    let full: VoicePackage?
    /// Which of the package's speakers.
    var speaker = 0
    /// Its sample from the Piper voices, to hear it before downloading.
    let sample: URL?

    var packages: [VoicePackage] { [light] + (full.map { [$0] } ?? []) }
}

/// Voices that speak on this Mac, without any account or key: Piper's voices, run by
/// sherpa-onnx's command-line tool. Both are downloaded only when the person asks for a
/// voice, from the projects' own GitHub releases, checked against the checksums GitHub
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

    private static func sample(_ path: String, speaker: Int = 0) -> URL? {
        URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/main/\(path)/samples/speaker_\(speaker).mp3")
    }

    static let catalogue: [LocalVoice] = {
        let ukrainian = "vits-piper-uk_UA-ukrainian_tts-medium-int8"
        let ukrainianDigest = "9e3e20f311e3c486d989c3d481d9537741deb7beaeed1aa63c737574498b1e75"
        return [
            LocalVoice(id: "uk-lada", name: "Лада", language: "uk", detail: "x_low", light: VoicePackage(package: "vits-piper-uk_UA-lada-x_low-int8", digest: "5ba331ec01c811d605951c30ad7f9f57dfe87aaaefb9295c83012867db14a91a", bytes: 13_332_976),
                       full: VoicePackage(package: "vits-piper-uk_UA-lada-x_low", digest: "7a2228f249299d19016cd6ca170bf6916f8664231bcbd9e61f447b861a039cf5", bytes: 26520908), sample: sample("uk/uk_UA/lada/x_low")),
            LocalVoice(id: "uk-tts-0", name: "Ukrainian TTS · 1", language: "uk", detail: "medium", light: VoicePackage(package: ukrainian, digest: ukrainianDigest, bytes: 22_767_075),
                       full: VoicePackage(package: "vits-piper-uk_UA-ukrainian_tts-medium", digest: "92be6ff21ebb1cbcc0c71121a6437db8d060cee5785287aaa6a19a2548f59c03", bytes: 80355083), speaker: 0, sample: sample("uk/uk_UA/ukrainian_tts/medium", speaker: 0)),
            LocalVoice(id: "uk-tts-1", name: "Ukrainian TTS · 2", language: "uk", detail: "medium", light: VoicePackage(package: ukrainian, digest: ukrainianDigest, bytes: 22_767_075),
                       full: VoicePackage(package: "vits-piper-uk_UA-ukrainian_tts-medium", digest: "92be6ff21ebb1cbcc0c71121a6437db8d060cee5785287aaa6a19a2548f59c03", bytes: 80355083), speaker: 1, sample: sample("uk/uk_UA/ukrainian_tts/medium", speaker: 1)),
            LocalVoice(id: "uk-tts-2", name: "Ukrainian TTS · 3", language: "uk", detail: "medium", light: VoicePackage(package: ukrainian, digest: ukrainianDigest, bytes: 22_767_075),
                       full: VoicePackage(package: "vits-piper-uk_UA-ukrainian_tts-medium", digest: "92be6ff21ebb1cbcc0c71121a6437db8d060cee5785287aaa6a19a2548f59c03", bytes: 80355083), speaker: 2, sample: sample("uk/uk_UA/ukrainian_tts/medium", speaker: 2)),
            LocalVoice(id: "en-amy", name: "Amy", language: "en", detail: "US · medium", light: VoicePackage(package: "vits-piper-en_US-amy-medium-int8", digest: "bd23c0aa629eb3719448582f45ede49e8fa6a679061fed5eab16a6a6fd8e7e82", bytes: 21_028_122),
                       full: VoicePackage(package: "vits-piper-en_US-amy-medium", digest: "9a5d1fc497f85e8022b785bff5f8105203b1e33099ee6265203efc70b0cb0264", bytes: 67223746), sample: sample("en/en_US/amy/medium")),
            LocalVoice(id: "en-lessac", name: "Lessac", language: "en", detail: "US · medium", light: VoicePackage(package: "vits-piper-en_US-lessac-medium-int8", digest: "f1c6d0295cf16087b05f80fdca5b44daca5cd78e2c425d419a42ba34929805f9", bytes: 20_969_179),
                       full: VoicePackage(package: "vits-piper-en_US-lessac-high", digest: "8619d204c7005866fe4f420181dfa79622af6a6222389f0b0818d2af31e0db0e", bytes: 115545841), sample: sample("en/en_US/lessac/medium")),
            LocalVoice(id: "en-kristin", name: "Kristin", language: "en", detail: "US · medium", light: VoicePackage(package: "vits-piper-en_US-kristin-medium-int8", digest: "16289d7ee8e6b2311a0a0af6531a55f498f82499644a1bb6fddb991fe6fa950c", bytes: 20_882_061),
                       full: VoicePackage(package: "vits-piper-en_US-kristin-medium", digest: "c2206f572df2956c50b1ae3367eebce3853c663e890cba8048cd62b1e4dbe6c7", bytes: 67259230), sample: sample("en/en_US/kristin/medium")),
            LocalVoice(id: "en-hfc", name: "HFC Female", language: "en", detail: "US · medium", light: VoicePackage(package: "vits-piper-en_US-hfc_female-medium-int8", digest: "7c467d19054ddf84056a4887a8be75f5f3b2a5d426637b526953a5e488fec5ce", bytes: 21_021_379),
                       full: VoicePackage(package: "vits-piper-en_US-hfc_female-medium", digest: "3fffdceb0c65bd9415a085d09c3cb88cc82f9d74a6ca453f8ce7fc5eaee81ff8", bytes: 67228166), sample: sample("en/en_US/hfc_female/medium")),
            LocalVoice(id: "en-ryan", name: "Ryan", language: "en", detail: "US · medium", light: VoicePackage(package: "vits-piper-en_US-ryan-medium-int8", digest: "376eb489d42e98cb49f0e13a633e8d88580bd247ed8aacc298a733210404f771", bytes: 21_083_446),
                       full: VoicePackage(package: "vits-piper-en_US-ryan-high", digest: "6a71edf4d308b9cb2eaeadc8d1f3c6bf96120ecb7fe52c29a2b6e139c59760ed", bytes: 115630708), sample: sample("en/en_US/ryan/medium")),
            LocalVoice(id: "en-joe", name: "Joe", language: "en", detail: "US · medium", light: VoicePackage(package: "vits-piper-en_US-joe-medium-int8", digest: "644527f29eca0ada5595d7b6e4daf6388f5ac0c4870b4d42996a6687fcefeb37", bytes: 21_230_019),
                       full: VoicePackage(package: "vits-piper-en_US-joe-medium", digest: "261b903a1fb2ce621e2b5b14233cd41223c3b9f9590f896c11daee4df22d9bd3", bytes: 67169394), sample: sample("en/en_US/joe/medium")),
            LocalVoice(id: "en-alba", name: "Alba", language: "en", detail: "GB · medium", light: VoicePackage(package: "vits-piper-en_GB-alba-medium-int8", digest: "f7581d123ae977f64f3032bb247d4deeac8440e881d918d36fdd36d8f1030fb7", bytes: 21_104_326),
                       full: VoicePackage(package: "vits-piper-en_GB-alba-medium", digest: "fcd45962906933eec4431d3688f7d74aaac8713c87c6717f91fd3b23463aa1a1", bytes: 67212349), sample: sample("en/en_GB/alba/medium")),
            LocalVoice(id: "en-cori", name: "Cori", language: "en", detail: "GB · medium", light: VoicePackage(package: "vits-piper-en_GB-cori-medium-int8", digest: "169ca8aff3adb271f009a4924c99928a811dbf2b52eaca2dbb460e8c34478c93", bytes: 20_768_736),
                       full: VoicePackage(package: "vits-piper-en_GB-cori-high", digest: "42922f07738fcde2e49eed4e959635692f73b933de35a6b7c1010162ff566292", bytes: 115574061), sample: sample("en/en_GB/cori/medium")),
            LocalVoice(id: "en-northern", name: "Northern English Male", language: "en", detail: "GB · medium", light: VoicePackage(package: "vits-piper-en_GB-northern_english_male-medium-int8", digest: "9b2afdc8f35426f6b2739f255e67841679a52b56d19ece874a1eae208cb88ad1", bytes: 21_100_291),
                       full: VoicePackage(package: "vits-piper-en_GB-northern_english_male-medium", digest: "2bb2c1e709f58c11f17c693b3b38f500e110e7f54f2651774ec48b8d41f12c55", bytes: 67210490), sample: sample("en/en_GB/northern_english_male/medium")),
        ]
    }()

    /// Packages on disk.
    private(set) var installed: Set<String> = []
    /// Downloads in progress, 0…1, by package.
    private(set) var progress: [String: Double] = [:]
    private(set) var problem: String?
    @ObservationIgnored private var samplePlayer: AVPlayer?

    static var folder: URL { AppPaths.support.appending(path: "Voices") }
    static var engineFolder: URL { folder.appending(path: engine.name) }
    static var tool: URL { engineFolder.appending(path: "bin/sherpa-onnx-offline-tts") }

    init() {
        refresh()
    }

    func refresh() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.folder.path)) ?? []
        installed = Set(names.filter { $0.hasPrefix("vits-") })
    }

    /// The package of the voice on disk, the full one when both are.
    func installedPackage(_ voice: LocalVoice) -> VoicePackage? {
        voice.packages.reversed().first { installed.contains($0.package) }
    }

    func isInstalled(_ voice: LocalVoice) -> Bool { installedPackage(voice) != nil }

    func isFull(_ voice: LocalVoice) -> Bool { installedPackage(voice) == voice.full }

    /// A download of the voice in progress, 0…1.
    func progress(of voice: LocalVoice) -> Double? {
        voice.packages.lazy.compactMap { self.progress[$0.package] }.first
    }

    /// The voice's sample, from the internet, before downloading anything.
    func playSample(_ voice: LocalVoice) {
        guard let url = voice.sample else { return }
        samplePlayer = AVPlayer(url: url)
        samplePlayer?.play()
    }

    // MARK: - Downloading and deleting

    /// Downloads the light version, or the full one, which then replaces the light.
    func download(_ voice: LocalVoice, full: Bool = false) async {
        guard let package = full ? voice.full : voice.light, progress(of: voice) == nil else { return }
        problem = nil
        progress[package.package] = 0
        defer { progress[package.package] = nil; refresh() }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            if !FileManager.default.isExecutableFile(atPath: Self.tool.path) {
                try await fetch(
                    "\(Self.release)/v2.0.1/\(Self.engine.name).tar.bz2", digest: Self.engine.digest,
                    bytes: Self.engine.bytes, share: 0.3, for: package.package
                )
            }
            try await fetch(
                "\(Self.release)/tts-models/\(package.package).tar.bz2", digest: package.digest,
                bytes: package.bytes, share: 1, for: package.package
            )
            if full { try? FileManager.default.removeItem(at: Self.folder.appending(path: voice.light.package)) }
        } catch {
            problem = error.localizedDescription
        }
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
    private func fetch(_ address: String, digest: String, bytes: Int64, share: Double, for package: String) async throws {
        guard let url = URL(string: address) else { return }
        let start = progress[package] ?? 0
        let tracker = DownloadTracker { [weak self] fraction in
            Task { @MainActor in self?.progress[package] = start + (share - start) * fraction }
        }
        let (file, _) = try await URLSession.shared.download(from: url, delegate: tracker)
        defer { try? FileManager.default.removeItem(at: file) }
        guard try Self.sha256(of: file) == digest else { throw Failure.checksum }
        let output = await Command.run("/usr/bin/tar", ["-xjf", file.path, "-C", Self.folder.path], timeout: .seconds(300))
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

    func delete(_ voice: LocalVoice) {
        for package in voice.packages {
            try? FileManager.default.removeItem(at: Self.folder.appending(path: package.package))
        }
        refresh()
        // The tool goes with the last voice.
        if installed.isEmpty { try? FileManager.default.removeItem(at: Self.engineFolder) }
    }

    /// Space the voices and the tool take.
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
    func synthesize(_ text: String, voice: LocalVoice, rate: Double) async -> URL? {
        guard let package = installedPackage(voice) else { return nil }
        let folder = Self.folder.appending(path: package.package)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard let model = files.first(where: { $0.hasSuffix(".onnx") }) else { return nil }
        let output = FileManager.default.temporaryDirectory.appending(path: "unimachub-voice-\(UUID().uuidString).wav")
        let result = await Command.run(Self.tool.path, [
            "--vits-model=\(folder.appending(path: model).path)",
            "--vits-tokens=\(folder.appending(path: "tokens.txt").path)",
            "--vits-data-dir=\(folder.appending(path: "espeak-ng-data").path)",
            "--vits-length-scale=\(String(format: "%.2f", 1 / max(rate, 0.3)))",
            "--sid=\(voice.speaker)",
            "--num-threads=2",
            "--output-filename=\(output.path)",
            text,
        ], timeout: .seconds(60))
        guard result?.status == 0, FileManager.default.fileExists(atPath: output.path) else {
            problem = result.map { String($0.text.suffix(300)) }
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
