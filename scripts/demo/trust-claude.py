#!/usr/bin/env python3
"""Abre Claude Code una vez en la carpeta de ejemplo y acepta «confío en esta carpeta», para que
el aviso no salga en el vídeo. Imprime lo que se ve al arrancar (para revisarlo)."""
import fcntl, os, pty, re, select, struct, sys, termios, time

folder = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(folder)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "ANTHROPIC"))}
    env["TERM"] = "xterm-256color"
    os.execvpe("zsh", ["zsh", "-lic", "claude"], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 110, 0, 0))

screen = b""
def read(seconds):
    global screen
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                screen += os.read(fd, 65536)
            except OSError:
                return
def plain():
    return re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[=>()][0-9A-Za-z]?", b"", screen).decode("utf8", "replace")

read(6)
if "trust" in plain().replace(" ", "").lower():
    os.write(fd, b"\x1b[B")
    time.sleep(0.4)
    os.write(fd, b"\r")
    screen = b""
    read(5)
print(plain()[-2500:])
os.write(fd, b"/exit\r")
read(2)
try:
    os.kill(pid, 9)
except ProcessLookupError:
    pass
