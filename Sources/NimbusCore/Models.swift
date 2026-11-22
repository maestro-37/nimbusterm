import Foundation

public enum SessionProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case local, ssh, sftp, rawTCP, rdp, vnc

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .local: return String(localized: "Локальный shell")
        case .ssh: return "SSH"
        case .sftp: return "SFTP"
        case .rawTCP: return "TCP"
        case .rdp: return "RDP"
        case .vnc: return "VNC"
        }
    }

    public var symbol: String {
        switch self {
        case .local: return "terminal"
        case .ssh: return "network"
        case .sftp: return "folder.badge.gearshape"
        case .rawTCP: return "cable.connector"
        case .rdp: return "display"
        case .vnc: return "rectangle.on.rectangle"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .ssh, .sftp: return 22
        case .rdp: return 3389
        case .vnc: return 5900
        case .local, .rawTCP: return 0
        }
    }

    /// Session kinds that open an embedded terminal pane.
    public var isTerminal: Bool {
        switch self {
        case .local, .ssh, .rawTCP: return true
        default: return false
        }
    }
}

public enum SSHAuth: String, Codable, CaseIterable, Identifiable, Sendable {
    case agent, key, password
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .agent: return "SSH agent / ~/.ssh/config"
        case .key: return String(localized: "Ключ")
        case .password: return String(localized: "Пароль")
        }
    }
}

public enum X11Mode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, untrusted, trusted
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .off: return String(localized: "Выкл.")
        case .untrusted: return "X11 (-X)"
        case .trusted: return String(localized: "Доверенный X11 (-Y)")
        }
    }
    public var flag: String? {
        switch self {
        case .off: return nil
        case .untrusted: return "-X"
        case .trusted: return "-Y"
        }
    }
}

public enum TunnelKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case local, remote, dynamic
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .local: return "Local (-L)"
        case .remote: return "Remote (-R)"
        case .dynamic: return "Dynamic SOCKS (-D)"
        }
    }
}

public enum SplitAxis: String, Codable, Sendable {
    case horizontal, vertical
}

public struct Folder: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}

public struct Session: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var folderID: UUID?
    public var protocolKind: SessionProtocol
    public var host: String
    public var port: Int
    public var user: String
    public var auth: SSHAuth
    public var identityFile: String
    public var proxyJump: String
    public var extraArgs: String
    public var x11: X11Mode
    public var compression: Bool
    public var keepalive: Int
    public var startupCommand: String
    public var environment: [String: String]
    public var terminalType: String
    public var logSession: Bool
    public var monitor: Bool
    public var notes: String
    public var tags: [String]
    public var favorite: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "",
        folderID: UUID? = nil,
        protocolKind: SessionProtocol = .ssh,
        host: String = "",
        port: Int = 22,
        user: String = "",
        auth: SSHAuth = .agent,
        identityFile: String = "",
        proxyJump: String = "",
        extraArgs: String = "",
        x11: X11Mode = .off,
        compression: Bool = false,
        keepalive: Int = 30,
        startupCommand: String = "",
        environment: [String: String] = [:],
        terminalType: String = "xterm-256color",
        logSession: Bool = false,
        monitor: Bool = false,
        notes: String = "",
        tags: [String] = [],
        favorite: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.folderID = folderID
        self.protocolKind = protocolKind
        self.host = host
        self.port = port
        self.user = user
        self.auth = auth
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.extraArgs = extraArgs
        self.x11 = x11
        self.compression = compression
        self.keepalive = keepalive
        self.startupCommand = startupCommand
        self.environment = environment
        self.terminalType = terminalType
        self.logSession = logSession
        self.monitor = monitor
        self.notes = notes
        self.tags = tags
        self.favorite = favorite
        self.createdAt = createdAt
    }

    public var displayName: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        switch protocolKind {
        case .local: return String(localized: "Локальный shell")
        default: return host.isEmpty ? "Без имени" : host
        }
    }

    public var destination: String {
        user.isEmpty ? host : "\(user)@\(host)"
    }

    public var isSafeDestination: Bool {
        !host.isEmpty && !host.hasPrefix("-") && !user.hasPrefix("-")
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, folderID, protocolKind, host, port, user, auth, identityFile, proxyJump,
             extraArgs, x11, compression, keepalive, startupCommand, environment, terminalType,
             logSession, monitor, notes, tags, favorite, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        name = c.value(.name, "")
        folderID = (try? c.decodeIfPresent(UUID.self, forKey: .folderID)) ?? nil
        protocolKind = c.value(.protocolKind, .ssh)
        host = c.value(.host, "")
        port = c.value(.port, 22)
        user = c.value(.user, "")
        auth = c.value(.auth, .agent)
        identityFile = c.value(.identityFile, "")
        proxyJump = c.value(.proxyJump, "")
        extraArgs = c.value(.extraArgs, "")
        x11 = c.value(.x11, .off)
        compression = c.value(.compression, false)
        keepalive = c.value(.keepalive, 30)
        startupCommand = c.value(.startupCommand, "")
        environment = c.value(.environment, [:])
        terminalType = c.value(.terminalType, "xterm-256color")
        logSession = c.value(.logSession, false)
        monitor = c.value(.monitor, false)
        notes = c.value(.notes, "")
        tags = c.value(.tags, [])
        favorite = c.value(.favorite, false)
        createdAt = c.value(.createdAt, Date())
    }
}

