import Foundation

public struct SFTPEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var linkTarget: String?
    public var size: Int64
    public var permissions: String
    public var modified: Date?

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        linkTarget: String? = nil,
        size: Int64 = 0,
        permissions: String = "",
        modified: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.linkTarget = linkTarget
        self.size = size
        self.permissions = permissions
        self.modified = modified
    }
}

public enum SFTPListing {
    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^([bcdlps-][rwxStTs-]{9}[@+.]?)\s+(?:\d+|\?)\s+\S+\s+\S+\s+(\d+)\s+((?:[A-Z][a-z]{2}\s+\d{1,2}|\d{1,2}\s+[A-Z][a-z]{2})\s+(?:\d{1,2}:\d{2}|\d{4}))\s+(.+)$"#
    )

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d yyyy"
        return f
    }()

    private static let dayFirstTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM HH:mm"
        return f
    }()

    private static let dayFirstYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    public static func join(base: String, name: String) -> String {
        if base == "/" || base.isEmpty { return "/" + name }
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    /// Normalizes POSIX-style remote paths without touching the local home directory.
    public static func normalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var stack: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !stack.isEmpty { stack.removeLast() }
            default:
                stack.append(String(component))
            }
        }
        let joined = stack.joined(separator: "/")
        if isAbsolute { return "/" + joined }
        return joined
    }

    public static func parent(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/", !normalized.isEmpty else { return "/" }
        let parent = (normalized as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    public static func parse(_ output: String, basePath: String) -> [SFTPEntry] {
        var entries: [SFTPEntry] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            var line = String(rawLine)
            if let range = line.range(of: "sftp> ") { line = String(line[range.upperBound...]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("Connected to"), !line.hasPrefix("total ") else { continue }
            guard let match = lineRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            func group(_ index: Int) -> String {
                guard let r = Range(match.range(at: index), in: line) else { return "" }
                return String(line[r])
            }
            let permissions = group(1)
            let size = Int64(group(2)) ?? 0
            let dateText = group(3)
            var rawName = group(4)
            var linkTarget: String?
            if let arrow = rawName.range(of: " -> ") {
                linkTarget = String(rawName[arrow.upperBound...])
                rawName = String(rawName[..<arrow.lowerBound])
            }
            // Some servers (and macOS sftp-server) return the full path in
            // the longname field. Normalize it and never join it twice.
            let rawLast = (rawName as NSString).lastPathComponent
            guard rawLast != ".", rawLast != ".." else { continue }
            let absolute = normalize(rawName.hasPrefix("/") ? rawName : join(base: basePath, name: rawName))
            let name = (absolute as NSString).lastPathComponent
            guard !name.isEmpty, !name.contains("\n"), !name.contains("\r") else { continue }
            let isDirectory = permissions.hasPrefix("d")
            let isSymlink = permissions.hasPrefix("l")
            let modified = timeFormatter.date(from: dateText)
                ?? yearFormatter.date(from: dateText)
                ?? dayFirstTimeFormatter.date(from: dateText)
                ?? dayFirstYearFormatter.date(from: dateText)
            entries.append(SFTPEntry(
                name: name,
                path: absolute,
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                linkTarget: linkTarget,
                size: size,
                permissions: permissions,
                modified: modified
            ))
        }
        return entries.sorted {
            if $0.name.hasPrefix(".") != $1.name.hasPrefix(".") { return !$0.name.hasPrefix(".") }
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func parseWorkingDirectory(_ output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: "Remote working directory: ") {
                return normalize(String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
            if line.hasPrefix("/") { return normalize(line) }
        }
        return nil
    }
}
