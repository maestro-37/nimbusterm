import UniformTypeIdentifiers
import SwiftUI
import NimbusCore

struct SnippetsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @LocalState private var editor: Snippet?
    @LocalState private var pendingDelete: Snippet?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Сниппеты")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    editor = Snippet(name: "", command: "")
                } label: {
                    Label("Добавить", systemImage: "plus")
                }
            }
            .padding(12)
            Divider()
            if app.library.snippets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 32, weight: .light))
                    Text("Макросы и команды, которые можно отправить в терминал.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(app.library.snippets) { snippet in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snippet.name.isEmpty ? "Без имени" : snippet.name)
                                    .font(.body.weight(.medium))
                                Text(snippet.command)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                if snippet.sendToAll {
                                    Text("во все панели")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Button("Отправить") { app.sendSnippet(snippet) }
                                .disabled(app.activeTab == nil)
                            Button {
                                editor = snippet
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            Button {
                                pendingDelete = snippet
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Divider()
            HStack {
                Text("Подстановки: {host}, {user}, {port}, {name}")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Готово") { dismiss() }
            }
            .padding(12)
        }
        .frame(width: 620, height: 460)
        .confirmationDialog(
            "Удалить сниппет?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                if let snippet = pendingDelete { app.deleteSnippet(snippet) }
                pendingDelete = nil
            }
            Button("Отмена", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.name ?? "")
        }
        .sheet(item: $editor) { snippet in
            SnippetEditorView(snippet: snippet).environmentObject(app)
        }
    }
}

struct SnippetEditorView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let snippet: Snippet
    @LocalState private var name: String
    @LocalState private var command: String
    @LocalState private var sendToAll: Bool

    init(snippet: Snippet) {
        self.snippet = snippet
        _name = LocalState(initialValue: snippet.name)
        _command = LocalState(initialValue: snippet.command)
        _sendToAll = LocalState(initialValue: snippet.sendToAll)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Имя", text: $name)
                VStack(alignment: .leading) {
                    Text("Команда")
                    TextEditor(text: $command)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 100)
                }
                Toggle("Отправлять во все панели", isOn: $sendToAll)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    var updated = snippet
                    updated.name = name
                    updated.command = command
                    updated.sendToAll = sendToAll
                    app.saveSnippet(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 480, height: 340)
    }
}

struct ImportView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Импорт и экспорт")
                .font(.title3.weight(.semibold))

            GroupBox("SSH config") {
                HStack {
                    Text("Прочитать ~/.ssh/config: Host, HostName, User, Port, IdentityFile, ProxyJump.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Импортировать") {
                        dismiss()
                        DispatchQueue.main.async { app.importSSHConfig() }
                    }
                }
                .padding(6)
            }

            GroupBox("MobaXterm") {
                HStack {
                    Text("Файл .mxtsessions или MobaXterm.ini. Импортируются SSH, SFTP, RDP и VNC сессии; пароли Moba не читаются.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Выбрать файл…") { chooseMobaFile() }
                }
                .padding(6)
            }

            GroupBox("NimbusTerm JSON") {
                HStack {
                    Text("Экспорт или импорт библиотеки: сессии, папки, туннели, сниппеты и настройки.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Импорт…") { chooseJSONFile() }
                    Button("Экспорт…") {
                        dismiss()
                        DispatchQueue.main.async { ExportPanel.run(app: app) }
                    }
                }
                .padding(6)
            }

            HStack {
                Text("Секреты не экспортируются: они остаются в Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Готово") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func chooseJSONFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            dismiss()
            DispatchQueue.main.async { app.importLibraryJSON(url: url) }
        }
    }

    private func chooseMobaFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            dismiss()
            DispatchQueue.main.async { app.importMoba(url: url) }
        }
    }
}
