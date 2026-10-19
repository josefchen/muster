"""Optional approval hooks carried over the existing private SSH connection."""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import shlex
import shutil
import socket
import stat
import sys
import tempfile
import threading
import time
import uuid

MAX_MESSAGE = 1 << 20

# Installed only by --install-approvals. An unavailable relay returns no decision,
# so the agent retains its own approval flow.
CLIENT = r'''import json, os, socket, stat, sys
def main():
    try:
        path, agent, event = sys.argv[1:]
        info = os.lstat(path)
        if info.st_uid != os.getuid() or not stat.S_ISSOCK(info.st_mode):
            return {}
        raw = sys.stdin.buffer.read((1 << 20) + 1)
        if len(raw) > 1 << 20:
            return {}
        body = json.loads(raw)
        if not isinstance(body, dict):
            return {}
        with socket.socket(socket.AF_UNIX) as conn:
            conn.settimeout(1)
            conn.connect(path)
            conn.settimeout(600 if agent == "codex" else 3600)
            conn.sendall((json.dumps({"agent": agent, "event": event, "input": body}) + "\n").encode())
            with conn.makefile("rb") as stream:
                answer = stream.readline((1 << 20) + 1)
            result = json.loads(answer)
            return result if isinstance(result, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}
print(json.dumps(main()))
'''


def controller_id(value):
    return str(uuid.UUID(value))


def relay_paths(controller, home=None, runtime=None):
    controller = controller_id(controller)
    home = Path.home() if home is None else Path(home)
    name = hashlib.sha256(controller.encode()).hexdigest()[:20]
    folder = home / ".local/share/muster/remote-approvals" / controller
    # macOS TMPDIR can exceed the Unix socket path limit.
    run = Path(runtime or "/tmp") / ("muster-remote-" + str(os.getuid()) + "-" + name)
    return folder, run


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise OSError("The approval relay directory must be private and owned by this user.")


