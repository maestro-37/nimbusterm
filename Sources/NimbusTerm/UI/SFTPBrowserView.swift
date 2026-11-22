import AppKit
import SwiftUI
import NimbusCore

struct SFTPBrowserView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: SFTPBrowserModel
    @LocalState private var showNewRemoteFolder = false
    @LocalState private var showNewLocalFolder = false
    @LocalState private var folderName = ""
    @LocalState private var renameTarget: SFTPEntry?
    @LocalState private var renameName = ""
    @LocalState private var chmodTarget: SFTPEntry?
    @LocalState private var chmodMode = "644"
    @LocalState private var confirmDelete: SFTPEntry?
    @LocalState private var showLocalPane = false
    @LocalState private var confirmReload = false
    @LocalState private var confirmCloseEditor = false

    init(model: SFTPBrowserModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.needsPassword {
                passwordCard
            } else {
                if let warning = model.trustWarning {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.open")
                        Text(warning).font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.18))
                }
                actionBar
                Divider()
                HSplitView {
                    remotePanel
                    rightPanel
                        .frame(minWidth: 320)
                }
                .frame(minHeight: 220)
                if !model.transfers.isEmpty {
                    Divider()
                    transfersBar
                }
                Divider()
                bottomBar
            }
        }
        .task { model.configure(app: app) }
        .alert("Новая папка (локально)", isPresented: $showNewLocalFolder) {
            TextField("Имя", text: $folderName)
            Button("Создать") { model.makeLocalDirectory(name: folderName) }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Новая папка (на сервере)", isPresented: $showNewRemoteFolder) {
            TextField("Имя", text: $folderName)
            Button("Создать") { model.makeDirectory(name: folderName) }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Переименовать", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Новое имя", text: $renameName)
            Button("Переименовать") {
                if let target = renameTarget { model.renameRemote(target, to: renameName) }
                renameTarget = nil
            }
            Button("Отмена", role: .cancel) { renameTarget = nil }
        }
        .alert("Права доступа", isPresented: Binding(
            get: { chmodTarget != nil },
            set: { if !$0 { chmodTarget = nil } }
        )) {
            TextField("Например 644 или 755", text: $chmodMode)
            Button("Применить") {
                if let target = chmodTarget { model.chmodRemote(target, mode: chmodMode) }
                chmodTarget = nil
            }
            Button("Отмена", role: .cancel) { chmodTarget = nil }
        }
        .alert("Удалить?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let target = confirmDelete { model.deleteRemote(target) }
                confirmDelete = nil
            }
            Button("Отмена", role: .cancel) { confirmDelete = nil }
        } message: {
            Text(confirmDelete?.path ?? "")
        }
        .confirmationDialog(
            "Перезаписать файлы?",
            isPresented: Binding(
                get: { model.overwritePrompt != nil },
                set: { if !$0 { model.cancelOverwrite() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Перезаписать", role: .destructive) { model.confirmOverwrite() }
            Button("Отмена", role: .cancel) { model.cancelOverwrite() }
        } message: {
            Text(model.overwritePrompt ?? "")
        }
        .confirmationDialog(
            "Перезагрузить файл?",
            isPresented: $confirmReload,
            titleVisibility: .visible
        ) {
            Button("Перезагрузить без сохранения", role: .destructive) { model.reloadEditor() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Несохранённые изменения будут потеряны.")
        }
        .confirmationDialog(
            "Закрыть редактор?",
            isPresented: $confirmCloseEditor,
            titleVisibility: .visible
        ) {
            Button("Закрыть без сохранения", role: .destructive) { model.closeEditor() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Несохранённые изменения будут потеряны.")
        }
        .confirmationDialog(
            "Несохранённые изменения",
            isPresented: Binding(
                get: { model.pendingEditorEntry != nil },
                set: { if !$0 { model.cancelPendingEditor() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Открыть без сохранения", role: .destructive) { model.confirmDiscardAndOpenPending() }
            Button("Отмена", role: .cancel) { model.cancelPendingEditor() }
        } message: {
            Text("Есть несохранённые изменения. Открыть другой файл без сохранения?")
        }
    }

    private var passwordCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 40, weight: .light))
            Text("SFTP: \(model.session.displayName)")
                .font(.headline)
            Text("Нужен пароль для \(model.session.destination).")
                .foregroundStyle(.secondary)
            SecureField("Пароль", text: $model.password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { model.connectWithPassword() }
            Toggle("Сохранить в Keychain", isOn: $model.rememberPassword)
            Button("Подключиться") { model.connectWithPassword() }
                .buttonStyle(.borderedProminent)
                .disabled(model.password.isEmpty)
            if let error = model.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                showLocalPane.toggle()
            } label: {
                Label(showLocalPane ? "Редактор" : "Локально",
                      systemImage: showLocalPane ? "doc.text" : "internaldrive")
            }
            .buttonStyle(.bordered)

            Button {
                model.reconnect()
            } label: {
                Label("Переподключить", systemImage: "arrow.clockwise")
            }
            .help("Переподключиться к серверу (Touch ID при необходимости)")

            Button {
                model.uploadSelected()
            } label: {
                Label("Загрузить на сервер", systemImage: "arrow.up.circle")
            }
            .disabled(model.selectedLocal.isEmpty)

            Button {
                model.downloadSelected()
            } label: {
                Label("Скачать на Mac", systemImage: "arrow.down.circle")
            }
            .disabled(model.selectedRemote.isEmpty)

            Divider().frame(height: 18)

            if let entry = selectedRemoteEntry {
                Button("Переименовать") {
                    renameName = entry.name
                    renameTarget = entry
                }
                Button("Права") {
                    chmodMode = "644"
                    chmodTarget = entry
                }
                Button("Редактировать") {
                    model.requestOpenInEditor(entry)
                    showLocalPane = false
                }
                Button("Удалить", role: .destructive) { confirmDelete = entry }
            }

            Spacer()

            if model.isConnecting {
                ProgressView().controlSize(.small)
                Text("Подключение…").font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .frame(maxWidth: 360)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var selectedRemoteEntry: SFTPEntry? {
        guard model.selectedRemote.count == 1, let path = model.selectedRemote.first else { return nil }
        return model.remoteEntries.first { $0.path == path }
    }

    /// Editor and local list share one slot, so switching keeps the divider
    /// (and the editor's width) exactly where it was.
    private var rightPanel: some View {
        ZStack {
            localPanel
                .opacity(showLocalPane ? 1 : 0)
                .allowsHitTesting(showLocalPane)
                .accessibilityHidden(!showLocalPane)
            editorPanel
                .opacity(showLocalPane ? 0 : 1)
                .allowsHitTesting(!showLocalPane)
                .accessibilityHidden(showLocalPane)
        }
    }

    private var localPanel: some View {
        PanelView(
            title: "Локально",
            subtitle: "Mac",
            path: $model.localPath,
            entries: model.localEntries,
            selection: $model.selectedLocal,
            showNewFolder: { folderName = "New Folder"; showNewLocalFolder = true },
            goUp: { model.localParent() },
            go: { model.goLocal($0) },
            refresh: { model.loadLocal() },
            onDoubleClick: { entry in
                if entry.isDirectory {
                    model.goLocal(entry.path)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                }
            },
            dragPrefix: "local:"
        )
        .dropDestination(for: String.self) { items, _ in
            var handled = false
            for item in items where item.hasPrefix("remote:") {
                let path = String(item.dropFirst("remote:".count))
                if let entry = model.remoteEntries.first(where: { $0.path == path }) {
                    model.requestDownload([entry])
                    handled = true
                }
            }
            return handled
        }
    }

    private var remotePanel: some View {
        PanelView(
            title: "Удалённо",
            subtitle: model.session.displayName,
            path: $model.remotePath,
            entries: model.remoteEntries,
            selection: $model.selectedRemote,
            showNewFolder: { folderName = "New Folder"; showNewRemoteFolder = true },
            goUp: { model.remoteParent() },
            go: { model.goRemote($0) },
            refresh: { model.loadRemote() },
            onDoubleClick: { entry in
                if entry.isDirectory {
                    model.goRemote(entry.path)
                } else {
                    model.requestOpenInEditor(entry)
                    showLocalPane = false
                }
            },
            dragPrefix: "remote:"
        )
        .dropDestination(for: String.self) { items, _ in
            var handled = false
            for item in items where item.hasPrefix("local:") {
                let path = String(item.dropFirst("local:".count))
                if let entry = model.localEntries.first(where: { $0.path == path }) {
                    model.requestUpload([entry])
                    handled = true
                }
            }
            return handled
        }
    }

    private var editorPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(model.editorEntry?.name ?? L10n.t("Редактор"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if model.isEditorDirty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .help(L10n.t("Есть несохранённые изменения"))
                }
                Spacer()
                if model.editorEntry != nil {
                    Button(L10n.t("Сохранить")) { model.saveEditor() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!model.isEditorDirty || model.editorSaving || model.editorBinary)
                    Button(L10n.t("Обновить")) {
                        if model.isEditorDirty { confirmReload = true } else { model.reloadEditor() }
                    }
                    Button(L10n.t("Закрыть")) {
                        if model.isEditorDirty { confirmCloseEditor = true } else { model.closeEditor() }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Divider()

            if model.editorEntry == nil {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(L10n.t("Выберите файл слева, чтобы открыть его в редакторе."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.editorLoading {
                ProgressView(L10n.t("Загрузка…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.editorBinary {
                VStack(spacing: 10) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                    if let error = model.editorError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                    }
                    Button(L10n.t("Открыть внешним редактором")) {
                        if let entry = model.editorEntry { model.editRemote(entry) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $model.editorText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
            }

            if let error = model.editorError, !model.editorBinary {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption2)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(6)
                .background(Color.orange.opacity(0.16))
            }
            if model.editorConflict {
                HStack(spacing: 8) {
                    Text(L10n.t("Файл изменён на сервере"))
                        .font(.caption2)
                    Spacer()
                    Button(L10n.t("Перезагрузить")) { model.reloadEditor() }
                    Button(L10n.t("Перезаписать"), role: .destructive) { model.saveEditor(force: true) }
                }
                .padding(6)
                .background(Color.red.opacity(0.16))
            }
        }
    }

    private var transfersBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Передачи")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Очистить завершённые") { model.clearFinished() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            ForEach(model.transfers.suffix(4)) { transfer in
                HStack(spacing: 8) {
                    Text(transfer.direction.rawValue)
                        .font(.system(.caption, design: .monospaced))
                    Text(transfer.name)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(width: 220, alignment: .leading)
                    if transfer.state == .running {
                        if let progress = transfer.progress {
                            ProgressView(value: progress).frame(width: 160)
                        } else {
                            ProgressView().controlSize(.small).frame(width: 160)
                        }
                        Button("Отмена") { model.cancel(transfer) }
                            .buttonStyle(.link)
                            .font(.caption)
                    } else {
                        Text(statusText(transfer))
                            .font(.caption2)
                            .foregroundStyle(transfer.state == .done ? .green : .red)
                        if !transfer.detail.isEmpty {
                            Text(transfer.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.25))
    }

    private func statusText(_ transfer: SFTPBrowserModel.Transfer) -> String {
        switch transfer.state {
        case .done: return L10n.t("готово")
        case .failed: return L10n.t("ошибка")
        case .cancelled: return L10n.t("отменено")
        case .running: return "…"
        }
    }

    private var bottomBar: some View {
        HStack {
            Text(model.remotePath.isEmpty ? "—" : model.remotePath)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(L10n.f("%lld объектов", model.remoteEntries.count))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(.bar)
    }
}

struct PanelView: View {
    let title: String
    let subtitle: String
    @Binding var path: String
    let entries: [SFTPEntry]
    @Binding var selection: Set<String>
    let showNewFolder: () -> Void
    let goUp: () -> Void
    let go: (String) -> Void
    let refresh: () -> Void
    let onDoubleClick: (SFTPEntry) -> Void
    let dragPrefix: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(LocalizedStringKey(stringLiteral: title))
                    .font(.caption.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button { goUp() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless)
                    .help("На уровень выше")
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Обновить")
                Button { showNewFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help("Новая папка")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

            TextField("Путь", text: $path)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .onSubmit { go(path) }

            List(selection: $selection) {
                ForEach(entries) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : (entry.isSymlink ? "link" : "doc"))
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                            .frame(width: 16)
                        Text(entry.name)
                            .lineLimit(1)
                        Spacer()
                        Text(entry.permissions)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 92, alignment: .leading)
                        if !entry.isDirectory {
                            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let modified = entry.modified {
                            Text(modified.formatted(date: .numeric, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tag(entry.path)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onDoubleClick(entry) }
                    .draggable(dragPrefix + entry.path)
                }
            }
            .listStyle(.plain)
        }
    }
}
