import Foundation

/// Integración con zsh. Faro arranca zsh con `ZDOTDIR` apuntando a una carpeta propia
/// cuyo `.zshenv` restaura el `ZDOTDIR` del usuario y carga `faro.zsh`, así nunca se
/// tocan los archivos de configuración del usuario.
public enum ShellIntegration {
    /// Código OSC privado que usa Faro para los eventos de la shell.
    public static let oscCode = 6973
    /// Secuencia de tecla que dispara el widget de control dentro de zle.
    public static let controlKey: [UInt8] = Array("\u{1b}[6973~".utf8)

    public static let directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Faro/shell/zsh", isDirectory: true)

    /// Escribe los scripts si faltan o han cambiado. Es idempotente y barato.
    public static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, contents) in [(".zshenv", zshenv), ("faro.zsh", script)] {
            let url = directory.appendingPathComponent(name)
            if (try? String(contentsOf: url, encoding: .utf8)) != contents {
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Variables de entorno para lanzar zsh con la integración activa.
    public static func environment(base: [String: String], controlDirectory: URL, minimalPrompt: Bool) -> [String: String] {
        var env = base
        if let userZdotdir = base["ZDOTDIR"] { env["FARO_USER_ZDOTDIR"] = userZdotdir }
        env["ZDOTDIR"] = directory.path
        env["FARO_SHELL_DIR"] = directory.path
        env["FARO_CTL"] = controlDirectory.path
        env["FARO_MINIMAL_PROMPT"] = minimalPrompt ? "1" : "0"
        return env
    }

    static let zshenv = #"""
    # Faro: devuelve ZDOTDIR a su valor original, carga tu .zshenv y luego la integración.
    if [[ -n ${FARO_USER_ZDOTDIR+x} ]]; then
      ZDOTDIR=$FARO_USER_ZDOTDIR
      unset FARO_USER_ZDOTDIR
    else
      unset ZDOTDIR
    fi
    [[ -f ${ZDOTDIR:-$HOME}/.zshenv ]] && builtin source ${ZDOTDIR:-$HOME}/.zshenv
    [[ -o interactive && -f $FARO_SHELL_DIR/faro.zsh ]] && builtin source $FARO_SHELL_DIR/faro.zsh
    """#

    static let script = #"""
    # Faro: integración con zsh. Informa a Faro de la carpeta, los comandos y la línea
    # que escribes, y le permite moverse de carpeta o rellenar la línea sin ensuciar el historial.
    [[ -o interactive ]] || return 0
    [[ -n ${_faro_loaded-} ]] && return 0
    typeset -g _faro_loaded=1
    zmodload zsh/datetime zsh/mapfile 2>/dev/null
    zmodload -F zsh/files b:zf_rm 2>/dev/null

    typeset -g _faro_ordered=0 _faro_start=0 _faro_running=0 _faro_last_buf= _faro_last_cur=-1 _faro_status=0
    typeset -g _faro_tty=${TTY:-/dev/tty}
    export TERM_PROGRAM=Faro

    _faro_enc() {
      local s=$1
      s=${s//\%/%25}; s=${s//$'\e'/%1B}; s=${s//$'\a'/%07}
      s=${s//;/%3B}; s=${s//$'\n'/%0A}; s=${s//$'\r'/%0D}
      REPLY=$s
    }
    _faro_send() { builtin print -rn -- $'\e]6973;'"$1"$'\a' >$_faro_tty }
    _faro_report_cwd() { _faro_enc "$PWD"; _faro_send "cwd;$REPLY" }

    _faro_precmd_first() {
      _faro_status=$?
      (( _faro_ordered )) || { _faro_ordered=1; _faro_order_hooks }
      if (( _faro_running )); then
        local -i ms=$(( (EPOCHREALTIME - _faro_start) * 1000 ))
        builtin print -rn -- $'\e]133;D;'"$_faro_status"$'\a' >$_faro_tty
        _faro_send "done;$_faro_status;$ms"
        _faro_running=0
      fi
      _faro_report_cwd
    }

    _faro_precmd_last() {
      if [[ ${FARO_MINIMAL_PROMPT-0} == 1 && $PS1 == '%n@%m %1~ %# ' ]]; then
        PS1='%F{4}❯%f '
      fi
      [[ $PS1 == *$'\e]133;A'* ]] || PS1="%{"$'\e]133;A\a'"%}$PS1"
      [[ $PS1 == *$'\e]133;B'* ]] || PS1="$PS1%{"$'\e]133;B\a'"%}"
      _faro_send "prompt"
    }

    # La primera vez, se coloca al principio y al final de precmd_functions para
    # capturar el estado antes que nadie y ajustar el prompt después del resto.
    _faro_order_hooks() {
      precmd_functions=(_faro_precmd_first ${precmd_functions:#(_faro_precmd_first|_faro_precmd_last)} _faro_precmd_last)
      [[ -n ${FARO_NO_HISTORY-} ]] && unset HISTFILE
      # zle no está disponible mientras se lee .zshenv: los widgets se registran aquí.
      add-zle-hook-widget line-init _faro_line_init
      add-zle-hook-widget line-pre-redraw _faro_report_buffer
      add-zle-hook-widget line-finish _faro_line_finish
      zle -N _faro_control
      local km
      for km in emacs viins vicmd; do bindkey -M $km $'\e[6973~' _faro_control; done
    \#(EditAction.zshBindings)
    }

    # Edición como en un documento (⌘⌫, ⌥←, ⇧→, ⌘Z…). Faro envía una tecla propia por acción
    # y este widget la ejecuta; las palabras se cortan en / - . como en un editor.
    _faro_edit() {
      local WORDCHARS='_' action=${WIDGET#_faro_e_}
      if [[ $action == sel-* ]]; then
        (( REGION_ACTIVE )) || { MARK=$CURSOR; REGION_ACTIVE=1 }
        action=${action#sel-}
      elif [[ $action != (kill-region|deselect|all) ]]; then
        REGION_ACTIVE=0
      fi
      case $action in
        all) MARK=0; CURSOR=${#BUFFER}; REGION_ACTIVE=1 ;;
        kill-region) (( REGION_ACTIVE )) && zle .kill-region; REGION_ACTIVE=0 ;;
        deselect) REGION_ACTIVE=0 ;;
        *) zle .$action ;;
      esac
    }

    _faro_preexec() {
      _faro_running=1
      _faro_start=$EPOCHREALTIME
      builtin print -rn -- $'\e]133;C\a' >$_faro_tty
      _faro_enc "$1"; _faro_send "exec;$REPLY"
    }

    _faro_report_buffer() {
      local state="$CURSOR,$MARK,$REGION_ACTIVE"
      [[ "$BUFFER" == "$_faro_last_buf" && $state == $_faro_last_cur ]] && return
      _faro_last_buf=$BUFFER
      _faro_last_cur=$state
      _faro_enc "$BUFFER"; _faro_send "buf;$state;$REPLY"
    }
    _faro_line_init() { _faro_last_buf=; _faro_last_cur=-1; _faro_report_buffer }
    _faro_line_finish() { _faro_send "buf;0,0,0;"; _faro_last_buf=; _faro_last_cur=-1 }

    _faro_control() {
      [[ -n ${FARO_CTL-} ]] || return 0
      local f=$FARO_CTL/request
      [[ -r $f ]] || return 0
      local data=${mapfile[$f]}
      zf_rm -f -- $f 2>/dev/null || command rm -f -- $f
      local op=${data%%$'\n'*} arg=${data#*$'\n'}
      case $op in
        cd)
          builtin cd -- "$arg" 2>/dev/null || return 0
          _faro_report_cwd
          local fn
          for fn in $precmd_functions; do [[ $fn == _faro_precmd_first ]] || $fn; done
          zle reset-prompt
          ;;
        setbuf) BUFFER=$arg; CURSOR=${#BUFFER} ;;
        insert) LBUFFER+=$arg ;;
        run) BUFFER=$arg; zle .accept-line ;;
      esac
    }

    autoload -Uz add-zsh-hook add-zle-hook-widget
    add-zsh-hook precmd _faro_precmd_first
    add-zsh-hook precmd _faro_precmd_last
    add-zsh-hook preexec _faro_preexec
    """#
}

/// Eventos que la shell envía a Faro por OSC 6973.
public enum ShellEvent: Equatable, Sendable {
    case cwd(String)
    case prompt
    case exec(String)
    case done(exit: Int32, milliseconds: Int)
    /// Línea que se está escribiendo, posición del cursor y selección (en caracteres), si la hay.
    case buffer(String, cursor: Int, selection: Range<Int>? = nil)

    public init?(payload: [UInt8]) {
        guard let text = String(bytes: payload, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "cwd" where parts.count >= 2:
            self = .cwd(Self.decode(parts.dropFirst().joined(separator: ";")))
        case "prompt":
            self = .prompt
        case "exec" where parts.count >= 2:
            self = .exec(Self.decode(parts.dropFirst().joined(separator: ";")))
        case "done" where parts.count >= 3:
            self = .done(exit: Int32(parts[1]) ?? 0, milliseconds: Int(parts[2]) ?? 0)
        case "buf" where parts.count >= 2:
            let state = parts[1].split(separator: ",").map { Int($0) ?? 0 }
            let cursor = state.first ?? 0
            var selection: Range<Int>?
            if state.count >= 3, state[2] != 0, state[1] != cursor {
                selection = min(state[1], cursor)..<max(state[1], cursor)
            }
            self = .buffer(parts.count > 2 ? Self.decode(parts[2]) : "", cursor: cursor, selection: selection)
        default:
            return nil
        }
    }

    static func decode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }
}

/// Acciones de edición tipo documento. Cada una viaja a zsh como una tecla propia (`ESC [ n ~`).
public enum EditAction: Int, CaseIterable, Sendable {
    case lineStart = 6980, lineEnd, wordLeft, wordRight
    case deleteToLineStart, deleteToLineEnd, deleteWordLeft, deleteWordRight
    case undo, redo
    case selectLeft, selectRight, selectWordLeft, selectWordRight, selectToLineStart, selectToLineEnd, selectAll
    case deleteSelection, deselect

    public var sequence: [UInt8] { Array("\u{1b}[\(rawValue)~".utf8) }

    var widget: String {
        switch self {
        case .lineStart: "beginning-of-line"
        case .lineEnd: "end-of-line"
        case .wordLeft: "backward-word"
        case .wordRight: "forward-word"
        case .deleteToLineStart: "backward-kill-line"
        case .deleteToLineEnd: "kill-line"
        case .deleteWordLeft: "backward-kill-word"
        case .deleteWordRight: "kill-word"
        case .undo: "undo"
        case .redo: "redo"
        case .selectLeft: "sel-backward-char"
        case .selectRight: "sel-forward-char"
        case .selectWordLeft: "sel-backward-word"
        case .selectWordRight: "sel-forward-word"
        case .selectToLineStart: "sel-beginning-of-line"
        case .selectToLineEnd: "sel-end-of-line"
        case .selectAll: "all"
        case .deleteSelection: "kill-region"
        case .deselect: "deselect"
        }
    }

    /// Equivalente para programas que no son la shell de Faro (Claude Code, ssh, bash…),
    /// con los atajos de readline que entienden casi todos.
    public var readlineFallback: [UInt8]? {
        switch self {
        case .lineStart: [0x01]
        case .lineEnd: [0x05]
        case .wordLeft: [0x1b, 0x62]
        case .wordRight: [0x1b, 0x66]
        case .deleteToLineStart: [0x15]
        case .deleteToLineEnd: [0x0b]
        case .deleteWordLeft: [0x1b, 0x7f]
        case .deleteWordRight: [0x1b, 0x64]
        case .undo: [0x1f]
        default: nil
        }
    }

    static var zshBindings: String {
        allCases.map { a in
            "  zle -N _faro_e_\(a.widget) _faro_edit; for km in emacs viins; do bindkey -M $km $'\\e[\(a.rawValue)~' _faro_e_\(a.widget); done"
        }.joined(separator: "\n")
    }
}
