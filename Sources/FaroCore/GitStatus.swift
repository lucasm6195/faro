import Foundation

/// Estado de un repositorio: rama, commits por subir o bajar y archivos cambiados.
public struct GitStatus: Equatable, Sendable {
    public struct File: Equatable, Sendable, Identifiable {
        /// Índice (preparado) y árbol de trabajo, como en `git status -s`: «M », « M», «??»…
        public var code: String
        public var path: String
        public var id: String { path }

        public init(code: String, path: String) {
            self.code = code
            self.path = path
        }

        public var isUntracked: Bool { code == "??" }
        public var isConflict: Bool { code.contains("U") || code == "AA" || code == "DD" }
        public var isStaged: Bool { !isUntracked && !isConflict && code.first.map { $0 != "." && $0 != " " } == true }

        /// Letra para mostrar: M modificado, A añadido, D borrado, R renombrado, ? nuevo, ! conflicto.
        public var letter: String {
            if isConflict { return "!" }
            if isUntracked { return "?" }
            let relevant = code.first(where: { $0 != "." && $0 != " " }) ?? "M"
            return String(relevant)
        }
    }

    public var branch: String?
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var files: [File] = []

    public init(branch: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0, files: [File] = []) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.files = files
    }

    public var changes: Int { files.count }
    public var staged: Int { files.filter(\.isStaged).count }
    public var conflicts: Int { files.filter(\.isConflict).count }
    public var isClean: Bool { files.isEmpty }

    /// Salida de `git status --porcelain=v2 --branch -z`.
    public static func parse(_ output: String) -> GitStatus {
        var status = GitStatus()
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let record = fields.popFirst() {
            if record.hasPrefix("# ") {
                let parts = record.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.head": status.branch = parts[1] == "(detached)" ? nil : parts[1]
                case "branch.upstream": status.upstream = parts[1]
                case "branch.ab":
                    for token in parts[1].split(separator: " ") {
                        if token.hasPrefix("+") { status.ahead = Int(token.dropFirst()) ?? 0 }
                        if token.hasPrefix("-") { status.behind = Int(token.dropFirst()) ?? 0 }
                    }
                default: break
                }
                continue
            }
            let kind = record.first
            switch kind {
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let parts = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                if parts.count == 9 { status.files.append(File(code: String(parts[1]), path: String(parts[8]))) }
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path, seguido de la ruta original en otro campo
                let parts = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                if parts.count == 10 { status.files.append(File(code: String(parts[1]), path: String(parts[9]))) }
                _ = fields.popFirst()
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let parts = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                if parts.count == 11 { status.files.append(File(code: String(parts[1]), path: String(parts[10]))) }
            case "?":
                status.files.append(File(code: "??", path: String(record.dropFirst(2))))
            default:
                break
            }
        }
        return status
    }

    /// Ejecuta `git status` en esa carpeta sin bloquear el repositorio para otros procesos
    /// (`--no-optional-locks`). Tarda unos milisegundos; nil si no es un repositorio o tarda
    /// más de 3 s.
    public static func read(directory: String, git: String) -> GitStatus? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["--no-optional-locks", "-C", directory, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// El git de Homebrew si existe; si no, el de las herramientas de Xcode (sin el atajo de
    /// /usr/bin/git, que pide instalarlas si faltan).
    public static func executable() -> String? {
        ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
         "/Applications/Xcode.app/Contents/Developer/usr/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
