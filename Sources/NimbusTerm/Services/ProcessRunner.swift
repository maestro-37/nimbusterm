import Darwin
import Foundation

struct ProcessResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

enum ProcessRunner {
    static func mergedEnvironment(_ overrides: [String: String]?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let overrides {
            for (key, value) in overrides { env[key] = value }
        }
        return env
    }

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval = 30,
        onStart: ((Process) -> Void)? = nil
    ) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = mergedEnvironment(environment)
                let output = Pipe()
                let error = Pipe()
                let input = Pipe()
                process.standardOutput = output
                process.standardError = error
                process.standardInput = input

                do {
                    try process.run()
                    onStart?(process)
                } catch {
                    continuation.resume(returning: ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                if let stdin {
                    input.fileHandleForWriting.write(stdin)
                }
                try? input.fileHandleForWriting.close()

                var outputData = Data()
                var errorData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    outputData = output.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errorData = error.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                process.waitUntilExit()
                group.wait()
                continuation.resume(returning: ProcessResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outputData, as: UTF8.self),
                    stderr: String(decoding: errorData, as: UTF8.self)
                ))
            }
        }
    }
}
