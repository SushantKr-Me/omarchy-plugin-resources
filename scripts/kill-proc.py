#!/usr/bin/env python3
"""
Terminate processes safely.
Sends SIGTERM first, waits briefly, then SIGKILL if needed.
Used by Resources+ Omarchy plugin.
"""
import os
import sys
import signal
import time
import json

def kill_process(pid):
    name = f"PID {pid}"
    try:
        with open(f"/proc/{pid}/comm", "r") as f:
            name = f.read().strip()
    except Exception:
        pass

    try:
        os.kill(pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError) as e:
        return {"success": False, "error": str(e), "pid": pid, "name": name}

    # Short wait for graceful exit
    time.sleep(0.12)

    # Force kill if still alive
    try:
        os.kill(pid, 0)
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass

    return {"success": True, "pid": pid, "name": name}

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.stdout.write(json.dumps({"success": False, "error": "No PID provided"}))
        sys.exit(1)

    try:
        pid = int(sys.argv[1])
        res = kill_process(pid)
    except Exception as e:
        res = {"success": False, "error": str(e)}

    sys.stdout.write(json.dumps(res))
    sys.stdout.flush()
