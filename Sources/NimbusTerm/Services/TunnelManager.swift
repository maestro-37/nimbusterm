import Darwin
import Foundation
import NimbusCore

struct TunnelRuntimeState {
    var isRunning = false
    var error: String?
}

private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > 16_384 {
            data = Data(data.suffix(8_192))
        }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var states: [UUID: TunnelRuntimeState] = [:]
    private var processes: [UUID: Process] = [:]
    private var askpassContexts: [UUID: AskpassContext] = [:]
    private var extraOptions = ""
    private var generations: [UUID: UUID] = [:]
    var onChange: (() -> Void)?

    func isRunning(_ id: UUID) -> Bool {
        states[id]?.isRunning ?? false
    }

    func startAutostart(
        tunnels: [Tunnel],
        sessions: [Session],
        secretProvider: (Session) -> String?
    ) {
        for tunnel in tunnels where tunnel.autostart {
            guard let session = sessions.first(where: { $0.id == tunnel.sessionID }) else { continue }
            start(tunnel, session: session, secret: secretProvider(session))
        }
    }

    func start(_ tunnel: Tunnel, session: Session, secret: String?) {
        guard processes[tunnel.id] == nil else { return }
        guard session.isSafeDestination else {
            states[tunnel.id] = TunnelRuntimeState(isRunning: false, error: L10n.t("Некорректный хост или пользователь"))
            onChange?()
            return
        }
        var environment = ProcessRunner.mergedEnvironment(nil)
        environment.removeValue(forKey: "SSH_ASKPASS")
        environment.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
        var context: AskpassContext?
        if let secret, !secret.isEmpty,
           let created = try? Askpass.makeContext(password: secret, helper: Askpass.ensureHelper()) {
            context = created
            askpassContexts[tunnel.id] = created
            for (key, value) in created.environment { environment[key] = value }
        }
        var options = extraOptions
        if context == nil { options += " -o BatchMode=yes" }
        AppPaths.ensureControlDirectory()
        let args = SSHCommandBuilder.tunnelArguments(
            for: tunnel,
            session: session,
            controlDirectory: AppPaths.controlMasterDirectory.path,
            extraOptions: options
        )
        let generation = UUID()
        generations[tunnel.id] = generation
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHCommandBuilder.sshPath)
        process.arguments = args
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let stderr = StderrBuffer()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderr.append(chunk)
        }
        process.terminationHandler = { [weak self] finished in
            errorPipe.fileHandleForReading.readabilityHandler = nil
            let text = stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self, self.generations[tunnel.id] == generation else { return }
                self.generations.removeValue(forKey: tunnel.id)
                self.processes.removeValue(forKey: tunnel.id)
                Askpass.cleanup(self.askpassContexts.removeValue(forKey: tunnel.id))
                var state = TunnelRuntimeState()
                state.isRunning = false
                if finished.terminationStatus != 0 {
                    state.error = text.isEmpty ? L10n.f("Процесс завершился с кодом %d", Int(finished.terminationStatus)) : text
                } else if !text.isEmpty {
                    state.error = text
                }
                self.states[tunnel.id] = state
                self.onChange?()
            }
        }
        do {
            try process.run()
            processes[tunnel.id] = process
            states[tunnel.id] = TunnelRuntimeState(isRunning: true, error: nil)
        } catch {
            Askpass.cleanup(askpassContexts.removeValue(forKey: tunnel.id))
            states[tunnel.id] = TunnelRuntimeState(isRunning: false, error: error.localizedDescription)
        }
        onChange?()
    }

    func stop(_ tunnelID: UUID) {
        guard let process = processes[tunnelID] else { return }
        generations[tunnelID] = UUID()
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        processes.removeValue(forKey: tunnelID)
        Askpass.cleanup(askpassContexts.removeValue(forKey: tunnelID))
        states[tunnelID] = TunnelRuntimeState(isRunning: false, error: nil)
        onChange?()
    }

    func stopAll() {
        for id in processes.keys { generations[id] = UUID() }
        for process in processes.values {
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
        }
        processes.removeAll()
        for context in askpassContexts.values { Askpass.cleanup(context) }
        askpassContexts.removeAll()
        states.removeAll()
    }

    func setExtraOptions(_ options: String) {
        extraOptions = options
    }
}
