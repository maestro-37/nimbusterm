import SwiftUI
import NimbusCore

struct TabStripView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(app.tabs) { tab in
                            TabItemView(tab: tab, isActive: app.activeTabID == tab.id)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: app.activeTabID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(newValue, anchor: .center) }
                }
            }

            Divider().frame(height: 22)

            Menu {
                Button("Локальный терминал") { app.newLocalTab() }
                Button("Quick Connect…") { app.showQuickConnect = true }
                Divider()
                Button("Новая сессия…") {
                    app.editingSession = Session()
                    app.showSessionEditor = true
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)
            .help("Новая вкладка")

            if let tab = app.activeTab, case .terminals = tab.kind {
                BroadcastToggle(tab: tab)
            }
        }
        .background(.bar)
    }
}

struct TabItemView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var tab: WorkspaceTab
    let isActive: Bool
    @LocalState private var hovered = false
    @LocalState private var showRename = false
    @LocalState private var renameName = ""

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                app.activeTabID = tab.id
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    Text(tab.title)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: 180, alignment: .leading)
                    Spacer(minLength: 18)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.accentColor.opacity(0.18) : (hovered ? Color.secondary.opacity(0.1) : .clear))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                app.requestCloseTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .padding(3)
                    .background(hovered ? Color.secondary.opacity(0.18) : .clear, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.trailing, 7)
            .accessibilityLabel("Закрыть вкладку")
        }
        .onHover { hovered = $0 }
        .contextMenu {
            if case .terminals = tab.kind {
                Button("Разделить вертикально") { app.activeTabID = tab.id; app.splitActive(axis: .horizontal) }
                Button("Разделить горизонтально") { app.activeTabID = tab.id; app.splitActive(axis: .vertical) }
                Toggle("Broadcast ввода", isOn: Binding(
                    get: { tab.isBroadcast },
                    set: { tab.isBroadcast = $0 }
                ))
                Divider()
            }
            Button("Переименовать…") {
                renameName = tab.title
                showRename = true
            }
            Button("Закрыть вкладку") { app.requestCloseTab(tab.id) }
        }
        .alert("Переименовать вкладку", isPresented: $showRename) {
            TextField("Имя", text: $renameName)
            Button("Переименовать") { tab.rename(renameName) }
            Button("Сбросить") { tab.rename("") }
            Button("Отмена", role: .cancel) {}
        }
    }

    private var icon: String {
        switch tab.kind {
        case .terminals: return "terminal"
        case .sftp: return "folder.badge.gearshape"
        case .external(let session, _): return session.protocolKind.symbol
        }
    }
}


struct BroadcastToggle: View {
    @ObservedObject var tab: WorkspaceTab

    var body: some View {
        Button {
            tab.isBroadcast.toggle()
        } label: {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(tab.isBroadcast ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 10)
        .help("Отправлять ввод во все панели (⇧⌘B)")
        .accessibilityLabel("Broadcast ввода")
    }
}
