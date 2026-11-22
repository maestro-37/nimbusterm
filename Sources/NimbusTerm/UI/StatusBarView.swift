import SwiftUI
import NimbusCore

struct StatusBarView: View {
    @EnvironmentObject private var app: AppModel

    private var session: Session? {
        app.activeTab?.activeController?.session
    }

    private var stats: RemoteStats? {
        guard let id = session?.id else { return nil }
        return app.monitorStats[id]
    }

    var body: some View {
        HStack(spacing: 10) {
            if let controller = app.activeTab?.activeController {
                Circle()
                    .fill(statusColor(controller))
                    .frame(width: 7, height: 7)
                Text(controller.title)
                    .font(.caption)
                    .lineLimit(1)
                if let session, !session.host.isEmpty {
                    Text(session.destination)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if controller.isLogging {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                        .help("Идёт запись лога")
                }
                if let remaining = controller.warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(remaining)
                }
            } else {
                Text(app.activeTab?.title ?? "NimbusTerm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let tab = app.activeTab, case .terminals = tab.kind {
                BroadcastBadge(tab: tab)
            }

            Spacer()

            if let stats {
                Text(stats.summary)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("Обновлено \(stats.updatedAt.formatted(date: .omitted, time: .standard))")
            }

            if let message = app.statusMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 260)
            }

            Text("вкладок: \(app.tabs.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
    }

    private func statusColor(_ controller: TerminalController) -> Color {
        if controller.isRunning { return .green }
        if !controller.started { return .secondary }
        if controller.exitCode == 0 { return .secondary }
        return .red
    }
}

struct BroadcastBadge: View {
    @ObservedObject var tab: WorkspaceTab

    var body: some View {
        if tab.isBroadcast {
            Label("BROADCAST", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption2.bold())
                .foregroundStyle(.orange)
        }
    }
}
