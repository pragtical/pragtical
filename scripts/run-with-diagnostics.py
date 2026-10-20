#!/usr/bin/env python3
"""Run a POSIX command, capturing macOS stacks if its output goes silent.

Example: python3 scripts/run-with-diagnostics.py --output /tmp/test-diagnostics \
    -- ./scripts/run-local build test scripts/lua/tests
"""

import argparse
import os
from pathlib import Path
import selectors
import shlex
import signal
import subprocess
import sys
import time


def process_tree(root_pid):
    """Return process state and owned descendants, including separate groups."""
    state = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,pgid=,pcpu=,state=,comm="],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, timeout=10, check=True,
    ).stdout
    rows = [line.split(None, 5) for line in state.splitlines()]
    owned = {str(root_pid)}
    while True:
        descendants = {row[0] for row in rows if len(row) == 6 and row[1] in owned}
        if descendants <= owned:
            break
        owned.update(descendants)
    return state, [row for row in rows if len(row) == 6 and row[0] in owned]


def capture_stacks(process_group, output, log):
    """Save process state and sample Pragtical and its child processes on macOS."""
    try:
        processes, owned = process_tree(process_group)
        (output / "processes.txt").write_text(processes)
        if sys.platform != "darwin":
            log("Native stack sampling is only enabled on macOS.")
            return
        editors = {row[0] for row in owned if Path(row[5]).name == "pragtical"}
        targets = set(editors)
        while True:
            descendants = {row[0] for row in owned if row[1] in targets}
            if descendants <= targets:
                break
            targets.update(descendants)
        for row in owned:
            if row[0] in targets:
                pid = row[0]
                log(f"Sampling {row[5]} PID {pid} for five seconds.")
                try:
                    with (output / f"sample-{pid}.log").open("w") as sample_log:
                        subprocess.run(
                            ["sample", pid, "5", "-file", str(output / f"sample-{pid}.txt")],
                            stdout=sample_log, stderr=subprocess.STDOUT,
                            timeout=20, check=True,
                        )
                except (OSError, subprocess.SubprocessError) as error:
                    log(f"Could not sample PID {pid}: {error}")
        if not editors:
            log("No Pragtical process remains in the monitored process group.")
    except (OSError, subprocess.SubprocessError) as error:
        log(f"Could not complete diagnostic capture: {error}")


def stop_processes(process):
    """Terminate the process group and reap the command, bounding its shutdown."""
    groups = {process.pid}
    try:
        _, owned = process_tree(process.pid)
        pids = {row[0] for row in owned}
        groups.update(int(row[2]) for row in owned if row[2] in pids)
    except (OSError, subprocess.SubprocessError):
        pass
    for group in groups:
        try:
            os.killpg(group, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    for group in groups:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait()


def main():
    """Stream command output, enforce an idle timeout, and preserve exit status."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True,
                        help="Directory for the console log and hang diagnostics")
    parser.add_argument("--idle-timeout", type=float, default=120,
                        help="Seconds without command output before sampling (default: 120)")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command or args.idle_timeout <= 0:
        parser.error("a command and a positive idle timeout are required")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    with (output / "console.log").open("wb") as console:
        def write(data):
            """Flush the same bytes to the CI console and the diagnostic artifact."""
            console.write(data)
            console.flush()
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()

        def log(message):
            """Emit a watchdog message without resetting the child's idle timer."""
            write((message + "\n").encode())

        log(f"Running {shlex.join(command)} on {sys.platform}/{os.uname().machine}")
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            start_new_session=True,
            env=dict(os.environ, PRAGTICAL_TEST_DIAGNOSTICS_DIR=str(output)),
        )
        try:
            # GitHub cancels a timed-out step with SIGTERM. Keep cleanup active.
            signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                last_output = time.monotonic()
                while selector.get_map() or process.poll() is None:
                    if time.monotonic() - last_output >= args.idle_timeout:
                        log(f"::error::No test output for {args.idle_timeout:g} seconds; "
                            "capturing diagnostics.")
                        capture_stacks(process.pid, output, log)
                        return 124
                    for key, _ in selector.select(timeout=1):
                        data = os.read(key.fd, 65536)
                        if data:
                            write(data)
                            last_output = time.monotonic()
                        else:
                            selector.unregister(key.fileobj)
            status = process.wait()
            return status if status >= 0 else 128 - status
        finally:
            stop_processes(process)
            process.stdout.close()


if __name__ == "__main__":
    sys.exit(main())
