import AppKit
import CleanerCore
import Observation

/// The small tools behind the Dock's widgets: a timer, a pomodoro, a colour picker.
@MainActor
@Observable
final class DockGadgets {
    // MARK: - Timer

    private(set) var timerEnd: Date?
    private(set) var timerLength: TimeInterval = 0
    /// Set for a few seconds when the timer runs out, so the widget can say so.
    private(set) var timerRang = false
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    func startTimer(minutes: Int) {
        timerLength = TimeInterval(minutes * 60)
        timerEnd = Date().addingTimeInterval(timerLength)
        timerRang = false
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes * 60)))
            guard !Task.isCancelled, let self else { return }
            self.timerEnd = nil
            self.ring()
            self.timerRang = true
            try? await Task.sleep(for: .seconds(8))
            self.timerRang = false
        }
    }

    func stopTimer() {
        timerTask?.cancel()
        timerEnd = nil
        timerRang = false
    }

    // MARK: - Pomodoro

    enum Phase { case focus, rest }

    static let focusMinutes = 25
    static let restMinutes = 5

    private(set) var phase = Phase.focus
    private(set) var phaseEnd: Date?
    /// Time left when paused; nil while running or before the first start.
    private(set) var pausedLeft: TimeInterval?
    @ObservationIgnored private var pomodoroTask: Task<Void, Never>?

    var phaseLength: TimeInterval { TimeInterval((phase == .focus ? Self.focusMinutes : Self.restMinutes) * 60) }
    var pomodoroRunning: Bool { phaseEnd != nil }

    /// Starts, pauses, or carries on.
    func togglePomodoro() {
        if let phaseEnd {
            pausedLeft = phaseEnd.timeIntervalSinceNow
            self.phaseEnd = nil
            pomodoroTask?.cancel()
        } else {
            run(for: pausedLeft ?? phaseLength)
            pausedLeft = nil
        }
    }

    func resetPomodoro() {
        pomodoroTask?.cancel()
        phase = .focus
        phaseEnd = nil
        pausedLeft = nil
    }

    func skipPhase() {
        pomodoroTask?.cancel()
        phase = phase == .focus ? .rest : .focus
        pausedLeft = nil
        run(for: phaseLength)
    }

    private func run(for seconds: TimeInterval) {
        phaseEnd = Date().addingTimeInterval(seconds)
        pomodoroTask?.cancel()
        pomodoroTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.ring()
            // Focus leads to a rest and a rest back to focus, on their own.
            self.phase = self.phase == .focus ? .rest : .focus
            self.run(for: self.phaseLength)
        }
    }

    private func ring() {
        NSSound(named: "Glass")?.play()
    }

    // MARK: - Colour picker

    /// Colours picked, newest first, as hex.
    private(set) var colours: [String] = []

    /// macOS's own magnifier: the colour under it goes on the clipboard as hex.
    func pickColour() {
        NSColorSampler().show { [weak self] colour in
            guard let colour, let rgb = colour.usingColorSpace(.sRGB) else { return }
            let hex = String(
                format: "#%02X%02X%02X",
                Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()),
                Int((rgb.blueComponent * 255).rounded())
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.colours = Array(([hex] + self.colours.filter { $0 != hex }).prefix(6))
            }
        }
    }
}

extension NSColor {
    /// A colour from `#RRGGBB`.
    convenience init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1
        )
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
