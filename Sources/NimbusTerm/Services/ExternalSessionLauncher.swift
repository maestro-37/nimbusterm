import AppKit
import Foundation
import NimbusCore

enum ExternalSessionLauncher {
    struct LaunchResult {
        var message: String
        var isError: Bool
    }

    @MainActor
    static func open(_ session: Session) -> LaunchResult {
        switch session.protocolKind {
        case .vnc:
            var components = URLComponents()
            components.scheme = "vnc"
            components.host = session.host
            components.port = session.port
            guard let url = components.url else {
                return LaunchResult(message: L10n.t("Некорректный адрес VNC"), isError: true)
            }
            if NSWorkspace.shared.open(url) {
                return LaunchResult(message: L10n.t("VNC: открыто в Screen Sharing"), isError: false)
            }
            return LaunchResult(message: L10n.t("Не найден клиент VNC. Системный Screen Sharing должен поддерживать vnc://"), isError: true)
        case .rdp:
            let file = makeRDPFile(for: session)
            guard NSWorkspace.shared.urlForApplication(toOpen: file) != nil else {
                return LaunchResult(
                    message: L10n.t("Не найден клиент RDP. Установите Windows App (Microsoft Remote Desktop) из App Store."),
                    isError: true
                )
            }
            if NSWorkspace.shared.open(file) {
                return LaunchResult(message: L10n.t("RDP: открыто во внешнем клиенте"), isError: false)
            }
            return LaunchResult(message: L10n.t("Не удалось открыть .rdp-файл"), isError: true)
        default:
            return LaunchResult(message: L10n.t("Сессия не является внешней"), isError: true)
        }
    }

    static func makeRDPFile(for session: Session) -> URL {
        AppPaths.ensureDirectory(AppPaths.cacheDirectory.appendingPathComponent("rdp", isDirectory: true))
        let safeName = session.displayName.replacingOccurrences(of: "/", with: "-")
        let url = AppPaths.cacheDirectory
            .appendingPathComponent("rdp", isDirectory: true)
            .appendingPathComponent("\(safeName)-\(session.id.uuidString.prefix(8)).rdp")
        var lines = [
            "full address:s:\(session.host):\(session.port)",
            "screen mode id:i:2",
            "use multimon:i:1",
            "prompt for credentials:i:1",
            "authentication level:i:2",
            "enablecredsspsupport:i:1"
        ]
        if !session.user.isEmpty {
            lines.append("username:s:\(session.user)")
        }
        let content = lines.joined(separator: "\r\n") + "\r\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
