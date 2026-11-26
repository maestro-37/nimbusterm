import Darwin
import Foundation
import NimbusCore

@MainActor
enum AppSelfTest {
    static func run() async -> Int32 {
        KeychainStore.prepareStore()
        if let account = ProcessInfo.processInfo.environment["NIMBUS_CHECK_ACCOUNT"] {
            let result = KeychainStore.getResult(account: account)
            print("KEYCHAIN_CHECK account=\(account) status=\(result.status) length=\(result.value?.count ?? 0)")
        }
        print("localizations:", Bundle.main.preferredLocalizations)
        print("settings label:", String(localized: "Настройки"))

        var failures = 0
        func check(_ condition: Bool, _ name: String, _ detail: String = "") {
            print(condition ? "ok  \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !condition { failures += 1 }
        }

        let editorProbe = SFTPBrowserModel(session: Session(
            name: "editor-probe", protocolKind: .sftp, host: "127.0.0.1", port: 22, user: "probe"
        ))
        let editorProbeURL = editorProbe.editorCacheURL(
            SFTPEntry(name: "probe.txt", path: "/root/probe.txt", isDirectory: false, size: 1)
        )
        check(
            FileManager.default.fileExists(atPath: editorProbeURL.deletingLastPathComponent().path),
            "editor.cache-dir",
            editorProbeURL.deletingLastPathComponent().path
        )
        try? FileManager.default.removeItem(at: editorProbeURL.deletingLastPathComponent().deletingLastPathComponent())

        let paneTab = WorkspaceTab(
            session: Session(name: "pane-probe", protocolKind: .local),
            settings: AppSettings(),
            helperURL: URL(fileURLWithPath: "/"),
            extraOptions: "",
            autoStart: false
        )
        paneTab.splitIntoQuad()
        check(PaneTreeOps.leaves(paneTab.root).count == 4, "panes.quad")
        let paneSource = WorkspaceTab(
            session: Session(name: "pane-source", protocolKind: .local),
            settings: AppSettings(),
            helperURL: URL(fileURLWithPath: "/"),
            extraOptions: "",
            autoStart: false
        )
        let sourceLeaf = PaneTreeOps.leaves(paneSource.root)[0]
        let targetLeaf = PaneTreeOps.leaves(paneTab.root)[0]
        check(paneTab.adopt(from: paneSource, leaf: sourceLeaf, at: targetLeaf, axis: .horizontal), "panes.adopt")
        check(PaneTreeOps.leaves(paneTab.root).count == 5, "panes.adopt.count")
        check(paneSource.controllers.isEmpty, "panes.detach")

        let echo = await ProcessRunner.run(executable: "/bin/echo", arguments: ["hello"])
        check(echo.status == 0 && echo.stdout == "hello\n", "process.run")

        for theme in TerminalTheme.allCases {
            let palette = Theme.palette(for: theme)
            check(palette.background != palette.foreground, "theme.\(theme.rawValue)")
            check(Theme.ansiPalette(for: theme)?.count == 16, "theme.ansi.\(theme.rawValue)")
        }
        for appearance in Appearance.allCases {
            check(!appearance.displayName.isEmpty, "appearance.\(appearance.rawValue)")
        }

        let account = "selftest-\(UUID().uuidString)"
        check(KeychainStore.set("keychain-secret", account: account), "keychain.set")
        check(KeychainStore.get(account: account) == "keychain-secret", "keychain.get")
        KeychainStore.delete(account: account)
        check(!KeychainStore.has(account: account), "keychain.delete")

        do {
            let helper = Askpass.ensureHelper()
            let context = try Askpass.makeContext(password: "sekret", helper: helper)
            let result = await ProcessRunner.run(executable: helper.path, arguments: ["Password:"], environment: context.environment)
            check(result.status == 0 && result.stdout == "sekret", "askpass", result.stdout)
            check(!FileManager.default.fileExists(atPath: context.passwordFile), "askpass one-shot")
            Askpass.cleanup(context)
        } catch {
            check(false, "askpass", error.localizedDescription)
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nimbusterm-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keyPath = directory.appendingPathComponent("testkey").path
        let keygen = await PTYRunner.run(
            executable: SSHCommandBuilder.sshKeygenPath,
            arguments: ["-t", "ed25519", "-f", keyPath, "-C", "selftest"],
            answers: [
                ("Enter passphrase", "testpass"),
                ("Enter same passphrase", "testpass")
            ],
            timeout: 30
        )
        check(
            keygen.status == 0
                && FileManager.default.fileExists(atPath: keyPath)
                && FileManager.default.fileExists(atPath: keyPath + ".pub"),
            "pty.ssh-keygen",
            keygen.stdout.suffix(200).description
        )
        try? FileManager.default.removeItem(at: directory)

        if ProcessInfo.processInfo.arguments.contains("--self-test-sftp") {
            failures += await sftpChecks()
        }
        if ProcessInfo.processInfo.arguments.contains("--self-test-tunnel") {
            failures += await tunnelChecks()
        }

        print(failures == 0 ? "App self-test passed." : "\(failures) app checks failed.")
        return failures == 0 ? 0 : 1
    }

    private static func sftpChecks() async -> Int {
        KeychainStore.prepareStore()
        if let account = ProcessInfo.processInfo.environment["NIMBUS_CHECK_ACCOUNT"] {
            let result = KeychainStore.getResult(account: account)
            print("KEYCHAIN_CHECK account=\(account) status=\(result.status) length=\(result.value?.count ?? 0)")
        }
        print("localizations:", Bundle.main.preferredLocalizations)
        print("settings label:", String(localized: "Настройки"))

        var failures = 0
        func check(_ condition: Bool, _ name: String, _ detail: String = "") {
            print(condition ? "ok  \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !condition { failures += 1 }
        }
        let port = Int(ProcessInfo.processInfo.environment["NIMBUSTERM_SFTP_PORT"] ?? "2222") ?? 2222
        var session = Session(name: "selftest", protocolKind: .sftp, host: "127.0.0.1", port: port, user: "test")
        session.auth = .password
        let client = SFTPClient(
            session: session,
            secret: "test",
            helperURL: Askpass.ensureHelper(),
            extraOptions: "-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
        )
        let home = await client.home()
        guard case .success(let (path, _)) = home else {
            check(false, "sftp.home", "\(home)")
            return failures
        }
        check(true, "sftp.home", path)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nimbusterm-sftp-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let upload = directory.appendingPathComponent("upload.txt")
        let download = directory.appendingPathComponent("download.txt")
        try? "hello sftp".write(to: upload, atomically: true, encoding: .utf8)
        let remote = (path == "/" ? "" : path) + "/nimbusterm-selftest.txt"

        let up = await client.upload(local: upload.path, remote: remote)
        if case .failure(let error) = up { check(false, "sftp.upload", error.message) } else { check(true, "sftp.upload") }

        let list = await client.list(path)
        if case .success(let entries) = list {
            check(entries.contains { $0.name == "nimbusterm-selftest.txt" && $0.size == 10 }, "sftp.list", entries.map { "\($0.name):\($0.size)" }.joined(separator: ", "))
        } else {
            check(false, "sftp.list", "\(list)")
        }

        let down = await client.download(remote: remote, local: download.path)
        if case .failure(let error) = down {
            check(false, "sftp.download", error.message)
        } else {
            let text = (try? String(contentsOf: download, encoding: .utf8)) ?? ""
            check(text == "hello sftp", "sftp.download", text)
        }

        let editorEntry = SFTPEntry(
            name: "nimbusterm-selftest.txt",
            path: remote,
            isDirectory: false,
            size: 10
        )
        let editorModel = SFTPBrowserModel(session: session)
        let editorLocal = editorModel.editorCacheURL(editorEntry)
        let editorDownload = await client.download(remote: remote, local: editorLocal.path)
        if case .failure(let error) = editorDownload {
            check(false, "sftp.editor.cache", error.message)
        } else {
            let text = (try? String(contentsOf: editorLocal, encoding: .utf8)) ?? ""
            check(text == "hello sftp", "sftp.editor.cache", text)
            try? FileManager.default.removeItem(at: editorLocal)
        }

        let keyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nimbusterm-key-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
        let keyPath = keyDirectory.appendingPathComponent("id_ed25519").path
        let generated = await ProcessRunner.run(
            executable: SSHCommandBuilder.sshKeygenPath,
            arguments: ["-t", "ed25519", "-N", "", "-f", keyPath, "-C", "selftest"],
            timeout: 30
        )
        check(generated.status == 0, "sftp.keygen", generated.stderr)
        var keySession = session
        keySession.auth = .key
        keySession.identityFile = keyPath
        let keyClient = SFTPClient(
            session: keySession,
            secret: nil,
            helperURL: Askpass.ensureHelper(),
            extraOptions: "-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
        )
        let keyHome = await keyClient.home()
        if case .success = keyHome { check(true, "sftp.publickey") } else { check(false, "sftp.publickey", "\(keyHome)") }
        try? FileManager.default.removeItem(at: keyDirectory)

        let targetRemote = (path == "/" ? "" : path) + "/nimbusterm-target.txt"
        let linkRemote = (path == "/" ? "" : path) + "/nimbusterm-link.txt"
        let oldLocal = directory.appendingPathComponent("old.txt")
        let newLocal = directory.appendingPathComponent("new.txt")
        try? "old".write(to: oldLocal, atomically: true, encoding: .utf8)
        try? "new".write(to: newLocal, atomically: true, encoding: .utf8)
        _ = await client.upload(local: oldLocal.path, remote: targetRemote)
        if case .success = await client.symlink(target: targetRemote, path: linkRemote) {
            _ = await client.upload(local: newLocal.path, remote: linkRemote)
            let link = await client.remoteEntry(linkRemote)
            check(link?.isSymlink == true, "sftp.symlink.preserved")
            let downloaded = directory.appendingPathComponent("target.txt")
            _ = await client.download(remote: targetRemote, local: downloaded.path)
            check((try? String(contentsOf: downloaded, encoding: .utf8)) == "new", "sftp.symlink.target")
            _ = await client.delete(linkRemote, isDirectory: false)
            _ = await client.delete(targetRemote, isDirectory: false)
        } else {
            check(false, "sftp.symlink")
        }

        let bad = await client.list("/definitely-not-there")
        if case .failure = bad { check(true, "sftp.error") } else { check(false, "sftp.error", "\(bad)") }

        let removed = await client.delete(remote, isDirectory: false)
        if case .failure(let error) = removed { check(false, "sftp.delete", error.message) } else { check(true, "sftp.delete") }
        try? FileManager.default.removeItem(at: directory)

        AppPaths.ensureControlDirectory()
        let sshArgs = SSHCommandBuilder.execArguments(
            for: session,
            controlDirectory: AppPaths.controlMasterDirectory.path,
            remoteCommand: "echo ssh-ok",
            extraOptions: "-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
        )
        let context = try? Askpass.makeContext(password: "test", helper: Askpass.ensureHelper())
        let ssh = await ProcessRunner.run(
            executable: SSHCommandBuilder.sshPath,
            arguments: sshArgs,
            environment: context?.environment ?? [:],
            timeout: 20
        )
        Askpass.cleanup(context)
        check(ssh.status == 0 && ssh.stdout.contains("ssh-ok"), "ssh.exec", ssh.stdout + ssh.stderr)

        return failures
    }

    private static func tunnelChecks() async -> Int {
        KeychainStore.prepareStore()
        if let account = ProcessInfo.processInfo.environment["NIMBUS_CHECK_ACCOUNT"] {
            let result = KeychainStore.getResult(account: account)
            print("KEYCHAIN_CHECK account=\(account) status=\(result.status) length=\(result.value?.count ?? 0)")
        }
        print("localizations:", Bundle.main.preferredLocalizations)
        print("settings label:", String(localized: "Настройки"))

        var failures = 0
        func check(_ condition: Bool, _ name: String, _ detail: String = "") {
            print(condition ? "ok  \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !condition { failures += 1 }
        }
        let port = Int(ProcessInfo.processInfo.environment["NIMBUSTERM_TUNNEL_PORT"] ?? "18081") ?? 18081
        var session = Session(name: "selftest", protocolKind: .ssh, host: "127.0.0.1", port: 2222, user: "test")
        session.auth = .password
        var tunnel = Tunnel(sessionID: session.id, bindPort: port)
        tunnel.targetHost = "127.0.0.1"
        tunnel.targetPort = 18080
        let manager = TunnelManager()
        manager.setExtraOptions("-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no")
        manager.start(tunnel, session: session, secret: "test")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        check(manager.states[tunnel.id]?.isRunning == true, "tunnel.running", manager.states[tunnel.id]?.error ?? "")
        let probe = await ProcessRunner.run(
            executable: "/usr/bin/nc",
            arguments: ["-z", "-w", "1", "127.0.0.1", String(port)],
            timeout: 5
        )
        check(probe.status == 0, "tunnel.listen", "status \(probe.status)")
        manager.stop(tunnel.id)
        try? await Task.sleep(nanoseconds: 700_000_000)
        check(manager.states[tunnel.id]?.isRunning == false, "tunnel.stopped")
        let closed = await ProcessRunner.run(
            executable: "/usr/bin/nc",
            arguments: ["-z", "-w", "1", "127.0.0.1", String(port)],
            timeout: 5
        )
        check(closed.status != 0, "tunnel.closed", "status \(closed.status)")
        return failures
    }
}
