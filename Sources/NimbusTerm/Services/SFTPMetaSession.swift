import Foundation
import NimbusCore

/// One long-lived `sftp` process per browser. Every command then costs a round
/// trip instead of a process start plus authentication.
final class SFTPMetaSession: @unchecked Sendable {
    private let arguments: [String]
    private let environment: [String: String]
    private let askpass: AskpassContext?

    private let lock = NSCondition()
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var primed = false
    private var closed = true
    private let readerQueue = DispatchQueue(label: "com.maestro37.nimbusterm.sftp.reader")
    private let workQueue = DispatchQueue(label: "com.maestro37.nimbusterm.sftp.meta")

    init(arguments: [String], environment: [String: String], askpass: AskpassContext?) {
        self.arguments = arguments
        self.environment = environment
        self.askpass = askpass
    }

    deinit {
        lock.lock()
        let running = process
        process = nil
        lock.unlock()
        running?.terminate()
        Askpass.cleanup(askpass)
    }

    func run(_ command: String, timeout: TimeInterval = 45) async -> SFTPBatchResult {
        await withCheckedContinuation { continuation in
            workQueue.async {
                continuation.resume(returning: self.execute(command, timeout: timeout))
            }
        }
    }

    // MARK: - Private

    private func execute(_ command: String, timeout: TimeInterval) -> SFTPBatchResult {
        AppPaths.ensureControlDirectory()
        guard start() else { return failure(L10n.t("sftp: не удалось запустить сессию")) }
        let deadline = Date().addingTimeInterval(timeout)

        if !primed {
            // Drop the banner and the first prompt before writing.
            guard waitForPrompt(deadline) else {
                return timedOut(timeout)
            }
            drain()
            primed = true
        }

        guard let input else { return failure(L10n.t("sftp: сессия закрыта")) }
        guard (try? input.write(contentsOf: Data((command + "\n").utf8))) != nil else {
            stop()
            return failure(L10n.t("sftp: не удалось отправить команду"))
        }

        guard waitForPrompt(deadline) else {
            return timedOut(timeout)
        }
        return takeOutput(command: command)
    }

    private func start() -> Bool {
        lock.lock()
        if !closed, process?.isRunning == true {
            lock.unlock()
            return true
        }
        lock.unlock()

        let process = Process()
        // `sftp` block-buffers its output on a plain pipe; a pty keeps prompts
        // and replies line-buffered so the session can stay open.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", SSHCommandBuilder.sftpPath] + arguments
        var fullEnvironment = ProcessInfo.processInfo.environment
        fullEnvironment.merge(environment) { _, new in new }
        process.environment = fullEnvironment

        let stdinPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.closed = true
            self.lock.broadcast()
            self.lock.unlock()
        }
        do {
            try process.run()
        } catch {
            return false
        }

        lock.lock()
        self.process = process
        input = stdinPipe.fileHandleForWriting
        buffer.removeAll()
        primed = false
        closed = false
        lock.unlock()

        let handle = outputPipe.fileHandleForReading
        readerQueue.async { [weak self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                self?.append(chunk)
            }
            self?.markClosed()
        }
        return true
    }

    private func stop() {
        lock.lock()
        let running = process
        process = nil
        input = nil
        buffer.removeAll()
        primed = false
        closed = true
        lock.broadcast()
        lock.unlock()
        running?.terminate()
    }

    private func append(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        lock.broadcast()
        lock.unlock()
    }

    private func markClosed() {
        lock.lock()
        closed = true
        lock.broadcast()
        lock.unlock()
    }

    private func waitForPrompt(_ deadline: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        while promptCount() < 1 {
            if closed { return false }
            if !lock.wait(until: deadline) { return false }
        }
        return true
    }

    private func promptCount() -> Int {
        String(decoding: buffer, as: UTF8.self).components(separatedBy: "sftp> ").count - 1
    }

    private func drain() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }

    private func takeOutput(command: String) -> SFTPBatchResult {
        lock.lock()
        defer { lock.unlock() }
        let text = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()

        guard let prompt = text.range(of: "sftp> ") else {
            return failure(L10n.t("sftp: не удалось разобрать ответ"))
        }
        var lines = text[..<prompt.lowerBound].components(separatedBy: "\n")
        // The tty echoes our own command line; the remote reply follows it.
        if let first = lines.first,
           first.trimmingCharacters(in: .whitespacesAndNewlines) == command {
            lines.removeFirst()
        }
        let output = lines.joined(separator: "\n")
        buffer = Data(text[prompt.upperBound...].utf8)
        return SFTPBatchResult(status: sftpHasErrorLine(output) ? 1 : 0, output: output)
    }

    private func timedOut(_ timeout: TimeInterval) -> SFTPBatchResult {
        stop()
        return failure(L10n.f("sftp: нет ответа за %d с", Int(timeout)))
    }

    private func failure(_ message: String) -> SFTPBatchResult {
        SFTPBatchResult(status: 1, output: message)
    }
}

/// `sftp` reports most failures on stderr with exit status 0, so the text is the signal.
func sftpHasErrorLine(_ output: String) -> Bool {
    let markers = [
        "No such file", "Permission denied", "Couldn't", "not found", "Invalid",
        "Connection closed", "remote open", "Failure", "You must supply"
    ]
    for line in output.split(whereSeparator: \.isNewline) {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.hasPrefix("sftp>"), !text.hasPrefix("/"),
              !text.hasPrefix("Remote working directory:") else { continue }
        if let first = text.first, "-dlbcps".contains(first) { continue }
        if markers.contains(where: { text.localizedCaseInsensitiveContains($0) }) { return true }
    }
    return false
}
