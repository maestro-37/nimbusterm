import AppKit
import SwiftUI
import NimbusCore

struct PaneTreeView: View {
    @ObservedObject var tab: WorkspaceTab
    let node: PaneTree

    var body: some View {
        switch node {
        case .leaf(let leafID):
            if let controller = tab.controller(for: leafID) {
                TerminalPaneView(controller: controller, tab: tab, leafID: leafID)
                    .frame(minWidth: 140, minHeight: 90)
                    .id(leafID)
            } else {
                Color.black
            }
        case .split(let axis, let first, let second):
            if axis == .horizontal {
                HSplitView {
                    PaneTreeView(tab: tab, node: first)
                    PaneTreeView(tab: tab, node: second)
                }
            } else {
                VSplitView {
                    PaneTreeView(tab: tab, node: first)
                    PaneTreeView(tab: tab, node: second)
                }
            }
        }
    }
}

struct TerminalRepresentable: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct TerminalPaneView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: WorkspaceTab
    let leafID: UUID

    @LocalState private var dropTargeted = false

    private var isActive: Bool { tab.activeLeafID == leafID }

    var body: some View {
        ZStack(alignment: .top) {
            TerminalRepresentable(view: controller.view)
                .onAppear {
                    controller.startIfNeeded()
                    focusIfActive()
                }
                .onChange(of: tab.activeLeafID) { _, _ in focusIfActive() }

            if let warning = controller.warning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(warning)
                        .lineLimit(2)
                    Spacer()
                }
                .font(.caption)
                .padding(7)
                .background(Color.orange.opacity(0.92))
                .foregroundStyle(.black)
                .allowsHitTesting(false)
            }

            if !controller.started {
                pendingOverlay
            } else if !controller.isRunning, controller.exitCode != nil {
                endedOverlay
            }

            HStack {
                Spacer()
                Menu {
                    Button("Разделить вертикально") {
                        tab.activeLeafID = leafID
                        tab.split(axis: .horizontal)
                    }
                    Button("Разделить горизонтально") {
                        tab.activeLeafID = leafID
                        tab.split(axis: .vertical)
                    }
                    Button("4 панели") {
                        tab.activeLeafID = leafID
                        tab.splitIntoQuad()
                    }
                    Divider()
                    Button("Перезапустить") { controller.restart() }
                        .disabled(controller.isRunning)
                    if controller.session.protocolKind == .ssh, !controller.hostTrusted, controller.hasSavedSecret {
                        Button("Доверять хосту (автопароль)") {
                            controller.hostTrusted = true
                            tab.trustHost(leafID: leafID, value: true)
                            app.markHostTrusted(controller.session)
                        }
                    }
                    Button("Закрыть панель", role: .destructive) { tab.closeLeaf(leafID) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                        .padding(4)
                        .background(.black.opacity(0.25), in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24, height: 22)
                .padding(6)
                .opacity(0.75)
                .accessibilityLabel("Действия с панелью")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            Rectangle()
                .strokeBorder(
                    dropTargeted ? Color.orange.opacity(0.9)
                        : (isActive ? Color.accentColor.opacity(0.75) : Color.clear),
                    lineWidth: dropTargeted ? 2 : 1
                )
                .allowsHitTesting(false)
        )
        .onDrop(of: [.text], isTargeted: $dropTargeted) { _ in
            guard let id = app.draggingTabID, id != tab.id else { return false }
            app.mergeTab(id, into: tab.id, at: leafID)
            app.draggingTabID = nil
            return true
        }
    }

    private var pendingOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: controller.session.protocolKind.symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 3) {
                Text(controller.session.displayName)
                    .font(.headline)
                if !controller.session.host.isEmpty {
                    Text(controller.session.destination)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Button("Подключиться") { controller.start() }
                .buttonStyle(.borderedProminent)
            Text("Вкладка восстановлена без автоматического подключения.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .shadow(radius: 12)
    }

    private var endedOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "stop.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(exitText)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Перезапустить") { controller.restart() }
                Button("Закрыть панель") { tab.closeLeaf(leafID) }
                if controller.hasSavedSecret, controller.session.auth != .agent {
                    Button("Забыть пароль") { controller.forgetSavedSecretAndRestart() }
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private var exitText: String {
        if let code = controller.exitCode {
            return L10n.f("Процесс завершился с кодом %d", Int(code))
        }
        return L10n.t("Соединение закрыто")
    }

    private func focusIfActive() {
        guard isActive else { return }
        DispatchQueue.main.async {
            if let window = controller.view.window {
                window.makeFirstResponder(controller.view)
            }
        }
    }
}
