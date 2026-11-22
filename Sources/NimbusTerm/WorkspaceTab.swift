import Foundation
import NimbusCore

@MainActor
final class WorkspaceTab: Identifiable, ObservableObject {
    enum Kind {
        case terminals
        case sftp(Session)
        case external(Session, String)
    }

    let id = UUID()
    let kind: Kind
    @Published var title: String
    private var customTitle: String?
    @Published var root: PaneTree
    @Published var activeLeafID: UUID
    @Published var isBroadcast = false
    @Published private(set) var controllers: [UUID: TerminalController] = [:]
    @Published private(set) var leafSessions: [UUID: Session] = [:]
    private(set) var sftpModel: SFTPBrowserModel?
    private var defaultTitle: String
    private var leafTrust: [UUID: Bool] = [:]

    var isTerminals: Bool {
        if case .terminals = kind { return true }
        return false
    }

    var onEmpty: (() -> Void)?
    var onChange: (() -> Void)?
    var trustProvider: (Session) -> Bool = { _ in false }
    var secretProvider: (Session) -> String? = { _ in nil }
    private var settings: AppSettings
    private let helperURL: URL
    private var extraOptions: String

    init(
        session: Session,
        settings: AppSettings,
        helperURL: URL,
        extraOptions: String,
        autoStart: Bool = true,
        hostTrusted: Bool = false
    ) {
        self.kind = .terminals
        self.title = session.displayName
        self.defaultTitle = session.displayName
        self.settings = settings
        self.helperURL = helperURL
        self.extraOptions = extraOptions
        let leaf = UUID()
        self.root = .leaf(leaf)
        self.activeLeafID = leaf
        self.leafSessions = [leaf: session]
        install(session: session, leafID: leaf, autoStart: autoStart, hostTrusted: hostTrusted)
    }

    init(
        tree: PaneTree,
        sessions: [UUID: Session],
        settings: AppSettings,
        helperURL: URL,
        extraOptions: String,
        title: String? = nil,
        trustedProvider: (Session) -> Bool = { _ in false }
    ) {
        self.kind = .terminals
        let computedTitle = PaneTreeOps.leaves(tree)
            .compactMap { sessions[$0]?.displayName }
            .first ?? "Терминал"
        self.title = title ?? computedTitle
        self.defaultTitle = computedTitle
        self.settings = settings
        self.helperURL = helperURL
        self.extraOptions = extraOptions
        self.root = tree
        self.activeLeafID = PaneTreeOps.leaves(tree).first ?? UUID()
        self.leafSessions = sessions
        for leafID in PaneTreeOps.leaves(tree) {
            guard let session = sessions[leafID] else { continue }
            install(
                session: session,
                leafID: leafID,
                autoStart: session.protocolKind == .local,
                hostTrusted: trustedProvider(session)
            )
        }
    }

    init(sftp session: Session) {
        self.kind = .sftp(session)
        let sftpTitle = "SFTP — \(session.displayName)"
        self.title = sftpTitle
        self.defaultTitle = sftpTitle
        self.settings = AppSettings()
        self.helperURL = URL(fileURLWithPath: "/")
        self.extraOptions = ""
        let leaf = UUID()
        self.root = .leaf(leaf)
        self.activeLeafID = leaf
        self.sftpModel = SFTPBrowserModel(session: session)
    }

    init(external session: Session, message: String) {
        self.kind = .external(session, message)
        let externalTitle = "\(session.protocolKind.displayName) — \(session.displayName)"
        self.title = externalTitle
        self.defaultTitle = externalTitle
        self.settings = AppSettings()
        self.helperURL = URL(fileURLWithPath: "/")
        self.extraOptions = ""
        let leaf = UUID()
        self.root = .leaf(leaf)
        self.activeLeafID = leaf
        self.sftpModel = nil
    }

