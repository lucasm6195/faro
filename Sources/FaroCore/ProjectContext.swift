import Foundation

public struct ProjectCommand: Sendable, Equatable, Hashable {
    public var command: String
    public var detail: String
    public init(_ command: String, _ detail: String) {
        self.command = command
        self.detail = detail
    }
}

public struct ProjectContext: Sendable, Equatable {
    public enum Kind: String, Sendable { case node, swift, rust, python, make, docker, xcode, expo, go }

    public var root: String?
    public var kinds: [Kind] = []
    public var commands: [ProjectCommand] = []
    public var gitBranch: String?
    public var gitRoot: String?

    public init() {}

    public var isEmpty: Bool { root == nil && gitRoot == nil }
}

/// Detecta qué hay en una carpeta leyendo archivos, sin lanzar procesos.
public enum ProjectDetector {
    static let markers = ["package.json", "Package.swift", "Cargo.toml", "Makefile", "pyproject.toml",
                          "requirements.txt", "docker-compose.yml", "compose.yaml", "go.mod", "project.yml"]

    public static func detect(directory: String) -> ProjectContext {
        var ctx = ProjectContext()
        let fm = FileManager.default
        if let git = findGit(from: directory) {
            ctx.gitRoot = git.root
            ctx.gitBranch = git.branch
        }
        var dir = URL(fileURLWithPath: directory)
        let stop = ctx.gitRoot.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? NSHomeDirectory()
        while dir.path.count > 1 && dir.path != stop {
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            if names.contains(where: { markers.contains($0) || $0.hasSuffix(".xcodeproj") }) {
                ctx.root = dir.path
                collect(dir: dir, names: Set(names), into: &ctx)
                break
            }
            dir.deleteLastPathComponent()
        }
        if ctx.gitRoot != nil {
            ctx.commands += [
                ProjectCommand("git status", "qué has cambiado"),
                ProjectCommand("git pull", "bajar lo último"),
                ProjectCommand("git push", "subir"),
                ProjectCommand("git add . && git commit -m \"\"", "guardar todo"),
            ]
        }
        return ctx
    }

    static func collect(dir: URL, names: Set<String>, into ctx: inout ProjectContext) {
        if names.contains("package.json") {
            ctx.kinds.append(.node)
            let pm = names.contains("bun.lockb") || names.contains("bun.lock") ? "bun"
                : names.contains("pnpm-lock.yaml") ? "pnpm"
                : names.contains("yarn.lock") ? "yarn" : "npm"
            let run = pm == "npm" ? "npm run" : pm
            if let data = try? Data(contentsOf: dir.appendingPathComponent("package.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let scripts = json["scripts"] as? [String: String] {
                    let preferred = ["dev", "start", "build", "test", "lint"]
                    let sorted = scripts.keys.sorted {
                        (preferred.firstIndex(of: $0) ?? 99, $0) < (preferred.firstIndex(of: $1) ?? 99, $1)
                    }
                    for name in sorted {
                        ctx.commands.append(ProjectCommand("\(run) \(name)", scripts[name] ?? ""))
                    }
                }
                let deps = (json["dependencies"] as? [String: Any] ?? [:]).keys
                if deps.contains("expo") {
                    ctx.kinds.append(.expo)
                    ctx.commands.append(ProjectCommand("npx expo start", "arrancar Expo"))
                }
            }
            ctx.commands.append(ProjectCommand("\(pm) install", "instalar todo"))
        }
        if names.contains("Package.swift") {
            ctx.kinds.append(.swift)
            ctx.commands += [ProjectCommand("swift build", "compilar"),
                             ProjectCommand("swift run", "compilar y abrir"),
                             ProjectCommand("swift test", "pasar los tests")]
        }
        if names.contains("Cargo.toml") {
            ctx.kinds.append(.rust)
            ctx.commands += [ProjectCommand("cargo run", "compilar y abrir"),
                             ProjectCommand("cargo build --release", "compilar para publicar"),
                             ProjectCommand("cargo test", "pasar los tests"),
                             ProjectCommand("cargo clippy", "repasar el código")]
        }
        if names.contains("go.mod") {
            ctx.kinds.append(.go)
            ctx.commands += [ProjectCommand("go run .", "arrancar"), ProjectCommand("go test ./...", "pasar los tests")]
        }
        if names.contains("pyproject.toml") || names.contains("requirements.txt") {
            ctx.kinds.append(.python)
            if !names.contains(".venv") {
                ctx.commands.append(ProjectCommand("python3 -m venv .venv", "crear el .venv"))
            } else {
                ctx.commands.append(ProjectCommand("source .venv/bin/activate", "entrar en el .venv"))
            }
            if names.contains("requirements.txt") {
                ctx.commands.append(ProjectCommand("pip install -r requirements.txt", "instalar todo"))
            }
            ctx.commands.append(ProjectCommand("pytest", "pasar los tests"))
        }
        if names.contains("Makefile"),
           let text = try? String(contentsOf: dir.appendingPathComponent("Makefile"), encoding: .utf8) {
            ctx.kinds.append(.make)
            for target in makeTargets(text).prefix(8) {
                ctx.commands.append(ProjectCommand("make \(target)", "del Makefile"))
            }
        }
        if names.contains("docker-compose.yml") || names.contains("compose.yaml") {
            ctx.kinds.append(.docker)
            ctx.commands += [ProjectCommand("docker compose up -d", "levantar"),
                             ProjectCommand("docker compose logs -f", "ver los logs"),
                             ProjectCommand("docker compose down", "parar")]
        }
        if names.contains("project.yml") {
            ctx.commands.append(ProjectCommand("xcodegen generate", "rehacer el proyecto de Xcode"))
        }
        if let xcodeproj = names.sorted().first(where: { $0.hasSuffix(".xcodeproj") }) {
            ctx.kinds.append(.xcode)
            ctx.commands.append(ProjectCommand("open \(xcodeproj)", "abrir en Xcode"))
        }
    }

    static func makeTargets(_ text: String) -> [String] {
        var targets: [String] = []
        for line in text.split(separator: "\n") {
            guard let first = line.first, first.isLetter || first.isNumber || first == "_" else { continue }
            guard let colon = line.firstIndex(of: ":"), !line[colon...].hasPrefix(":=") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !name.contains(" "), !name.contains("$"), !name.contains("="), !targets.contains(name) {
                targets.append(name)
            }
        }
        return targets
    }

    /// Busca el repositorio git subiendo carpetas y lee la rama de `HEAD`.
    public static func findGit(from directory: String) -> (root: String, branch: String?)? {
        var dir = URL(fileURLWithPath: directory)
        let fm = FileManager.default
        while dir.path.count > 1 {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue,
                   let text = try? String(contentsOf: dotGit, encoding: .utf8),
                   let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = URL(fileURLWithPath: path, relativeTo: dir).standardizedFileURL
                }
                return (dir.path, readBranch(gitDir: gitDir))
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    static func readBranch(gitDir: URL) -> String? {
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") { return String(trimmed.dropFirst("ref: refs/heads/".count)) }
        return String(trimmed.prefix(7))
    }
}
