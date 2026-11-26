import AppKit
import Foundation
import NimbusCore

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct PendingHostTrust: Identifiable {
    let id = UUID()
    var session: Session
}

@MainActor
final class AppModel: ObservableObject {
    @Published var library: Library {
        didSet {
            guard ready else { return }
            scheduleSave()
            applySettingsToTabs()
        }
    }
    @Published var tabs: [WorkspaceTab] = []
    @Published var activeTabID: UUID?
    @Published var draggingTabID: UUID?
    @Published var selectedID: UUID?
    @Published var showSessionEditor = false
    @Published var editingSession: Session?
    @Published var showQuickConnect = false
    @Published var showPreferences = false
    @Published var showSnippets = false
    @Published var showTunnels = false
    @Published var showKeys = false
    @Published var showImport = false
    @Published var alert: AppAlert?
    @Published var statusMessage: String?
    @Published var sidebarVisible = true
    @Published var pendingCloseTabID: UUID?
    @Published var pendingHostTrust: PendingHostTrust?
    @Published var saveBlocked = false
    @Published var quarantineFailed = false

    let helperURL: URL
    let tunnels = TunnelManager()
    let monitor = MonitorService()
    private let store: LibraryStore
    private var ready = false
    private var saveWorkItem: DispatchWorkItem?

    init(store: LibraryStore = LibraryStore()) {
        let isSelfTest = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--self-test") }
        if isSelfTest {
            self.store = LibraryStore(
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("nimbusterm-selftest-\(UUID().uuidString).json")
            )
            self.library = Library()
            self.helperURL = Askpass.ensureHelper()
            return
        }
        self.store = store
        self.helperURL = Askpass.ensureHelper()
        AppPaths.ensureDirectory(AppPaths.supportDirectory)
        AppPaths.ensureControlDirectory()
        AppPaths.ensureDirectory(AppPaths.tempDirectory)
        AppPaths.cleanupStaleSecrets()
        AppPaths.cleanupControlSockets()
        var loaded = Library()
        var blocked = false
        var quarantineFailed = false
        var startupAlert: AppAlert?
        switch store.loadResult() {
        case .success(let library):
            loaded = library
        case .failure(let error):
            if let backup = store.loadBackup() {
                loaded = backup
                startupAlert = AppAlert(
                    title: "Загружена резервная копия",
                    message: L10n.f("Основной файл библиотеки повреждён. Загружена копия .bak. Повреждённый файл сохранён рядом. %@", error.localizedDescription)
                )
            } else {
                blocked = true
                startupAlert = AppAlert(
                    title: "Библиотека повреждена",
                    message: "Не удалось прочитать library.json, резервной копии нет. Сохранение остановлено, чтобы не потерять данные. Нажмите «Разрешить сохранение» в баннере, когда будете готовы начать с пустой библиотеки."
                )
            }
            if store.quarantineCorruptFile() == nil {
                quarantineFailed = true
                blocked = true
            }
        }
        if loaded.skippedRecords > 0 {
            let backup = store.copyUnreadBackup()
            blocked = true
            if backup == nil { quarantineFailed = true }
            startupAlert = AppAlert(
                title: "Библиотека прочитана частично",
                message: "Пропущено записей: \(loaded.skippedRecords). Копия исходного файла: \(backup?.lastPathComponent ?? "не создана"). Сохранение остановлено, чтобы не потерять данные. Нажмите «Разрешить сохранение», когда будете готовы."
            )
        }
        self.library = loaded
        self.saveBlocked = blocked
        self.quarantineFailed = quarantineFailed
        ready = true
        if let startupAlert {
            alert = startupAlert
        }
        if loaded.settings.restoreTabs, !loaded.openTabs.isEmpty {
            restoreTabs(loaded.openTabs)
        } else {
            newLocalTab()
        }
        monitor.onStats = { [weak self] sessionID, stats in
            self?.monitorStats[sessionID] = stats
        }
        monitor.onError = { [weak self] sessionID, message in
            guard let self, let session = self.library.sessions.first(where: { $0.id == sessionID }) else { return }
            self.statusMessage = L10n.f("Мониторинг %@: %@", session.displayName, message)
        }
        tunnels.onChange = { [weak self] in self?.objectWillChange.send() }
        syncServices()
        if loaded.openTabs.isEmpty == false {
            schedulePersist()
        }
    }

