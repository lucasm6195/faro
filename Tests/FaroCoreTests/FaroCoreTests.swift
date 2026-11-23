import Darwin
import Foundation
import Testing
@testable import FaroCore

@Suite struct ShellEventTests {
    @Test func parsesEvents() {
        #expect(ShellEvent(payload: Array("cwd;/Users/a/Mis%20cosas".utf8)) == .cwd("/Users/a/Mis cosas"))
        #expect(ShellEvent(payload: Array("exec;echo a%3Bb".utf8)) == .exec("echo a;b"))
        #expect(ShellEvent(payload: Array("done;127;42".utf8)) == .done(exit: 127, milliseconds: 42))
        #expect(ShellEvent(payload: Array("buf;3;git".utf8)) == .buffer("git", cursor: 3))
        #expect(ShellEvent(payload: Array("buf;0;".utf8)) == .buffer("", cursor: 0))
        #expect(ShellEvent(payload: Array("prompt".utf8)) == .prompt)
        #expect(ShellEvent(payload: Array("nada".utf8)) == nil)
    }

    @Test func bufferWithSelection() {
        #expect(ShellEvent(payload: Array("buf;5,1,1;hola mundo".utf8)) == .buffer("hola mundo", cursor: 5, selection: 1..<5))
        #expect(ShellEvent(payload: Array("buf;2,7,1;hola mundo".utf8)) == .buffer("hola mundo", cursor: 2, selection: 2..<7))
        #expect(ShellEvent(payload: Array("buf;5,1,0;hola mundo".utf8)) == .buffer("hola mundo", cursor: 5))
        #expect(ShellEvent(payload: Array("buf;0,0,0;".utf8)) == .buffer("", cursor: 0))
    }

    @Test func detectsAgents() {
        #expect(AIAgent.detect(command: "claude --continue") == .claude)
        #expect(AIAgent.detect(command: "npx @openai/codex") == .codex)
        #expect(AIAgent.detect(command: "ollama run llama3.2") == .ollama)
        #expect(AIAgent.detect(command: "FOO=1 /opt/homebrew/bin/opencode") == .opencode)
        #expect(AIAgent.detect(command: "git status") == nil)
        #expect(Set(AIAgent.allCases.map(\.rawValue)).count == AIAgent.allCases.count)
    }

    @Test func percentRoundTrip() {
        #expect(ShellEvent(payload: Array("buf;5;100%25 ñ".utf8)) == .buffer("100% ñ", cursor: 5))
    }
}

@Suite struct TokenizerTests {
    @Test func splitsWords() {
        let t = Tokenizer("cd Mis\\ cosas/Pro")
        #expect(t.words == ["cd", "Mis\\ cosas/Pro"])
        #expect(t.lastWordUnescaped == "Mis cosas/Pro")
        #expect(t.head == "cd ")
        #expect(!t.isTypingFirstWord)
    }

    @Test func trailingSpace() {
        let t = Tokenizer("git ")
        #expect(t.lastWord == "")
        #expect(t.head == "git ")
        #expect(!t.isTypingFirstWord)
        #expect(Tokenizer("gi").isTypingFirstWord)
    }

    @Test func escapes() {
        #expect(Tokenizer.escape("Mis cosas (1)/") == "Mis\\ cosas\\ \\(1\\)/")
        #expect(Tokenizer.escape("~/Proyectos") == "~/Proyectos")
    }
}

@Suite struct EngineTests {
    func engine(_ commands: [(String, String)], entries: [DirectoryEntry] = []) -> SuggestionEngine {
        var h = HistoryIndex()
        let now = Date()
        for (i, (c, d)) in commands.enumerated() {
            h.record(CommandRecord(command: c, directory: d, date: now.addingTimeInterval(Double(i))))
        }
        var dirs = DirectoryIndex()
        dirs.visit(NSHomeDirectory())
        return SuggestionEngine(history: h, directories: dirs, context: ProjectContext(),
                                executables: PrefixIndex(["git", "gzip", "go"]), listDirectory: { _ in entries })
    }

