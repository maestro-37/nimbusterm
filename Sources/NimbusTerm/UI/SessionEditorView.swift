import Darwin
import AppKit
import SwiftUI
import NimbusCore

struct SessionEditorView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @LocalState private var draft: Session
    @LocalState private var password = ""
    @LocalState private var hasStoredPassword = false
    @LocalState private var removePassword = false
    @LocalState private var confirmDelete = false
    @LocalState private var envText = ""
    @LocalState private var tagsText = ""
    private let isNew: Bool

    init(original: Session, isNew: Bool) {
        _draft = LocalState(initialValue: original)
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Общее") {
                    TextField("Имя", text: $draft.name, prompt: Text("Например, prod-web"))
                    Picker("Тип", selection: $draft.protocolKind) {
                        ForEach(SessionProtocol.allCases) { kind in
                            Label(kind.displayName, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    .onChange(of: draft.protocolKind) { _, newValue in
                        draft.port = newValue.defaultPort
                    }
                    Picker("Папка", selection: $draft.folderID) {
                        Text("Без папки").tag(UUID?.none)
                        ForEach(app.library.folders) { folder in
                            Text(app.folderPath(folder.id)).tag(Optional(folder.id))
                        }
                    }
                    Toggle("В избранном", isOn: $draft.favorite)
                }

                if draft.protocolKind != .local {
                    Section("Подключение") {
                        TextField("Хост", text: $draft.host)
                            .textContentType(.URL)
                        TextField("Порт", value: $draft.port, format: .number)
                        TextField("Пользователь", text: $draft.user)
                        if draft.protocolKind == .ssh || draft.protocolKind == .sftp {
                            SecureField(LocalizedStringKey(passwordLabel), text: $password)
                            if hasStoredPassword {
                                HStack {
                                    Label("Сохранён в Keychain", systemImage: "checkmark.seal")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                    Spacer()
                                    Button("Удалить", role: .destructive) {
                                        removePassword = true
                                        hasStoredPassword = false
                                        password = ""
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                            Text(LocalizedStringKey(passwordHint))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if draft.protocolKind == .rdp || draft.protocolKind == .vnc {
                            Text("Пароль и параметры сеанса хранит внешний клиент (Windows App / Screen Sharing).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if draft.protocolKind == .ssh || draft.protocolKind == .sftp {
                    Section("Аутентификация") {
                        Picker("Способ", selection: $draft.auth) {
                            ForEach(SSHAuth.allCases) { auth in
                                Text(auth.displayName).tag(auth)
                            }
                        }
                        if draft.auth == .key {
                            HStack {
                                TextField("Файл ключа", text: $draft.identityFile, prompt: Text("~/.ssh/id_ed25519"))
                                Button("Выбрать…") { chooseKey() }
                            }
                        }
                        TextField("ProxyJump", text: $draft.proxyJump, prompt: Text("user@bastion"))
                    }

                    Section("SSH") {
                        HStack {
                            Picker("X11", selection: $draft.x11) {
                                ForEach(X11Mode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            Toggle("Сжатие", isOn: $draft.compression)
                        }
                        TextField("Keepalive, сек", value: $draft.keepalive, format: .number)
                        TextField("Команда при входе", text: $draft.startupCommand, prompt: Text("tmux attach"))
                        TextField("Доп. аргументы ssh", text: $draft.extraArgs, prompt: Text("-o ForwardAgent=yes"))
                        TextField("TERM", text: $draft.terminalType)
                    }
                }

                if draft.protocolKind.isTerminal {
                    Section("Терминал") {
                        Toggle("Писать лог сессии", isOn: $draft.logSession)
                        Text("Лог может содержать секреты, если они выводятся в терминал.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Toggle("Мониторинг CPU/RAM/диска", isOn: $draft.monitor)
                            .disabled(draft.protocolKind != .ssh)
                    }
                }

                if draft.protocolKind == .ssh || draft.protocolKind == .sftp {
                    Section("Переменные окружения") {
                    TextEditor(text: $envText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 58)
                    Text("По одной на строку: KEY=VALUE. Передаются через SetEnv.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Заметки") {
                    TextEditor(text: $draft.notes)
                        .frame(height: 56)
                    TextField("Теги (через запятую)", text: $tagsText)
                }

                if !isNew {
                    Section {
                        Button("Удалить сессию", role: .destructive) {
                            confirmDelete = true
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "Новая сессия" : "Сессия")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if isNew {
                        Button("Сохранить и открыть") { save(open: true) }
                            .disabled(!isValid)
                    }
                    Button("Сохранить") { save(open: false) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid)
                }
            }
            .confirmationDialog("Удалить сессию?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    app.deleteSession(draft)
                    dismiss()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("\(draft.displayName) будет удалена вместе с сохранённым паролем.")
            }
            .onAppear {
                envText = draft.environment
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: "\n")
                tagsText = draft.tags.joined(separator: ", ")
                hasStoredPassword = app.hasSecret(for: draft)
            }
        }
        .frame(width: 620, height: 560)
    }

    private var passwordLabel: String { "Пароль / passphrase" }

    private var passwordHint: String {
        switch draft.auth {
        case .password:
            return "Пароль для входа. Хранится в macOS Keychain; заполните поле и нажмите «Сохранить»."
        case .key:
            return "Passphrase для выбранного ключа. Хранится в Keychain; пустое поле сохраняет текущий секрет."
        case .agent:
            return "Для SSH agent пароль обычно не нужен, но если agent не сработает, сохранённый пароль будет предложен как fallback."
        }
    }

    private var isValid: Bool {
        if draft.protocolKind == .local { return true }
        let host = draft.host.trimmingCharacters(in: .whitespaces)
        return !host.isEmpty && !host.hasPrefix("-") && !draft.user.hasPrefix("-") && draft.port > 0
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            draft.identityFile = url.path
        }
    }

    private func save(open: Bool) {
        var session = draft
        if session.name.trimmingCharacters(in: .whitespaces).isEmpty {
            session.name = session.protocolKind == .local ? String(localized: "Локальный shell") : session.host
        }
        session.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var environment: [String: String] = [:]
        for line in envText.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let eq = text.firstIndex(of: "="), eq != text.startIndex else { continue }
            environment[String(text[..<eq])] = String(text[text.index(after: eq)...])
        }
        session.environment = environment
        app.saveSession(session, password: password.isEmpty ? nil : password)
        if removePassword && password.isEmpty { app.deleteSecret(for: session) }
        if !password.isEmpty { hasStoredPassword = true }
        app.editingSession = nil
        dismiss()
        if open { app.openSession(session) }
    }
}

struct QuickConnectView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @LocalState private var query = ""

    private var matches: [Session] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return Array(app.allSessions.prefix(10)) }
        return app.allSessions.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.host.localizedCaseInsensitiveContains(trimmed)
                || $0.destination.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Connect")
                .font(.title3.weight(.semibold))
            TextField("Имя сессии или user@host:port", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { connect() }
            if !matches.isEmpty {
                Text("Сессии")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(matches) { session in
                            Button {
                                app.openSession(session)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: session.protocolKind.symbol)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(session.displayName)
                                        Text(session.destination)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            HStack {
                Text("Новый адрес откроется как временная SSH-сессия.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Подключиться") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    private func connect() {
        app.quickConnect(query)
        dismiss()
    }
}

struct PreferencesView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Язык") {
                    Picker("Язык интерфейса", selection: interfaceLanguage) {
                        Text("Системный").tag("system")
                        Text("Русский").tag("ru")
                        Text("English").tag("en")
                    }
                    Text("Изменения вступают в силу после перезапуска приложения.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Перезапустить сейчас") { restartApp() }
                }
                Section("Безопасность") {
                    Toggle("Защищать пароли Touch ID", isOn: Binding(
                        get: { KeychainStore.useBiometrics },
                        set: { KeychainStore.useBiometrics = $0 }
                    ))
                    .disabled(!KeychainStore.biometricsAvailable())
                    Text("Touch ID спрашивается один раз за запуск перед чтением паролей.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section("Внешний вид") {
                    Picker("Тема приложения", selection: appearance) {
                        ForEach(Appearance.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Тема терминала", selection: theme) {
                        ForEach(TerminalTheme.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Терминал") {
                    TextField("Шрифт", text: fontName)
                    HStack {
                        Text("Размер")
                        Slider(value: fontSize, in: 9...28, step: 1)
                        Text("\(Int(app.library.settings.fontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 44)
                    }
                    TextField("Scrollback, строк", value: scrollback, format: .number)
                    Toggle("Показывать скрытые файлы в SFTP", isOn: showHidden)
                }
                Section("SSH") {
                    TextField("Пользователь по умолчанию", text: defaultUser)
                    TextField("Доп. опции ssh", text: sshOptions, prompt: Text("-o AddKeysToAgent=yes"))
                    TextField("Интервал мониторинга, сек", value: monitorInterval, format: .number)
                }
                Section("Сессии и логи") {
                    Toggle("Восстанавливать вкладки при запуске", isOn: restoreTabs)
                    Toggle("Подтверждать закрытие", isOn: confirmClose)
                    Toggle("Писать логи всех сессий", isOn: loggingEnabled)
                    HStack {
                        TextField("Папка логов", text: logDirectory)
                        Button("Выбрать…") { chooseLogDirectory() }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Секреты хранятся в macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 560)
    }

    private var interfaceLanguage: Binding<String> {
        Binding(
            get: {
                if let code = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first {
                    if code.hasPrefix("en") { return "en" }
                    if code.hasPrefix("ru") { return "ru" }
                }
                return "system"
            },
            set: { value in
                if value == "system" {
                    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                } else {
                    UserDefaults.standard.set([value], forKey: "AppleLanguages")
                }
            }
        )
    }

    private func restartApp() {
        app.shutdown()
        let url = Bundle.main.bundleURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if url.pathExtension == "app" {
                NSWorkspace.shared.open(url)
            }
            exit(0)
        }
    }

    private var appearance: Binding<Appearance> {
        Binding(
            get: { app.library.settings.appearance },
            set: { app.library.settings.appearance = $0 }
        )
    }
    private var theme: Binding<TerminalTheme> {
        Binding(get: { app.library.settings.theme }, set: { app.library.settings.theme = $0 })
    }
    private var fontName: Binding<String> {
        Binding(get: { app.library.settings.fontName }, set: { app.library.settings.fontName = $0 })
    }
    private var fontSize: Binding<Double> {
        Binding(get: { app.library.settings.fontSize }, set: { app.library.settings.fontSize = $0 })
    }
    private var scrollback: Binding<Int> {
        Binding(get: { app.library.settings.scrollback }, set: { app.library.settings.scrollback = max(500, $0) })
    }
    private var showHidden: Binding<Bool> {
        Binding(get: { app.library.settings.showHiddenFiles }, set: { app.library.settings.showHiddenFiles = $0 })
    }
    private var defaultUser: Binding<String> {
        Binding(get: { app.library.settings.defaultUser }, set: { app.library.settings.defaultUser = $0 })
    }
    private var sshOptions: Binding<String> {
        Binding(get: { app.library.settings.sshExtraOptions }, set: { app.library.settings.sshExtraOptions = $0 })
    }
    private var monitorInterval: Binding<Double> {
        Binding(get: { app.library.settings.monitorInterval }, set: { app.library.settings.monitorInterval = max(2, $0) })
    }
    private var restoreTabs: Binding<Bool> {
        Binding(get: { app.library.settings.restoreTabs }, set: { app.library.settings.restoreTabs = $0 })
    }
    private var confirmClose: Binding<Bool> {
        Binding(get: { app.library.settings.confirmClose }, set: { app.library.settings.confirmClose = $0 })
    }
    private var loggingEnabled: Binding<Bool> {
        Binding(get: { app.library.settings.loggingEnabled }, set: { app.library.settings.loggingEnabled = $0 })
    }
    private var logDirectory: Binding<String> {
        Binding(get: { app.library.settings.logDirectory }, set: { app.library.settings.logDirectory = $0 })
    }

    private func chooseLogDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: AppPaths.expand(app.library.settings.logDirectory))
        if panel.runModal() == .OK, let url = panel.url {
            app.library.settings.logDirectory = AppPaths.abbreviate(url.path)
        }
    }
}
