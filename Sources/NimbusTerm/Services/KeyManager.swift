import Foundation
import NimbusCore

struct SSHKey: Identifiable, Sendable {
    var id: String { privatePath }
    var name: String
    var privatePath: String
    var publicPath: String?
    var type: String
    var comment: String
    var fingerprint: String?

    var publicKey: String? {
        guard let publicPath else { return nil }
        return try? String(contentsOfFile: publicPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum KeyManager {
    static var sshDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh", isDirectory: true)
    }

    static func list() -> [SSHKey] {
        let manager = FileManager.default
        let ignored: Set<String> = ["config", "known_hosts", "known_hosts.old", "authorized_keys", "environment"]
        guard let files = try? manager.contentsOfDirectory(atPath: sshDirectory.path) else { return [] }
        var keys: [SSHKey] = []
        for file in files.sorted() {
            guard !file.hasSuffix(".pub"), !ignored.contains(file), !file.hasPrefix(".") else { continue }
            let privatePath = sshDirectory.appendingPathComponent(file).path
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: privatePath, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let publicPath = privatePath + ".pub"
            var type = ""
            var comment = ""
            var fingerprintText: String?
            if let contents = try? String(contentsOfFile: publicPath, encoding: .utf8) {
                let parts = contents.split(separator: " ", maxSplits: 2).map(String.init)
                if parts.count >= 2 {
                    type = parts[0]
                    comment = parts.count > 2 ? parts[2] : ""
                }
                fingerprintText = fingerprint(of: publicPath)
            }
            keys.append(SSHKey(
                name: file,
                privatePath: privatePath,
                publicPath: manager.fileExists(atPath: publicPath) ? publicPath : nil,
                type: type,
                comment: comment,
                fingerprint: fingerprintText
            ))
        }
        return keys
    }

    static func fingerprint(of publicPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHCommandBuilder.sshKeygenPath)
        process.arguments = ["-lf", publicPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    static func generate(name: String, comment: String, passphrase: String) async throws -> SSHKey {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw KeyError.invalidName
        }
        let path = sshDirectory.appendingPathComponent(name).path
        guard !FileManager.default.fileExists(atPath: path) else { throw KeyError.exists }
        try? FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDirectory.path)

        var arguments = ["-t", "ed25519", "-a", "100", "-f", path]
        if !comment.isEmpty { arguments += ["-C", comment] }
        let result: ProcessResult
        if passphrase.isEmpty {
            arguments += ["-N", ""]
            result = await ProcessRunner.run(
                executable: SSHCommandBuilder.sshKeygenPath,
                arguments: arguments,
                timeout: 60
            )
        } else {
            result = await PTYRunner.run(
                executable: SSHCommandBuilder.sshKeygenPath,
                arguments: arguments,
                answers: [
                    ("Enter passphrase", passphrase),
                    ("Enter same passphrase", passphrase)
                ],
                timeout: 60
            )
        }
        guard result.status == 0, FileManager.default.fileExists(atPath: path) else {
            throw KeyError.failed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return SSHKey(
            name: name,
            privatePath: path,
            publicPath: path + ".pub",
            type: "ssh-ed25519",
            comment: comment,
            fingerprint: fingerprint(of: path + ".pub")
        )
    }

    static func install(key: SSHKey, on session: Session, password: String) async -> Result<String, KeyInstallError> {
        guard let publicPath = key.publicPath else { return .failure(KeyInstallError(L10n.t("Нет публичного ключа"))) }
        var arguments: [String] = []
        if session.port > 0 { arguments += ["-p", String(session.port)] }
        arguments += ["-i", publicPath]
        arguments += ["-o", "StrictHostKeyChecking=accept-new"]
        arguments += ["-o", "ConnectTimeout=10"]
        guard session.isSafeDestination else { return .failure(KeyInstallError(L10n.t("Некорректный хост или пользователь"))) }
        arguments += ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive"]
        if !session.proxyJump.isEmpty { arguments += ["-J", session.proxyJump] }
        arguments += Shell.split(session.extraArgs)
        let destination = session.user.isEmpty ? session.host : "\(session.user)@\(session.host)"
        arguments.append("--")
        arguments.append(destination)
        let result = await PTYRunner.run(
            executable: SSHCommandBuilder.sshCopyIDPath,
            arguments: arguments,
            answers: [
                ("password:", password),
                ("Password:", password)
            ],
            timeout: 40
        )
        if result.status == 0 {
            return .success(L10n.f("Ключ %@ установлен на %@", key.name, destination))
        }
        let message = (result.stdout + "\n" + result.stderr)
            .split(whereSeparator: \.isNewline)
            .suffix(6)
            .joined(separator: "\n")
        return .failure(KeyInstallError(message.isEmpty ? L10n.f("ssh-copy-id завершился с кодом %d", Int(result.status)) : message))
    }
}

struct KeyInstallError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

enum KeyError: LocalizedError {
    case invalidName
    case exists
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidName: return L10n.t("Имя ключа может содержать только буквы, цифры, точку, дефис и подчёркивание")
        case .exists: return L10n.t("Файл ключа уже существует")
        case .failed(let text): return text
        }
    }
}
