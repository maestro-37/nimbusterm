import Foundation
import NimbusCore

@MainActor
final class MonitorService: ObservableObject {
    var onStats: ((UUID, RemoteStats) -> Void)?
    var onError: ((UUID, String) -> Void)?
    private var timers: [UUID: Timer] = [:]
    private var sessions: [UUID: Session] = [:]
    private var secrets: [UUID: String] = [:]
    private var inFlight: Set<UUID> = []
    private var interval: TimeInterval = 5
    private var extraOptions = ""
    private var notifiedErrors: Set<UUID> = []

    func sync(
        sessions: [Session],
        settings: AppSettings,
        secretProvider: (Session) -> String?
    ) {
        let newInterval = max(2, settings.monitorInterval)
        if abs(newInterval - interval) > 0.01 {
            for timer in timers.values { timer.invalidate() }
            timers.removeAll()
        }
        interval = newInterval
        extraOptions = settings.sshExtraOptions
        let monitored = sessions.filter { $0.monitor && $0.protocolKind == .ssh }
        let wanted = Set(monitored.map(\.id))

        for (id, timer) in timers where !wanted.contains(id) {
            timer.invalidate()
            timers.removeValue(forKey: id)
            self.sessions.removeValue(forKey: id)
            secrets.removeValue(forKey: id)
        }

        for session in monitored {
            self.sessions[session.id] = session
            secrets[session.id] = secretProvider(session)
            if timers[session.id] == nil {
                let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.poll(session.id) }
                }
                timers[session.id] = timer
                Task { @MainActor in self.poll(session.id) }
            }
        }
    }

    private func poll(_ sessionID: UUID) {
        guard !inFlight.contains(sessionID), let session = sessions[sessionID] else { return }
        inFlight.insert(sessionID)
        let secret = secrets[sessionID]
        let options = extraOptions + (secret == nil ? " -o BatchMode=yes" : "")
        AppPaths.ensureControlDirectory()
        let args = SSHCommandBuilder.execArguments(
            for: session,
            controlDirectory: AppPaths.controlMasterDirectory.path,
            remoteCommand: RemoteStatsParser.command,
            extraOptions: options
        )
        var environment: [String: String]? = nil
        var context: AskpassContext?
        if let secret, !secret.isEmpty,
           let created = try? Askpass.makeContext(password: secret, helper: Askpass.ensureHelper()) {
            context = created
            environment = created.environment
        }
        Task { [weak self] in
            let result = await ProcessRunner.run(
                executable: SSHCommandBuilder.sshPath,
                arguments: args,
                environment: environment,
                timeout: 15
            )
            Askpass.cleanup(context)
            await MainActor.run {
                guard let self else { return }
                self.inFlight.remove(sessionID)
                guard result.status == 0 else {
                    if !self.notifiedErrors.contains(sessionID) {
                        self.notifiedErrors.insert(sessionID)
                        let text = (result.stderr.isEmpty ? result.stdout : result.stderr)
                            .split(whereSeparator: \.isNewline).first.map(String.init) ?? "код \(result.status)"
                        self.onError?(sessionID, text)
                    }
                    return
                }
                self.notifiedErrors.remove(sessionID)
                let stats = RemoteStatsParser.parse(result.stdout)
                self.onStats?(sessionID, stats)
            }
        }
    }

    func stopAll() {
        for timer in timers.values { timer.invalidate() }
        timers.removeAll()
        inFlight.removeAll()
    }
}