    @Published var monitorStats: [UUID: RemoteStats] = [:]

    var hasActiveWork: Bool {
        if tunnels.states.values.contains(where: { $0.isRunning }) { return true }
        return tabs.contains { tab in
            tab.controllers.values.contains(where: { $0.isRunning }) || (tab.sftpModel?.hasActiveWork ?? false)
        }
    }

    var activeTab: WorkspaceTab? {
        tabs.first { $0.id == activeTabID }
    }

    var activeController: TerminalController? {
        activeTab?.activeController
    }

    // MARK: - Library queries

    func session(id: UUID?) -> Session? {
        guard let id else { return nil }
        return library.sessions.first { $0.id == id }
    }

    func folder(id: UUID?) -> Folder? {
        guard let id else { return nil }
        return library.folders.first { $0.id == id }
    }

    func sessions(in folderID: UUID?) -> [Session] {
        library.sessions
            .filter { $0.folderID == folderID }
            .sorted {
                if $0.favorite != $1.favorite { return $0.favorite }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    func childFolders(of parentID: UUID?) -> [Folder] {
        library.folders
            .filter { $0.parentID == parentID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func folderPath(_ id: UUID?) -> String {
        guard let id, let folder = folder(id: id) else { return "" }
        let parent = folderPath(folder.parentID)
        return parent.isEmpty ? folder.name : parent + " / " + folder.name
    }

    var allSessions: [Session] {
        library.sessions.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Opening sessions

    func openSession(_ session: Session) {
        if session.protocolKind != .local && !session.isSafeDestination {
            alert = AppAlert(title: "Сессия", message: "Некорректный хост или пользователь")
            return
        }
        switch session.protocolKind {
        case .local, .rawTCP:
            openTerminal(session)
        case .ssh:
            let usesSecret = session.auth == .password
                || (session.auth == .key && (secret(for: session) ?? "").isEmpty == false)
            if usesSecret && !isHostTrusted(session) {
                pendingHostTrust = PendingHostTrust(session: session)
            } else {
                openTerminal(session, hostTrusted: isHostTrusted(session))
            }
        case .sftp:
            add(WorkspaceTab(sftp: session))
        case .rdp, .vnc:
            let result = ExternalSessionLauncher.open(session)
            add(WorkspaceTab(external: session, message: result.message))
        }
    }

    func openSFTPForActive() {
        guard let session = activeController?.session else { return }
        openSFTP(session)
    }

    func openSFTP(_ original: Session) {
        guard original.protocolKind == .ssh || original.protocolKind == .sftp else { return }
        var session = original
        session.protocolKind = .sftp
        if let existing = tabs.first(where: {
            if case .sftp(let tabSession) = $0.kind { return tabSession.id == session.id }
            return false
        }) {
            activeTabID = existing.id
            return
        }
        add(WorkspaceTab(sftp: session))
    }

    func confirmHostTrust() {
        guard let pending = pendingHostTrust else { return }
        markHostTrusted(pending.session)
        pendingHostTrust = nil
        openTerminal(pending.session, hostTrusted: true)
    }

    func newLocalTab() {
        openTerminal(Session(name: String(localized: "Локальный shell"), protocolKind: .local))
    }

    private func openTerminal(_ session: Session, hostTrusted: Bool = false) {
        let tab = WorkspaceTab(
            session: session,
            settings: library.settings,
            helperURL: helperURL,
            extraOptions: library.settings.sshExtraOptions,
            hostTrusted: hostTrusted
        )
        add(tab)
    }

    func quickConnect(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let match = library.sessions.first(where: {
            $0.displayName.caseInsensitiveCompare(trimmed) == .orderedSame
                || $0.host.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            openSession(match)
            return
        }
        var host = trimmed
        var user = ""
        var port = 22
        if let at = host.firstIndex(of: "@") {
            user = String(host[..<at])
            host = String(host[host.index(after: at)...])
        }
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            let inner = String(host[host.index(after: host.startIndex)..<close])
            let rest = host[host.index(after: close)...]
            if rest.hasPrefix(":"), let value = Int(rest.dropFirst()) { port = value }
            host = inner
        } else if let colon = host.lastIndex(of: ":"), host[host.index(after: colon)...].allSatisfy(\.isNumber) {
            port = Int(host[host.index(after: colon)...]) ?? 22
            host = String(host[..<colon])
        }
        guard !host.isEmpty, !host.hasPrefix("-"), !user.hasPrefix("-") else {
            alert = AppAlert(title: "Quick Connect", message: "Некорректный адрес")
            return
        }
        var session = Session(name: trimmed, protocolKind: .ssh, host: host, port: port, user: user)
        session.auth = .agent
        openSession(session)
    }

    func add(_ tab: WorkspaceTab) {
        tab.onEmpty = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.requestCloseTab(tab.id)
        }
        tab.onChange = { [weak self] in self?.handleTabChange() }
        tab.trustProvider = { [weak self] session in self?.isHostTrusted(session) ?? false }
        tab.secretProvider = { [weak self] session in self?.secret(for: session) }
        tabs.append(tab)
        activeTabID = tab.id
        schedulePersist()
    }

    func requestCloseTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let hasRunning = tab.controllers.values.contains { $0.isRunning } || (tab.sftpModel?.hasActiveWork ?? false)
        if library.settings.confirmClose && hasRunning {
            pendingCloseTabID = id
        } else {
            closeTab(id)
        }
    }

    func requestCloseActiveTab() {
        guard let activeTabID else { return }
        requestCloseTab(activeTabID)
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].stopAll()
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs[safe: min(index, tabs.count - 1)]?.id
        }
        handleTabChange()
    }

    func closeActiveTab() {
        guard let activeTabID else { return }
        closeTab(activeTabID)
    }

    func splitActive(axis: SplitAxis) {
        activeTab?.split(axis: axis)
        schedulePersist()
    }

    func splitActiveIntoQuad() {
        activeTab?.splitIntoQuad()
        schedulePersist()
    }

    func moveTab(_ id: UUID, toIndex index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }), !tabs.isEmpty else { return }
        let target = min(max(index, 0), tabs.count - 1)
        guard target != from else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: target)
        schedulePersist()
    }

    /// Drops a single-pane tab into another tab as a new split pane.
    /// Multi-pane tabs are ignored: split them in place instead.
    func mergeTab(_ id: UUID, into targetID: UUID, at leafID: UUID, axis: SplitAxis = .horizontal) {
        guard id != targetID,
              let index = tabs.firstIndex(where: { $0.id == id }),
              let target = tabs.first(where: { $0.id == targetID }),
              target.isTerminals,
              PaneTreeOps.leaves(tabs[index].root).count == 1,
              let sourceLeaf = PaneTreeOps.leaves(tabs[index].root).first
        else { return }
        guard target.adopt(from: tabs[index], leaf: sourceLeaf, at: leafID, axis: axis) else { return }
        tabs.remove(at: index)
        activeTabID = targetID
        schedulePersist()
    }

    func closeActiveLeaf() {
        guard let tab = activeTab else { return }
        tab.closeLeaf(tab.activeLeafID)
    }

    func toggleBroadcast() {
        activeTab?.isBroadcast.toggle()
        objectWillChange.send()
    }

    func zoomFont(by delta: Double) {
        let next = min(28, max(9, library.settings.fontSize + delta))
        guard next != library.settings.fontSize else { return }
        library.settings.fontSize = next
        applySettingsToTabs()
    }

    func applySettingsToTabs() {
        for tab in tabs {
            tab.apply(settings: library.settings)
        }
        tunnels.setExtraOptions(library.settings.sshExtraOptions)
        syncServices()
    }

    private func syncServices() {
        var running: [Session] = []
        var seen = Set<UUID>()
        for tab in tabs {
            for controller in tab.controllers.values where controller.isRunning {
                let session = library.sessions.first { $0.id == controller.session.id } ?? controller.session
                guard seen.insert(session.id).inserted else { continue }
                running.append(session)
            }
        }
        let runningIDs = Set(running.map(\.id))
        monitorStats = monitorStats.filter { runningIDs.contains($0.key) }
        monitor.sync(
            sessions: running,
            settings: library.settings,
            secretProvider: { [weak self] session in self?.secret(for: session) }
        )
    }

    private func handleTabChange() {
        schedulePersist()
        syncServices()
    }

    private func trustKey(_ session: Session) -> String {
        "trusted.\(session.host.lowercased()):\(session.port)"
    }

    func isHostTrusted(_ session: Session) -> Bool {
        UserDefaults.standard.bool(forKey: trustKey(session))
    }

    func markHostTrusted(_ session: Session) {
        let key = trustKey(session)
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
        }
        for tab in tabs {
            for (leafID, controller) in tab.controllers where controller.session.id == session.id {
                controller.hostTrusted = true
                tab.trustHost(leafID: leafID, value: true)
            }
        }
    }

    // MARK: - CRUD

    func saveSession(_ session: Session, password: String?) {
        if let index = library.sessions.firstIndex(where: { $0.id == session.id }) {
            library.sessions[index] = session
        } else {
            library.sessions.append(session)
        }
        if let password, !password.isEmpty {
            KeychainStore.set(password, account: session.id.uuidString)
            syncServices()
        }
        schedulePersist()
    }

    func deleteSession(_ session: Session) {
        KeychainStore.delete(account: session.id.uuidString)
        let toClose = tabs.filter { tabUses($0, sessionID: session.id) }.map(\.id)
        for id in toClose { closeTab(id) }
        library.sessions.removeAll { $0.id == session.id }
        for tab in tabs {
            tab.apply(settings: library.settings)
        }
        schedulePersist()
    }

    private func tabUses(_ tab: WorkspaceTab, sessionID: UUID) -> Bool {
        switch tab.kind {
        case .terminals:
            return tab.leafSessions.values.contains { $0.id == sessionID }
        case .sftp(let session):
            return session.id == sessionID
        case .external(let session, _):
            return session.id == sessionID
        }
    }

    func duplicateSession(_ session: Session) {
        var copy = session
        copy.id = UUID()
        copy.name = session.displayName + " copy"
        copy.createdAt = Date()
        if let secret = KeychainStore.get(account: session.id.uuidString) {
            KeychainStore.set(secret, account: copy.id.uuidString)
        }
        library.sessions.append(copy)
        schedulePersist()
    }

    @discardableResult
    func addFolder(name: String, parentID: UUID?) -> Folder {
        let folder = Folder(name: name, parentID: parentID)
        library.folders.append(folder)
        schedulePersist()
        return folder
    }

    func renameFolder(_ folder: Folder, to name: String) {
        guard let index = library.folders.firstIndex(where: { $0.id == folder.id }) else { return }
        library.folders[index].name = name
        schedulePersist()
    }

    func deleteFolder(_ folder: Folder) {
        for session in library.sessions where session.folderID == folder.id {
            if let index = library.sessions.firstIndex(where: { $0.id == session.id }) {
                library.sessions[index].folderID = folder.parentID
            }
        }
        for child in library.folders where child.parentID == folder.id {
            if let index = library.folders.firstIndex(where: { $0.id == child.id }) {
                library.folders[index].parentID = folder.parentID
            }
        }
        library.folders.removeAll { $0.id == folder.id }
        schedulePersist()
    }

    func moveSession(_ sessionID: UUID, to folderID: UUID?) {
        guard let index = library.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        library.sessions[index].folderID = folderID
        schedulePersist()
    }

    // MARK: - Secrets

    func secret(for session: Session) -> String? {
        if let direct = KeychainStore.get(account: session.id.uuidString), !direct.isEmpty {
            return direct
        }
        // Reuse the saved password for sessions that point at the same server.
        for other in library.sessions where other.id != session.id
            && other.host == session.host
            && other.port == session.port
            && other.user == session.user {
            if let value = KeychainStore.get(account: other.id.uuidString), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    func saveSecret(_ secret: String, for session: Session) {
        KeychainStore.set(secret, account: session.id.uuidString)
        syncServices()
    }

    func deleteSecret(for session: Session) {
        KeychainStore.delete(account: session.id.uuidString)
        syncServices()
    }

    func hasSecret(for session: Session) -> Bool {
        KeychainStore.has(account: session.id.uuidString)
    }

    // MARK: - Snippets

    func sendSnippet(_ snippet: Snippet) {
        guard let tab = activeTab else { return }
        if snippet.sendToAll || tab.isBroadcast {
            for controller in tab.controllers.values {
                let text = Shell.substitute(snippet.command, session: controller.session) + "\r"
                controller.send(ArraySlice(text.utf8))
            }
        } else if let controller = tab.activeController {
            let text = Shell.substitute(snippet.command, session: controller.session) + "\r"
            controller.send(ArraySlice(text.utf8))
        }
    }

    func saveSnippet(_ snippet: Snippet) {
        if let index = library.snippets.firstIndex(where: { $0.id == snippet.id }) {
            library.snippets[index] = snippet
        } else {
            library.snippets.append(snippet)
        }
        schedulePersist()
    }

    func deleteSnippet(_ snippet: Snippet) {
        library.snippets.removeAll { $0.id == snippet.id }
        schedulePersist()
    }

    // MARK: - Import / export

    func importSSHConfig() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
        guard let data = try? Data(contentsOf: url) else {
            alert = AppAlert(title: "Импорт SSH config", message: "Файл ~/.ssh/config не найден")
            return
        }
        let imported = SSHConfigImporter.parse(data: data, defaultUser: library.settings.defaultUser)
        let existing = Set(library.sessions.map { "\($0.name.lowercased())|\($0.host.lowercased())|\($0.port)" })
        let fresh = imported.filter { !existing.contains("\($0.name.lowercased())|\($0.host.lowercased())|\($0.port)") }
        guard !fresh.isEmpty else {
            alert = AppAlert(title: "Импорт SSH config", message: "Новых сессий нет — все уже есть в библиотеке.")
            return
        }
        let folder: Folder
        if let existing = library.folders.first(where: { $0.parentID == nil && $0.name == "SSH config" }) {
            folder = existing
        } else {
            folder = addFolder(name: "SSH config", parentID: nil)
        }
        var sessions = fresh
        for index in sessions.indices { sessions[index].folderID = folder.id }
        library.sessions.append(contentsOf: sessions)
        schedulePersist()
        alert = AppAlert(
            title: "Импорт SSH config",
            message: L10n.f("Добавлено: %lld, пропущено дублей: %lld", sessions.count, imported.count - sessions.count)
        )
    }

    func importMoba(url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            alert = AppAlert(title: "Импорт MobaXterm", message: "Не удалось прочитать файл")
            return
        }
        let result = MobaSessionsImporter.parse(data: data)
        let existing = Set(library.sessions.map { "\($0.name.lowercased())|\($0.host.lowercased())|\($0.port)|\($0.protocolKind.rawValue)" })
        let fresh = result.sessions.filter {
            !existing.contains("\($0.name.lowercased())|\($0.host.lowercased())|\($0.port)|\($0.protocolKind.rawValue)")
        }
        guard !fresh.isEmpty else {
            alert = AppAlert(title: "Импорт MobaXterm", message: "Новых сессий нет — все уже есть в библиотеке.")
            return
        }
        library.folders.append(contentsOf: result.folders)
        library.sessions.append(contentsOf: fresh)
        schedulePersist()
        var message = L10n.f("Импортировано сессий: %lld", fresh.count)
        if result.sessions.count > fresh.count { message += L10n.f(", дублей: %lld", result.sessions.count - fresh.count) }
        if result.skipped > 0 { message += L10n.f(", пропущено: %lld", result.skipped) }
        alert = AppAlert(title: "Импорт MobaXterm", message: message)
    }

    func importLibraryJSON(url: URL) {
        do {
            let imported = try store.importLibrary(from: url)
            guard imported.skippedRecords == 0 else {
                alert = AppAlert(
                    title: "Импорт JSON",
                    message: L10n.f("В файле %lld записей не читаются. Импорт остановлен, данные не изменены.", imported.skippedRecords)
                )
                return
            }
            let folderIDs = Set(library.folders.map(\.id))
            let sessionIDs = Set(library.sessions.map(\.id))
            let tunnelIDs = Set(library.tunnels.map(\.id))
            let snippetIDs = Set(library.snippets.map(\.id))
            let folders = imported.folders.filter { !folderIDs.contains($0.id) }
            let safeSessions = imported.sessions.filter { $0.protocolKind == .local || $0.isSafeDestination }
            let sessions = safeSessions.filter { !sessionIDs.contains($0.id) }
            let tunnels = imported.tunnels.filter { !tunnelIDs.contains($0.id) }
            let snippets = imported.snippets.filter { !snippetIDs.contains($0.id) }
            library.folders.append(contentsOf: folders)
            library.sessions.append(contentsOf: sessions)
            library.tunnels.append(contentsOf: tunnels)
            library.snippets.append(contentsOf: snippets)
            schedulePersist()
            alert = AppAlert(
                title: "Импорт JSON",
                message: L10n.f("Добавлено: сессий %lld, папок %lld, туннелей %lld, сниппетов %lld. Секреты не импортируются.", sessions.count, folders.count, tunnels.count, snippets.count)
            )
        } catch {
            alert = AppAlert(title: "Импорт JSON", message: error.localizedDescription)
        }
    }

    func exportLibrary(to url: URL) {
        do {
            try store.export(library, to: url)
            alert = AppAlert(title: "Экспорт", message: L10n.f("Сохранено: %@", url.lastPathComponent))
        } catch {
            alert = AppAlert(title: "Экспорт", message: error.localizedDescription)
        }
    }

    // MARK: - Persistence

    func scheduleSave() {
        guard !saveBlocked else { return }
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func saveNow() {
        guard !saveBlocked else { return }
        do {
            try store.save(library)
        } catch {
            alert = AppAlert(title: "Сохранение", message: error.localizedDescription)
        }
    }

    func unblockSaving() {
        guard !quarantineFailed else {
            alert = AppAlert(
                title: "Сохранение заблокировано",
                message: "Не удалось отложить повреждённый library.json. Скопируйте его вручную из папки Application Support/NimbusTerm, затем перезапустите приложение."
            )
            return
        }
        saveBlocked = false
        schedulePersist()
        scheduleSave()
    }

    func schedulePersist() {
        let ids = Set(library.sessions.map(\.id))
        library.openTabs = tabs.compactMap { $0.savedTab(libraryIDs: ids) }
        scheduleSave()
    }

    private func restoreTabs(_ saved: [SavedTab]) {
        let sessions = Dictionary(uniqueKeysWithValues: library.sessions.map { ($0.id, $0) })
        var restored: [WorkspaceTab] = []
        for savedTab in saved {
            if let sftpID = savedTab.sftpSessionID, let session = sessions[sftpID] {
                restored.append(WorkspaceTab(sftp: session))
                continue
            }
            var leafSessions: [UUID: Session] = [:]
            func build(_ pane: SavedPane) -> PaneTree {
                switch pane {
                case .leaf(let sessionID):
                    let leaf = UUID()
                    if let sessionID, let session = sessions[sessionID], session.protocolKind.isTerminal {
                        leafSessions[leaf] = session
                    } else {
                        leafSessions[leaf] = Session(name: String(localized: "Локальный shell"), protocolKind: .local)
                    }
                    return .leaf(leaf)
                case .split(let axis, let first, let second):
                    return .split(axis: axis, first: build(first), second: build(second))
                }
            }
            let tree = build(savedTab.root)
            restored.append(WorkspaceTab(
                tree: tree,
                sessions: leafSessions,
                settings: library.settings,
                helperURL: helperURL,
                extraOptions: library.settings.sshExtraOptions,
                title: savedTab.title,
                trustedProvider: { [weak self] session in self?.isHostTrusted(session) ?? false }
            ))
        }
        for tab in restored {
            tab.onEmpty = { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.requestCloseTab(tab.id)
            }
            tab.onChange = { [weak self] in self?.handleTabChange() }
            tab.trustProvider = { [weak self] session in self?.isHostTrusted(session) ?? false }
            tab.secretProvider = { [weak self] session in self?.secret(for: session) }
        }
        tabs = restored
        activeTabID = restored.first?.id
    }

    func shutdown() {
        persistTabsNow()
        saveNow()
        for tab in tabs { tab.stopAll() }
        tunnels.stopAll()
        monitor.stopAll()
        AppPaths.cleanupControlSockets()
        AppPaths.cleanupStaleSecrets()
    }

    private func persistTabsNow() {
        let ids = Set(library.sessions.map(\.id))
        library.openTabs = tabs.compactMap { $0.savedTab(libraryIDs: ids) }
    }

    func startAutostartTunnels() {
        tunnels.startAutostart(
            tunnels: library.tunnels,
            sessions: library.sessions,
            secretProvider: { [weak self] session in self?.secret(for: session) }
        )
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
