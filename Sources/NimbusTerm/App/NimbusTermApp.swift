import AppKit
import SwiftUI
import NimbusCore
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var app: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--self-test") || arguments.contains("--self-test-sftp") || arguments.contains("--self-test-tunnel") else { return }
        Task {
            let code = await AppSelfTest.run()
            fflush(stdout)
            exit(code)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app, app.library.settings.confirmClose, app.hasActiveWork else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Завершить NimbusTerm?"
        alert.informativeText = "Есть активные терминальные сессии, туннели или передачи файлов. Они будут завершены."
        alert.addButton(withTitle: "Завершить")
        alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        app?.shutdown()
    }
}

@main
struct NimbusTermApp: App {
    @StateObject private var app = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("NimbusTerm") {
            MainWindow()
                .environmentObject(app)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(colorScheme)
                .onAppear {
                    KeychainStore.prepareStore()
                    delegate.app = app
                    app.tunnels.setExtraOptions(app.library.settings.sshExtraOptions)
                    app.startAutostartTunnels()
                }
        }
        .commands { AppCommands(app: app) }
        .windowToolbarStyle(.unifiedCompact)
    }

    private var colorScheme: ColorScheme? {
        switch app.library.settings.appearance {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var app: AppModel

    private func findAction(_ action: NSFindPanelAction) {
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Новая сессия…") {
                app.editingSession = Session()
                app.showSessionEditor = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Локальный терминал") { app.newLocalTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Quick Connect…") { app.showQuickConnect = true }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Импорт…") { app.showImport = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Закрыть вкладку") { app.requestCloseActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Экспорт библиотеки…") { ExportPanel.run(app: app) }
        }

        CommandMenu("Сессия") {
            Button("Разделить вертикально") { app.splitActive(axis: .horizontal) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(app.activeTab?.isTerminals != true)
            Button("Разделить горизонтально") { app.splitActive(axis: .vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(app.activeTab?.isTerminals != true)
            Button("4 панели") { app.splitActiveIntoQuad() }
                .disabled(app.activeTab?.isTerminals != true)
            Button("Закрыть панель") { app.closeActiveLeaf() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(app.activeTab?.isTerminals != true)
            Divider()
            Toggle("Broadcast ввода", isOn: Binding(
                get: { app.activeTab?.isBroadcast ?? false },
                set: { app.activeTab?.isBroadcast = $0 }
            ))
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(app.activeTab?.isTerminals != true)
            Divider()
            Button("SFTP для текущей сессии") { app.openSFTPForActive() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(app.activeController == nil)
            Button("Логирование сессии: вкл/выкл") {
                app.activeController?.toggleLogging()
            }
            .disabled(app.activeController == nil)
            Button("Сниппеты…") { app.showSnippets = true }
            Button("Туннели…") { app.showTunnels = true }
            Button("Ключи…") { app.showKeys = true }
        }

        CommandGroup(replacing: .appSettings) {
            Button("Настройки…") { app.showPreferences = true }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .textEditing) {
            Button("Найти…") { findAction(.showFindPanel) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Найти далее") { findAction(.next) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Найти назад") { findAction(.previous) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            Button("Показать/скрыть сайдбар") { app.sidebarVisible.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button("Увеличить шрифт") { app.zoomFont(by: 1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Уменьшить шрифт") { app.zoomFont(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
        }
    }
}

@MainActor
enum ExportPanel {
    static func run(app: AppModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "nimbusterm-sessions.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            app.exportLibrary(to: url)
        }
    }
}