    @Test func historyPrefixAndGhost() {
        let e = engine([("git status", "/p"), ("git push", "/p"), ("git status", "/p")])
        let s = e.suggestions(buffer: "git st", cwd: "/p")
        #expect(s.first?.replacement == "git status")
        #expect(e.ghost(buffer: "git st", cwd: "/p") == "atus")
    }

    @Test func predictsNextCommand() {
        let e = engine([("git add .", "/p"), ("git commit -m \"x\"", "/p"), ("git add .", "/p"),
                        ("git commit -m \"y\"", "/p"), ("ls", "/p"), ("git add .", "/p")])
        let p = e.predictions(cwd: "/p")
        #expect(p.first?.replacement.hasPrefix("git commit") == true)
    }

    @Test func directoryAffinity() {
        let e = engine([("npm run dev", "/web"), ("npm run dev", "/web"), ("npm run test", "/api"), ("npm run test", "/api")])
        #expect(e.suggestions(buffer: "npm run", cwd: "/web").first?.replacement == "npm run dev")
        #expect(e.suggestions(buffer: "npm run", cwd: "/api").first?.replacement == "npm run test")
    }

    @Test func pathsForCd() {
        let e = engine([], entries: [DirectoryEntry(name: "Proyectos", isDirectory: true),
                                     DirectoryEntry(name: "Pelis", isDirectory: true),
                                     DirectoryEntry(name: "Presupuesto.pdf", isDirectory: false),
                                     DirectoryEntry(name: "Mis cosas", isDirectory: true)])
        let s = e.suggestions(buffer: "cd Pr", cwd: "/x")
        #expect(s.map(\.replacement).contains("cd Proyectos/"))
        #expect(!s.map(\.replacement).contains("cd Presupuesto.pdf"))
        #expect(e.suggestions(buffer: "cd Mis", cwd: "/x").first?.replacement == "cd Mis\\ cosas/")
        #expect(e.suggestions(buffer: "open Pre", cwd: "/x").first?.replacement == "open Presupuesto.pdf")
    }

    @Test func subcommandsAndExecutables() {
        let e = engine([])
        #expect(e.suggestions(buffer: "gi", cwd: "/x").contains { $0.replacement == "git " })
        #expect(e.suggestions(buffer: "git sw", cwd: "/x").contains { $0.replacement.hasPrefix("git switch") })
    }

    @Test func ignoresSecrets() {
        var h = HistoryIndex()
        h.record(CommandRecord(command: "export API_KEY=abc", directory: nil, date: Date()))
        #expect(h.stats.isEmpty)
    }

    @Test func fastWithLargeHistory() {
        var commands: [(String, String)] = []
        for i in 0..<20_000 { commands.append(("comando-\(i % 5000) --opcion \(i)", "/d\(i % 50)")) }
        let e = engine(commands)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for prefix in ["c", "co", "com", "comando-1", "comando-12", "git", "cd "] {
                _ = e.suggestions(buffer: prefix, cwd: "/d1")
            }
        }
        #expect(elapsed < .milliseconds(200), "Demasiado lento: \(elapsed)")
    }
}

