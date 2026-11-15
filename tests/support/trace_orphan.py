"""Trace a process that is about to become an orphan in a session of its own.

What rr does with a replay's checkpoints: the process is a fork of a process
whose parent goes away, so it is reparented to the nearest subreaper while its
tracer keeps it.  Here an intermediate starts `sleep 600` in a new session; this
process seizes it with PTRACE_SEIZE while the intermediate still makes it a
descendant (the Yama ptrace scope), writes its pid to argv[1], lets the
intermediate exit, and stays its tracer until it ends.
"""
import ctypes
import os
import sys

PTRACE_SEIZE = 0x4206
WALL = 0x40000000

libc = ctypes.CDLL(None, use_errno=True)
pid_file = sys.argv[1]
report_r, report_w = os.pipe()
go_r, go_w = os.pipe()
intermediate = os.fork()
if intermediate == 0:
    os.close(report_r)
    os.close(go_w)
    orphan = os.fork()
    if orphan == 0:
        os.setsid()
        os.execvp("sleep", ["sleep", "600"])
    os.write(report_w, f"{orphan}\n".encode())
    os.read(go_r, 1)
    os._exit(0)
os.close(report_w)
os.close(go_r)
orphan = int(os.read(report_r, 64).decode())
if libc.ptrace(PTRACE_SEIZE, orphan, None, None) != 0:
    sys.exit(f"trace_orphan: PTRACE_SEIZE {orphan} failed: errno {ctypes.get_errno()}")
with open(pid_file, "w") as f:
    f.write(f"{orphan}\n")
os.write(go_w, b"x")
os.waitpid(intermediate, 0)
while True:
    try:
        _, status = os.waitpid(orphan, WALL)
    except ChildProcessError:
        break
    if os.WIFEXITED(status) or os.WIFSIGNALED(status):
        break
    # A stop the tracee took (a signal): let it continue with the signal.
    sig = os.WSTOPSIG(status) if os.WIFSTOPPED(status) else 0
    libc.ptrace(7, orphan, None, sig)  # PTRACE_CONT
