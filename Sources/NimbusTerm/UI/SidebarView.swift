import AppKit
import SwiftUI
import NimbusCore

struct SidebarView: View {
    @EnvironmentObject private var app: AppModel
    @LocalState private var search = ""
    @LocalState private var folderPrompt: FolderPrompt?

    private var filteredSessions: [Session] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return app.allSessions.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.host.localizedCaseInsensitiveContains(query)
                || $0.user.localizedCaseInsensitiveContains(query)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Поиск сессий", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(7)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()

            List(selection: $app.selectedID) {
                if !search.isEmpty {
                    Section("Результаты") {
                        ForEach(filteredSessions) { session in
                            SessionRow(session: session)
                        }
                    }
                } else {
                    let favorites = app.library.sessions.filter(\.favorite)
                    if !favorites.isEmpty {
                        Section("Избранное") {
                            ForEach(favorites) { SessionRow(session: $0) }
                        }
                    }
                    Section("Сессии") {
                        ForEach(app.childFolders(of: nil)) { folder in
                            FolderRow(folder: folder, prompt: $folderPrompt)
                        }
                        ForEach(app.sessions(in: nil).filter { !$0.favorite }) { session in
                            SessionRow(session: session)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .contextMenu {
                Button("Новая сессия…") {
                    app.editingSession = Session()
                    app.showSessionEditor = true
                }
                Button("Новая папка…") {
                    folderPrompt = FolderPrompt(parentID: nil)
                }
                Divider()
                Button("Quick Connect…") { app.showQuickConnect = true }
                Button("Импорт…") { app.showImport = true }
            }
        }
        .alert("Папка", isPresented: Binding(
            get: { folderPrompt != nil },
            set: { if !$0 { folderPrompt = nil } }
        )) {
            TextField("Имя папки", text: Binding(
                get: { folderPrompt?.name ?? "" },
                set: { folderPrompt?.name = $0 }
            ))
            Button("Создать") {
                if let prompt = folderPrompt {
                    if let folder = prompt.folder {
                        app.renameFolder(folder, to: prompt.name.isEmpty ? "Папка" : prompt.name)
                    } else {
                        app.addFolder(name: prompt.name.isEmpty ? "Папка" : prompt.name, parentID: prompt.parentID)
                    }
                }
                folderPrompt = nil
            }
            Button("Отмена", role: .cancel) { folderPrompt = nil }
        }
    }
}

struct FolderPrompt: Identifiable {
    let id = UUID()
    var parentID: UUID?
    var folder: Folder?
    var name = ""

    init(parentID: UUID?, folder: Folder? = nil) {
        self.parentID = parentID
        self.folder = folder
        self.name = folder?.name ?? ""
    }
}

struct FolderRow: View {
    @EnvironmentObject private var app: AppModel
    let folder: Folder
    @Binding var prompt: FolderPrompt?
    @LocalState private var expanded = true
    @LocalState private var confirmDelete = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(app.childFolders(of: folder.id)) { child in
                FolderRow(folder: child, prompt: $prompt)
            }
            ForEach(app.sessions(in: folder.id).filter { !$0.favorite }) { session in
                SessionRow(session: session)
            }
        } label: {
            Label(folder.name, systemImage: expanded ? "folder.fill" : "folder")
                .lineLimit(1)
        }
        .tag(folder.id)
        .contextMenu {
            Button("Новая сессия…") {
                app.editingSession = Session(folderID: folder.id)
                app.showSessionEditor = true
            }
            Button("Новая подпапка…") {
                prompt = FolderPrompt(parentID: folder.id)
            }
            Divider()
            Button("Переименовать…") {
                prompt = FolderPrompt(parentID: folder.parentID, folder: folder)
            }
            Button("Удалить папку", role: .destructive) {
                confirmDelete = true
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
            app.moveSession(id, to: folder.id)
            return true
        }
        .confirmationDialog(
            "Удалить папку?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) { app.deleteFolder(folder) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Сессии и подпапки будут перемещены на уровень выше.")
        }
    }

    private var count: Int {
        app.sessions(in: folder.id).count + app.childFolders(of: folder.id).count
    }
}

struct SessionRow: View {
    @EnvironmentObject private var app: AppModel
    let session: Session
    @LocalState private var hovered = false
    @LocalState private var confirmDelete = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.protocolKind.symbol)
                .foregroundStyle(session.favorite ? Color.orange : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName)
                    .lineLimit(1)
                if !session.host.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let stats = app.monitorStats[session.id], session.monitor {
                Circle()
                    .fill((stats.diskUsedPercent ?? 0) > 85 ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
                    .help(stats.summary)
            }
        }
        .contentShape(Rectangle())
        .tag(session.id)
        .onTapGesture(count: 2) { app.openSession(session) }
        .draggable(session.id.uuidString)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { app.openSession(session) }
        .contextMenu {
            Button("Открыть") { app.openSession(session) }
            Button("Редактировать…") {
                app.editingSession = session
                app.showSessionEditor = true
            }
            Button("Дублировать") { app.duplicateSession(session) }
            if session.protocolKind == .ssh || session.protocolKind == .sftp {
                Button("Открыть SFTP") {
                    app.openSFTP(session)
                }
            }
            Divider()
            if session.protocolKind == .ssh || session.protocolKind == .sftp {
                Button("Копировать ssh-команду") {
                    let command = SSHCommandBuilder.printableCommand(for: session)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    app.statusMessage = command
                }
            } else if session.protocolKind == .rawTCP {
                Button("Копировать nc-команду") {
                    let command = "nc \(session.host) \(session.port)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    app.statusMessage = command
                }
            }
            if session.favorite {
                Button("Убрать из избранного") { setFavorite(false) }
            } else {
                Button("В избранное") { setFavorite(true) }
            }
            Divider()
            Button("Удалить", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Удалить сессию?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { app.deleteSession(session) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("\(session.displayName) будет удалена вместе с сохранённым паролем. Это действие нельзя отменить.")
        }
    }

    private var subtitle: String {
        var text = session.host
        if !session.user.isEmpty { text = session.user + "@" + text }
        if session.port > 0 && session.port != session.protocolKind.defaultPort {
            text += ":\(session.port)"
        }
        return text
    }

    private func setFavorite(_ value: Bool) {
        guard let index = app.library.sessions.firstIndex(where: { $0.id == session.id }) else { return }
        app.library.sessions[index].favorite = value
    }
}
