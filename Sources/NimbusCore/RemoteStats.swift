import Foundation

public struct RemoteStats: Equatable, Sendable {
    public var load1: Double?
    public var load5: Double?
    public var load15: Double?
    public var memoryUsedMB: Int?
    public var memoryTotalMB: Int?
    public var diskUsedPercent: Int?
    public var uptime: String?
    public var updatedAt: Date

    public init(
        load1: Double? = nil,
        load5: Double? = nil,
        load15: Double? = nil,
        memoryUsedMB: Int? = nil,
        memoryTotalMB: Int? = nil,
        diskUsedPercent: Int? = nil,
        uptime: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
        self.memoryUsedMB = memoryUsedMB
        self.memoryTotalMB = memoryTotalMB
        self.diskUsedPercent = diskUsedPercent
        self.uptime = uptime
        self.updatedAt = updatedAt
    }

    public var summary: String {
        var parts: [String] = []
        if let load1 { parts.append(String(format: "load %.2f", load1)) }
        if let used = memoryUsedMB, let total = memoryTotalMB, total > 0 {
            parts.append("RAM \(used)/\(total) MB")
        }
        if let diskUsedPercent { parts.append("disk \(diskUsedPercent)%") }
        if let uptime, !uptime.isEmpty { parts.append(uptime) }
        return parts.joined(separator: "  ·  ")
    }
}

public enum RemoteStatsParser {
    public static let command = "LC_ALL=C sh -c 'uptime; echo @@; cat /proc/loadavg 2>/dev/null; echo @@; (free -m 2>/dev/null || vm_stat 2>/dev/null) | head -8; echo @@; df -P / 2>/dev/null | tail -1'"

    public static func parse(_ output: String) -> RemoteStats {
        var stats = RemoteStats()
        let chunks = output.components(separatedBy: "@@")
        if let uptime = chunks.first {
            stats.uptime = parseUptime(uptime)
        }
        if chunks.count > 1 {
            let values = chunks[1].split(whereSeparator: \.isWhitespace)
            if values.count >= 3 {
                stats.load1 = Double(values[0])
                stats.load5 = Double(values[1])
                stats.load15 = Double(values[2])
            }
        }
        if chunks.count > 2 {
            parseMemory(chunks[2], into: &stats)
        }
        if chunks.count > 3 {
            stats.diskUsedPercent = parseDisk(chunks[3])
        }
        stats.updatedAt = Date()
        return stats
    }

    static func parseUptime(_ text: String) -> String? {
        guard let upRange = text.range(of: " up ") else { return nil }
        var tail = String(text[upRange.upperBound...])
        for marker in ["load average", "load averages"] {
            if let r = tail.range(of: marker) { tail = String(tail[..<r.lowerBound]) }
        }
        tail = tail.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
        tail = tail.replacingOccurrences(
            of: #",\s+\d+\s+users?$"#,
            with: "",
            options: .regularExpression
        )
        return tail.isEmpty ? nil : tail
    }

    static func parseMemory(_ text: String, into stats: inout RemoteStats) {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first == "Mem:" , fields.count >= 3 else { continue }
            guard let total = Int(fields[1]), let used = Int(fields[2]) else { continue }
            stats.memoryTotalMB = total
            if fields.count >= 7, let available = Int(fields[6]) {
                stats.memoryUsedMB = max(0, total - available)
            } else {
                stats.memoryUsedMB = used
            }
            return
        }
    }

    static func parseDisk(_ text: String) -> Int? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 5 else { return nil }
        return Int(fields[4].replacingOccurrences(of: "%", with: ""))
    }
}
