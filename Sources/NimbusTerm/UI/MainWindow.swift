import SwiftUI
import NimbusCore

struct MainWindow: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { app.sidebarVisible ? .all : .detailOnly },
            set: { app.sidebarVisible = $0 != .detailOnly }
        )) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            VStack(spacing: 0) {
                if app.saveBlocked {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Библиотека повреждена: сохранение остановлено, чтобы не потерять данные.")
                            .font(.caption)
                        Spacer()
                        Button("Разрешить сохранение") { app.unblockSaving() }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.18))
                }
                if app.tabs.isEmpty {
                    WelcomeView()
                } else {
                    TabStripView()
                    Divider()
                    TabContentView()
                    Divider()
                    StatusBarView()
                }
            }
        }
        .toolbar { toolbar }
        .sheet(isPresented: $app.showSessionEditor) {
            SessionEditorView(
                original: app.editingSession ?? Session(),
                isNew: app.editingSession.map { session in
                    !app.library.sessions.contains { $0.id == session.id }
                } ?? true
            )
            .environmentObject(app)
            .onDisappear { app.editingSession = nil }
        }
        .sheet(isPresented: $app.showQuickConnect) {
            QuickConnectView().environmentObject(app)
        }
        .sheet(isPresented: $app.showSnippets) {
            SnippetsView().environmentObject(app)
        }
        .sheet(isPresented: $app.showTunnels) {
            TunnelsView().environmentObject(app)
        }
        .sheet(isPresented: $app.showKeys) {
            KeysView().environmentObject(app)
        }
        .sheet(isPresented: $app.showImport) {
            ImportView().environmentObject(app)
        }
        .sheet(isPresented: $app.showPreferences) {
            PreferencesView().environmentObject(app)
        }
        .alert(item: $app.alert) { alert in
            Alert(
                title: Text(LocalizedStringKey(stringLiteral: alert.title)),
                message: Text(LocalizedStringKey(stringLiteral: alert.message)),
                dismissButton: .default(Text("OK"))
            )
        }
        .confirmationDialog(
            "Доверять host key?",
            isPresented: Binding(
                get: { app.pendingHostTrust != nil },
                set: { if !$0 { app.pendingHostTrust = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Подключиться (TOFU)") { app.confirmHostTrust() }
            Button("Отмена", role: .cancel) { app.pendingHostTrust = nil }
        } message: {
            if let pending = app.pendingHostTrust {
                Text("Сессия \(pending.session.displayName) использует сохранённый пароль. Host key сервера \(pending.session.destination) будет принят автоматически при первом подключении. Продолжить?")
            }
        }
        .confirmationDialog(
            "Закрыть вкладку?",
            isPresented: Binding(
                get: { app.pendingCloseTabID != nil },
                set: { if !$0 { app.pendingCloseTabID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Закрыть", role: .destructive) {
                if let id = app.pendingCloseTabID { app.closeTab(id) }
                app.pendingCloseTabID = nil
            }
            Button("Отмена", role: .cancel) { app.pendingCloseTabID = nil }
        } message: {
            Text("В сессии выполняется процесс. Закрыть вкладку и завершить его?")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 2) {
                toolbarButton("plus", help: "Новая сессия (⇧⌘N)", label: "Новая сессия") {
                    app.editingSession = Session()
                    app.showSessionEditor = true
                }
                toolbarButton("bolt.fill", help: "Quick Connect (⌘K)", label: "Quick Connect") {
                    app.showQuickConnect = true
                }
                toolbarButton("terminal", help: "Локальный терминал (⌘T)", label: "Локальный терминал") {
                    app.newLocalTab()
                }

                Menu {
                    Button {
                        app.showSnippets = true
                    } label: {
                        Label("Сниппеты…", systemImage: "text.badge.plus")
                    }
                    Button {
                        app.showTunnels = true
                    } label: {
                        Label("Туннели…", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    Button {
                        app.showKeys = true
                    } label: {
                        Label("Ключи…", systemImage: "key")
                    }
                    Divider()
                    Button {
                        app.showImport = true
                    } label: {
                        Label("Импорт…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Инструменты")
                .accessibilityLabel("Инструменты")

                toolbarButton("gearshape", help: "Настройки (⌘,)", label: "Настройки") {
                    app.showPreferences = true
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func toolbarButton(
        _ systemName: String,
        help: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label)
    }

}

struct TabContentView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if let tab = app.activeTab {
            switch tab.kind {
            case .terminals:
                PaneTreeView(tab: tab, node: tab.root)
                    .id(tab.id)
            case .sftp:
                if let model = tab.sftpModel {
                    SFTPBrowserView(model: model)
                        .id(tab.id)
                } else {
                    WelcomeView()
                }
            case .external(let session, let message):
                ExternalTabView(session: session, message: message)
            }
        } else {
            WelcomeView()
        }
    }
}

struct ExternalTabView: View {
    let session: Session
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: session.protocolKind.symbol)
                .font(.system(size: 56, weight: .light))
            Text("\(session.protocolKind.displayName): \(session.displayName)")
                .font(.title2)
            Text(message)
                .foregroundStyle(.secondary)
            Text(session.destination)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Button("Открыть снова") {
                _ = ExternalSessionLauncher.open(session)
            }
            .buttonStyle(.borderedProminent)
            Text("Пароль и настройки подключения хранит внешний клиент.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.15))
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var app: AppModel

    private var recent: [Session] {
        Array(app.allSessions.prefix(6))
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "terminal.fill")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("NimbusTerm")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("SSH · SFTP · туннели · X11 · RDP/VNC")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    app.newLocalTab()
                } label: {
                    Label("Локальный терминал", systemImage: "terminal")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    app.editingSession = Session()
                    app.showSessionEditor = true
                } label: {
                    Label("Новая сессия", systemImage: "plus")
                }
                Button {
                    app.showQuickConnect = true
                } label: {
                    Label("Quick Connect", systemImage: "bolt.horizontal")
                }
            }
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Недавние сессии")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(recent) { session in
                        Button {
                            app.openSession(session)
                        } label: {
                            HStack {
                                Image(systemName: session.protocolKind.symbol)
                                Text(session.displayName)
                                Spacer()
                                Text(session.destination)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 440)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
