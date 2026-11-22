import Foundation
import NimbusCore

struct SFTPError: Error {
    var message: String

    init(_ message: String) { self.message = message }
}

struct SFTPBatchResult {
    var status: Int32
    var output: String
}

final class SFTPClient {
    let session: Session
    let secret: String?
    let helperURL: URL
    let extraOptions: String
    private let meta: SFTPMetaSession

    init(session: Session, secret: String?, helperURL: URL, extraOptions: String) {
        self.session = session
        self.secret = secret
        self.helperURL = helperURL
        self.extraOptions = extraOptions

        let context = (secret?.isEmpty == false)
            ? try? Askpass.makeContext(password: secret!, helper: Askpass.ensureHelper(keep: true))
            : nil
        var environment = context?.environment ?? [:]
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        AppPaths.ensureControlDirectory()
        self.meta = SFTPMetaSession(
            arguments: SSHCommandBuilder.sftpArguments(
                for: session,
                controlDirectory: AppPaths.controlMasterDirectory.path,
                extraOptions: extraOptions
            ),
            environment: environment,
            askpass: context
        )
    }

    private func quote(_ path: String) -> String {
        // Newlines would become new sftp commands; the UI does not support
        // such names anyway.
        let cleaned = path
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        return "\"" + cleaned
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func context() -> AskpassContext? {
        guard let secret, !secret.isEmpty else { return nil }
        return try? Askpass.makeContext(password: secret, helper: helperURL)
    }

    func batch(_ commands: [String], timeout: TimeInterval = 45, onStart: ((Process) -> Void)? = nil) async -> SFTPBatchResult {
        AppPaths.ensureControlDirectory()
        var options = extraOptions
        // `sftp -b` disables password prompting, so askpass auth needs the
        // interactive reader. In that mode we trust terminationStatus plus the
        // error-line scan; with key/agent auth we use batch and the real status.
        if secret == nil { options += " -o BatchMode=yes -b -" }
        let args = SSHCommandBuilder.sftpArguments(
            for: session,
            controlDirectory: AppPaths.controlMasterDirectory.path,
            extraOptions: options
        )
        let askpass = context()
        var environment = askpass?.environment ?? [:]
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        let result = await ProcessRunner.run(
            executable: SSHCommandBuilder.sftpPath,
            arguments: args,
            environment: environment,
            stdin: (commands.joined(separator: "\n") + "\nbye\n").data(using: .utf8),
            timeout: timeout,
            onStart: onStart
        )
        Askpass.cleanup(askpass)
        let output = result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
        let failed = secret != nil && sftpHasErrorLine(output)
        return SFTPBatchResult(status: failed ? 1 : result.status, output: output)
    }

    func home() async -> Result<(String, [SFTPEntry]), SFTPError> {
        let result = await batch(["pwd", "ls -la ."])
        guard result.status == 0, let path = SFTPListing.parseWorkingDirectory(result.output) else {
            return .failure(SFTPError(errorText(result)))
        }
        return .success((path, SFTPListing.parse(result.output, basePath: path)))
    }

    func list(_ path: String) async -> Result<[SFTPEntry], SFTPError> {
        let result = await meta.run("ls -la \(quote(path))")
        guard result.status == 0 else { return .failure(SFTPError(errorText(result))) }
        return .success(SFTPListing.parse(result.output, basePath: path))
    }

    func mkdir(_ path: String) async -> Result<Void, SFTPError> {
        let result = await meta.run("mkdir \(quote(path))")
        return result.status == 0 ? .success(()) : .failure(SFTPError(errorText(result)))
    }

    func rename(_ from: String, to: String) async -> Result<Void, SFTPError> {
        let result = await meta.run("rename \(quote(from)) \(quote(to))")
        return result.status == 0 ? .success(()) : .failure(SFTPError(errorText(result)))
    }

    func delete(_ path: String, isDirectory: Bool) async -> Result<Void, SFTPError> {
        let command = isDirectory ? "rmdir" : "rm"
        let result = await meta.run("\(command) \(quote(path))")
        return result.status == 0 ? .success(()) : .failure(SFTPError(errorText(result)))
    }

    func symlink(target: String, path: String) async -> Result<Void, SFTPError> {
        let result = await meta.run("symlink \(quote(target)) \(quote(path))")
        return result.status == 0 ? .success(()) : .failure(SFTPError(errorText(result)))
    }

    func chmod(_ path: String, mode: String) async -> Result<Void, SFTPError> {
        let result = await meta.run("chmod \(mode) \(quote(path))")
        return result.status == 0 ? .success(()) : .failure(SFTPError(errorText(result)))
    }

    func download(remote: String, local: String, timeout: TimeInterval = 3600, onStart: ((Process) -> Void)? = nil) async -> Result<Void, SFTPError> {
        let result = await batch(["get -p \(quote(remote)) \(quote(local))"], timeout: timeout, onStart: onStart)
        return result.status == 0 ? .success(()) : .failure(SFTPError(errorText(result)))
    }

    func upload(local: String, remote: String, timeout: TimeInterval = 3600, onStart: ((Process) -> Void)? = nil) async -> Result<Void, SFTPError> {
        // A symlink must be written through, not replaced by a regular file.
        if let existing = await remoteEntry(remote), existing.isSymlink {
            let direct = await batch(["put \(quote(local)) \(quote(remote))"], timeout: timeout, onStart: onStart)
            return direct.status == 0 ? .success(()) : .failure(SFTPError(errorText(direct)))
        }
        // Upload beside the target and rename on success: cancelling must not
        // truncate an existing remote file.
        let temporary = remote + ".nimbusterm-part-\(UUID().uuidString.prefix(6))"
        let put = await batch(["put \(quote(local)) \(quote(temporary))"], timeout: timeout, onStart: onStart)
        guard put.status == 0 else {
            _ = await batch(["rm \(quote(temporary))"])
            return .failure(SFTPError(errorText(put)))
        }
        let move = await batch(["rename \(quote(temporary)) \(quote(remote))"])
        if move.status != 0 {
            _ = await batch(["rm \(quote(temporary))"])
            return .failure(SFTPError(errorText(move)))
        }
        return .success(())
    }

    func remoteEntry(_ path: String) async -> SFTPEntry? {
        let parent = SFTPListing.parent(of: path)
        let name = (path as NSString).lastPathComponent
        guard case .success(let entries) = await list(parent) else { return nil }
        return entries.first { $0.name == name }
    }

    private func errorText(_ result: SFTPBatchResult) -> String {
        let lines = result.output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter {
                !$0.isEmpty
                    && !$0.hasPrefix("sftp>")
                    && !$0.hasPrefix("Fetching ")
                    && !$0.hasPrefix("Uploading ")
            }
        return lines.suffix(5).joined(separator: "\n").isEmpty
            ? L10n.f("sftp завершился с кодом %d", Int(result.status))
            : lines.suffix(5).joined(separator: "\n")
    }
}

enum LocalListing {
    static func list(_ path: String, showHidden: Bool) -> [SFTPEntry] {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        )) ?? []
        return contents.map { file in
            let values = try? file.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            return SFTPEntry(
                name: file.lastPathComponent,
                path: file.path,
                isDirectory: isDirectory,
                isSymlink: values?.isSymbolicLink ?? false,
                size: Int64(values?.fileSize ?? 0),
                permissions: isDirectory ? "drwxr-xr-x" : "-rw-r--r--",
                modified: values?.contentModificationDate
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
