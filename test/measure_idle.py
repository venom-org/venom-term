#!/usr/bin/env python3
"""Linux resource probe. Run after zig build -Doptimize=ReleaseFast."""
import concurrent.futures
import json
import subprocess
import time


def measure(case):
    count, width, height = case
    process = subprocess.Popen(
        ["./zig-out/bin/term-bench", str(count), str(width), str(height)],
        stderr=subprocess.PIPE, text=True,
    )
    try:
        ready = process.stderr.readline().strip()
        if not ready.endswith("idle_ready"):
            raise RuntimeError(ready)

        def sample():
            with open(f"/proc/{process.pid}/stat") as source:
                stat = source.read().split()
            with open(f"/proc/{process.pid}/status") as source:
                status = dict(line.split(":", 1) for line in source if ":" in line)
            return (
                int(stat[13]) + int(stat[14]),
                int(status["VmRSS"].split()[0]),
                int(status["Threads"]),
            )

        before = sample()
        time.sleep(3)
        after = sample()
        _, stderr = process.communicate(timeout=15)
        if process.returncode:
            raise RuntimeError(stderr)
        return dict(
            panes=count, cols=width, rows=height, report=ready,
            idle_seconds=3, idle_cpu_ticks=after[0] - before[0],
            rss_kib=after[1], threads=after[2],
        )
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


if __name__ == "__main__":
    with concurrent.futures.ThreadPoolExecutor() as pool:
        for result in pool.map(measure, [(1, 80, 24), (32, 80, 24), (1, 250, 80), (32, 250, 80)]):
            print(json.dumps(result))
