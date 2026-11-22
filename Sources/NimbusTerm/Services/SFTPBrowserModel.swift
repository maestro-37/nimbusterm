import Darwin
import AppKit
import Foundation
import NimbusCore

@MainActor
final class SFTPBrowserModel: ObservableObject {
    enum TransferDirection: String {
        case upload = "↑"
        case download = "↓"
    }

    enum TransferState {
        case running
        case done
        case failed
        case cancelled
    }

    struct Transfer: Identifiable {
        let id = UUID()
        var name: String
        var direction: TransferDirection
        var progress: Double?
        var state: TransferState = .running
        var detail: String = ""
    }

    let session: Session
    @Published var localPath: String = NSHomeDirectory()
    @Published var remotePath: String = ""
    @Published var localEntries: [SFTPEntry] = []
    @Published var remoteEntries: [SFTPEntry] = []
    @Published var selectedLocal: Set<String> = []
    @Published var selectedRemote: Set<String> = []
    @Published var isConnecting = false
    @Published var error: String?
    @Published var needsPassword = false
    @Published var password = ""
    @Published var rememberPassword = true
    @Published var trustWarning: String?
    @Published var overwritePrompt: String?
    private var overwriteAction: (() -> Void)?

    @Published var editorEntry: SFTPEntry?
    @Published var editorText = ""
    @Published var editorOriginal = ""
    @Published var editorLoading = false
    @Published var editorSaving = false
    @Published var editorError: String?
    @Published var editorBinary = false
    @Published var editorConflict = false
    @Published var pendingEditorEntry: SFTPEntry?
    private var editorBaseline: EditBaseline?
    @Published var transfers: [Transfer] = []

    private var client: SFTPClient?
    private weak var app: AppModel?
    private var secret: String?
    private var active: [UUID: Process] = [:]
    private var cancelled: Set<UUID> = []
    fileprivate var editTimers: [String: Timer] = [:]
    fileprivate var editDates: [String: Date] = [:]
    fileprivate var editBaselines: [String: EditBaseline] = [:]
    fileprivate var inFlightEdits: Set<String> = []

    struct EditBaseline {
        var date: Date?
        var size: Int64
    }

    init(session: Session) {
        self.session = session
    }

    private var configured = false
    private var pendingRemember = false

    func configure(app: AppModel) {
        guard !configured else { return }
        configured = true
        self.app = app
        secret = app.secret(for: session)
        client = SFTPClient(
            session: session,
            secret: secret,
            helperURL: app.helperURL,
            extraOptions: app.library.settings.sshExtraOptions
        )
        loadLocal()
        if !(app.isHostTrusted(session)) {
            trustWarning = String(
                format: NSLocalizedString("Первый контакт с %@. Host key будет принят автоматически (TOFU). Проверьте отпечаток, если сервер новый.", comment: ""),
                session.destination
            )
        }
        if session.auth == .password && (secret ?? "").isEmpty {
            needsPassword = true
        } else {
            connect()
        }
    }

    func reconnect() {
        guard let app else { return }
        KeychainStore.clearCache()
        configured = false
        needsPassword = false
        configure(app: app)
    }

    func connectWithPassword() {
        guard !password.isEmpty else { return }
        secret = password
        needsPassword = false
        pendingRemember = rememberPassword
        client = SFTPClient(
            session: session,
            secret: secret,
            helperURL: app?.helperURL ?? URL(fileURLWithPath: "/"),
            extraOptions: app?.library.settings.sshExtraOptions ?? ""
        )
        connect()
    }

    private func connect() {
        guard let client else { return }
        isConnecting = true
        error = nil
        Task {
            let result = await client.home()
            isConnecting = false
            switch result {
            case .success(let (path, entries)):
                remotePath = path
                remoteEntries = entries
                trustWarning = nil
                app?.markHostTrusted(session)
                if pendingRemember, let secret {
                    app?.saveSecret(secret, for: session)
                }
                pendingRemember = false
            case .failure(let message):
                error = message.message
                needsPassword = true
                password = ""
                pendingRemember = false
            }
        }
    }