@Suite struct ImportTests {
    @Test func zshHistoryExtendedAndMultiline() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("faro-hist-\(UUID())")
        var data = Data(": 1700000000:0;ls -la\n: 1700000100:0;echo uno\\\ndos\n".utf8)
        data.append(contentsOf: [0x65, 0x63, 0x68, 0x6F, 0x20, 0xC3, 0x83, 0x91, 0x0A])
        try data.write(to: url)
        let records = ZshHistoryImporter.load(from: url)
        #expect(records.map(\.command) == ["ls -la", "echo uno\ndos", "echo ñ"])
        #expect(records.first?.date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func makeTargets() {
        let targets = ProjectDetector.makeTargets("CC := gcc\nall: build\nbuild:\n\tgo build\n.PHONY: all\ntest: build\n")
        #expect(targets == ["all", "build", "test"])
    }

    @Test func settingsToleratesMissingKeys() throws {
        let s = try JSONDecoder().decode(FaroSettings.self, from: Data(#"{"fontSize": 16}"#.utf8))
        #expect(s.fontSize == 16)
        #expect(s.themeID == Theme.faroNoche.id)
        #expect(s.tabsInSidebar == false)
    }

    @Test func themesAreValid() {
        #expect(Set(Theme.all.map(\.id)).count == Theme.all.count)
        #expect(Theme.all.count >= 12)
    }
}

@Suite struct ShellScriptTests {
    @Test(arguments: [ShellIntegration.script, ShellIntegration.zshenv])
    func zshSyntaxIsValid(_ script: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("faro-\(UUID()).zsh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-n", url.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 0, "\(message)")
    }
}

@Suite struct AgentScreenTests {
    @Test func claudeWorkingWithTodos() {
        let lines = [
            "⏺ Update Todos",
            "  ⎿  ☒ Leer el proyecto",
            "     ☒ Crear el modelo",
            "     ☐ Escribir los tests",
            "     ☐ Compilar",
            "",
            "✻ Pondering… (12s · ↑ 1.2k tokens · esc to interrupt)",
        ]
        let s = AgentScreenReader.read(lines)
        #expect(s.working)
        #expect(s.tasksDone == 2 && s.tasksTotal == 4)
        #expect(s.progress == 0.5)
        #expect(s.status == "Pondering…")
    }

    @Test func codexWorking() {
        #expect(AgentScreenReader.read(["• Working (8s • esc to interrupt)"]).working)
        #expect(AIAgent.detect(command: "clear; claude \"$(</tmp/a;b.txt)\"") == .claude)
        #expect(AIAgent.detect(command: "cd web && codex") == .codex)
        #expect(AIAgent.detect(command: "echo \"claude; hola\"") == nil)
        let held = AgentScreenReader.read(["✻ Bootstrapping… (12s · thinking)", "Do you want to proceed?", "❯ 1. Yes", "  2. Yes, and switch to auto mode", "  3. No"])
        #expect(held.needsInput && !held.working)
        let narrow = AgentScreenReader.read(["● Checking Intl euro formatting", "✻ Fermenting… (20s · thinking)", "❯ ", "⏵⏵ auto mode on"])
        #expect(narrow.working)
        #expect(narrow.status == "Fermenting…")
        #expect(AgentScreenReader.read(["· Running… (1m 20s · ↓ 2.1k tokens)"]).working)
        #expect(!AgentScreenReader.read(["Terminó en 12s", "❯ "]).working)
    }

    @Test func waitingForPermission() {
        let s = AgentScreenReader.read(["Bash command", "  rm -rf build", "Do you want to proceed?", "❯ 1. Yes", "  2. No"])
        #expect(!s.working)
        #expect(s.needsInput)
    }

    @Test func idleScreen() {
        let s = AgentScreenReader.read(["╭────╮", "│ >  │", "╰────╯", "  ? for shortcuts"])
        #expect(!s.working && !s.needsInput && s.tasksTotal == nil)
    }

    @Test func trackerFinishes() {
        var t = AgentTracker()
        let start = Date()
        t.update(AgentScreen(working: true), outputRecently: true, now: start)
        #expect(t.phase == .working(since: start))
        t.update(AgentScreen(), outputRecently: false, now: start.addingTimeInterval(10))
        #expect(t.phase == .working(since: start))
        t.update(AgentScreen(), outputRecently: false, now: start.addingTimeInterval(11))
        #expect(t.phase == .finished(at: start.addingTimeInterval(11), after: 11))
        t.acknowledge()
        #expect(t.phase == .idle)
    }

    @Test func shortBurstsAreNotFinishes() {
        var t = AgentTracker()
        let start = Date()
        t.update(AgentScreen(working: true), outputRecently: true, now: start)
        t.update(AgentScreen(), outputRecently: false, now: start.addingTimeInterval(1))
        t.update(AgentScreen(), outputRecently: false, now: start.addingTimeInterval(2))
        #expect(t.phase == .idle)
    }
}

@Suite struct PortTests {
    @Test func parsesProcArgs() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { bytes += $0 }
        bytes += Array("/usr/local/bin/node".utf8) + [0, 0, 0]
        bytes += Array("node".utf8) + [0] + Array("next".utf8) + [0] + Array("dev".utf8) + [0]
        bytes += Array("PATH=/bin".utf8) + [0]
        #expect(PortScanner.parseArguments(bytes) == ["node", "next", "dev"])
    }

    @Test func labels() {
        #expect(ServerKind.label(name: "node", arguments: ["node", "/p/node_modules/.bin/next", "dev"]) == "Next.js")
        #expect(ServerKind.label(name: "next-server (v15.1.0)", arguments: ["next-server (v15.1.0)"]) == "Next.js")
        #expect(ServerKind.label(name: "node", arguments: ["node", "/p/node_modules/.bin/vite"]) == "Vite")
        #expect(ServerKind.label(name: "Python", arguments: ["python3", "-m", "http.server", "8000"]) == "Python http.server")
        #expect(ServerKind.label(name: "postgres", arguments: ["postgres", "-D", "/x"]) == "PostgreSQL")
        #expect(ServerKind.label(name: "rapportd", arguments: ["rapportd"]) == nil)
    }

    @Test func rootClimbsWrappersButStopsAtShellAndAgent() {
        let server = ListeningPort(
            port: 3000, pid: 40, name: "next-server (v15)", arguments: ["next-server (v15)"], executable: "/opt/homebrew/bin/node",
            parents: [
                ProcessNode(pid: 30, name: "node", arguments: ["node", "/p/node_modules/.bin/next", "dev"]),
                ProcessNode(pid: 20, name: "npm run dev", arguments: ["npm run dev"]),
                ProcessNode(pid: 10, name: "zsh", arguments: ["/bin/zsh", "-c", "npm run dev"]),
                ProcessNode(pid: 5, name: "claude", arguments: ["claude"]),
            ])
        #expect(server.root == 20)
        #expect(server.launchedBy == .claude)
        #expect(server.label == "Next.js")
        #expect(!server.isApp)

        let direct = ListeningPort(port: 8000, pid: 50, name: "Python", arguments: ["python3", "-m", "http.server"],
                                   executable: "/usr/bin/python3", parents: [ProcessNode(pid: 10, name: "-zsh", arguments: ["-zsh"])])
        #expect(direct.root == 50)
        #expect(direct.launchedBy == nil)

        let script = ListeningPort(port: 8001, pid: 80, name: "Python", arguments: ["python3", "-m", "http.server"], executable: "/usr/bin/python3",
                                   parents: [ProcessNode(pid: 79, name: "bash", arguments: ["/bin/bash", "/p/bin/npm", "run", "dev"]),
                                             ProcessNode(pid: 78, name: "zsh", arguments: ["/bin/zsh", "-c", "npm run dev"])])
        #expect(script.root == 79)

        let app = ListeningPort(port: 7000, pid: 60, name: "ControlCenter", arguments: [],
                                executable: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter")
        #expect(app.isApp)

        let python = ListeningPort(port: 8000, pid: 70, name: "Python", arguments: ["python3", "-m", "http.server"],
                                   executable: "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python")
        #expect(!python.isApp)
    }

    @Test func findsOwnListeningSocket() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(bound == 0)
        #expect(listen(fd, 4) == 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))

        let clock = ContinuousClock()
        var ports: [ListeningPort] = []
        let elapsed = clock.measure { ports = PortScanner.scan() }
        let mine = try #require(ports.first { $0.pid == getpid() && $0.port == port })
        #expect(PortScanner.isListening(port: port))
        #expect(mine.localOnly)
        #expect(!mine.arguments.isEmpty)
        #expect(elapsed < .milliseconds(500))
        print("scan: \(ports.count) puertos en \(elapsed)")
        if ProcessInfo.processInfo.environment["FARO_PRINT_PORTS"] != nil {
            for p in ports { print(p.port, p.label, p.isApp ? "app" : "dev", p.directory ?? "-", p.root, p.launchedBy?.name ?? "-", p.parents.map(\.name)) }
        }
    }
}

