import ArgumentParser
import CleanerCore
import Foundation

/// The resolver behind development domains; the login agent runs this.
struct DNSServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dns-serve",
        abstract: "Answer 127.0.0.1 for names under the given domains, on the loopback address."
    )

    @Option(help: "Port to listen on.")
    var port: UInt16 = DevDomains.port

    @Option(name: .customLong("domain"), help: "A domain to answer for, such as test. Repeat for more.")
    var domains: [String] = []

    func run() async throws {
        guard !domains.isEmpty else {
            throw ValidationError("Give at least one --domain.")
        }
        let server = try DevDNSServer(port: port, domains: domains)
        server.start()
        print("Answering for \(domains.joined(separator: ", ")) on 127.0.0.1:\(port)")
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }
}
