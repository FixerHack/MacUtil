import CleanerCore
import SwiftUI

/// Settings the shell, Git and ssh already have, described and switchable.
struct TerminalView: View {
    @Bindable var store: TerminalStore

    var body: some View {
        VStack(spacing: 0) {
            if !store.hasLoaded {
                BusyView(title: "Reading your settings…")
            } else {
                header
                Divider()
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Terminal")
        .task {
            if !store.hasLoaded { await store.load() }
        }
        .toolbar {
            ToolbarItem {
                Button("Turn Everything Off", systemImage: "arrow.uturn.backward") {
                    Task { await store.turnOffEverything() }
                }
                .disabled(store.enabled.isEmpty || store.isBusy)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Everything MacUtil adds goes between two marked lines in your files. The rest is left exactly as you wrote it, and turning a setting off takes its lines back out.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let problem = store.problem {
                Text(verbatim: problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var list: some View {
        List {
            ForEach(TerminalOption.Place.allCases, id: \.self) { place in
                if let options = store.options[place], !options.isEmpty {
                    Section {
                        ForEach(options) { option in
                            row(option)
                        }
                    } header: {
                        Text(title(for: place))
                    } footer: {
                        Text(file(for: place))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func row(_ option: TerminalOption) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(option.title)
                Text(option.details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if option.place != .login, option.place != .git {
                Text(verbatim: option.lines.joined(separator: "  "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            Toggle(option.title, isOn: Binding(
                get: { store.isOn(option) },
                set: { _ in Task { await store.toggle(option) } }
            ))
            .labelsHidden()
            .disabled(store.isBusy)
        }
        .padding(.vertical, 2)
    }

    private func title(for place: TerminalOption.Place) -> LocalizedStringKey {
        switch place {
        case .shell: "Shell"
        case .git: "Git"
        case .ssh: "Secure shell"
        case .login: "Opening a window"
        }
    }

    private func file(for place: TerminalOption.Place) -> LocalizedStringKey {
        switch place {
        case .shell: "Written to ~/.zshrc"
        case .git: "Written with git config --global"
        case .ssh: "Written to ~/.ssh/config, at the end: ssh keeps the first value it finds, so anything you wrote above still wins."
        case .login: "Creates or removes ~/.hushlogin"
        }
    }
}