@Suite struct LinkTests {
    let files: [String: Bool] = [
        "/p/src/app/page.tsx": false, "/p/src": true, "/p/README.md": false, "/root/lib/util.ts": false, "/home/u/notes.txt": false,
    ]
    func exists(_ path: String) -> (exists: Bool, isDirectory: Bool) { (files[path] != nil, files[path] ?? false) }

    @Test func pathsWithLines() {
        #expect(LinkTarget.resolve("src/app/page.tsx:42", directory: "/p", exists: exists) == .file(path: "/p/src/app/page.tsx", line: 42, column: nil))
        #expect(LinkTarget.resolve("src/app/page.tsx:42:7:", directory: "/p", exists: exists) == .file(path: "/p/src/app/page.tsx", line: 42, column: 7))
        #expect(LinkTarget.resolve("(src/app/page.tsx(12,3))", directory: "/p", exists: exists) == .file(path: "/p/src/app/page.tsx", line: 12, column: 3))
        #expect(LinkTarget.resolve("./README.md.", directory: "/p", exists: exists) == .file(path: "/p/README.md", line: nil, column: nil))
        #expect(LinkTarget.resolve("b/src/app/page.tsx", directory: "/p", exists: exists) == .file(path: "/p/src/app/page.tsx", line: nil, column: nil))
        #expect(LinkTarget.resolve("lib/util.ts:3", directory: "/p", roots: ["/root"], exists: exists) == .file(path: "/root/lib/util.ts", line: 3, column: nil))
        #expect(LinkTarget.resolve("src", directory: "/p", exists: exists) == .directory("/p/src"))
        #expect(LinkTarget.resolve("missing.ts:4", directory: "/p", exists: exists) == nil)
        #expect(LinkTarget.resolve("file:///p/README.md#L9", directory: "/x", exists: exists) == .file(path: "/p/README.md", line: 9, column: nil))
    }

