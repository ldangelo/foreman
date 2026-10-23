#!/usr/bin/env python3
"""spawn.py <logfile> <pidfile> <cwd> <command...>: start <command> detached in its own
session (so it outlives the calling tool shell), append its output to <logfile>, write its
pid to <pidfile> and print it. Starting and stopping stay with the caller; nothing is
matched by name."""
import subprocess
import sys

log, pidfile, cwd, *cmd = sys.argv[1:]
with open(log, "ab") as out:
    p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
with open(pidfile, "w") as f:
    f.write(str(p.pid))
print(p.pid)
