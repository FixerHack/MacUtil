import CleanerCore
import CryptoKit
import Foundation
import Observation

/// HolosTTS, the best open Ukrainian voices, with voices cloned from a recording.
///
/// It runs on PyTorch, so it gets a Python environment of its own inside UniMacHub's
/// folder, made by `uv` (downloaded from its GitHub release and checked against GitHub's
/// checksum): Python 3.12, PyTorch, the holos-tts package, and the stress and phoneme
/// packages for Ukrainian at fixed commits. The model itself comes from Hugging Face the
/// first time it starts. All of it, about 2.5 GB, lives in one folder and goes in one
/// delete. A small Python server keeps the model loaded and answers over a pipe.
@MainActor
@Observable
final class HolosEngine {
    static let shared = HolosEngine()

    struct Voice: Equatable, Codable {
        let name: String
        let gender: String
        let custom: Bool
    }

    /// Roughly what the whole thing takes once installed.
    static let size: Int64 = 2_600_000_000

    #if arch(arm64)
        static let uv = (name: "uv-aarch64-apple-darwin", digest: "81b811b57e4624df7ed3aac148e0359100d9962f3d9dce00aec533dc2e086731")
    #else
        static let uv = (name: "uv-x86_64-apple-darwin", digest: "20c47e4c1f630b8abaff8c291fa9b9aa300fef92c4fbff95adf198b55287cda7")
    #endif
    static let packages = [
        "holos-tts==0.4",
        "ukrainian-word-stress @ https://github.com/patriotyk/ukrainian-word-stress/archive/d5b37ea0abe9711930d9c3b0b13edec5a0675512.zip",
        "ipa-uk @ https://github.com/patriotyk/ipa-uk/archive/3faf05ec50fd4880965b6c76f8e479a4f82117f5.zip",
    ]

    static var home: URL { LocalVoices.folder.appending(path: "holos") }
    static var python: URL { home.appending(path: "env/bin/python") }
    static var log: URL { home.appending(path: "install.log") }
    static var voicesFile: URL { home.appending(path: "voices.json") }

    private(set) var voices: [Voice] = []
    /// What the installation is doing, while it does.
    private(set) var stage: String?
    private(set) var progress: Double?
    private(set) var problem: String?

    @ObservationIgnored private var installing: Task<Void, Never>?
    @ObservationIgnored private var server: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var waiting: [Int: CheckedContinuation<JSONValue, Never>] = [:]
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var idle: Task<Void, Never>?

