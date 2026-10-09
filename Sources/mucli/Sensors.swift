import ArgumentParser
import CleanerCore
import Foundation

/// Prints what the hardware reports about itself.
struct Sensors: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sensors",
        abstract: "Show temperatures, fan speeds and power draw."
    )

    func run() async throws {
        let readings = SystemSensors.read()
        guard !readings.isEmpty else {
            print("This Mac reports no sensors MacUtil can read.")
            return
        }
        for kind in [SensorReading.Kind.temperature, .fan, .power] {
            let group = readings.filter { $0.kind == kind }.sorted { $0.value > $1.value }
            guard !group.isEmpty else { continue }
            print("\n\(kind.rawValue):")
            for reading in group.prefix(12) {
                let unit = switch kind {
                case .temperature: "°C"
                case .fan: "rpm"
                case .power: "W"
                }
                let name = reading.label.map { "\(reading.key)  \($0)" } ?? reading.key
                print(String(format: "  %-28s %7.1f %@", (name as NSString).utf8String!, reading.value, unit))
            }
        }
    }
}