    @Test func urls() {
        #expect(LinkTarget.resolve("https://acopio.app/x).", directory: "/p", exists: exists) == .web(URL(string: "https://acopio.app/x")!))
        #expect(LinkTarget.resolve("localhost:3000/api", directory: "/p", exists: exists) == .web(URL(string: "http://localhost:3000/api")!))
        #expect(LinkTarget.resolve("mailto:a@b.com", directory: "/p", exists: exists) == .web(URL(string: "mailto:a@b.com")!))
        #expect(LinkTarget.resolve("slack://open", directory: "/p", exists: exists) == .other("slack://open"))
    }

    @Test func editorURLs() {
        #expect(CodeEditor.cursor.url(path: "/Users/me/Faro Terminal/a.swift", line: 12, column: 4)?.absoluteString
                == "cursor://file/Users/me/Faro%20Terminal/a.swift:12:4")
        #expect(CodeEditor.zed.url(path: "/a/b.rs", line: nil, column: nil)?.absoluteString == "zed://file/a/b.rs")
        #expect(CodeEditor.xcode.url(path: "/a", line: 1, column: nil) == nil)
        #expect(CodeEditor.cursor.command(path: "/a b/c.ts", line: 4, column: 2)?.arguments == ["--goto", "/a b/c.ts:4:2"])
        #expect(CodeEditor.antigravity.command(path: "/a", line: 1, column: nil) == nil)
    }
}