public struct Tunnel: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var sessionID: UUID
    public var kind: TunnelKind
    public var bindHost: String
    public var bindPort: Int
    public var targetHost: String
    public var targetPort: Int
    public var autostart: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        sessionID: UUID,
        kind: TunnelKind = .local,
        bindHost: String = "127.0.0.1",
        bindPort: Int = 8080,
        targetHost: String = "",
        targetPort: Int = 80,
        autostart: Bool = false
    ) {
        self.id = id
        self.name = name
        self.sessionID = sessionID
        self.kind = kind
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.autostart = autostart
    }

    public var displayName: String {
        name.isEmpty ? "\(kind.displayName) :\(bindPort)" : name
    }

    public var specArgument: String {
        switch kind {
        case .local: return "\(bindHost):\(bindPort):\(targetHost):\(targetPort)"
        case .remote: return "\(bindHost):\(bindPort):\(targetHost):\(targetPort)"
        case .dynamic: return "\(bindHost):\(bindPort)"
        }
    }
}

public struct Snippet: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    public var sendToAll: Bool

    public init(id: UUID = UUID(), name: String, command: String, sendToAll: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.sendToAll = sendToAll
    }
}

public enum Appearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, dark, light
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: return String(localized: "Системная")
        case .dark: return String(localized: "Тёмная")
        case .light: return String(localized: "Светлая")
        }
    }
}

