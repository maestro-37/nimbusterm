import AppKit
import Foundation
import NimbusCore
import SwiftTerm

final class BroadcastTerminalView: LocalProcessTerminalView {
    var willSend: ((ArraySlice<UInt8>) -> Void)?
    var onFocus: (() -> Void)?
    var acceptsInput = false

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard acceptsInput else { return }
        willSend?(data)
        super.send(source: source, data: data)
    }
}

@MainActor
final class TerminalController: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let session: Session
    let view: BroadcastTerminalView

    @Published private(set) var title: String
    @Published private(set) var isRunning = false
    @Published private(set) var started = false
    @Published private(set) var exitCode: Int32?
    @Published private(set) var warning: String?
    @Published private(set) var isLogging = false

    var autoStart = true
    var hostTrusted: Bool
    var trustProvider: (() -> Bool)?
    var secretProvider: (() -> String?)?
    var onTitle: ((String) -> Void)?
    var onInput: ((ArraySlice<UInt8>) -> Void)?
    var onTerminated: (() -> Void)?
    var onStateChange: (() -> Void)?
    var onFocus: (() -> Void)?

    private var askpass: AskpassContext?
    private var logDirectory: URL?
    private var logDestination: URL?
    private var logStartDate = Date()
    private var helperURL: URL
    private var settings: AppSettings

    init(session: Session, settings: AppSettings, helperURL: URL, hostTrusted: Bool = false) {
        self.session = session
        self.helperURL = helperURL
        self.settings = settings
        self.hostTrusted = hostTrusted
        self.title = session.displayName
        let font = Theme.font(settings)
        let options = TerminalOptions(
            termName: session.terminalType,
            cursorStyle: .blinkBlock,
            scrollback: max(500, settings.scrollback)
        )
        self.view = BroadcastTerminalView(frame: .zero, font: font, options: options)
        super.init()
        view.processDelegate = self
        view.willSend = { [weak self] data in self?.onInput?(data) }
        view.onFocus = { [weak self] in self?.onFocus?() }
        apply(settings: settings)
    }

    func apply(settings: AppSettings) {
        self.settings = settings
        view.font = Theme.font(settings)
        let palette = Theme.palette(for: settings.theme)
        view.nativeForegroundColor = palette.foreground
        view.nativeBackgroundColor = palette.background
        view.caretColor = palette.cursor
        view.selectedTextBackgroundColor = palette.selection
        if let ansi = Theme.ansiPalette(for: settings.theme) {
            view.installColors(ansi)
        }
    }

    func startIfNeeded() {
        if autoStart { start() }
    }

    func start() {
        guard !started else { return }
        started = true
        exitCode = nil
        warning = nil
        if session.x11 != .off {
            let xquartz = "/opt/X11/bin/xset"
            if !FileManager.default.fileExists(atPath: xquartz) {
                warning = L10n.t("XQuartz не установлен — X11-приложения не смогут открыться. Установите XQuartz.")
            }
        }
        if settingsLoggingEnabled() { beginLogging() }

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SSH_ASKPASS")
        environment.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
        environment["TERM"] = session.terminalType
        environment["COLORTERM"] = "truecolor"

        let secret = secretProvider?() ?? KeychainStore.get(account: session.id.uuidString)
        let trusted = trustProvider?() ?? hostTrusted
        hostTrusted = trusted
        let usesSecret = trusted && secret != nil && !(secret ?? "").isEmpty
        if session.auth == .password && (secret ?? "").isEmpty {
            warning = L10n.t("Пароль не сохранён в Keychain — ssh спросит его в терминале. Сохраните пароль в редакторе сессии.")
        } else if secret != nil && !trusted {
            warning = L10n.t("Host key не подтверждён — автопароль отключён. Подключитесь и нажмите «Доверять хосту (автопароль)».")
        }
        if usesSecret, let secret, !secret.isEmpty, let context = try? Askpass.makeContext(password: secret, helper: helperURL) {
            askpass = context
            for (key, value) in context.environment { environment[key] = value }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                Askpass.cleanup(self?.askpass)
                self?.askpass = nil
            }
        }
        let environmentArray = environment.map { "\($0.key)=\($0.value)" }

        switch session.protocolKind {
        case .local:
            let shell = environment["SHELL"] ?? "/bin/zsh"
            view.startProcess(executable: shell, args: ["-l"], environment: environmentArray)
        case .ssh:
            let controlDir = AppPaths.controlMasterDirectory.path
            AppPaths.ensureControlDirectory()
            let args = SSHCommandBuilder.terminalArguments(
                for: session,
                controlDirectory: controlDir,
                extraOptions: currentExtraOptions(),
                acceptNewHostKey: usesSecret
            )
            view.startProcess(executable: SSHCommandBuilder.sshPath, args: args, environment: environmentArray)
        case .rawTCP:
            view.startProcess(
                executable: SSHCommandBuilder.ncPath,
                args: [session.host, String(session.port)],
                environment: environmentArray
            )
        default:
            warning = "Этот тип сессии не открывается в терминале"
            return
        }
        view.acceptsInput = true
        isRunning = true
        onStateChange?()
    }

    func stop() {
        view.terminate()
        cleanupSecrets()
    }

    func flushLogs() {
        finishLogging()
    }

    func toggleLogging() {
        if isLogging {
            finishLogging()
        } else {
            beginLogging()
        }
    }

    func send(_ data: ArraySlice<UInt8>) {
        guard isRunning else { return }
        view.process.send(data: data)
    }

    private var settingsExtraOptions = ""

    func setDefaultExtraOptions(_ value: String) {
        settingsExtraOptions = value
    }

    private func currentExtraOptions() -> String {
        settingsExtraOptions
    }

    private func settingsLoggingEnabled() -> Bool {
        session.logSession || settings.loggingEnabled
    }

    private func beginLogging() {
        guard !isLogging else { return }
        let base = AppPaths.expand(settings.logDirectory)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())
        logStartDate = Date()
        let dir = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent(".active-\(session.id.uuidString.prefix(8))-\(stamp)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            warning = L10n.f("Не удалось создать папку логов: %@", error.localizedDescription)
            return
        }
        logDirectory = dir
        isLogging = true
        logDestination = dir.deletingLastPathComponent()
            .appendingPathComponent("session-\(session.id.uuidString.prefix(8))-\(stamp).log")
        view.setHostLogging(directory: dir.path)
    }

    private func finishLogging() {
        isLogging = false
        guard let directory = logDirectory, let destination = logDestination else { return }
        logDirectory = nil
        logDestination = nil
        view.setHostLogging(directory: nil)

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        let sorted = files.sorted { lhs, rhs in
            let l = Int(lhs.lastPathComponent.split(separator: "-").last ?? "") ?? 0
            let r = Int(rhs.lastPathComponent.split(separator: "-").last ?? "") ?? 0
            return l < r
        }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        var data = Data()
        let header = "# NimbusTerm session \(session.displayName) \(session.destination) started \(logStartDate.formatted(date: .numeric, time: .standard))\n"
        data.append(header.data(using: .utf8) ?? Data())
        for file in sorted {
            if let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date {
                data.append("[\(timeFormatter.string(from: date))] ".data(using: .utf8) ?? Data())
            }
            if let chunk = try? Data(contentsOf: file) {
                data.append(chunk)
                if !chunk.isEmpty, chunk.last != 0x0A { data.append(0x0A) }
            }
        }
        if !data.isEmpty {
            do {
                try data.write(to: destination)
                try? FileManager.default.removeItem(at: directory)
            } catch {
                warning = L10n.f("Не удалось записать лог: %@", error.localizedDescription)
            }
        } else {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func cleanupSecrets() {
        Askpass.cleanup(askpass)
        askpass = nil
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard !title.isEmpty else { return }
        self.title = title
        onTitle?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        self.exitCode = exitCode
        view.acceptsInput = false
        cleanupSecrets()
        finishLogging()
        onStateChange?()
        onTerminated?()
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        isRunning = false
        warning = L10n.f("Не удалось запустить процесс: %@", String(describing: error))
        view.acceptsInput = false
        cleanupSecrets()
        finishLogging()
        onStateChange?()
    }

    var hasSavedSecret: Bool {
        KeychainStore.has(account: session.id.uuidString)
    }

    func forgetSavedSecretAndRestart() {
        KeychainStore.delete(account: session.id.uuidString)
        cleanupSecrets()
        started = false
        exitCode = nil
        start()
    }

    func restart() {
        guard !isRunning else { return }
        started = false
        exitCode = nil
        start()
    }
}
