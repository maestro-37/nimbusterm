import Foundation

public enum Askpass {
    private static let helperName = "nimbusterm-askpass.sh"
    private static let keepHelperName = "nimbusterm-askpass-keep.sh"

    /// Writes the askpass helper once per app launch and returns its path.
    /// `keep: true` leaves the password file in place, for a long-lived ssh process.
    public static func ensureHelper(keep: Bool = false) -> URL {
        AppPaths.ensureDirectory(AppPaths.tempDirectory)
        let url = AppPaths.tempDirectory.appendingPathComponent(keep ? keepHelperName : helperName)
        let script = """
        #!/bin/sh
        f="${NIMBUSTERM_ASKPASS_FILE:-}"
        [ -n "$f" ] && [ -r "$f" ] || exit 1
        cat "$f"
        \(keep ? "" : "rm -f \"$f\"")
        """
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Creates a 0600 password file for one ssh process. Delete it as soon as the process exits.
    public static func makeContext(password: String, helper: URL) throws -> AskpassContext {
        AppPaths.ensureDirectory(AppPaths.tempDirectory)
        AppPaths.ensureDirectory(AppPaths.tempDirectory)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: AppPaths.tempDirectory.path)
        let file = AppPaths.tempDirectory.appendingPathComponent("pwd-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: file.path,
            contents: password.data(using: .utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw NSError(domain: "NimbusTerm", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать временный файл для пароля"])
        }
        return AskpassContext(helper: helper.path, passwordFile: file.path)
    }

    public static func cleanup(_ context: AskpassContext?) {
        guard let context else { return }
        try? FileManager.default.removeItem(atPath: context.passwordFile)
    }

    public static func environment(_ context: AskpassContext?) -> [String: String] {
        context?.environment ?? [:]
    }
}
