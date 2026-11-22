import Darwin
import Foundation

enum PTYRunner {
    /// Runs a command inside a pseudo-terminal and answers prompt patterns.
    /// Used so secrets never appear in process arguments.
    static func run(
        executable: String,
        arguments: [String],
        answers: [(pattern: String, reply: String)],
        timeout: TimeInterval = 40
    ) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var master: Int32 = -1
                let pid = forkpty(&master, nil, nil, nil)
                if pid == 0 {
                    var argv = ([executable] + arguments).map { strdup($0) }
                    argv.append(nil)
                    execv(executable, argv)
                    _exit(127)
                }
                guard pid > 0 else {
                    continuation.resume(returning: ProcessResult(status: -1, stdout: "", stderr: "forkpty failed"))
                    return
                }

                var output = Data()
                var remaining = answers
                var buffer = [UInt8](repeating: 0, count: 4096)
                let deadline = Date().addingTimeInterval(timeout)
                var terminated = false
                var status: Int32 = 0

                while true {
                    var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&descriptor, 1, 100)
                    if ready > 0 && (descriptor.revents & Int16(POLLIN)) != 0 {
                        let count = read(master, &buffer, buffer.count)
                        if count > 0 {
                            output.append(buffer, count: count)
                            let text = String(decoding: output, as: UTF8.self)
                            if !remaining.isEmpty {
                                for index in remaining.indices {
                                    if text.contains(remaining[index].pattern) {
                                        let reply = remaining[index].reply + "\n"
                                        _ = reply.withCString { write(master, $0, strlen($0)) }
                                        remaining.remove(at: index)
                                        break
                                    }
                                }
                            }
                        }
                    }
                    var childStatus: Int32 = 0
                    let waited = waitpid(pid, &childStatus, WNOHANG)
                    if waited == pid {
                        status = childStatus
                        terminated = true
                        break
                    }
                    if Date() > deadline {
                        kill(pid, SIGTERM)
                        waitpid(pid, &childStatus, 0)
                        status = childStatus
                        terminated = true
                        break
                    }
                }
                close(master)

                let exitCode: Int32
                if (status & 0x7F) == 0 {
                    exitCode = (status >> 8) & 0xFF
                } else {
                    exitCode = 128 + (status & 0x7F)
                }
                continuation.resume(returning: ProcessResult(
                    status: terminated ? exitCode : -1,
                    stdout: String(decoding: output, as: UTF8.self),
                    stderr: ""
                ))
            }
        }
    }
}
