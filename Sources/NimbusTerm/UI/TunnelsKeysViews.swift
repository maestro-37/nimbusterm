import AppKit
import SwiftUI
import NimbusCore

struct TunnelsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @LocalState private var editor: TunnelEditor?
    @LocalState private var inlineMessage: String?
    @LocalState private var pendingDelete: Tunnel?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SSH-туннели")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    editor = TunnelEditor(tunnel: newTunnel(), isNew: true)
                } label: {
                    Label("Новый туннель", systemImage: "plus")
                }
                .disabled(app.library.sessions.filter { $0.protocolKind == .ssh }.isEmpty)
            }
            .padding(12)
            if let inlineMessage {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(LocalizedStringKey(stringLiteral: inlineMessage)).font(.caption)
                    Spacer()
                    Button("Закрыть") { self.inlineMessage = nil }
                        .buttonStyle(.link)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.18))
            }
            Divider()
            if app.library.tunnels.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 32, weight: .light))
                    Text("Local, Remote и Dynamic (SOCKS) туннели поверх SSH-сессии.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(app.library.tunnels) { tunnel in
                        TunnelRow(
                            tunnel: tunnel,
                            manager: app.tunnels,
                            session: app.session(id: tunnel.sessionID),
                            onStart: { start(tunnel) },
                            onStop: { app.tunnels.stop(tunnel.id) },
                            onEdit: { editor = TunnelEditor(tunnel: tunnel, isNew: false) },
                            onDelete: { pendingDelete = tunnel }
                        )
                    }
                }
            }
            Divider()
            HStack {
                Text("Туннель использует сохранённый пароль сессии из Keychain. Без пароля нужен ключ или agent.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Готово") { dismiss() }
            }
            .padding(12)
        }
        .frame(width: 720, height: 520)
        .confirmationDialog(
            "Удалить туннель?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                if let tunnel = pendingDelete { delete(tunnel) }
                pendingDelete = nil
            }
            Button("Отмена", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.displayName ?? "")
        }
        .sheet(item: $editor) { item in
            TunnelEditorView(editor: item).environmentObject(app)
        }
    }

    private func newTunnel() -> Tunnel {
        Tunnel(sessionID: app.library.sessions.first(where: { $0.protocolKind == .ssh })?.id ?? UUID())
    }

    private func start(_ tunnel: Tunnel) {
        guard let session = app.session(id: tunnel.sessionID) else {
            inlineMessage = "Сессия для туннеля не найдена"
            return
        }
        if !app.isHostTrusted(session) {
            inlineMessage = String(
                format: NSLocalizedString("Первый контакт с %@: host key будет принят автоматически (TOFU). Сверьте отпечаток в терминале, если сервер новый.", comment: ""),
                session.destination
            )
            app.markHostTrusted(session)
        }
        app.tunnels.start(tunnel, session: session, secret: app.secret(for: session))
    }

    private func delete(_ tunnel: Tunnel) {
        app.tunnels.stop(tunnel.id)
        app.library.tunnels.removeAll { $0.id == tunnel.id }
        app.schedulePersist()
    }
}

