import Foundation

public struct INIEntry: Sendable {
    public var key: String
    public var value: String
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct INISection: Sendable {
    public var name: String
    public var entries: [INIEntry]
    public init(name: String, entries: [INIEntry] = []) {
        self.name = name
        self.entries = entries
    }

    public func value(_ key: String) -> String? {
        entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

public enum INIParser {
    public static func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(data: data, encoding: .windowsCP1252) ?? ""
    }

    public static func parse(_ text: String) -> [INISection] {
        var sections: [INISection] = []
        var current = INISection(name: "")
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                if !current.name.isEmpty || !current.entries.isEmpty { sections.append(current) }
                current = INISection(name: String(line.dropFirst().dropLast()))
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            line = ""
            current.entries.append(INIEntry(key: key, value: value))
        }
        if !current.name.isEmpty || !current.entries.isEmpty { sections.append(current) }
        return sections
    }
}
