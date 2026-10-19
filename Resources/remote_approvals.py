"""Optional approval hooks carried over the existing private SSH connection."""

import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
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

# One native hook owns the result. Cooperating receivers get the same request;
# the first decision wins and closing the losing connection withdraws its copy.
CLIENT = r'''import json, math, os, selectors, shlex, signal, socket, stat, subprocess, sys, time
from pathlib import Path
LIMIT = 1 << 20

def peers(agent, event):
    path = Path(__file__).with_name("peers.json")
    if not path.exists():
        return []
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > LIMIT:
        raise ValueError("Invalid shared approval settings")
    settings = json.loads(path.read_text())
    if settings.get("version") != 1:
        raise ValueError("Unknown shared approval settings")
    result = []
    for entry in settings["entries"]:
        if entry["agent"] == agent and entry["event"] == event:
            for handler in entry["group"]["hooks"]:
                timeout = handler.get("timeout", 570)
                if not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout <= 0:
                    raise ValueError("Invalid receiver timeout")
                command = shlex.split(handler["command"])
                if not command:
                    raise ValueError("Missing approval receiver command")
                result.append((command, timeout))
    if len(result) > 8:
        raise ValueError("Too many approval receivers")
    return result

def decision(body, event):
    if not isinstance(body, dict):
        return False
    output = body.get("hookSpecificOutput")
    if not isinstance(output, dict) or output.get("hookEventName", event) != event:
        return False
    if event == "PreToolUse":
        return output.get("permissionDecision") in ("allow", "deny")
    return isinstance(output.get("decision"), dict) and output["decision"].get("behavior") in ("allow", "deny")

def main():
    selector = selectors.DefaultSelector()
    workers = []
    stopped = [False]
    def stop(*_):
        stopped[0] = True
    for name in ("SIGINT", "SIGTERM", "SIGHUP"):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), stop)
    def close(worker):
        if worker not in workers:
            return
        workers.remove(worker)
        for stream in (worker.get("read"), worker.get("write")):
            if stream is not None:
                try:
                    selector.unregister(stream)
                except (KeyError, ValueError):
                    pass
                if isinstance(stream, socket.socket):
                    try:
                        stream.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                stream.close()
        process = worker.get("process")
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=.1)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            except ProcessLookupError:
                process.wait()
    try:
        path, agent, event = sys.argv[1:]
        if agent not in ("codex", "claude") or event not in ("PermissionRequest", "PreToolUse"):
            return {}
        raw = sys.stdin.buffer.read(LIMIT + 1)
        if len(raw) > LIMIT:
            return {}
        body = json.loads(raw)
        if not isinstance(body, dict):
            return {}
        receivers = peers(agent, event)
        hold = 600 if agent == "codex" else 3600
        deadline = time.monotonic() + hold
        conn = socket.socket(socket.AF_UNIX)
        try:
            info = os.lstat(path)
            if info.st_uid != os.getuid() or not stat.S_ISSOCK(info.st_mode):
                raise OSError("Invalid approval socket")
            conn.settimeout(1)
            conn.connect(path)
            conn.sendall((json.dumps({"agent": agent, "event": event, "input": body}) + "\n").encode())
            conn.setblocking(False)
            worker = {"read": conn, "data": bytearray(), "deadline": deadline, "muster": True}
            workers.append(worker)
            selector.register(conn, selectors.EVENT_READ, (worker, False))
        except OSError:
            conn.close()
        for command, timeout in receivers:
            try:
                process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=subprocess.DEVNULL, start_new_session=True)
            except OSError:
                continue
            worker = {"read": process.stdout, "write": process.stdin, "process": process,
                      "data": bytearray(), "sent": 0, "deadline": min(deadline, time.monotonic() + timeout)}
            workers.append(worker)
            for stream, writing in ((process.stdout, False), (process.stdin, True)):
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_WRITE if writing else selectors.EVENT_READ, (worker, writing))
        while workers and not stopped[0] and time.monotonic() < deadline:
            for worker in list(workers):
                if time.monotonic() >= worker["deadline"]:
                    close(worker)
            for key, _ in selector.select(.1) if workers else []:
                worker, writing = key.data
                if worker not in workers:
                    continue
                try:
                    if writing:
                        worker["sent"] += os.write(key.fd, raw[worker["sent"]:])
                        if worker["sent"] == len(raw):
                            selector.unregister(key.fileobj)
                            worker["write"].close()
                            worker["write"] = None
                        continue
                    chunk = os.read(key.fd, min(65536, LIMIT + 1 - len(worker["data"])))
                    worker["data"].extend(chunk)
                    if len(worker["data"]) > LIMIT:
                        close(worker)
                        continue
                    if chunk and not (worker.get("muster") and b"\n" in worker["data"]):
                        continue
                    result = json.loads(worker["data"])
                    if worker.get("muster") and result == {"_muster": "native"}:
                        return {}
                    if decision(result, event):
                        return result
                    close(worker)
                except BlockingIOError:
                    continue
                except (OSError, ValueError, TypeError):
                    close(worker)
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        return {}
    finally:
        for worker in list(workers):
            close(worker)
        selector.close()
    return {}

try:
    print(json.dumps(main()))
except BrokenPipeError:
    pass
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


def read_peers(folder, home=None):
    home = Path.home() if home is None else Path(home)
    path = folder / "peers.json"
    if not path.exists():
        return None, []
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > MAX_MESSAGE:
        raise ValueError("Shared approval settings must be private and owned by this user.")
    before = path.read_bytes()
    settings = json.loads(before)
    if not isinstance(settings, dict) or settings.get("version") != 1 or not isinstance(settings.get("entries"), list):
        raise ValueError("Unknown shared approval settings.")
    for entry in settings["entries"]:
        if (not isinstance(entry, dict) or entry.get("agent") not in ("claude", "codex") or
                entry.get("event") not in ("PermissionRequest", "PreToolUse") or
                not isinstance(entry.get("settings"), str) or not isinstance(entry.get("group"), dict) or
                not isinstance(entry["group"].get("hooks"), list) or not entry["group"]["hooks"] or
                not isinstance(entry.get("index"), int) or not 0 <= entry["index"] <= 10000 or
                not isinstance(entry.get("positions"), list) or len(entry["positions"]) != len(entry["group"]["hooks"]) or
                any(not isinstance(p, int) or not 0 <= p <= 10000 for p in entry["positions"]) or
                entry["positions"] != sorted(set(entry["positions"])) or
                (entry.get("remaining") is not None and re.fullmatch(r"[0-9a-f]{64}", str(entry["remaining"])) is None)):
            raise ValueError("Invalid shared approval entry.")
        for handler in entry["group"]["hooks"]:
            timeout = handler.get("timeout", 570) if isinstance(handler, dict) else None
            if (not relay_handler(handler, home, entry["agent"]) or
                    not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout <= 0):
                raise ValueError("Invalid shared Agent Relay handler.")
    return before, settings["entries"]


def relay_handler(handler, home, agent):
    """Recognize only Relay's direct Python client, never arbitrary policy hooks."""
    if not isinstance(handler, dict) or handler.get("type") != "command" or handler.get("async"):
        return False
    try:
        args = shlex.split(handler.get("command", ""))
    except ValueError:
        return False
    client = home / ".local/share/agent-relay/connector/hook-client.py"
    return (len(args) == 4 and Path(args[0]).is_absolute() and
            re.fullmatch(r"python(?:3(?:\.\d+)?)?", Path(args[0]).name.lower()) is not None and
            args[1] == str(client) and args[2] == agent and re.fullmatch(r"[A-Za-z0-9_-]+", args[3]) is not None)


def hook_digest(handlers):
    return hashlib.sha256(json.dumps(handlers, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def share_relay(groups, home, agent, event, target):
    kept, entries = [], []
    for index, group in enumerate(groups):
        handlers = group.get("hooks", [])
        positions = [i for i, handler in enumerate(handlers) if relay_handler(handler, home, agent)]
        if not positions:
            kept.append(group)
            continue
        matcher = group.get("matcher")
        accepted = (None, "", "*") if event == "PermissionRequest" else ("AskUserQuestion|ExitPlanMode",)
        if matcher not in accepted or set(group) - {"hooks", "matcher"}:
            raise ValueError("Review the scoped Agent Relay hook before sharing approvals.")
        client = home / ".local/share/agent-relay/connector/hook-client.py"
        info = client.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError("The Agent Relay client must be owned by this user.")
        if any(not isinstance(handlers[i].get("timeout", 570), (int, float)) or
               not math.isfinite(handlers[i].get("timeout", 570)) or handlers[i].get("timeout", 570) <= 0
               for i in positions):
            raise ValueError("Invalid Agent Relay hook timeout.")
        remaining = [handler for i, handler in enumerate(handlers) if i not in positions]
        entry = {"agent": agent, "event": event, "settings": str(target), "index": index,
                 "group": dict(group, hooks=[handlers[i] for i in positions]),
                 "positions": positions, "remaining": hook_digest(remaining) if remaining else None}
        entries.append(entry)
        if remaining:
            kept.append(dict(group, hooks=remaining))
    return kept, entries


def restore_relay(groups, entries, home, agent):
    """Restore saved handlers without replacing changes made by another installer."""
    groups = list(groups)
    commands = {h.get("command") for g in groups for h in g.get("hooks", []) if relay_handler(h, home, agent)}
    for entry in sorted(entries, key=lambda e: e["index"]):
        saved = entry["group"]
        handlers = [(position, handler) for position, handler in zip(entry["positions"], saved["hooks"])
                    if handler.get("command") not in commands]
        if not handlers:
            continue
        metadata = {k: v for k, v in saved.items() if k != "hooks"}
        anchor = next((g for g in groups if entry["remaining"] is not None and
                       {k: v for k, v in g.items() if k != "hooks"} == metadata and
                       hook_digest(g.get("hooks", [])) == entry["remaining"]), None)
        if anchor is not None:
            for position, handler in handlers:
                anchor["hooks"].insert(position, handler)
        else:
            groups.insert(min(entry["index"], len(groups)), dict(metadata, hooks=[h for _, h in handlers]))
        commands.update(h["command"] for _, h in handlers)
    return groups


def configure_approvals(controller, install, home=None, runtime=None, share_agent_relay=False):
    """Preserve unrelated hooks, symlinks, permissions and the original settings."""
    explicit_home = home is not None
    home = Path.home() if home is None else Path(home)
    folder, run = relay_paths(controller, home, runtime)
    client = folder / "hook.py"
    peers_before, peers = read_peers(folder, home)
    updated_peers = []
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
            shared = [entry for entry in peers if entry["agent"] == agent and entry["event"] == event]
            if any(entry["settings"] != str(target) for entry in shared):
                raise ValueError("Shared approvals belong to another agent settings path.")
            if install and (share_agent_relay or shared):
                kept, discovered = share_relay(kept, home, agent, event, target)
                if discovered:
                    fresh_commands = {h["command"] for e in discovered for h in e["group"]["hooks"]}
                    shared = [e for e in shared if not any(h["command"] in fresh_commands for h in e["group"]["hooks"])] + discovered
                    changed = True
                updated_peers.extend(shared)
            elif not install and shared:
                kept = restore_relay(kept, shared, home, agent)
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
            if kept != groups:
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
    for agent, event in {(e["agent"], e["event"]) for e in updated_peers}:
        if sum(len(e["group"]["hooks"]) for e in updated_peers if e["agent"] == agent and e["event"] == event) > 8:
            raise ValueError("Too many shared approval receivers.")
    if install:
        replace_file(client, CLIENT.encode())
    peers_after = ((json.dumps({"version": 1, "entries": updated_peers}, indent=2) + "\n").encode()
                   if updated_peers else None)
    resource_plans = [(folder / "peers.json", peers_before, peers_after, 0o600)] if peers_before != peers_after else []
    applied = []
    try:
        for target, before, after, mode in resource_plans + plans:
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if before is not None and target != folder / "peers.json":
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
            if after is None:
                target.unlink()
            else:
                replace_file(target, after, mode)
            applied.append((target, before, after, mode))
        if install:
            replace_file(folder / "enabled", b"1\n")
        else:
            (folder / "enabled").unlink(missing_ok=True)
    except Exception:
        for target, before, after, mode in reversed(applied):
            current = target.read_bytes() if target.exists() else None
            if current == after:
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
                # An explicit jump to the native agent must release every receiver;
                # a lost SSH connection still leaves the other receiver available.
                slot["body"] = body if body else {"_muster": "native"}
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
        changed = configure_approvals(controller, "--install-approvals" in sys.argv,
                                      share_agent_relay="--share-with-agent-relay" in sys.argv)
        _, shared = read_peers(relay_paths(controller)[0])
        print(json.dumps({"changed": changed, "installed": "--install-approvals" in sys.argv,
                          "shared_agent_relay_hooks": sum(len(e["group"]["hooks"]) for e in shared)}))
    except (ValueError, OSError, IndexError) as error:
        print("Muster: " + str(error), file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