struct TunnelRow: View {
    let tunnel: Tunnel
    @ObservedObject var manager: TunnelManager
    let session: Session?
    let onStart: () -> Void
    let onStop: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(manager.isRunning(tunnel.id) ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.displayName)
                    .font(.body.weight(.medium))
                Text("\(tunnel.kind.displayName)  \(tunnel.specArgument)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let session {
                    Text("через \(session.displayName)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let error = manager.states[tunnel.id]?.error, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            Spacer()
            if manager.isRunning(tunnel.id) {
                Button("Стоп") { onStop() }
            } else {
                Button("Старт") { onStart() }
                    .disabled(session == nil)
            }
            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

struct TunnelEditor: Identifiable {
    let id = UUID()
    var tunnel: Tunnel
    var isNew: Bool
}

struct TunnelEditorView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let editor: TunnelEditor
    @LocalState private var tunnel: Tunnel
    @LocalState private var name: String

    init(editor: TunnelEditor) {
        self.editor = editor
        _tunnel = LocalState(initialValue: editor.tunnel)
        _name = LocalState(initialValue: editor.tunnel.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Имя", text: $name)
                Picker("SSH-сессия", selection: $tunnel.sessionID) {
                    ForEach(app.library.sessions.filter { $0.protocolKind == .ssh }) { session in
                        Text(session.displayName).tag(session.id)
                    }
                }
                Picker("Тип", selection: $tunnel.kind) {
                    ForEach(TunnelKind.allCases) { Text($0.displayName).tag($0) }
                }
                TextField("Bind host", text: $tunnel.bindHost)
                TextField("Bind port", value: $tunnel.bindPort, format: .number)
                if tunnel.kind != .dynamic {
                    TextField("Target host", text: $tunnel.targetHost)
                    TextField("Target port", value: $tunnel.targetPort, format: .number)
                }
                Toggle("Запускать при старте приложения", isOn: $tunnel.autostart)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    var value = tunnel
                    value.name = name
                    if let index = app.library.tunnels.firstIndex(where: { $0.id == value.id }) {
                        app.library.tunnels[index] = value
                    } else {
                        app.library.tunnels.append(value)
                    }
                    app.schedulePersist()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(app.session(id: tunnel.sessionID) == nil || tunnel.bindPort <= 0 || (tunnel.kind != .dynamic && tunnel.targetHost.isEmpty))
            }
            .padding(12)
        }
        .frame(width: 480, height: 440)
    }
}

struct KeysView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @LocalState private var keys: [SSHKey] = []
    @LocalState private var showGenerate = false
    @LocalState private var installKey: SSHKey?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SSH-ключи")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    showGenerate = true
                } label: {
                    Label("Сгенерировать ed25519", systemImage: "plus")
                }
                Button {
                    reloadKeys()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Обновить")
            }
            .padding(12)
            Divider()
            if keys.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "key")
                        .font(.system(size: 32, weight: .light))
                    Text("В ~/.ssh нет приватных ключей.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(keys) { key in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.name)
                                .font(.body.weight(.medium))
                            if !key.type.isEmpty {
                                Text([key.type, key.comment].filter { !$0.isEmpty }.joined(separator: "  "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let fingerprint = key.fingerprint {
                                Text(fingerprint)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Button("Скопировать публичный") {
                            if let publicKey = key.publicKey {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(publicKey, forType: .string)
                                app.statusMessage = L10n.f("Публичный ключ %@ скопирован", key.name)
                            }
                        }
                        .disabled(key.publicKey == nil)
                        Button("Установить на сервер…") { installKey = key }
                            .disabled(key.publicKey == nil || app.library.sessions.filter { $0.protocolKind == .ssh }.isEmpty)
                    }
                    .padding(.vertical, 4)
                }
            }
            Divider()
            HStack {
                Text("Приватные ключи не покидают ~/.ssh. Passphrase вводится через PTY и не попадает в argv.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Готово") { dismiss() }
            }
            .padding(12)
        }
        .frame(width: 720, height: 520)
        .onAppear { reloadKeys() }
        .sheet(isPresented: $showGenerate) {
            GenerateKeyView { reloadKeys() }
                .environmentObject(app)
        }
        .sheet(item: $installKey) { key in
            InstallKeyView(key: key) { reloadKeys() }
                .environmentObject(app)
        }
    }

    private func reloadKeys() {
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { KeyManager.list() }.value
            keys = loaded
        }
    }
}

struct GenerateKeyView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @LocalState private var name = "id_ed25519_nimbus"
    @LocalState private var comment = ""
    @LocalState private var passphrase = ""
    @LocalState private var working = false
    @LocalState private var error: String?
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Имя файла", text: $name)
                TextField("Комментарий", text: $comment, prompt: Text("user@mac"))
                SecureField("Passphrase (необязательно)", text: $passphrase)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button(working ? "Генерация…" : "Создать") {
                    working = true
                    Task {
                        do {
                            _ = try await KeyManager.generate(name: name, comment: comment, passphrase: passphrase)
                            working = false
                            onDone()
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                            working = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || name.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460, height: 280)
    }
}

struct InstallKeyView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let key: SSHKey
    let onDone: () -> Void
    @LocalState private var sessionID: UUID?
    @LocalState private var password = ""
    @LocalState private var working = false
    @LocalState private var result: String?

    private var sshSessions: [Session] {
        app.library.sessions.filter { $0.protocolKind == .ssh }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Сессия", selection: $sessionID) {
                    Text("Выберите…").tag(UUID?.none)
                    ForEach(sshSessions) { session in
                        Text(session.displayName).tag(Optional(session.id))
                    }
                }
                SecureField("Пароль на сервере", text: $password)
                if let result {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("установлен") ? .green : .red)
                        .lineLimit(6)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }
                Button(working ? "Установка…" : "Установить") {
                    guard let session = app.session(id: sessionID) else { return }
                    working = true
                    Task {
                        let outcome = await KeyManager.install(key: key, on: session, password: password)
                        working = false
                        switch outcome {
                        case .success(let message): result = message; onDone()
                        case .failure(let message): result = message.message
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || sessionID == nil)
            }
            .padding(12)
        }
        .frame(width: 460, height: 300)
        .onAppear {
            if sessionID == nil { sessionID = sshSessions.first?.id }
        }
    }
}