    func loadLocal() {
        let path = localPath
        let showHidden = app?.library.settings.showHiddenFiles ?? false
        Task.detached(priority: .userInitiated) {
            let entries = LocalListing.list(path, showHidden: showHidden)
            await MainActor.run { [weak self] in self?.localEntries = entries }
        }
    }

    func loadRemote() {
        guard let client, !remotePath.isEmpty else { return }
        Task {
            let result = await client.list(remotePath)
            switch result {
            case .success(let entries): remoteEntries = entries
            case .failure(let message): error = message.message
            }
        }
    }

    func goLocal(_ path: String) {
        localPath = path
        selectedLocal = []
        loadLocal()
    }

    func goRemote(_ path: String) {
        remotePath = path
        selectedRemote = []
        loadRemote()
    }

    func localParent() {
        goLocal(SFTPListing.parent(of: localPath))
    }

    func remoteParent() {
        goRemote(SFTPListing.parent(of: remotePath))
    }

    // MARK: - Transfers

    func downloadSelected() {
        let entries = remoteEntries.filter { selectedRemote.contains($0.path) }
        guard !entries.isEmpty else {
            error = L10n.t("Выберите файлы для скачивания")
            return
        }
        requestDownload(entries)
    }

    func uploadSelected() {
        let entries = localEntries.filter { selectedLocal.contains($0.path) }
        guard !entries.isEmpty else {
            error = L10n.t("Выберите файлы для загрузки")
            return
        }
        requestUpload(entries)
    }

    func requestDownload(_ entries: [SFTPEntry]) {
        let conflicts = entries.filter {
            FileManager.default.fileExists(atPath: SFTPListing.join(base: localPath, name: $0.name))
        }
        if !conflicts.isEmpty {
            overwritePrompt = L10n.f("Локально уже есть: %@. Перезаписать?", conflictNames(conflicts))
            overwriteAction = { [weak self] in self?.performDownloads(entries) }
            return
        }
        performDownloads(entries)
    }

    func requestUpload(_ entries: [SFTPEntry]) {
        let existing = Set(remoteEntries.map(\.name))
        let conflicts = entries.filter { existing.contains($0.name) }
        if !conflicts.isEmpty {
            overwritePrompt = L10n.f("На сервере уже есть: %@. Перезаписать?", conflictNames(conflicts))
            overwriteAction = { [weak self] in self?.performUploads(entries) }
            return
        }
        performUploads(entries)
    }

    private func conflictNames(_ entries: [SFTPEntry]) -> String {
        let names = entries.prefix(3).map(\.name).joined(separator: ", ")
        return entries.count > 3 ? "\(names) и ещё \(entries.count - 3)" : names
    }

    private func performDownloads(_ entries: [SFTPEntry]) {
        let target = localPath
        Task {
            for entry in entries { await download(entry, to: target) }
        }
    }

    private func performUploads(_ entries: [SFTPEntry]) {
        let target = remotePath
        Task {
            for entry in entries { await upload(entry, to: target) }
        }
    }

    func confirmOverwrite() {
        let action = overwriteAction
        overwriteAction = nil
        overwritePrompt = nil
        action?()
    }

    func cancelOverwrite() {
        overwriteAction = nil
        overwritePrompt = nil
    }

    func download(_ entry: SFTPEntry) async {
        await download(entry, to: localPath)
    }

    func upload(_ entry: SFTPEntry) async {
        await upload(entry, to: remotePath)
    }

