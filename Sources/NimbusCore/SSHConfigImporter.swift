import Foundation

public enum SSHConfigImporter {
    public static func parse(data: Data, defaultUser: String = "") -> [Session] {
        parse(text: String(data: data, encoding: .utf8) ?? "", defaultUser: defaultUser)
    }

    public static func parse(text: String, defaultUser: String = "") -> [Session] {
        var sessions: [Session] = []
        var aliases: [String] = []
        var settings: [(String, String)] = []
        var matchBlock = false

        func flush() {
            defer {
                aliases = []
                settings = []
            }
            guard !aliases.isEmpty, !matchBlock else { return }
            func setting(_ key: String) -> String? {
                settings.last { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
            }
            let hostName = setting("HostName")
            let user = setting("User") ?? defaultUser
            guard !user.hasPrefix("-") else { return }
            let port = Int(setting("Port") ?? "") ?? 22
            let identity = setting("IdentityFile") ?? ""
            let proxy = setting("ProxyJump") ?? ""
            for alias in aliases {
                guard !alias.contains("*"), !alias.contains("?"), !alias.hasPrefix("!"), !alias.hasPrefix("-") else { continue }
                let resolvedHost = (hostName ?? alias)
                    .replacingOccurrences(of: "%h", with: alias)
                    .replacingOccurrences(of: "%r", with: user)
                guard !resolvedHost.hasPrefix("-") else { continue }
                var session = Session(name: alias)
                session.protocolKind = .ssh
                session.host = resolvedHost
                session.user = user
                session.port = port
                session.identityFile = AppPaths.expand(identity)
                session.proxyJump = proxy
                session.auth = identity.isEmpty ? .agent : .key
                sessions.append(session)
            }
        }

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard let keyPart = parts.first else { continue }
            let key = String(keyPart)
            let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            switch key.lowercased() {
            case "host":
                flush()
                aliases = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                matchBlock = false
            case "match":
                flush()
                matchBlock = true
            case "include":
                continue
            default:
                if !matchBlock, !aliases.isEmpty {
                    settings.append((key, value))
                }
            }
        }
        flush()
        return sessions
    }
}
