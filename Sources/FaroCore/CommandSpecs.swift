import Foundation

/// Comandos habituales con sus subcomandos y una explicación corta en español.
public enum CommandSpecs {
    public static let descriptions: [String: String] = [
        "cd": "ir a otra carpeta", "ls": "ver qué hay aquí", "open": "abrir con su app",
        "git": "tu repo", "npm": "paquetes de Node", "pnpm": "como npm, pero más rápido",
        "bun": "Node, pero más rápido", "yarn": "paquetes de Node", "npx": "probar un paquete sin instalarlo",
        "brew": "instalar cosas en el Mac", "docker": "contenedores", "swift": "proyectos de Swift",
        "cargo": "proyectos de Rust", "python3": "Python", "pip": "paquetes de Python",
        "claude": "hablar con Claude aquí", "code": "abrir en VS Code", "cursor": "abrir en Cursor",
        "cat": "ver un archivo", "mkdir": "carpeta nueva", "rm": "borrar (no va a la papelera)", "mv": "mover o cambiar de nombre",
        "cp": "copiar", "touch": "archivo vacío", "grep": "buscar texto dentro", "find": "buscar archivos",
        "curl": "llamar a una URL", "ssh": "entrar en otro ordenador", "vim": "editar en la terminal", "nano": "editar en la terminal, fácil",
        "xcodebuild": "compilar con Xcode", "xcodegen": "rehacer el proyecto de Xcode", "make": "lo que diga el Makefile",
        "node": "Node", "top": "qué está gastando", "htop": "qué está gastando", "kill": "cerrar un proceso",
        "vercel": "subir a Vercel", "supabase": "Supabase", "stripe": "Stripe", "gh": "GitHub desde aquí",
    ]

    public static let subcommands: [String: [ProjectCommand]] = [
        "git": [
            ProjectCommand("git status", "qué has cambiado"), ProjectCommand("git add .", "añadir todo"),
            ProjectCommand("git commit -m \"\"", "guardar con un mensaje"), ProjectCommand("git push", "subir"),
            ProjectCommand("git pull", "bajar lo último"), ProjectCommand("git switch -c ", "rama nueva"),
            ProjectCommand("git switch ", "cambiar de rama"), ProjectCommand("git log --oneline --graph", "historial"),
            ProjectCommand("git diff", "ver qué cambia"), ProjectCommand("git stash", "guardar para luego"),
            ProjectCommand("git stash pop", "recuperar lo guardado"), ProjectCommand("git branch", "ver las ramas"),
            ProjectCommand("git clone ", "copiar un repo"), ProjectCommand("git restore ", "deshacer los cambios de un archivo"),
        ],
        "npm": [
            ProjectCommand("npm install", "instalar todo"), ProjectCommand("npm run dev", "arrancar en local"),
            ProjectCommand("npm run build", "compilar"), ProjectCommand("npm test", "pasar los tests"),
            ProjectCommand("npm install -D ", "añadir solo para desarrollo"), ProjectCommand("npm outdated", "qué se ha quedado viejo"),
        ],
        "brew": [
            ProjectCommand("brew install ", "instalar"), ProjectCommand("brew install --cask ", "instalar una app"),
            ProjectCommand("brew upgrade", "actualizar todo"), ProjectCommand("brew update", "ver qué hay nuevo"),
            ProjectCommand("brew search ", "buscar"), ProjectCommand("brew list", "lo que tienes"),
            ProjectCommand("brew services list", "lo que arranca solo"), ProjectCommand("brew cleanup", "hacer sitio"),
        ],
        "docker": [
            ProjectCommand("docker ps", "qué está en marcha"), ProjectCommand("docker compose up -d", "levantar"),
            ProjectCommand("docker compose down", "parar"), ProjectCommand("docker images", "imágenes"),
            ProjectCommand("docker logs -f ", "ver los logs"), ProjectCommand("docker system prune", "limpiar"),
        ],
        "swift": [
            ProjectCommand("swift build", "compilar"), ProjectCommand("swift run", "compilar y abrir"),
            ProjectCommand("swift test", "pasar los tests"), ProjectCommand("swift package resolve", "bajar las dependencias"),
        ],
        "claude": [
            ProjectCommand("claude", "empezar aquí"), ProjectCommand("claude --continue", "seguir donde lo dejaste"),
            ProjectCommand("claude --resume", "elegir una conversación"), ProjectCommand("claude -p \"\"", "preguntar algo rápido"),
        ],
        "gh": [
            ProjectCommand("gh pr create", "abrir un PR"), ProjectCommand("gh pr list", "ver los PR"),
            ProjectCommand("gh repo view --web", "abrir el repo en el navegador"), ProjectCommand("gh auth login", "entrar"),
        ],
        "ls": [ProjectCommand("ls -la", "todo, también lo oculto")],
        "open": [ProjectCommand("open .", "abrir en Finder")],
        "code": [ProjectCommand("code .", "abrir en VS Code")],
        "cursor": [ProjectCommand("cursor .", "abrir en Cursor")],
    ]

    /// Comandos cuyo argumento suele ser una ruta.
    public static let takesPath: Set<String> = [
        "cd", "ls", "open", "cat", "less", "code", "cursor", "vim", "nano", "rm", "mv", "cp", "touch",
        "mkdir", "source", "bat", "head", "tail", "zed", "xed", "chmod", "du", "tree",
    ]
    public static let takesDirectoryOnly: Set<String> = ["cd", "pushd", "z"]
}

/// Puntuación difusa sencilla: prefijo > inicio de palabra > subsecuencia.
public enum Fuzzy {
    public static func score(_ query: String, in candidate: String) -> Double? {
        if query.isEmpty { return 0.1 }
        let q = query.lowercased(), c = candidate.lowercased()
        if c.hasPrefix(q) { return 1.0 + Double(q.count) / Double(max(c.count, 1)) }
        if c.contains(" " + q) || c.contains("/" + q) || c.contains("-" + q) { return 0.7 }
        if c.contains(q) { return 0.5 }
        var qi = q.startIndex
        var gaps = 0
        var lastMatch: String.Index?
        for ci in c.indices where qi < q.endIndex {
            if c[ci] == q[qi] {
                if let last = lastMatch, c.index(after: last) != ci { gaps += 1 }
                lastMatch = ci
                qi = q.index(after: qi)
            }
        }
        guard qi == q.endIndex else { return nil }
        return max(0.05, 0.4 - Double(gaps) * 0.05)
    }
}
