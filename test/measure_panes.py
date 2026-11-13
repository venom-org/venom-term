#!/usr/bin/env python3
"""Probe for examples/panes.zig. Linux only.

Run after `zig build -Doptimize=ReleaseFast`:

    python3 test/measure_panes.py [lines]

Drives ./zig-out/bin/example-panes inside a PTY (as a user's terminal would),
with SHELL=/bin/sh, and reports idle CPU, `cat` latency on a large file,
OSC 7501/133 logging, resize propagation and the example's exit stats.
"""
import fcntl
import json
import os
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

BIN = "./zig-out/bin/example-panes"
COLS, ROWS = 200, 50


def set_size(fd, cols, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def cpu_ticks(pid):
    with open(f"/proc/{pid}/stat") as source:
        stat = source.read().rsplit(")", 1)[1].split()
    return int(stat[11]) + int(stat[12])  # utime + stime


def rss_kib(pid):
    with open(f"/proc/{pid}/status") as source:
        for line in source:
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    return 0


class Screen:
    """Drains the master side so the example never blocks on output."""

    def __init__(self, fd):
        self.fd, self.data, self.cond = fd, bytearray(), threading.Condition()
        threading.Thread(target=self.pump, daemon=True).start()

    def pump(self):
        while True:
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                chunk = b""
            with self.cond:
                if not chunk:
                    self.closed = True
                    self.cond.notify_all()
                    return
                self.data += chunk
                self.cond.notify_all()

    def mark(self):
        with self.cond:
            return len(self.data)

    def wait(self, needle, start, timeout=120):
        deadline = time.monotonic() + timeout
        with self.cond:
            while needle not in self.data[start:]:
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError(needle)
                self.cond.wait(left)
            return time.monotonic()


def baseline_cat(path):
    """cat into a plain PTY of the same inner size, drained as fast as possible."""
    master, slave = os.openpty()
    set_size(slave, COLS // 2 - 2, ROWS - 3)
    start = time.monotonic()
    proc = subprocess.Popen(["cat", path], stdout=slave, stderr=slave)
    os.close(slave)
    while True:
        try:
            if not os.read(master, 65536):
                break
        except OSError:
            break
    proc.wait()
    os.close(master)
    return time.monotonic() - start


def main():
    lines = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
    tmp = tempfile.mkdtemp(prefix="venom-panes-")
    big = os.path.join(tmp, "big.txt")
    with open(big, "w") as out:
        for i in range(lines):
            out.write(f"{i:08d} the quick brown fox jumps over the lazy dog 0123456789 abcdefghij\n")
    size = os.path.getsize(big)
    log_path = os.path.join(tmp, "stderr.log")

    master, slave = os.openpty()
    set_size(slave, COLS, ROWS)
    env = dict(os.environ, SHELL="/bin/sh", PS1="$ ", TERM="xterm-256color")
    env.pop("ENV", None)
    with open(log_path, "w") as log:
        proc = subprocess.Popen([BIN], stdin=slave, stdout=slave, stderr=log, env=env,
                                start_new_session=True,
                                preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
    os.close(slave)
    screen = Screen(master)
    send = lambda b: os.write(master, b)
    result = {"cols": COLS, "rows": ROWS, "file_lines": lines, "file_bytes": size}
    try:
        screen.wait(b"$", 0, 10)
        time.sleep(1.0)

        # Idle: shells at a prompt, nothing changes. Expect no CPU and no output.
        before_bytes, before = screen.mark(), cpu_ticks(proc.pid)
        time.sleep(5)
        result.update(idle_seconds=5, idle_cpu_ticks=cpu_ticks(proc.pid) - before,
                      idle_output_bytes=screen.mark() - before_bytes, idle_rss_kib=rss_kib(proc.pid))

        # cat latency: from Enter to the marker being rendered by the example.
        start_mark, ticks = screen.mark(), cpu_ticks(proc.pid)
        t0 = time.monotonic()
        send(f"cat {big}; echo CAT''DONE\r".encode())
        t1 = screen.wait(b"CATDONE", start_mark)
        result.update(cat_seconds=round(t1 - t0, 3),
                      cat_mib_per_s=round(size / (1 << 20) / (t1 - t0), 2),
                      cat_cpu_ticks=cpu_ticks(proc.pid) - ticks,
                      cat_output_bytes=screen.mark() - start_mark,
                      cat_rss_kib=rss_kib(proc.pid),
                      baseline_pty_cat_seconds=round(baseline_cat(big), 3))
        time.sleep(0.5)

        # Idle again after a large scrollback was produced.
        before = cpu_ticks(proc.pid)
        time.sleep(3)
        result["idle_after_cat_cpu_ticks_3s"] = cpu_ticks(proc.pid) - before

        # OSC observations go to stderr.
        send(b"printf '\\033]133;A\\007\\033]7501;state=working:app=build:progress=40\\007'\r")
        time.sleep(0.5)

        # Resize: the inner shell sees the new pane size (rows-3 x cols/2-2).
        set_size(master, 120, 40)
        proc.send_signal(28)  # SIGWINCH, in case the kernel did not deliver one
        time.sleep(0.3)
        mark = screen.mark()
        # Spaces may render as cursor moves, so make the reply space-free.
        send(b"stty size | tr ' ' x\r")
        screen.wait(b"37x58", mark, 5)
        result["resize_inner_rows_x_cols"] = "37x58"

        # Focus switch, input to the right pane, then quit.
        send(b"\x01o")
        time.sleep(0.2)
        mark = screen.mark()
        send(b"echo RIGHT''PANE\r")
        screen.wait(b"RIGHTPANE", mark, 5)
        send(b"\x01q")
        proc.wait(timeout=10)
        result["exit_code"] = proc.returncode
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    with open(log_path) as log:
        stderr = log.read().splitlines()
    result["osc_log"] = [line for line in stderr if line.startswith("osc")]
    result["stats"] = next((line for line in stderr if line.startswith("stats")), None)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
