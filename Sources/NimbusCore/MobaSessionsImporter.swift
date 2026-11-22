import Foundation

public struct MobaImportResult: Sendable {
    public var folders: [Folder] = []
    public var sessions: [Session] = []
    public var skipped: Int = 0

    public init() {}
}

public enum MobaSessionsImporter {
    /// Decodes the substitutions MobaXterm applies inside its INI values.
    public static func decodeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "__PTVIRG__", with: ";")
            .replacingOccurrences(of: "__DBLQUO__", with: "\"")
            .replacingOccurrences(of: "__PIPE__", with: "|")
            .replacingOccurrences(of: "__PERCENT__", with: "%")
            .replacingOccurrences(of: "__DIEZE__", with: "#")
            .replacingOccurrences(of: "_CurrentDrive_", with: "C:")
    }

    public static func parse(data: Data, rootName: String = "MobaXterm") -> MobaImportResult {
        parse(text: INIParser.decode(data), rootName: rootName)
    }

    public static func parse(text: String, rootName: String = "MobaXterm") -> MobaImportResult {
        var result = MobaImportResult()
        let root = Folder(name: rootName)
        result.folders.append(root)
        var folderCache: [String: UUID] = [:]

        func folder(for subRep: String) -> UUID {
            let components = subRep.split(separator: "\\").map(String.init).filter { !$0.isEmpty }
            guard !components.isEmpty else { return root.id }
            var parent = root.id
            var path = ""
            for component in components {
                path += "/" + component
                if let existing = folderCache[path] {
                    parent = existing
                } else {
                    let folder = Folder(name: component, parentID: parent)
                    result.folders.append(folder)
                    folderCache[path] = folder.id
                    parent = folder.id
                }
            }
            return parent
        }

        for section in INIParser.parse(text) where section.name.hasPrefix("Bookmarks") {
            let targetFolder = folder(for: section.value("SubRep") ?? "")
            for entry in section.entries {
                if entry.key.caseInsensitiveCompare("SubRep") == .orderedSame { continue }
                if entry.key.caseInsensitiveCompare("ImgNum") == .orderedSame { continue }
                if let session = parseSession(name: entry.key, record: entry.value) {
                    var session = session
                    session.folderID = targetFolder
                    result.sessions.append(session)
                } else {
                    result.skipped += 1
                }
            }
        }
        return result
    }

    public static func parseSession(name: String, record: String) -> Session? {
        guard record.hasPrefix("#") else { return nil }
        let fields = record.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3 else { return nil }
        let groups = fields[2].split(separator: "%", omittingEmptySubsequences: false).map(String.init)
        guard let type = Int(groups.first ?? "") else { return nil }

        func field(_ index: Int) -> String {
            guard index < groups.count else { return "" }
            return decodeValue(groups[index])
        }
        func intField(_ index: Int) -> Int? { Int(field(index)) }

        var session = Session(name: decodeValue(name))
        switch type {
        case 0:
            session.protocolKind = .ssh
        case 4:
            session.protocolKind = .rdp
        case 5:
            session.protocolKind = .vnc
        case 7:
            session.protocolKind = .sftp
        default:
            return nil
        }
        session.host = field(1)
        session.port = intField(2) ?? session.protocolKind.defaultPort
        session.user = field(3)
        guard !session.host.isEmpty, !session.host.hasPrefix("-"), !session.user.hasPrefix("-") else { return nil }

        switch session.protocolKind {
        case .ssh:
            session.x11 = field(5) == "-1" ? .untrusted : .off
            session.compression = field(6) == "-1"
            session.startupCommand = field(7)
            session.identityFile = field(14)
            if session.identityFile.lowercased().hasSuffix(".ppk") { session.identityFile = "" }
            session.auth = session.identityFile.isEmpty ? .agent : .key
        case .sftp:
            session.identityFile = field(9)
            session.auth = session.identityFile.isEmpty ? .agent : .key
        case .rdp, .vnc:
            break
        default:
            break
        }

        if let terminalTypes = fields[safe: 3]?.split(separator: "%"), terminalTypes.count > 13 {
            let term = String(terminalTypes[13])
            if !term.isEmpty && term != "xterm" { session.terminalType = term }
        }
        if let logFlag = fields[safe: 3]?.split(separator: "%"), logFlag.count > 11 {
            session.logSession = String(logFlag[11]) == "-1"
        }
        return session
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