    private func install(session: Session, leafID: UUID, autoStart: Bool, hostTrusted: Bool) {
        leafTrust[leafID] = hostTrusted
        let controller = TerminalController(session: session, settings: settings, helperURL: helperURL, hostTrusted: hostTrusted)
        controller.trustProvider = { [weak self] in self?.trustProvider(session) ?? false }
        controller.secretProvider = { [weak self] in self?.secretProvider(session) }
        controller.setDefaultExtraOptions(extraOptions)
        controller.autoStart = autoStart
        controller.onTitle = { [weak self] title in
            guard let self else { return }
            if self.activeLeafID == leafID, self.customTitle == nil { self.title = title }
        }
        controller.onInput = { [weak self] data in
            self?.broadcast(data, from: leafID)
        }
        controller.onTerminated = { [weak self] in
            self?.onChange?()
        }
        controller.onStateChange = { [weak self] in
            self?.onChange?()
        }
        controller.onFocus = { [weak self] in
            self?.activeLeafID = leafID
        }
        controllers[leafID] = controller
    }

    var activeController: TerminalController? {
        controllers[activeLeafID]
    }

    func controller(for leafID: UUID) -> TerminalController? {
        controllers[leafID]
    }

    func session(for leafID: UUID) -> Session? {
        leafSessions[leafID]
    }

    func split(axis: SplitAxis) {
        guard case .terminals = kind else { return }
        let source = leafSessions[activeLeafID] ?? Session(name: "Локальный shell", protocolKind: .local)
        let newLeaf = UUID()
        let newSession: Session
        if source.protocolKind == .local {
            newSession = Session(name: "Локальный shell", protocolKind: .local)
        } else {
            newSession = source
        }
        leafSessions[newLeaf] = newSession
        install(session: newSession, leafID: newLeaf, autoStart: true, hostTrusted: leafTrust[activeLeafID] ?? false)
        root = PaneTreeOps.split(root, at: activeLeafID, axis: axis, newLeaf: newLeaf)
        activeLeafID = newLeaf
        onChange?()
    }

    func closeLeaf(_ leafID: UUID) {
        guard leafSessions.count > 1 else {
            onEmpty?()
            return
        }
        controllers[leafID]?.stop()
        controllers.removeValue(forKey: leafID)
        leafSessions.removeValue(forKey: leafID)
        if let newRoot = PaneTreeOps.removing(root, leaf: leafID) {
            root = newRoot
        }
        if activeLeafID == leafID {
            activeLeafID = PaneTreeOps.leaves(root).first ?? activeLeafID
        }
        onChange?()
    }

    func trustHost(leafID: UUID, value: Bool) {
        controllers[leafID]?.hostTrusted = value
        leafTrust[leafID] = value
    }

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            customTitle = nil
            title = defaultTitle
        } else {
            customTitle = trimmed
            title = trimmed
        }
    }

    func broadcast(_ data: ArraySlice<UInt8>, from leafID: UUID) {
        guard isBroadcast else { return }
        for (id, controller) in controllers where id != leafID {
            controller.send(data)
        }
    }

    func apply(settings: AppSettings) {
        self.settings = settings
        self.extraOptions = settings.sshExtraOptions
        for controller in controllers.values {
            controller.apply(settings: settings)
            controller.setDefaultExtraOptions(extraOptions)
        }
    }

    func stopAll() {
        for controller in controllers.values {
            controller.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak controller] in
                controller?.flushLogs()
            }
        }
        sftpModel?.shutdown()
    }

    func savedTab(libraryIDs: Set<UUID>) -> SavedTab? {
        switch kind {
        case .external:
            return nil
        case .sftp(let session):
            guard libraryIDs.contains(session.id) else { return nil }
            return SavedTab(root: .leaf(nil), title: title, sftpSessionID: session.id)
        case .terminals:
            func saved(_ node: PaneTree) -> SavedPane {
                switch node {
                case .leaf(let leafID):
                    if let session = leafSessions[leafID], libraryIDs.contains(session.id) {
                        return .leaf(session.id)
                    }
                    return .leaf(nil)
                case .split(let axis, let first, let second):
                    return .split(axis: axis, first: saved(first), second: saved(second))
                }
            }
            return SavedTab(root: saved(root), title: title)
        }
    }
}
