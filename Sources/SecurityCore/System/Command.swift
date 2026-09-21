import Foundation

/// Runs a system tool and captures its output (stdout and stderr together).
enum Command {
    struct Output: Sendable {
        let status: Int32
        let text: String
    }

    /// Returns nil if the tool could not start or ran longer than `timeout`.
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: Duration = .seconds(15)
    ) async -> Output? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
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