@Suite struct WorkspaceTests {
    @Test func roundTripAndResume() throws {
        let tab = WorkspaceSnapshot.Tab(root: .split(horizontal: true, fraction: 0.6,
            first: .leaf(.init(directory: "/p", agent: "claude", agentTab: true, claudeSession: "05158b5d-6388-41ac-b492-05673af9cc21", shellPid: 99)),
            second: .leaf(.init(directory: "/p/web"))), focused: 1)
        let snapshot = WorkspaceSnapshot(windows: [.init(frame: [10, 20, 900, 600], tabs: [tab], selectedTab: 0)], savedAt: Date(timeIntervalSince1970: 1_000))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("faro-ws-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try snapshot.save(to: url)
        let loaded = try #require(WorkspaceSnapshot.load(from: url))
        // El pid de la shell no se guarda.
        #expect(loaded.windows[0].tabs[0].root.leaves[0].shellPid == nil)
        #expect(loaded.windows[0].tabs[0].root.leaves.map(\.directory) == ["/p", "/p/web"])
        #expect(loaded.windows[0].tabs[0].root.leaves[0].resumeCommand == "claude --resume 05158b5d-6388-41ac-b492-05673af9cc21")
        #expect(loaded.windows[0].tabs[0].root.leaves[1].resumeCommand == nil)
        #expect(WorkspaceSnapshot.Leaf(directory: "/", agent: "claude", claudeSession: "x; rm -rf ~").resumeCommand == "claude --continue")
        #expect(WorkspaceSnapshot.Leaf(directory: "/", agent: "codex").resumeCommand == "codex")
    }

    @Test func findsClaudeUnderShell() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("faro-claude-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "05158b5d-6388-41ac-b492-05673af9cc21"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/-p"), withIntermediateDirectories: true)
        try Data("{\"pid\": 300, \"sessionId\": \"\(id)\"}".utf8).write(to: root.appendingPathComponent("sessions/300.json"))
        let children: [Int32: [Int32]] = [100: [200], 200: [300]]
        // Sin transcripción todavía no hay nada que retomar: Claude nuevo.
        #expect(ClaudeSessions.running(under: 100, children: children, directory: root) == "")
        #expect(WorkspaceSnapshot.Leaf(directory: "/", agent: "claude", claudeSession: "").resumeCommand == "claude")
        try Data("{}".utf8).write(to: root.appendingPathComponent("projects/-p/\(id).jsonl"))
        #expect(ClaudeSessions.running(under: 100, children: children, directory: root) == id)
        #expect(ClaudeSessions.running(under: 999, children: children, directory: root) == nil)
        // Con el Claude de verdad de este Mac (solo lectura), si hay alguno en marcha.
        if ProcessInfo.processInfo.environment["FARO_REAL_CLAUDE"] != nil {
            let table = PortScanner.childrenTable()
            for (parent, kids) in table where kids.contains(where: { ClaudeSessions.sessionID(pid: $0, directory: ClaudeSessions.defaultDirectory) != nil }) {
                print("shell \(parent) → \(ClaudeSessions.running(under: parent, children: table) ?? "nada")")
            }
        }
    }
}

@Suite struct PortConflictTests {
    @Test func messages() {
        let cases: [(String, Int)] = [
            ("Error: listen EADDRINUSE: address already in use :::3000\n    at Server.setupListenHandle", 3000),
            ("Error: listen EADDRINUSE: address already in use 127.0.0.1:8080", 8080),
            (" ⚠ Port 3000 is in use, using available port 3001 instead.", 3000),
            ("Port 5173 is in use, trying another one...", 5173),
            ("error when starting dev server:\nError: Port 5173 is already in use", 5173),
            ("› Port 8081 is being used by another process", 8081),
            ("Address already in use - bind(2) for \"127.0.0.1\" port 3000 (Errno::EADDRINUSE)", 3000),
            ("listen tcp :8080: bind: address already in use", 8080),
            ("Bind for 0.0.0.0:5432 failed: port is already allocated", 5432),
            ("Address already in use\nPort 5000 is in use by another program.", 5000),
        ]
        for (output, port) in cases {
            #expect(PortConflict.port(in: output) == port, "\(output)")
        }
        #expect(PortConflict.port(in: "Compiled successfully in 1.2s") == nil)
        #expect(PortConflict.port(in: "Ready on http://localhost:3000") == nil)
    }

    @Test func fromCommand() {
        #expect(PortConflict.port(in: "OSError: [Errno 48] Address already in use", command: "python3 -m http.server 8765") == 8765)
        #expect(PortConflict.port(in: "Error: That port is already in use.", command: "python manage.py runserver") == 8000)
        #expect(PortConflict.port(inCommand: "PORT=4000 node server.js") == 4000)
        #expect(PortConflict.port(inCommand: "npm run dev -- --port 3002") == 3002)
        #expect(PortConflict.port(inCommand: "rails s -p 3001") == 3001)
        #expect(PortConflict.port(inCommand: "npm run dev") == nil)
    }
}

@Suite struct ProjectTests {
    func context(_ commands: [String]) -> ProjectContext {
        var c = ProjectContext()
        c.commands = commands.map { ProjectCommand($0, "") }
        return c
    }

