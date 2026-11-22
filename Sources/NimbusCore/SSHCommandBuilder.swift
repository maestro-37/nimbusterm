import Foundation

public struct AskpassContext: Sendable {
    public var helper: String
    public var passwordFile: String

    public init(helper: String, passwordFile: String) {
        self.helper = helper
        self.passwordFile = passwordFile
    }

    public var environment: [String: String] {
        [
            "SSH_ASKPASS": helper,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ":0",
            "NIMBUSTERM_ASKPASS_FILE": passwordFile
        ]
    }
}

public enum SSHCommandBuilder {
    public static let sshPath = "/usr/bin/ssh"
    public static let sftpPath = "/usr/bin/sftp"
    public static let sshKeygenPath = "/usr/bin/ssh-keygen"
    public static let sshCopyIDPath = "/usr/bin/ssh-copy-id"
    public static let ncPath = "/usr/bin/nc"

    private static func configQuote(_ value: String) -> String {
        guard value.contains(" ") || value.contains("\t") || value.contains("\"")
                || value.contains("#") || value.contains("\n") || value.contains("\r") else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func destination(for session: Session) -> String {
        session.user.isEmpty ? session.host : "\(session.user)@\(session.host)"
    }

    private static func baseOptions(
        for session: Session,
        controlDirectory: String,
        nonInteractive: Bool,
        extraOptions: String,
        multiplex: Bool = true,
        acceptNewHostKey: Bool = false
    ) -> [String] {
        var args: [String] = []
        args += ["-o", "ConnectTimeout=10"]
        let keepalive = session.keepalive > 0 ? session.keepalive : 30
        args += ["-o", "ServerAliveInterval=\(keepalive)", "-o", "ServerAliveCountMax=3"]
        args += ["-o", "TCPKeepAlive=yes"]
        if multiplex {
            args += ["-o", "ControlMaster=auto"]
            args += ["-o", "ControlPath=\"\(controlDirectory)/%C\""]
            args += ["-o", "ControlPersist=300"]
        }
        args += ["-o", (nonInteractive || acceptNewHostKey) ? "StrictHostKeyChecking=accept-new" : "StrictHostKeyChecking=ask"]
        if session.compression { args.append("-C") }
        if !session.proxyJump.isEmpty { args += ["-J", session.proxyJump] }
        if session.port > 0 { args += ["-p", String(session.port)] }
        if !session.user.isEmpty { args += ["-l", session.user] }
        if !session.environment.isEmpty {
            for key in session.environment.keys.sorted() where !key.contains("=") {
                args += ["-o", "SetEnv=\(key)=\(configQuote(session.environment[key] ?? ""))"]
            }
        }
        switch session.auth {
        case .key:
            if !session.identityFile.isEmpty {
                args += ["-i", AppPaths.expand(session.identityFile)]
                args += ["-o", "IdentitiesOnly=yes"]
            }
        case .password:
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive"]
        case .agent:
            break
        }
        args += Shell.split(session.extraArgs)
        args += Shell.split(extraOptions)
        return args
    }

    /// Arguments for an interactive terminal session.
    public static func terminalArguments(
        for session: Session,
        controlDirectory: String,
        extraOptions: String = "",
        acceptNewHostKey: Bool = false
    ) -> [String] {
        var args = baseOptions(
            for: session,
            controlDirectory: controlDirectory,
            nonInteractive: false,
            extraOptions: extraOptions,
            acceptNewHostKey: acceptNewHostKey
        )
        if let flag = session.x11.flag { args.append(flag) }
        args.append("--")
        args.append(destination(for: session))
        let startup = session.startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !startup.isEmpty { args.append(startup) }
        return args
    }

    /// Arguments for a non-interactive exec channel (monitoring, one-shot commands).
    public static func execArguments(
        for session: Session,
        controlDirectory: String,
        remoteCommand: String,
        extraOptions: String = ""
    ) -> [String] {
        var args = baseOptions(
            for: session,
            controlDirectory: controlDirectory,
            nonInteractive: true,
            extraOptions: extraOptions
        )
        args.append("--")
        args.append(destination(for: session))
        args.append(remoteCommand)
        return args
    }

    public static func sftpArguments(
        for session: Session,
        controlDirectory: String,
        extraOptions: String = ""
    ) -> [String] {
        var args: [String] = []
        args += ["-o", "ConnectTimeout=10"]
        args += ["-o", "ControlMaster=auto"]
        args += ["-o", "ControlPath=\"\(controlDirectory)/%C\""]
        args += ["-o", "ControlPersist=300"]
        args += ["-o", "StrictHostKeyChecking=accept-new"]
        if session.compression { args.append("-C") }
        if !session.proxyJump.isEmpty { args += ["-J", session.proxyJump] }
        if session.port > 0 { args += ["-P", String(session.port)] }
        if !session.user.isEmpty { args += ["-o", "User=\(session.user)"] }
        if session.auth == .key && !session.identityFile.isEmpty {
            args += ["-i", AppPaths.expand(session.identityFile)]
            args += ["-o", "IdentitiesOnly=yes"]
        }
        if session.auth == .password {
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive"]
        }
        args += Shell.split(session.extraArgs)
        args += Shell.split(extraOptions)
        args.append("--")
        args.append(destination(for: session))
        return args
    }

    public static func tunnelArguments(
        for tunnel: Tunnel,
        session: Session,
        controlDirectory: String,
        extraOptions: String = ""
    ) -> [String] {
        var args = baseOptions(
            for: session,
            controlDirectory: controlDirectory,
            nonInteractive: true,
            extraOptions: extraOptions,
            multiplex: false
        )
        args.append("-N")
        args += ["-o", "ExitOnForwardFailure=yes"]
        switch tunnel.kind {
        case .local: args += ["-L", tunnel.specArgument]
        case .remote: args += ["-R", tunnel.specArgument]
        case .dynamic: args += ["-D", tunnel.specArgument]
        }
        args.append("--")
        args.append(destination(for: session))
        return args
    }

    /// Command line for quick `ssh` copies to the clipboard.
    public static func printableCommand(for session: Session) -> String {
        let parts = ["ssh"]
            + (session.port > 0 && session.port != 22 ? ["-p", String(session.port)] : [])
            + (session.identityFile.isEmpty ? [] : ["-i", AppPaths.expand(session.identityFile)])
            + [destination(for: session)]
        func quoted(_ value: String) -> String {
            let needsQuotes = value.rangeOfCharacter(from: CharacterSet(charactersIn: " '\"$`\\!#&|;()<>")) != nil
            return needsQuotes ? Shell.quote(value) : value
        }
        return parts.map(quoted).joined(separator: " ")
    }
}
