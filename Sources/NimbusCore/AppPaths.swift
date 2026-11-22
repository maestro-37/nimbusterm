import Foundation

public enum AppPaths {
    public static let bundleID = "com.maestro37.nimbusterm"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("NimbusTerm", isDirectory: true)
    }

    public static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("NimbusTerm", isDirectory: true)
    }

    public static var libraryURL: URL {
        supportDirectory.appendingPathComponent("library.json")
    }

    /// Short path: OpenSSH control sockets have a ~104 byte limit, and
    /// "Application Support" alone eats too much of it.
    public static var controlMasterDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".nimbusterm-cm", isDirectory: true)
    }

    public static var tempDirectory: URL {
        supportDirectory.appendingPathComponent("tmp", isDirectory: true)
    }

    public static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public static func ensureControlDirectory() {
        ensureDirectory(controlMasterDirectory)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: controlMasterDirectory.path
        )
    }

    public static func expand(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        return (path as NSString).expandingTildeInPath
    }

    public static func cleanupControlSockets() {
        let manager = FileManager.default
        guard let sockets = try? manager.contentsOfDirectory(atPath: controlMasterDirectory.path) else { return }
        for socket in sockets {
            try? manager.removeItem(atPath: controlMasterDirectory.appendingPathComponent(socket).path)
        }
    }

    public static func cleanupStaleSecrets() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(atPath: tempDirectory.path) else { return }
        for file in files where file.hasPrefix("pwd-") {
            try? manager.removeItem(atPath: tempDirectory.appendingPathComponent(file).path)
        }
    }

    public static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}