def replace_file(path, body, mode=0o600):
    fd, staged = tempfile.mkstemp(prefix=".muster-", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(staged, path)
    finally:
        if os.path.exists(staged):
            os.unlink(staged)


def configure_approvals(controller, install, home=None, runtime=None):
    """Preserve unrelated hooks, symlinks, permissions and the original settings."""
    explicit_home = home is not None
    home = Path.home() if home is None else Path(home)
    folder, run = relay_paths(controller, home, runtime)
    client = folder / "hook.py"
    plans = []
    paths = [("claude", (home / ".claude" if explicit_home else Path(os.environ.get("CLAUDE_CONFIG_DIR", str(home / ".claude")))) / "settings.json"),
             ("codex", (home / ".codex" if explicit_home else Path(os.environ.get("CODEX_HOME", str(home / ".codex")))) / "hooks.json")]
    for agent, link in paths:
        target = link.resolve()
        if target.exists() and (not stat.S_ISREG(target.stat().st_mode) or
                                not stat.S_IMODE(target.stat().st_mode) & 0o222 or not os.access(target, os.W_OK)):
            raise PermissionError("Agent settings are not writable: " + str(link))
        before = target.read_bytes() if target.exists() else None
        settings = json.loads(before) if before is not None else {}
        if not isinstance(settings, dict) or not isinstance(settings.get("hooks", {}), dict):
            raise ValueError("Agent settings are not a JSON object: " + str(link))
        if install and settings.get("disableAllHooks") is True:
            raise ValueError("Hooks are disabled in " + str(link) + "; review that setting in the agent first.")
        events = settings.get("hooks", {})
        changed = False
        for event in ("PermissionRequest", "PreToolUse"):
            groups = events.get(event, [])
            if not isinstance(groups, list):
                raise ValueError("Unexpected hook configuration: " + str(link))
            kept = []
            for group in groups:
                if not isinstance(group, dict) or not isinstance(group.get("hooks", []), list):
                    raise ValueError("Unexpected hook group: " + str(link))
                def owned(handler):
                    try:
                        return isinstance(handler, dict) and shlex.split(handler.get("command", ""))[1:2] == [str(client)]
                    except ValueError:
                        return False
                handlers = [h for h in group.get("hooks", []) if not owned(h)]
                if len(handlers) == len(group.get("hooks", [])):
                    kept.append(group)
                elif handlers:
                    kept.append(dict(group, hooks=handlers))
                    changed = True
                else:
                    changed = True
            wanted = event == "PermissionRequest" or agent == "claude"
            if install and wanted:
                command = " ".join(shlex.quote(s) for s in
                                   (shutil.which("python3") or sys.executable, str(client), str(run / "approvals.sock"), agent, event))
                handler = {"type": "command", "command": command,
                           "timeout": 630 if agent == "codex" else 3600}
                group = {"hooks": [handler]}
                if agent == "claude":
                    group["matcher"] = "*" if event == "PermissionRequest" else "AskUserQuestion|ExitPlanMode"
                kept.append(group)
                changed = True
            if kept:
                events[event] = kept
            else:
                events.pop(event, None)
        if events:
            settings["hooks"] = events
        else:
            settings.pop("hooks", None)
        after = (json.dumps(settings, indent=2, ensure_ascii=False) + "\n").encode()
        if changed and before != after:
            mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o600
            plans.append((target, before, after, mode))
    if install or folder.exists():
        private_directory(folder)
    if install:
        replace_file(client, CLIENT.encode())
    applied = []
    try:
        for target, before, after, mode in plans:
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if before is not None:
                backup = Path(str(target) + ".muster-remote-original")
                try:
                    fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
                except FileExistsError:
                    pass
                else:
                    with os.fdopen(fd, "wb") as stream:
                        stream.write(before)
            current = target.read_bytes() if target.exists() else None
            if current != before:
                raise OSError("Agent settings changed during setup; retry.")
            replace_file(target, after, mode)
            applied.append((target, before, after, mode))
        if install:
            replace_file(folder / "enabled", b"1\n")
        else:
            (folder / "enabled").unlink(missing_ok=True)
    except Exception:
        for target, before, after, mode in reversed(applied):
            if target.read_bytes() == after:
                if before is None:
                    target.unlink()
                else:
                    replace_file(target, before, mode)
        raise
    return [str(p[0]) for p in plans]


class ApprovalBridge:
    def __init__(self, controller, emit, home=None, runtime=None):
        self.folder, self.run = relay_paths(controller, home, runtime)
        self.emit = emit
        self.stop = threading.Event()
        self.mutex = threading.Lock()
        self.pending = {}
        self.slots = threading.BoundedSemaphore(64)
        self.listener = None
        self.lockfile = None
        self.close_lock = threading.Lock()
        self.last_contact = time.monotonic()

    @property
    def enabled(self):
        return (self.folder / "enabled").is_file()

    def start(self):
        if not self.enabled:
            return False
        private_directory(self.run)
        self.lockfile = (self.run / "owner.lock").open("a")
        try:
            fcntl.flock(self.lockfile, fcntl.LOCK_EX | fcntl.LOCK_NB)
            path = self.run / "approvals.sock"
            if path.exists():
                if not stat.S_ISSOCK(path.lstat().st_mode):
                    raise OSError("The approval socket path is already occupied.")
                path.unlink()
            self.listener = socket.socket(socket.AF_UNIX)
            self.listener.bind(str(path))
            os.chmod(path, 0o600)
            self.listener.listen(16)
            self.listener.settimeout(.2)
            threading.Thread(target=self.accept, daemon=True).start()
            threading.Thread(target=self.watch_contact, daemon=True).start()
            return True
        except Exception:
            if self.listener:
                self.listener.close()
                self.listener = None
            self.lockfile.close()
            self.lockfile = None
            raise

    def touch(self):
        self.last_contact = time.monotonic()

    def check_contact(self, now=None):
        if (time.monotonic() if now is None else now) - self.last_contact > 30:
            self.close()

    def watch_contact(self):
        while not self.stop.wait(1):
            self.check_contact()

    def accept(self):
        listener = self.listener
        while not self.stop.is_set():
            try:
                conn, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            if not self.slots.acquire(blocking=False):
                conn.close()
            else:
                def serve(connection=conn):
                    try:
                        self.request(connection)
                    finally:
                        self.slots.release()
                threading.Thread(target=serve, daemon=True).start()

    def request(self, conn):
        request_id = str(uuid.uuid4())
        event = threading.Event()
        slot = {"ready": event, "body": {}, "conn": conn}
        registered = False
        try:
            with conn:
                conn.settimeout(2)
                with conn.makefile("rb") as stream:
                    line = stream.readline(MAX_MESSAGE + 1)
                    if len(line) > MAX_MESSAGE or not line.endswith(b"\n"):
                        return
                    request = json.loads(line)
                    agent, kind = request.get("agent"), request.get("event")
                    if agent not in ("codex", "claude") or kind not in ("PermissionRequest", "PreToolUse"):
                        return
                    if kind == "PreToolUse" and agent != "claude":
                        return
                    body = request.get("input")
                    if not isinstance(body, dict) or not isinstance(body.get("session_id"), str) or not body["session_id"]:
                        return
                    path = "/" + agent + ("/permission" if kind == "PermissionRequest" else "/question")
                    with self.mutex:
                        if len(self.pending) >= 64 or self.stop.is_set():
                            return
                        self.pending[request_id] = slot
                        registered = True
                    self.emit({"protocol": 1, "event": "prompt", "requestID": request_id, "path": path, "input": body})
                    deadline = time.monotonic() + (600 if agent == "codex" else 3600)
                    conn.settimeout(None)
                    while not event.wait(.1) and not self.stop.is_set() and time.monotonic() < deadline:
                        if select.select([conn], [], [], 0)[0]:
                            # Only one request per socket. EOF means the agent answered
                            # natively or exited; extra bytes are not another request.
                            return
                    conn.sendall((json.dumps(slot["body"]) + "\n").encode())
        except (OSError, ValueError, TypeError, AttributeError):
            pass
        finally:
            if registered:
                with self.mutex:
                    self.pending.pop(request_id, None)
                try:
                    self.emit({"protocol": 1, "event": "cancel", "requestID": request_id})
                except OSError:
                    pass

    def answer(self, request_id, body):
        if not isinstance(body, dict):
            return
        with self.mutex:
            slot = self.pending.get(request_id)
            if slot is not None:
                slot["body"] = body
                slot["ready"].set()

    def close(self):
        with self.close_lock:
            self.stop.set()
            if self.listener:
                self.listener.close()
                self.listener = None
                (self.run / "approvals.sock").unlink(missing_ok=True)
            with self.mutex:
                for slot in self.pending.values():
                    slot["ready"].set()
            if self.lockfile:
                self.lockfile.close()
                self.lockfile = None


if __name__ == "__main__" and any(v in sys.argv for v in ("--install-approvals", "--remove-approvals")):
    try:
        controller = sys.argv[sys.argv.index("--controller") + 1]
        changed = configure_approvals(controller, "--install-approvals" in sys.argv)
        print(json.dumps({"changed": changed, "installed": "--install-approvals" in sys.argv}))
    except (ValueError, OSError, IndexError) as error:
        print("Muster: " + str(error), file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
