import Foundation

/// Runs a system tool and captures its output (stdout and stderr together).
public enum Command {
    public struct Output: Sendable {
        public let status: Int32
        public let text: String
    }

    /// Returns nil if the tool could not start or ran longer than `timeout`.
    ///
    /// `input` goes to the tool's standard input, which is where a password belongs: unlike
    /// an argument, it never shows up in the process list.
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: Duration = .seconds(15),
        environment: [String: String] = [:],
        input: Data? = nil
    ) async -> Output? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let stdin = input.map { _ in Pipe() }
            process.standardInput = stdin ?? FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            if let stdin, let input {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }

            let watchdog = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: watchdog)

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            if process.terminationReason == .uncaughtSignal {
                return nil
            }
            return Output(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
        }.value
    }
}
