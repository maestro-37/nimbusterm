import Foundation
import NimbusCore

var failures = 0
var checks = 0

func check(_ condition: Bool, _ name: String, _ detail: String = "") {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL: \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func run(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    if failures == before { print("ok  \(name)") }
}

run("shell.split") {
    check(Shell.split("-o A -o \"B C\" -o 'D E'") == ["-o", "A", "-o", "B C", "-o", "D E"], "quotes")
    check(Shell.split("a\\ b") == ["a b"], "backslash")
    check(Shell.quote("it's") == "'it'\\''s'", "quote")
}

run("sftp.listing") {
    let output = """
    Connected to example.com.
    sftp> ls -la
    drwxr-xr-x    2 user group     4096 Nov 20 12:00 sub dir
    -rw-r--r--    1 user group     1234 Nov 20 12:00 hello world.txt
    lrwxrwxrwx    1 user group        7 Nov 20  2025 link -> target
    """
    let entries = SFTPListing.parse(output, basePath: "/home/user")
    check(entries.count == 3, "count", "\(entries.count)")
    check(entries[0].name == "sub dir", "dir name")
    check(entries[0].isDirectory, "dir flag")
    check(entries[0].path == "/home/user/sub dir", "dir path")
    check(entries[1].name == "hello world.txt", "file name")
    check(entries[1].size == 1234, "file size")
    check(entries[2].linkTarget == "target", "symlink")

    let dayFirst = SFTPListing.parse("-rw-r--r--   1 501      20             10 21 Nov 12:21 nimbusterm-selftest.txt", basePath: "/")
    check(dayFirst.count == 1, "day-first count", "\(dayFirst.count)")
    check(dayFirst.first?.name == "nimbusterm-selftest.txt", "day-first name")
    check(dayFirst.first?.size == 10, "day-first size")
    check(dayFirst.first?.modified != nil, "day-first date")

    let mac = SFTPListing.parse("-rw-r--r--@    ? testuser staff   123 Nov 21 14:11 mac.txt", basePath: "/Users")
    check(mac.count == 1, "mac listing count", "\(mac.count)")
    check(mac.first?.name == "mac.txt", "mac listing name")
    check(mac.first?.size == 123, "mac listing size")

    let fullPaths = SFTPListing.parse("""
    drwxr-xr-x    2 root root 4096 Oct 28 2000 /root/./bots/DeadMorozik
    drwxr-xr-x    2 root root 4096 Oct 28 2000 /root/./bots/.
    drwxr-xr-x    2 root root 4096 Oct 28 2000 /root/./bots/..
    """, basePath: "/root/./bots")
    check(fullPaths.count == 1, "full path count", "\(fullPaths.count)")
    check(fullPaths.first?.name == "DeadMorozik", "full path name")
    check(fullPaths.first?.path == "/root/bots/DeadMorozik", "full path normalized")
    check(SFTPListing.normalize("/root/./bots/../bots") == "/root/bots", "normalize")
    check(SFTPListing.parseWorkingDirectory("Remote working directory: /root/./bots") == "/root/bots", "pwd normalize")
}

run("moba.import") {
    let fixture = """
    [Bookmarks]
    SubRep=
    ImgNum=42
    Prod =#109#0%example.com%22%root%%-1%0%%%%%0%0%0%%%-1%0%0%0%%1080%%0%0%1%%0%%%%0%-1%-1%0#MobaFont%10%0%0%-1%15%236,236,236%30,30,30%180,180,192%0%-1%0%%xterm%-1%0%_Std_Colors_0_%80%24%0%0%-1%<none>%%0%0%-1%-1#0# #-1

    [Bookmarks_1]
    SubRep=Team\\QA
    ImgNum=41
    Files=#140#7%files.example.com%22%deploy%-1%0%/var/www%0%0%/keys/id%0%1080%%%%-1#MobaFont%10%0%0%-1%15%236,236,236%30,30,30%180,180,192%0%-1%0%%xterm%-1%0%_Std_Colors_0_%80%24%0%0%-1%<none>%%0%0%-1%-1#0# #-1
    """
    let result = MobaSessionsImporter.parse(text: fixture)
    check(result.sessions.count == 2, "session count", "\(result.sessions.count)")
    let prod = result.sessions.first { $0.name == "Prod" }
    check(prod?.host == "example.com", "host")
    check(prod?.user == "root", "user")
    check(prod?.port == 22, "port")
    check(prod?.x11 == .untrusted, "x11")
    let files = result.sessions.first { $0.name == "Files" }
    check(files?.protocolKind == .sftp, "sftp protocol")
    check(files?.identityFile == "/keys/id", "key")
    check(result.folders.contains { $0.name == "QA" }, "folder")
}

run("sshconfig.import") {
    let fixture = """
    Host prod
      HostName 1.2.3.4
      User root
      Port 2222
      IdentityFile ~/.ssh/id_ed25519
    Host *.internal
      User admin
    Host db
      HostName db.local
    """
    let sessions = SSHConfigImporter.parse(text: fixture, defaultUser: "me")
    check(sessions.count == 2, "count", "\(sessions.count)")
    check(sessions.first?.name == "prod", "name")
    check(sessions.first?.host == "1.2.3.4", "host")
    check(sessions.first?.port == 2222, "port")
    check(sessions.first?.auth == .key, "key auth")
    check(sessions.last?.name == "db", "db")
    check(sessions.last?.user == "me", "default user")
}

run("pane.tree") {
    let a = UUID(), b = UUID(), c = UUID()
    var tree = PaneTree.leaf(a)
    tree = PaneTreeOps.split(tree, at: a, axis: .horizontal, newLeaf: b)
    tree = PaneTreeOps.split(tree, at: b, axis: .vertical, newLeaf: c)
    check(PaneTreeOps.leaves(tree) == [a, b, c], "leaves")
    tree = PaneTreeOps.removing(tree, leaf: b)!
    check(PaneTreeOps.leaves(tree) == [a, c], "after remove")
}

run("ssh.arguments") {
    var session = Session(name: "x", protocolKind: .ssh, host: "host", port: 2222, user: "u")
    session.auth = .key
    session.identityFile = "~/.ssh/id_ed25519"
    session.x11 = .trusted
    session.compression = true
    session.startupCommand = "tmux attach"
    let args = SSHCommandBuilder.terminalArguments(for: session, controlDirectory: "/tmp/cm")
    check(args.contains("-p"), "port flag")
    check(args.contains("2222"), "port")
    check(args.contains("-l"), "user flag")
    check(args.contains("-Y"), "x11")
    check(args.contains("-C"), "compression")
    check(args.last == "tmux attach", "startup")
    check(args[args.count - 2] == "u@host", "destination")
    check(args.contains("ControlPath=\"/tmp/cm/%C\""), "control path")
    check(args.contains("--"), "option terminator")
    check(session.isSafeDestination, "safe destination")
    check(args.contains("StrictHostKeyChecking=ask"), "interactive host key")
    let trusted = SSHCommandBuilder.terminalArguments(
        for: session,
        controlDirectory: "/tmp/cm",
        acceptNewHostKey: true
    )
    check(trusted.contains("StrictHostKeyChecking=accept-new"), "trusted host key")

    let sftp = SSHCommandBuilder.sftpArguments(for: session, controlDirectory: "/tmp/cm")
    check(!sftp.contains("-b"), "sftp no batch flag")
    check(sftp.last == "u@host", "sftp destination")
    check(sftp.contains("ControlPath=\"/tmp/cm/%C\""), "sftp control path")

    let tunnel = Tunnel(sessionID: session.id, bindPort: 8080)
    let tunnelArgs = SSHCommandBuilder.tunnelArguments(
        for: tunnel,
        session: session,
        controlDirectory: "/tmp/cm"
    )
    check(!tunnelArgs.contains("ControlMaster=auto"), "tunnel not multiplexed")
    check(tunnelArgs.contains("-L"), "tunnel forward")
    check(tunnelArgs.last == "u@host", "tunnel destination")
    check(MobaSessionsImporter.decodeValue("a__PIPE__b__PTVIRG__c__DIEZE__d") == "a|b;c#d", "moba decode")
    var unsafe = session
    unsafe.host = "-oProxyCommand=evil"
    check(!unsafe.isSafeDestination, "unsafe host")
}

run("library.store") {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nimbus-lib-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("library.json")
    let store = LibraryStore(url: url)

    try? "{ definitely not json".write(to: url, atomically: true, encoding: .utf8)
    if case .failure = store.loadResult() { check(true, "corrupt detected") } else { check(false, "corrupt detected") }
    let quarantined = store.quarantineCorruptFile()
    check(quarantined != nil && !FileManager.default.fileExists(atPath: url.path), "quarantine")

    var library = Library()
    library.sessions = [Session(name: "prod", host: "example.com")]
    try? store.save(library)
    if case .success(let loaded) = store.loadResult() {
        check(loaded.sessions.count == 1 && loaded.sessions.first?.name == "prod", "round trip")
    } else {
        check(false, "round trip")
    }

    let mixed = """
    {"version":1,"folders":[{"id":123}],"tunnels":[],"snippets":[],"settings":{},"openTabs":[],
     "sessions":[{"id":"11111111-1111-1111-1111-111111111111","name":"good","host":"h"},
                 {"id":"not-a-uuid","name":"bad"}]}
    """
    try? mixed.write(to: url, atomically: true, encoding: .utf8)
    if case .success(let loaded) = store.loadResult() {
        check(loaded.folders.isEmpty, "lossy folders")
        check(loaded.sessions.count == 2, "tolerant sessions")
        check(loaded.skippedRecords == 1, "skipped records", "\(loaded.skippedRecords)")
    } else {
        check(false, "lossy decode")
    }
    try? FileManager.default.removeItem(at: directory)
}

run("remote.stats") {
    let output = """
     12:00:00 up 3 days,  4:05,  1 user,  load average: 0.10, 0.20, 0.30
    @@
    0.11 0.22 0.33 1/100 1234
    @@
                  total        used        free      shared  buff/cache   available
    Mem:           8000        3000        1000         100        4000        4500
    @@
    /dev/sda1      1000000  450000    550000      45% /
    """
    let stats = RemoteStatsParser.parse(output)
    check(stats.load1 == 0.11, "load")
    check(stats.memoryTotalMB == 8000, "mem total")
    check(stats.memoryUsedMB == 3500, "mem used")
    check(stats.diskUsedPercent == 45, "disk")
    check(stats.uptime == "3 days,  4:05", "uptime", stats.uptime ?? "nil")
}

print(failures == 0 ? "\nAll \(checks) checks passed." : "\n\(failures) of \(checks) checks failed.")
exit(failures == 0 ? 0 : 1)
