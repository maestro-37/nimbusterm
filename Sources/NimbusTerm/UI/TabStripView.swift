import AppKit
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
                    .background(NoVerticalBounce { app.draggingTabID = nil })
                }
                .onChange(of: app.activeTabID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(newValue, anchor: .center) }
                }
                .background(NoVerticalBounce())
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
        .onDrop(of: [.text], isTargeted: nil) { _ in
            guard let id = app.draggingTabID else { return false }
            app.moveTab(id, toIndex: app.tabs.count - 1)
            app.draggingTabID = nil
            return true
        }
    }
}

struct TabItemView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var tab: WorkspaceTab
    let isActive: Bool
    @LocalState private var hovered = false
    @LocalState private var width: CGFloat = 120
    @LocalState private var showRename = false
    @LocalState private var renameName = ""

    var body: some View {
        ZStack(alignment: .trailing) {
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
            .onTapGesture { app.activeTabID = tab.id }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { app.activeTabID = tab.id }

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
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, value in width = value }
        })
        .onDrag {
            app.draggingTabID = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(tabID: tab.id, width: width, app: app))
        .help("Перетащите, чтобы изменить порядок; на панель терминала — чтобы разделить")
        .contextMenu {
            if case .terminals = tab.kind {
                Button("Разделить вертикально") { app.activeTabID = tab.id; app.splitActive(axis: .horizontal) }
                Button("Разделить горизонтально") { app.activeTabID = tab.id; app.splitActive(axis: .vertical) }
                Button("4 панели") { app.activeTabID = tab.id; app.splitActiveIntoQuad() }
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


/// Places the tab live while it is dragged, so the strip itself is the preview.
struct TabDropDelegate: DropDelegate {
    let tabID: UUID
    let width: CGFloat
    let app: AppModel

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let id = app.draggingTabID, id != tabID,
              let from = app.tabs.firstIndex(where: { $0.id == id }),
              let hovered = app.tabs.firstIndex(where: { $0.id == tabID })
        else { return nil }
        var target = hovered + (info.location.x > width / 2 ? 1 : 0)
        if target > from { target -= 1 }
        if target != from { app.moveTab(id, toIndex: target) }
        return DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        _ = dropUpdated(info: info)
    }

    func performDrop(info: DropInfo) -> Bool {
        app.draggingTabID = nil
        return true
    }
}

/// SwiftUI sizes the horizontal tab strip's document taller than the viewport,
/// so the bar can scroll away vertically. Clamp it on every layout.
struct NoVerticalBounce: NSViewRepresentable {
    var onMouseUp: (() -> Void)?

    final class Guard: NSView {
        private var scrollMonitor: Any?
        var onMouseUp: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard scrollMonitor == nil, window != nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseUp]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if event.type == .leftMouseUp {
                    self.onMouseUp?()
                    return event
                }
                let frame = self.convert(self.bounds, to: nil)
                guard frame.contains(event.locationInWindow) else { return event }
                return abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? nil : event
            }
        }

        deinit {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        }

        override func layout() {
            super.layout()
            var node: NSView? = superview
            while let current = node {
                if let scroll = current as? NSScrollView {
                    scroll.verticalScrollElasticity = .none
                    scroll.hasVerticalScroller = false
                    let limit = scroll.contentSize.height
                    if let doc = scroll.documentView, limit > 0, doc.frame.height > limit {
                        var frame = doc.frame
                        frame.size.height = limit
                        doc.frame = frame
                    }
                }
                node = current.superview
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = Guard()
        view.onMouseUp = onMouseUp
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
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
