import AppKit
import CleanerCore
import SwiftUI

// MARK: - Top strip

/// The strip beside the notch in the opened island: the pages on the left, batteries on the
/// right, and the notch itself left clear in the middle.
struct IslandTopStrip: View {
    @Bindable var model: IslandModel

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                tab(.home, symbol: "house.fill", label: "Home")
                if model.agents.showsAgents {
                    tab(.agents, symbol: "sparkles", label: "Agents")
                        .overlay(alignment: .topTrailing) {
                            if model.agents.sessions.contains(where: \.needsYou) {
                                Circle().fill(.orange).frame(width: 6, height: 6).offset(x: -3, y: 2)
                            }
                        }
                }
            }
            Spacer(minLength: (model.geometry?.notch?.width ?? IslandGeometry.tabSize.width) + 24)
            if model.batteries.isEnabled {
                HStack(spacing: 10) {
                    ForEach(model.batteries.devices.prefix(4)) { device in
                        BatteryChip(device: device)
                    }
                }
            }
        }
    }

    private func tab(_ page: IslandModel.Page, symbol: String, label: LocalizedStringKey) -> some View {
        let chosen = model.page == page
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.page = page }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 20)
                .background(chosen ? Color.white.opacity(0.16) : .clear, in: .capsule)
                .foregroundStyle(.white.opacity(chosen ? 1 : 0.5))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(Text(label))
    }
}

private struct BatteryChip: View {
    let device: DeviceBattery

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: device.kind.symbol).font(.system(size: 10))
            Text(verbatim: "\(device.level)%").font(.system(size: 10, weight: .medium).monospacedDigit())
            if device.isCharging {
                Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(.green)
            }
        }
        .foregroundStyle(device.level <= 20 && !device.isCharging ? Color.red : .white.opacity(0.75))
        .help(Text(verbatim: details))
    }

    private var details: String {
        var parts = [device.name]
        if let left = device.left { parts.append("L \(left)%") }
        if let right = device.right { parts.append("R \(right)%") }
        if let box = device.caseLevel { parts.append("◻︎ \(box)%") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Agents

/// The agents page: each session with what it is doing, its question if it has one, and
/// how much of the subscriptions is left.
struct AgentsPage: View {
    let model: IslandModel

    private var agents: AgentsModel { model.agents }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            sessions.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            LimitsColumn(agents: agents).frame(width: 170, alignment: .leading)
        }
    }

    @ViewBuilder private var sessions: some View {
        if agents.sessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(.white.opacity(0.4))
                Text(agents.claudeConnected
                    ? "No coding agents at work"
                    : "Connect Claude Code in Overview → Dynamic Island to see its sessions here")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    ForEach(agents.sessions) { session in
                        AgentRow(session: session, model: model)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

private struct AgentRow: View {
    let session: AgentSession
    let model: IslandModel

    private var agents: AgentsModel { model.agents }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentSymbol(session: session).font(.system(size: 13, weight: .semibold)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: session.project).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(verbatim: session.stateText).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(session.updated, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }

            if case let .needsPermission(what) = session.state, !what.isEmpty {
                Text(verbatim: what)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 8))
            }

            if agents.questions.contains(session.id) {
                HStack(spacing: 8) {
                    Button { agents.allow(session.id) } label: {
                        Text("Allow").padding(.horizontal, 12).padding(.vertical, 4)
                            .background(Color.green.opacity(0.85), in: .capsule)
                    }
                    Button { agents.deny(session.id) } label: {
                        Text("Deny").padding(.horizontal, 12).padding(.vertical, 4)
                            .background(Color.white.opacity(0.14), in: .capsule)
                    }
                    Spacer()
                    Button {
                        agents.answerInTerminal(session.id)
                        model.close()
                    } label: {
                        Label("Answer There", systemImage: "arrow.up.forward.app")
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.white.opacity(session.needsYou ? 0.1 : 0.05), in: .rect(cornerRadius: 12))
        .contentShape(.rect(cornerRadius: 12))
        .onTapGesture {
            agents.open(session)
            model.close()
        }
    }
}

/// The agent's mark, moving while it works or waits.
struct AgentSymbol: View {
    let session: AgentSession

    var body: some View {
        switch session.state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            Image(systemName: session.kind == .claude ? "asterisk" : "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(session.needsYou ? Color.orange : session.kind.tint)
                .symbolEffect(.pulse, isActive: session.needsYou || session.isWorking)
        }
    }
}

extension AgentKind {
    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.55, green: 0.75, blue: 1)
        }
    }
}

extension AgentSession {
    /// What it is doing, in a few words.
    var stateText: String {
        switch state {
        case .ready: String(localized: "Ready")
        case let .working(tool): tool.map { String(localized: "Working: \($0)") } ?? String(localized: "Working…")
        case .needsPermission: String(localized: "Asks for permission")
        case let .needsInput(message): message ?? String(localized: "Waiting for you")
        case let .done(message): message ?? String(localized: "Done")
        case let .failed(message): message ?? String(localized: "Stopped with an error")
        }
    }

    /// The fewest words, for the wings.
    var wingText: String {
        switch state {
        case .needsPermission, .needsInput: String(localized: "Asks")
        case .done: String(localized: "Done")
        default: project
        }
    }
}

// MARK: - Limits

private struct LimitsColumn: View {
    let agents: AgentsModel

    var body: some View {
        let now = Date()
        let claude = agents.claudeLimits?.current(at: now)
        let codex = agents.codexLimits?.current(at: now)
        VStack(alignment: .leading, spacing: 10) {
            if let claude, !claude.isEmpty { block("Claude", claude) }
            if let codex, !codex.isEmpty { block("Codex", codex) }
            if claude?.isEmpty ?? true, codex?.isEmpty ?? true {
                Text("Limits show up after the next answer from Claude Code or Codex")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func block(_ name: String, _ limits: AgentLimits) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: name).font(.caption.weight(.semibold))
            if let five = limits.fiveHour { LimitBar(label: "5 h", window: five) }
            if let week = limits.week { LimitBar(label: "Week", window: week) }
        }
    }
}

private struct LimitBar: View {
    let label: LocalizedStringKey
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label).frame(width: 34, alignment: .leading)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(color)
                            .frame(width: geometry.size.width * min(1, max(0, window.usedPercent / 100)))
                    }
                }
                .frame(height: 4)
                Text(verbatim: "\(Int(window.usedPercent.rounded()))%").monospacedDigit().frame(width: 32, alignment: .trailing)
            }
            if let resets = window.resetsAt {
                Text("Resets \(resets.formatted(Self.style(for: resets)))")
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .font(.system(size: 10))
    }

    private var color: Color {
        switch window.usedPercent {
        case ..<70: .green
        case ..<90: .orange
        default: .red
        }
    }

    /// The time alone within a day, the day too beyond it.
    private static func style(for date: Date) -> Date.FormatStyle {
        date.timeIntervalSinceNow < 20 * 3600
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).hour().minute()
    }
}

// MARK: - Calendar

/// The next event, in the opened island.
struct CalendarChip: View {
    let event: CalendarFeed.Event

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "calendar").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: event.title).font(.caption.weight(.semibold)).lineLimit(2)
                Text(verbatim: "\(event.start.formatted(date: .omitted, time: .shortened)) · \(event.start.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .font(.caption)
    }
}