    func download(_ entry: SFTPEntry, to localDirectory: String) async {
        guard let client else { return }
        if entry.isDirectory {
            guard !(entry.isSymlink && entry.isDirectory) else { return }
            let directory = SFTPListing.join(base: localDirectory, name: entry.name)
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            } catch {
                self.error = error.localizedDescription
                return
            }
            let listing = await client.list(entry.path)
            switch listing {
            case .success(let children):
                for child in children { await download(child, to: directory) }
                loadLocal()
            case .failure(let error):
                self.error = error.message
            }
            return
        }
        let finalPath = SFTPListing.join(base: localDirectory, name: entry.name)
        let partPath = finalPath + ".nimbusterm-part"
        let transfer = Transfer(name: entry.name, direction: .download, progress: 0)
        transfers.append(transfer)
        let transferID = transfer.id
        let total = max(0, entry.size)
        let progressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.transfers.first(where: { $0.id == transferID })?.state == .running {
                let attributes = try? FileManager.default.attributesOfItem(atPath: partPath)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                if total > 0, let index = self.transfers.firstIndex(where: { $0.id == transferID }) {
                    self.transfers[index].progress = min(1, Double(size) / Double(total))
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        let result = await client.download(remote: entry.path, local: partPath) { process in
            DispatchQueue.main.async { self.active[transferID] = process }
        }
        progressTask.cancel()
        active.removeValue(forKey: transferID)
        if cancelled.contains(transferID) {
            try? FileManager.default.removeItem(atPath: partPath)
            finish(transferID, state: .cancelled, detail: "отменено")
            return
        }
        switch result {
        case .success:
            let destination = URL(fileURLWithPath: finalPath)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: finalPath, isDirectory: &isDirectory), isDirectory.boolValue {
                try? FileManager.default.removeItem(atPath: partPath)
                finish(transferID, state: .failed, detail: "Локальный путь занят папкой: \(finalPath)")
                return
            }
            do {
                if FileManager.default.fileExists(atPath: finalPath) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: URL(fileURLWithPath: partPath))
                } else {
                    try FileManager.default.moveItem(atPath: partPath, toPath: finalPath)
                }
                finish(transferID, state: .done, detail: "")
                loadLocal()
            } catch {
                try? FileManager.default.removeItem(atPath: partPath)
                finish(transferID, state: .failed, detail: error.localizedDescription)
            }
        case .failure(let message):
            try? FileManager.default.removeItem(atPath: partPath)
            finish(transferID, state: .failed, detail: message.message)
        }
    }

    func upload(_ entry: SFTPEntry, to remoteDirectory: String) async {
        guard let client else { return }
        guard !remoteDirectory.isEmpty else { return }
        if entry.isDirectory {
            guard !entry.isSymlink else { return }
            let directory = SFTPListing.join(base: remoteDirectory, name: entry.name)
            if case .failure(let error) = await client.mkdir(directory) {
                // Existing directory is fine; anything else is surfaced below
                // when the first child upload fails.
                _ = error
            }
            let children = await Task.detached(priority: .userInitiated) {
                LocalListing.list(entry.path, showHidden: true)
            }.value
            for child in children {
                await upload(child, to: directory)
            }
            loadRemote()
            return
        }
        let remote = SFTPListing.join(base: remoteDirectory, name: entry.name)
        let transfer = Transfer(name: entry.name, direction: .upload, progress: nil)
        transfers.append(transfer)
        let transferID = transfer.id
        let result = await client.upload(local: entry.path, remote: remote) { process in
            DispatchQueue.main.async { self.active[transferID] = process }
        }
        active.removeValue(forKey: transferID)
        if cancelled.contains(transferID) {
            finish(transferID, state: .cancelled, detail: "отменено")
            return
        }
        switch result {
        case .success:
            finish(transferID, state: .done, detail: "")
            loadRemote()
        case .failure(let message):
            finish(transferID, state: .failed, detail: message.message)
        }
    }

    private func finish(_ id: UUID, state: TransferState, detail: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = state
        transfers[index].detail = detail
        if state == .done { transfers[index].progress = 1 }
    }

    func cancel(_ transfer: Transfer) {
        cancelled.insert(transfer.id)
        active[transfer.id]?.terminate()
    }

    func clearFinished() {
        transfers.removeAll { $0.state != .running }
    }

    // MARK: - Remote operations

    func makeDirectory(name: String) {
        guard let client, !name.isEmpty else { return }
        let path = SFTPListing.join(base: remotePath, name: name)
        Task {
            let result = await client.mkdir(path)
            if case .failure(let message) = result { error = message.message } else { loadRemote() }
        }
    }

    func makeLocalDirectory(name: String) {
        guard !name.isEmpty else { return }
        let path = SFTPListing.join(base: localPath, name: name)
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            loadLocal()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func renameRemote(_ entry: SFTPEntry, to newName: String) {
        guard let client, !newName.isEmpty else { return }
        let target = SFTPListing.join(base: remotePath, name: newName)
        Task {
            let result = await client.rename(entry.path, to: target)
            if case .failure(let message) = result { error = message.message } else { loadRemote() }
        }
    }

    func chmodRemote(_ entry: SFTPEntry, mode: String) {
        guard let client, !mode.isEmpty else { return }
        Task {
            let result = await client.chmod(entry.path, mode: mode)
            if case .failure(let message) = result { error = message.message } else { loadRemote() }
        }
    }

    func deleteRemote(_ entry: SFTPEntry) {
        guard let client else { return }
        Task {
            let result = await client.delete(entry.path, isDirectory: entry.isDirectory)
            if case .failure(let message) = result { error = message.message } else { loadRemote() }
        }
    }

    func deleteLocal(_ entry: SFTPEntry) {
        do {
            try FileManager.default.removeItem(atPath: entry.path)
            loadLocal()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Embedded editor

    func requestOpenInEditor(_ entry: SFTPEntry) {
        if entry.isDirectory {
            goRemote(entry.path)
            return
        }
        if isEditorDirty {
            pendingEditorEntry = entry
            return
        }
        openInEditor(entry)
    }

    func openInEditor(_ entry: SFTPEntry, discard: Bool = false) {
        guard let client else { return }
        if isEditorDirty && !discard {
            pendingEditorEntry = entry
            return
        }
        if entry.size > 2_000_000 {
            editorEntry = entry
            editorText = ""
            editorOriginal = ""
            editorLoading = false
            editorSaving = false
            editorBinary = true
            editorConflict = false
            editorError = L10n.t("Файл больше 2 МБ — откройте внешним редактором")
            return
        }
        editorEntry = entry
        editorOriginal = ""
        editorText = ""
        editorLoading = true
        editorSaving = false
        editorError = nil
        editorBinary = false
        editorConflict = false
        editorBaseline = EditBaseline(date: entry.modified, size: entry.size)
        let cache = editorCacheURL(entry)
        Task {
            let result = await client.download(remote: entry.path, local: cache.path)
            editorLoading = false
            switch result {
            case .success:
                guard let data = try? Data(contentsOf: cache) else {
                    editorError = L10n.t("Не удалось прочитать файл")
                    return
                }
                guard data.count <= 2_000_000 else {
                    editorBinary = true
                    editorError = L10n.t("Файл больше 2 МБ — откройте внешним редактором")
                    return
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    editorBinary = true
                    editorError = L10n.t("Бинарный файл — встроенный редактор не поддерживает. Скачайте или откройте внешним редактором.")
                    return
                }
                editorText = text
                editorOriginal = text
                editorError = nil
            case .failure(let error):
                editorError = error.message
            }
        }
    }

    func saveEditor(force: Bool = false) {
        guard let client, let entry = editorEntry, !editorBinary, !editorSaving else { return }
        editorSaving = true
        editorError = nil
        Task {
            if !force, let baseline = editorBaseline {
                guard let now = await client.remoteEntry(entry.path) else {
                    editorSaving = false
                    editorConflict = true
                    editorError = L10n.t("Файл исчез на сервере — сохранение остановлено.")
                    return
                }
                if now.size != baseline.size
                    || (baseline.date != nil && now.modified != nil && now.modified! > baseline.date!) {
                    editorSaving = false
                    editorConflict = true
                    editorError = L10n.t("Файл изменён на сервере — перезагрузите или перезапишите принудительно.")
                    return
                }
            }
            let cache = self.editorCacheURL(entry)
            AppPaths.ensureDirectory(cache.deletingLastPathComponent())
            do {
                try editorText.write(to: cache, atomically: true, encoding: .utf8)
            } catch {
                editorSaving = false
                editorError = error.localizedDescription
                return
            }
            let result = await client.upload(local: cache.path, remote: entry.path)
            editorSaving = false
            switch result {
            case .success:
                editorOriginal = editorText
                editorConflict = false
                editorError = nil
                if let updated = await client.remoteEntry(entry.path) {
                    editorEntry = updated
                    editorBaseline = EditBaseline(date: updated.modified, size: updated.size)
                }
                loadRemote()
            case .failure(let error):
                editorError = error.message
            }
        }
    }

    func editorCacheURL(_ entry: SFTPEntry, name: String? = nil) -> URL {
        let directory = AppPaths.cacheDirectory
            .appendingPathComponent("edit", isDirectory: true)
            .appendingPathComponent(session.id.uuidString, isDirectory: true)
        // sftp get fails with "open local ...: No such file" if the parent is missing.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = (name ?? entry.path).replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe)
    }

    func reloadEditor() {
        guard let entry = editorEntry else { return }
        openInEditor(entry, discard: true)
    }

    func discardEditorChanges() {
        editorText = editorOriginal
        editorConflict = false
        editorError = nil
    }

    func closeEditor() {
        editorEntry = nil
        editorText = ""
        editorOriginal = ""
        editorError = nil
        editorBinary = false
        editorConflict = false
        editorBaseline = nil
    }

    func confirmDiscardAndOpenPending() {
        guard let entry = pendingEditorEntry else { return }
        pendingEditorEntry = nil
        openInEditor(entry, discard: true)
    }

    func cancelPendingEditor() {
        pendingEditorEntry = nil
    }

    func editRemote(_ entry: SFTPEntry) {
        guard let client else { return }
        let local = editorCacheURL(entry, name: entry.name)
        Task {
            let result = await client.download(remote: entry.path, local: local.path)
            switch result {
            case .success:
                NSWorkspace.shared.open(local)
                watch(local: local, remote: entry.path, baseline: EditBaseline(date: entry.modified, size: entry.size))
                app?.statusMessage = L10n.f("Редактирование %@; изменения загружаются автоматически", entry.name)
            case .failure(let message):
                error = message.message
            }
        }
    }

    private func quoted(_ path: String) -> String {
        "\"" + path
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    deinit {
        for timer in editTimers.values { timer.invalidate() }
        for process in active.values { process.terminate() }
    }
}

// MARK: - Remote edit watchers

extension SFTPBrowserModel {
    func watch(local: URL, remote: String, baseline: EditBaseline) {
        editTimers[local.path]?.invalidate()
        editDates[local.path] = modificationDate(local)
        editBaselines[local.path] = baseline
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let client = self.client else { return }
                guard !self.inFlightEdits.contains(local.path) else { return }
                guard let current = self.modificationDate(local) else { return }
                if let last = self.editDates[local.path], current <= last { return }
                self.editDates[local.path] = current
                self.inFlightEdits.insert(local.path)
                defer { self.inFlightEdits.remove(local.path) }

                if let known = self.editBaselines[local.path] {
                    guard let remoteNow = await client.remoteEntry(remote) else {
                        self.error = L10n.f("Файл исчез на сервере: %@. Авто-загрузка остановлена.", remote)
                        self.editTimers[local.path]?.invalidate()
                        self.editTimers.removeValue(forKey: local.path)
                        return
                    }
                    if remoteNow.size != known.size
                        || (known.date != nil && remoteNow.modified != nil && remoteNow.modified! > known.date!) {
                        self.error = L10n.f("Файл изменён на сервере: %@. Авто-загрузка остановлена, чтобы не затереть чужие правки.", remote)
                        self.editTimers[local.path]?.invalidate()
                        self.editTimers.removeValue(forKey: local.path)
                        return
                    }
                }

                let result = await client.upload(local: local.path, remote: remote)
                switch result {
                case .success:
                    if let updated = await client.remoteEntry(remote) {
                        self.editBaselines[local.path] = EditBaseline(date: updated.modified, size: updated.size)
                    }
                    self.app?.statusMessage = L10n.f("Загружено на сервер: %@", local.lastPathComponent)
                    self.loadRemote()
                case .failure(let error):
                    self.error = error.message
                }
            }
        }
        editTimers[local.path] = timer
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func stopEditing() {
        for timer in editTimers.values { timer.invalidate() }
        editTimers.removeAll()
        editDates.removeAll()
        editBaselines.removeAll()
        inFlightEdits.removeAll()
    }

    var hasActiveWork: Bool {
        !active.isEmpty || transfers.contains { $0.state == .running } || isEditorDirty
    }

    var isEditorDirty: Bool {
        editorEntry != nil && editorText != editorOriginal
    }

    func shutdown() {
        stopEditing()
        for process in active.values {
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
        }
        active.removeAll()
    }
}