    @Test func suggestedLayout() {
        let p = Project.suggested(directory: "/Users/me/Proyectos/acopio", context: context(["pnpm dev", "pnpm build", "git status"]), claude: true)
        #expect(p.name == "acopio")
        #expect(p.layout.terminals.map(\.command) == ["claude", "pnpm dev", nil])
        #expect(p.summary == "Claude · pnpm dev · shell")
        let plain = Project.suggested(directory: "/x", context: context(["cargo run"]), claude: false)
        #expect(plain.layout.terminals.count == 1)
        #expect(Project.devCommand(context(["npm run build", "npm run start"])) == "npm run start")
        #expect(Project.devCommand(context(["npx expo start", "npm install"])) == "npx expo start")
    }

    @Test func editAndStore() throws {
        var p = Project.suggested(directory: "/a", context: context(["npm run dev"]), claude: true)
        p.layout = p.layout.settingCommand("claude --continue", at: 0).settingCommand(nil, at: 1)
        #expect(p.layout.terminals.map(\.command) == ["claude --continue", nil, nil])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("faro-projects-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProjectStore.save([p], to: url)
        #expect(ProjectStore.load(from: url) == [p])
    }
}

@Suite struct CommandBlockTests {
    @Test func lifecycle() {
        var blocks = CommandBlocks(limit: 3)
        blocks.begin(command: "ls", directory: "/p", row: 10)
        #expect(blocks.last?.isRunning == true)
        #expect(blocks.block(at: 14, cursorRow: 15)?.command == "ls")
        blocks.finish(exit: 0, milliseconds: 12)
        blocks.end(promptRow: 13)
        #expect(blocks.last?.endRow == 12)
        #expect(blocks.block(at: 13, cursorRow: 20) == nil)
        blocks.begin(command: "true", directory: "/p", row: 13)
        blocks.end(promptRow: 14)
        #expect(blocks.last?.endRow == 13)
        blocks.begin(command: "a", directory: "/p", row: 20)
        blocks.begin(command: "b", directory: "/p", row: 30)
        #expect(blocks.all.count == 3)
        #expect(blocks.all[1].endRow == 29)
        blocks.drop(before: 14)
        #expect(blocks.all.map(\.command) == ["a", "b"])
    }

    @Test func readsRows() {
        let rows = [(row: 40, text: "❯ npm run dev"), (row: 41, text: "> dev"), (row: 42, text: "ready")]
        #expect(CommandBlocks.commandRow(in: rows, command: "npm run dev") == 40)
        #expect(CommandBlocks.text(of: [("", false), ("Hola ", false), ("mun", false), ("do  ", true), ("", false)]) == "Hola\nmundo")
    }
}

@Suite struct GitStatusTests {
    @Test func parsesPorcelainV2() {
        let out = [
            "# branch.oid 1234", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 aaa bbb src/app page.tsx",
            "1 M. N... 100644 100644 100644 aaa bbb README.md",
            "2 R. N... 100644 100644 100644 aaa bbb R100 nuevo.swift", "viejo.swift",
            "u UU N... 100644 100644 100644 100644 a b c conflicto.ts",
            "? notas.txt",
        ].joined(separator: "\0") + "\0"
        let s = GitStatus.parse(out)
        #expect(s.branch == "main")
        #expect(s.upstream == "origin/main")
        #expect(s.ahead == 2 && s.behind == 1)
        #expect(s.files.map(\.path) == ["src/app page.tsx", "README.md", "nuevo.swift", "conflicto.ts", "notas.txt"])
        #expect(s.files.map(\.letter) == ["M", "M", "R", "!", "?"])
        #expect(s.staged == 2)
        #expect(s.conflicts == 1)
        #expect(GitStatus.parse("# branch.oid (initial)\0# branch.head main\0").isClean)
    }

    @Test func readsRealRepo() throws {
        guard let git = GitStatus.executable() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("faro-git-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", dir.path, "init", "-q", "-b", "main"]
        try p.run(); p.waitUntilExit()
        try Data("hola".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let status = try #require(GitStatus.read(directory: dir.path, git: git))
        #expect(status.branch == "main")
        #expect(status.files == [GitStatus.File(code: "??", path: "a.txt")])
        #expect(GitStatus.read(directory: "/", git: git) == nil)
    }
}