public enum TerminalTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case nimbus, solarizedDark, solarizedLight, dracula, system
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .nimbus: return "Nimbus"
        case .solarizedDark: return "Solarized Dark"
        case .solarizedLight: return "Solarized Light"
        case .dracula: return "Dracula"
        case .system: return String(localized: "Как в системе")
        }
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var appearance: Appearance
    public var theme: TerminalTheme
    public var fontName: String
    public var fontSize: Double
    public var scrollback: Int
    public var defaultUser: String
    public var loggingEnabled: Bool
    public var logDirectory: String
    public var confirmClose: Bool
    public var restoreTabs: Bool
    public var sshExtraOptions: String
    public var monitorInterval: Double
    public var showHiddenFiles: Bool

    public init(
        appearance: Appearance = .dark,
        theme: TerminalTheme = .nimbus,
        fontName: String = "Menlo",
        fontSize: Double = 13,
        scrollback: Int = 10_000,
        defaultUser: String = NSUserName(),
        loggingEnabled: Bool = false,
        logDirectory: String = "~/Documents/NimbusTerm/Logs",
        confirmClose: Bool = true,
        restoreTabs: Bool = true,
        sshExtraOptions: String = "",
        monitorInterval: Double = 5,
        showHiddenFiles: Bool = false
    ) {
        self.appearance = appearance
        self.theme = theme
        self.fontName = fontName
        self.fontSize = fontSize
        self.scrollback = scrollback
        self.defaultUser = defaultUser
        self.loggingEnabled = loggingEnabled
        self.logDirectory = logDirectory
        self.confirmClose = confirmClose
        self.restoreTabs = restoreTabs
        self.sshExtraOptions = sshExtraOptions
        self.monitorInterval = monitorInterval
        self.showHiddenFiles = showHiddenFiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        appearance = c.value(.appearance, d.appearance)
        theme = c.value(.theme, d.theme)
        fontName = c.value(.fontName, d.fontName)
        fontSize = c.value(.fontSize, d.fontSize)
        scrollback = c.value(.scrollback, d.scrollback)
        defaultUser = c.value(.defaultUser, d.defaultUser)
        loggingEnabled = c.value(.loggingEnabled, d.loggingEnabled)
        logDirectory = c.value(.logDirectory, d.logDirectory)
        confirmClose = c.value(.confirmClose, d.confirmClose)
        restoreTabs = c.value(.restoreTabs, d.restoreTabs)
        sshExtraOptions = c.value(.sshExtraOptions, d.sshExtraOptions)
        monitorInterval = c.value(.monitorInterval, d.monitorInterval)
        showHiddenFiles = c.value(.showHiddenFiles, d.showHiddenFiles)
    }

    private enum CodingKeys: String, CodingKey {
        case appearance, theme, fontName, fontSize, scrollback, defaultUser, loggingEnabled,
             logDirectory, confirmClose, restoreTabs, sshExtraOptions, monitorInterval,
             showHiddenFiles
    }
}

public indirect enum SavedPane: Codable, Equatable, Sendable {
    case leaf(UUID?)
    case split(axis: SplitAxis, first: SavedPane, second: SavedPane)
}

public struct SavedTab: Codable, Equatable, Sendable {
    public var root: SavedPane
    public var title: String
    public var sftpSessionID: UUID?

    public init(root: SavedPane, title: String, sftpSessionID: UUID? = nil) {
        self.root = root
        self.title = title
        self.sftpSessionID = sftpSessionID
    }
}

public struct Library: Codable, Sendable {
    public var version: Int
    public var folders: [Folder]
    public var sessions: [Session]
    public var tunnels: [Tunnel]
    public var snippets: [Snippet]
    public var settings: AppSettings
    public var openTabs: [SavedTab]
    public var skippedRecords: Int

    public init(
        version: Int = 1,
        folders: [Folder] = [],
        sessions: [Session] = [],
        tunnels: [Tunnel] = [],
        snippets: [Snippet] = [],
        settings: AppSettings = AppSettings(),
        openTabs: [SavedTab] = [],
        skippedRecords: Int = 0
    ) {
        self.version = version
        self.folders = folders
        self.sessions = sessions
        self.tunnels = tunnels
        self.snippets = snippets
        self.settings = settings
        self.openTabs = openTabs
        self.skippedRecords = skippedRecords
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, 1)
        var skipped = 0
        func lossy<T: Decodable>(_ key: CodingKeys) -> [T] {
            guard let raw = try? c.decodeIfPresent([Lossy<T>].self, forKey: key) else { return [] }
            skipped += raw.reduce(0) { $0 + ($1.value == nil ? 1 : 0) }
            return raw.compactMap(\.value)
        }
        folders = lossy(.folders)
        sessions = lossy(.sessions)
        tunnels = lossy(.tunnels)
        snippets = lossy(.snippets)
        settings = c.value(.settings, AppSettings())
        openTabs = lossy(.openTabs)
        skippedRecords = skipped
    }

    private enum CodingKeys: String, CodingKey {
        case version, folders, sessions, tunnels, snippets, settings, openTabs
    }
}

struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        if let decoded = try? decodeIfPresent(T.self, forKey: key) { return decoded }
        return fallback
    }
}