    init() {
        voices = (try? Data(contentsOf: Self.voicesFile)).flatMap { try? JSONDecoder().decode([Voice].self, from: $0) } ?? []
    }

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: Self.python.path) && !voices.isEmpty }

    // MARK: - Installing

    func install() {
        guard installing == nil else { return }
        problem = nil
        installing = Task { [weak self] in
            await self?.runInstall()
            self?.installing = nil
            self?.stage = nil
            self?.progress = nil
        }
    }

    func cancel() {
        installing?.cancel()
        stop()
    }

    private func runInstall() async {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.home, withIntermediateDirectories: true)
        manager.createFile(atPath: Self.log.path, contents: nil)
        do {
            // 1. uv, which makes the environment.
            let uv = Self.home.appending(path: "\(Self.uv.name)/uv")
            if !manager.isExecutableFile(atPath: uv.path) {
                step(String(localized: "Getting the installer…"), 0.02)
                guard let url = URL(string: "https://github.com/astral-sh/uv/releases/download/0.13.7/\(Self.uv.name).tar.gz") else { return }
                let (file, _) = try await URLSession.shared.download(from: url)
                defer { try? manager.removeItem(at: file) }
                guard try await Task.detached(operation: { try Self.sha256(of: file) }).value == Self.uv.digest else {
                    throw LocalVoices.Failure.checksum
                }
                try await run("/usr/bin/tar", ["-xzf", file.path, "-C", Self.home.path], minutes: 2)
            }
            try Task.checkCancellation()
            // 2. Python of its own, not the system's.
            step(String(localized: "Getting Python…"), 0.08)
            try await run(uv.path, ["venv", "--allow-existing", "--python", "3.12", Self.home.appending(path: "env").path], minutes: 10)
            try Task.checkCancellation()
            // 3. PyTorch, HolosTTS and the Ukrainian text tools: the large part.
            step(String(localized: "Getting PyTorch and HolosTTS, about 1.5 GB…"), 0.15)
            try await run(uv.path, ["pip", "install", "--python", Self.python.path] + Self.packages, minutes: 60)
            try Task.checkCancellation()
            // 4. The model and the stress dictionary, on the first start.
            step(String(localized: "Getting the voice model and learning its voices…"), 0.75)
            try await start()
            let reply = await request(["cmd": .string("ready")], minutes: 30)
            guard reply["ok"]?.bool == true else {
                throw HolosFailure.message(reply["error"]?.string ?? String(localized: "HolosTTS did not start."))
            }
            take(reply)
            step(String(localized: "Ready"), 1)
        } catch is CancellationError {
            stop()
            problem = nil
        } catch {
            stop()
            problem = error.localizedDescription + " " + String(localized: "The details are in install.log in the voices folder.")
        }
    }

    private func step(_ text: String, _ fraction: Double) {
        stage = text
        progress = fraction
        append(to: Self.log, "== \(text)\n")
    }

    enum HolosFailure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case let .message(text): text }
        }
    }

    /// Runs a step, its output going to the log.
    private func run(_ tool: String, _ arguments: [String], minutes: Int) async throws {
        let output = await Command.run(tool, arguments, timeout: .seconds(minutes * 60), environment: Self.environment)
        append(to: Self.log, "$ \(tool) \(arguments.joined(separator: " "))\n\(output?.text ?? "(did not finish)")\n")
        guard let output, output.status == 0 else {
            let tail = output.map { String($0.text.suffix(400)) } ?? String(localized: "did not finish in time")
            throw HolosFailure.message(tail)
        }
    }

    /// Everything the environment downloads stays in its own folder.
    static var environment: [String: String] {
        [
            "UV_PYTHON_INSTALL_DIR": home.appending(path: "python").path,
            "UV_CACHE_DIR": home.appending(path: "cache/uv").path,
            "HF_HOME": home.appending(path: "cache/huggingface").path,
            "STANZA_RESOURCES_DIR": home.appending(path: "cache/stanza").path,
            "UNIMACHUB_HOLOS_HOME": home.path,
            "PYTHONUNBUFFERED": "1",
            "TOKENIZERS_PARALLELISM": "false",
        ]
    }

    private func append(to file: URL, _ text: String) {
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    private nonisolated static func sha256(of file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func take(_ reply: JSONValue) {
        voices = (reply["voices"]?.array ?? []).compactMap { voice in
            guard let name = voice["name"]?.string else { return nil }
            return Voice(name: name, gender: voice["gender"]?.string ?? "female", custom: voice["custom"]?.bool ?? false)
        }
        try? JSONEncoder().encode(voices).write(to: Self.voicesFile, options: .atomic)
    }

    // MARK: - Removing

    func remove() {
        cancel()
        try? FileManager.default.removeItem(at: Self.home)
        voices = []
        problem = nil
    }

    // MARK: - The server

    private func start() async throws {
        guard server == nil else { return }
        guard let script = Bundle.main.url(forResource: "holos_server", withExtension: "py") else {
            throw HolosFailure.message(String(localized: "This copy of UniMacHub has no HolosTTS server inside."))
        }
        let process = Process()
        process.executableURL = Self.python
        process.arguments = [script.path]
        process.environment = ProcessInfo.processInfo.environment.merging(Self.environment) { _, new in new }
        let toServer = Pipe()
        let fromServer = Pipe()
        process.standardInput = toServer
        process.standardOutput = fromServer
        let errors = try? FileHandle(forWritingTo: Self.log)
        _ = try? errors?.seekToEnd()
        process.standardError = errors ?? FileHandle.nullDevice
        fromServer.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.received(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.ended() }
        }
        try process.run()
        server = process
        input = toServer.fileHandleForWriting
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            guard let reply = JSONValue.parse(String(decoding: line, as: UTF8.self)),
                  let id = reply["id"]?.number.map({ Int($0) }),
                  let continuation = waiting.removeValue(forKey: id)
            else { continue }
            continuation.resume(returning: reply)
        }
    }

    private func ended() {
        server = nil
        input = nil
        buffer = Data()
        for continuation in waiting.values {
            continuation.resume(returning: .object(["ok": .bool(false), "error": .string("HolosTTS stopped.")]))
        }
        waiting = [:]
    }

    func stop() {
        server?.terminate()
        ended()
    }

    private func request(_ fields: [String: JSONValue], minutes: Double = 2) async -> JSONValue {
        guard let input else { return .object(["ok": .bool(false), "error": .string("HolosTTS is not running.")]) }
        let id = nextID
        nextID += 1
        var message = fields
        message["id"] = .number(Double(id))
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
            try? input.write(contentsOf: Data((message.isEmpty ? "{}" : JSONValue.object(message).text + "\n").utf8))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard let self, let late = self.waiting.removeValue(forKey: id) else { return }
                late.resume(returning: .object(["ok": .bool(false), "error": .string("HolosTTS took too long.")]))
            }
        }
    }

    /// Starts the server when needed, and stops it after ten idle minutes to give the memory back.
    private func ready() async -> Bool {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
        if server != nil { return true }
        do {
            try await start()
        } catch {
            problem = error.localizedDescription
            return false
        }
        let reply = await request(["cmd": .string("ready")], minutes: 10)
        if reply["ok"]?.bool == true { take(reply) } else { problem = reply["error"]?.string }
        return reply["ok"]?.bool == true
    }

    // MARK: - Speaking and cloning

    func say(_ text: String, voice: String, speed: Double) async -> URL? {
        guard isInstalled, await ready() else { return nil }
        let output = FileManager.default.temporaryDirectory.appending(path: "unimachub-holos-\(UUID().uuidString).wav")
        let reply = await request([
            "cmd": .string("say"), "text": .string(text), "voice": .string(voice),
            "speed": .number(speed), "out": .string(output.path),
        ])
        guard reply["ok"]?.bool == true else {
            problem = reply["error"]?.string
            return nil
        }
        return output
    }

    /// A voice of the person's own, from a recording of them speaking.
    func clone(_ recording: URL, name: String) async -> Voice? {
        guard isInstalled, await ready() else { return nil }
        let reply = await request(["cmd": .string("clone"), "audio": .string(recording.path), "name": .string(name)], minutes: 5)
        guard reply["ok"]?.bool == true, let saved = reply["name"]?.string else {
            problem = reply["error"]?.string ?? String(localized: "The voice could not be made from this recording.")
            return nil
        }
        let voice = Voice(name: saved, gender: reply["gender"]?.string ?? "female", custom: true)
        voices.removeAll { $0.name == saved }
        voices.append(voice)
        try? JSONEncoder().encode(voices).write(to: Self.voicesFile, options: .atomic)
        return voice
    }

    func forget(_ name: String) async {
        if await ready() { _ = await request(["cmd": .string("forget"), "name": .string(name)]) }
        voices.removeAll { $0.name == name }
        try? JSONEncoder().encode(voices).write(to: Self.voicesFile, options: .atomic)
    }
}
