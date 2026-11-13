"""Plays t-life on a pseudo-terminal, with each engine: lets it run,
pauses, steps, speeds up and slows down, starts again, and quits; then
checks that it stopped cleanly and put the terminal back as it was.

    python3 -I tests/terminal.py tests/life
"""

import fcntl
import os
import pty
import re
import select
import struct
import sys
import termios
import time

ESC = "\x1b"


def play(argv, keys, rows=24, cols=80):
    """Runs `argv` on a terminal `cols` by `rows`, typing `keys`, each a
    string, or a number of seconds to wait; gives its output, and how it
    stopped, and the terminal's settings before and after."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(argv[0], argv)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    before = termios.tcgetattr(fd)
    out = b""

    def read_for(seconds):
        nonlocal out
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                try:
                    data = os.read(fd, 1 << 16)
                except OSError:
                    return
                if not data:
                    return
                out += data

    read_for(0.5)
    for k in keys:
        if isinstance(k, (int, float)):
            read_for(k)
        else:
            os.write(fd, k.encode())
            read_for(0.2)
    deadline = time.time() + 10
    while True:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            break
        if time.time() > deadline:
            os.kill(pid, 9)
            sys.exit("FAIL: it didn't stop when told to")
        read_for(0.1)
    read_for(0.2)
    after = termios.tcgetattr(fd)
    os.close(fd)
    return out.decode("utf-8", "replace"), status, before, after


def frames(text):
    """The frames drawn, without colours: each starts at the top left. The
    other screen starts with one that's empty, which isn't one."""
    plain = [re.sub(ESC + r"\[[0-9;?]*[A-Za-z]", "", f) for f in text.split(ESC + "[H")]
    return [f for f in plain[1:] if f.strip()]


def status(frame):
    """A frame's last line: the words under the board."""
    return frame.rstrip("\r\n").split("\r\n")[-1]


def gen(frame):
    """The generation a frame says it shows."""
    m = re.match(r"gen (\d+) ", status(frame))
    return int(m.group(1)) if m else None


def check(what, ok):
    if not ok:
        sys.exit("FAIL: " + what)


def main():
    exe = sys.argv[1]
    for engine in ["pool", "spawn", "one"]:
        # Run a moment, pause, step twice, go on twice as fast, slow down,
        # start again, and quit.
        keys = [0.5, " ", 0.3, "n", "n", 0.3, " ", "+", 0.5, "-", "r", 0.3, "q"]
        text, how, before, after = play([exe, "--engine", engine, "--threads", "3"], keys)
        what = engine + ": "
        check(what + "it stopped cleanly", os.WIFEXITED(how) and os.WEXITSTATUS(how) == 0)
        check(what + "it used the other screen", ESC + "[?1049h" in text)
        check(what + "it went back to the first screen", text.rstrip().endswith(ESC + "[?1049l"))
        check(what + "it showed the cursor again", ESC + "[?25h" in text)
        check(what + "the terminal's as it was", before == after)
        shown = frames(text)
        check(what + "it drew frames", len(shown) > 10)
        # Each frame fills the terminal: 23 lines of cells, 46 rows, and a
        # line of words, all at most 80 wide.
        lines = shown[0].rstrip("\r\n").split("\r\n")
        check(what + "a frame is 24 lines", len(lines) == 24)
        check(what + "no line is wider than the terminal", all(len(l) <= 80 for l in lines))
        check(what + "it says the rule", "B3/S23" in status(shown[0]))
        gens = [gen(f) for f in shown]
        check(what + "each frame says its generation", all(g is not None for g in gens))
        paused = [g for f, g in zip(shown, gens) if "paused" in status(f)]
        check(what + "it paused", len(paused) > 2)
        # While paused, the generation changes only by the steps.
        check(what + "it stepped twice while paused", max(paused) - min(paused) == 2)
        check(what + "it went twice as fast", any("x2" in status(f) for f in shown))
        check(what + "it started again", gens[-1] < max(gens))
    print("terminal ok")


main()
