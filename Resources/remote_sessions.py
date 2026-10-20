"""Read agent state on an SSH host; emit summaries, never transcript contents."""

import datetime
from contextlib import closing
import getpass
import json
import os
from pathlib import Path
import re
import select
import socket
import sqlite3
import sys
import time
import threading

WINDOW = 3 * 3600
TAIL = 1 << 20
LIMIT = 500


def timestamp(value, fallback=0):
    if isinstance(value, (int, float)):
        return value / 1000 if value > 100_000_000_000 else value
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (AttributeError, TypeError, ValueError):
        return fallback


def text(message):
    content = message.get("content", [])
    if isinstance(content, str):
        return content
    return "\n".join(p.get("text", "") for p in content if isinstance(p, dict))


def stamp(path):
    try:
        s = path.stat()
        return s.st_ino, s.st_size, s.st_mtime_ns
    except OSError:
        return None


class Reader:
    def __init__(self, home=None):
        self.home = Path(home or Path.home())
        self.codex_home = self.home / ".codex" if home is not None else Path(os.environ.get("CODEX_HOME", str(self.home / ".codex")))
        self.claude_home = self.home / ".claude" if home is not None else Path(os.environ.get("CLAUDE_CONFIG_DIR", str(self.home / ".claude")))
        self.files = {}
        self.databases = {}
        self.rollouts = {}
        self.errors = set()

    def database(self, path, load, agent):
        key = (stamp(path), stamp(Path(str(path) + "-wal")))
        if key[0] is None:
            self.databases.pop(path, None)
            return []
        cached = self.databases.get(path)
        if cached and cached[0] == key:
            return cached[1]
        try:
            with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.3)) as db:
                db.row_factory = sqlite3.Row
                rows = load(db)
            self.databases[path] = key, rows
            return rows
        except (sqlite3.Error, OSError, ValueError, KeyError):
            self.errors.add(agent + " data unavailable; retrying")
            return cached[1] if cached else []

    def transcript(self, path, agent):
        if agent == "codex":
            return self.codex_transcript(path)
        key = stamp(path)
        if key is None:
            self.errors.add(agent.title() + " transcript unavailable; retrying")
            cached = self.files.get(path)
            return cached[1] if cached else None
        cached = self.files.get(path)
        if cached and cached[0] == key:
            return cached[1]
        try:
            with path.open("rb") as stream:
                first = stream.readline(64 << 10)
                start = max(0, key[1] - TAIL)
                stream.seek(start)
                data = stream.read(TAIL)
            lines = data.split(b"\n")
            if start:
                lines = lines[1:]
            lines = lines[:-1]  # the last record may still be being written
            records = []
            for line in lines:
                try:
                    item = json.loads(line)
                    if isinstance(item, dict):
                        records.append(item)
                except (ValueError, UnicodeError):
                    continue
            try:
                header = json.loads(first)
            except (ValueError, UnicodeError):
                header = {}
            result = self.chat_state(records, header, agent)
            if result is not None:
                self.files[path] = key, result
            else:
                self.errors.add(agent.title() + " session state unavailable; retrying")
            return result
        except (OSError, ValueError, TypeError, AttributeError, IndexError, KeyError):
            self.errors.add(agent.title() + " transcript unavailable; retrying")
            return cached[1] if cached else None

    def codex_transcript(self, path):
        key = stamp(path)
        cached = self.rollouts.get(path)
        if cached and cached["stamp"] == key:
            result = self.codex_result(cached)
            if result is None:
                self.errors.add("Codex session state unavailable; retrying")
            return result
        if key is None:
            self.errors.add("Codex transcript unavailable; retrying")
            return self.codex_result(cached) if cached else None
        if not cached or cached["stamp"][0] != key[0] or key[1] < cached["offset"]:
            cached = {"stamp": key, "offset": 0, "status": None, "since": 0, "lastActivity": 0, "questions": {}}
        # Read metadata once, then only appended bytes. Oversized records are skipped
        # in bounded chunks; a large tool output cannot displace an older question.
        markers = (b"task_started", b"task_complete", b"turn_aborted", b"token_count",
                   b"request_user_input", b"function_call_output", b"send_user_message_question_reply",
                   b'"role":"user"', b'"role": "user"')
        try:
            with path.open("rb") as stream:
                stream.seek(cached["offset"])
                while stream.tell() < key[1]:
                    line = stream.readline(TAIL + 1)
                    oversized = len(line) > TAIL
                    while line and not line.endswith(b"\n") and stream.tell() < key[1]:
                        line = stream.readline(TAIL + 1)
                        oversized = True
                    if not line.endswith(b"\n"):
                        break  # retry a record still being written from its original offset
                    cached["offset"] = stream.tell()
                    if oversized or not any(marker in line for marker in markers):
                        continue
                    try:
                        self.codex_event(cached, json.loads(line))
                    except (ValueError, UnicodeError, TypeError, AttributeError, IndexError, KeyError):
                        continue
            cached["stamp"] = key
            self.rollouts[path] = cached
            result = self.codex_result(cached)
            if result is None:
                self.errors.add("Codex session state unavailable; retrying")
            return result
        except OSError:
            self.errors.add("Codex transcript unavailable; retrying")
            return self.codex_result(cached)

    @staticmethod
    def codex_event(state, record):
        p = record.get("payload", {})
        at = timestamp(record.get("timestamp"))
        kind = p.get("type")
        questions = state["questions"]
        if kind in ("task_started", "task_complete", "turn_aborted"):
            state.update(status="working" if kind == "task_started" else "done", since=at)
        elif kind == "token_count":
            state["lastActivity"] = max(state["lastActivity"], at)
        elif kind == "message" and p.get("role") == "user":
            message = text(p)
            if "send_user_message_question_reply" in message:
                for call, index in Reader.question_replies(message):
                    if index is None:
                        questions.pop(call, None)
                    elif call in questions:
                        questions[call][0].pop(index, None)
                        if not questions[call][0]:
                            questions.pop(call)
            elif Reader.written(message):
                questions.clear()   # you wrote to the thread since: the questions before it are behind you
        elif kind == "function_call_output":
            try:
                output = json.loads(p.get("output", "{}"))
                if isinstance(output, dict) and output.get("accepted") is True:
                    return
            except (TypeError, ValueError):
                pass
            questions.pop(p.get("call_id"), None)
        elif kind == "function_call" and p.get("name", "").split(".")[-1] in ("request_user_input_async", "request_user_input"):
            args = json.loads(p.get("arguments", "{}"))
            items = args.get("questions", [])
            pending = {i: str(q.get("title") or q.get("question") or "Codex has a question")[:220] for i, q in enumerate(items)}
            if pending:
                questions[p["call_id"]] = (pending, at)

    # An unanswered question stops asking after Muster's three-hour window.
    QUESTION_LIFE = 3 * 3600

    @staticmethod
    def written(message):
        """A message you wrote, not context Codex adds as a user message (AGENTS.md and the like)."""
        stripped = message.strip()
        return bool(stripped) and not stripped.startswith("<") and not stripped.startswith("# AGENTS.md")

    @staticmethod
    def question_replies(message):
        body = message.split("<send_user_message_question_reply>")[-1].split("</send_user_message_question_reply>")[0]
        try:
            records = json.loads(body)
            result = []
            for record in records:
                parts = json.loads(record["questionItemId"])
                call = next(p for p in parts if isinstance(p, str) and p.startswith("call_"))
                index = parts[-1] if len(parts) > 2 and type(parts[-1]) is int else None
                result.append((call, index))
            return result
        except (ValueError, TypeError, KeyError, StopIteration):
            return [(call, None) for call in re.findall(r"\bcall_[A-Za-z0-9_]+", message)]

    @staticmethod
    def codex_result(state):
        status = state["status"]
        since, activity = state["since"], state["lastActivity"]
        asking = None
        fresh = [q for q in state["questions"].values() if time.time() - q[1] <= Reader.QUESTION_LIFE]
        if fresh:
            pending, at = max(fresh, key=lambda q: q[1])
            asking = pending[min(pending)]
            if len(pending) > 1:
                asking += " (and " + str(len(pending)-1) + " more)"
            status, since = "needsYou", max(since, at)
        if status is None:
            if not activity:
                return None
            status, since = "working", activity
        return {"status": status, "since": since, "lastActivity": activity, "asking": asking}

    @staticmethod
    def chat_state(records, header, agent):
        if not records:
            return None
        title, project = "", ""
        if isinstance(header, dict):
            title = str(header.get("customTitle") or text(header.get("message", {})))[:80]
        for record in reversed(records):
            project = project or str(record.get("cwd", ""))
            if record.get("type") == "custom-title":
                title = str(record.get("customTitle", title))[:80]
            if agent == "cursor":
                status = "done" if record.get("type") == "turn_ended" else "working"
                return {"status": status, "since": timestamp(record.get("timestamp")), "title": title, "project": project}
            if record.get("isSidechain") or record.get("type") not in ("user", "assistant", "system"):
                continue
            kind = record.get("type")
            if kind == "system" and record.get("subtype") != "stop_hook_summary":
                continue
            message = record.get("message", {})
            status = "working"
            asking = None
            if kind == "system" or (kind == "assistant" and message.get("stop_reason") == "end_turn"):
                status = "done"
            elif kind == "assistant":
                for part in message.get("content", []):
                    if not isinstance(part, dict):
                        continue
                    if part.get("type") == "tool_use" and part.get("name") in ("AskUserQuestion", "ExitPlanMode"):
                        status = "needsYou"
                        questions = part.get("input", {}).get("questions", [])
                        asking = str(questions[0].get("question", "Claude has a question"))[:240] if questions else "Approve the plan?"
            return {"status": status, "since": timestamp(record.get("timestamp")), "asking": asking, "title": title, "project": project}
        return None

    def codex(self, now):
        candidates = [p for p in self.codex_home.glob("state_*.sqlite") if re.fullmatch(r"state_\d+\.sqlite", p.name)]
        if not candidates:
            return []
        path = max(candidates, key=lambda p: int(p.stem.split("_")[-1]))

        def load(db):
            columns = {r[1] for r in db.execute("PRAGMA table_info(threads)")}
            if not {"id", "rollout_path", "cwd"}.issubset(columns):
                raise ValueError("Unknown thread schema")
            names = ["NULLIF(" + k + ",'')" for k in ("name", "title", "first_user_message") if k in columns]
            title = "COALESCE(" + ",".join(names + ["''"]) + ")" if names else "''"
            times = ["NULLIF(updated_at_ms,0)"] if "updated_at_ms" in columns else []
            if "updated_at" in columns:
                times.append("updated_at*1000")
            if not times:
                raise ValueError("Unknown thread timestamps")
            updated = "COALESCE(" + ",".join(times + ["0"]) + ")"
            archived = "archived=0 AND " if "archived" in columns else ""
            sql = "SELECT id,rollout_path,cwd," + title + " AS title," + updated + " AS updated FROM threads WHERE " + archived + updated + ">? ORDER BY updated DESC LIMIT ?"
            return [dict(r) for r in db.execute(sql, (int((now - WINDOW) * 1000), LIMIT + 1))]

        result = []
        for row in self.database(path, load, "Codex"):
            if row["updated"] < (now - WINDOW) * 1000:
                continue
            if not isinstance(row["rollout_path"], str) or not row["rollout_path"]:
                self.errors.add("Codex transcript unavailable; retrying")
                continue
            state = self.transcript(Path(row["rollout_path"]), "codex")
            if state:
                result.append(dict(state, agent="codex", sid=row["id"], title=str(row["title"])[:80], project=row["cwd"]))
        return result

    def claude(self, now):
        result = []
        for path in (self.claude_home / "projects").glob("*/*.jsonl"):
            info = stamp(path)
            if path.name.startswith("agent-") or not info or info[2] / 1e9 < now - WINDOW:
                continue
            state = self.transcript(path, "claude")
            if state:
                result.append(dict(state, agent="claude", sid=path.stem))
        return result

    def cursor(self, now):
        result = {}
        for path in (self.home / ".cursor/projects").glob("*/agent-transcripts/*/*.jsonl"):
            info = stamp(path)
            if not info or info[2] / 1e9 < now - WINDOW:
                continue
            state = self.transcript(path, "cursor")
            if state:
                state = dict(state)
                state["since"] = info[2] / 1e9
                result[path.stem] = dict(state, agent="cursor", sid=path.stem)
        locations = [self.home / "Library/Application Support/Cursor/User/globalStorage/state.vscdb", self.home / ".config/Cursor/User/globalStorage/state.vscdb"]
        for path in locations:
            def load(db):
                return [dict(r) for r in db.execute("SELECT composerId,value FROM composerHeaders WHERE isSubagent=0 AND isArchived=0 AND MAX(lastUpdatedAt,COALESCE(checkpointAt,0))>? ORDER BY MAX(lastUpdatedAt,COALESCE(checkpointAt,0)) DESC LIMIT ?", (int((now-WINDOW)*1000), LIMIT + 1))]
            for row in self.database(path, load, "Cursor"):
                try:
                    h = json.loads(row["value"])
                    state = result.get(row["composerId"], {"agent": "cursor", "sid": row["composerId"], "status": "working", "since": 0})
                    at = timestamp(max(h.get("lastUpdatedAt", 0), h.get("conversationCheckpointLastUpdatedAt", 0)))
                    if at < now - WINDOW:
                        continue
                    if h.get("hasBlockingPendingActions"):
                        state.update(status="needsYou", since=max(at, state["since"]))
                    elif not state["since"]:
                        state.update(status="working" if at > now - 600 else "idle", since=at)
                    state.update(title=str(h.get("name") or state.get("title", ""))[:80], project=h.get("workspaceIdentifier", {}).get("uri", {}).get("fsPath", state.get("project", "")))
                    result[row["composerId"]] = state
                except (ValueError, TypeError, AttributeError):
                    continue
        return list(result.values())

    def scan(self, now=None):
        now = time.time() if now is None else now
        self.errors = set()
        sessions = []
        for read in (self.codex, self.claude, self.cursor):
            try:
                sessions.extend(read(now))
            except (OSError, ValueError, TypeError, AttributeError, IndexError, KeyError):
                self.errors.add(read.__name__.title() + " data unavailable; retrying")
        sessions.sort(key=lambda s: (s["status"] != "needsYou", -s["since"]))
        for session in sessions:
            for key, length in (("title", 80), ("project", 4096), ("asking", 240), ("sid", 256)):
                if isinstance(session.get(key), str):
                    session[key] = session[key][:length]
        keep = {s["sid"] for s in sessions}
        self.files = {p: v for p, v in self.files.items() if p.stem in keep}
        active_rollouts = {Path(row["rollout_path"]) for _, rows in self.databases.values() for row in rows if isinstance(row.get("rollout_path"), str)}
        self.rollouts = {p: v for p, v in self.rollouts.items() if p in active_rollouts}
        return {"protocol": 1, "hostname": socket.gethostname(), "user": getpass.getuser(), "sessions": sessions[:LIMIT], "errors": sorted(self.errors), "limited": len(sessions) > LIMIT}


def main():
    reader = Reader()
    controller = sys.argv[sys.argv.index("--controller") + 1] if "--controller" in sys.argv else None
    bridge_type = globals().get("ApprovalBridge")
    bridge = None
    output_lock = threading.Lock()
    stopped = threading.Event()
    last_contact = [time.monotonic()]
    def emit(frame):
        with output_lock:
            print(json.dumps(frame, separators=(",", ":"), ensure_ascii=True), flush=True)
    def controls():
        while not stopped.is_set():
            line = sys.stdin.buffer.readline((1 << 20) + 1)
            if not line or len(line) > 1 << 20:
                stopped.set()
                return
            try:
                message = json.loads(line)
                if message.get("event") in ("ping", "answer"):
                    last_contact[0] = time.monotonic()
                    if bridge:
                        bridge.touch()
                if bridge and message.get("event") == "answer":
                    bridge.answer(message.get("requestID"), message.get("body"))
            except (ValueError, TypeError, AttributeError):
                continue
    if "--once" not in sys.argv:
        threading.Thread(target=controls, daemon=True).start()
    previous, last_sent = None, 0
    try:
        while True:
            bridge_error = None
            if controller and bridge_type:
                if bridge and (not bridge.enabled or bridge.stop.is_set()):
                    bridge.close()
                    bridge = None
                if bridge is None:
                    candidate = bridge_type(controller, emit)
                    try:
                        if candidate.enabled and time.monotonic() - last_contact[0] > 30:
                            bridge_error = "Approval relay paused; Muster is not responding."
                        elif candidate.start():
                            bridge = candidate
                    except OSError:
                        bridge_error = "Approval relay unavailable; another Muster may be connected."
            frame = reader.scan()
            frame["approvals"] = bridge is not None
            if bridge_error:
                frame["errors"].append(bridge_error)
            body = json.dumps(frame, separators=(",", ":"), ensure_ascii=True)
            if body != previous or time.monotonic() - last_sent >= 15:
                emit(frame)
                previous, last_sent = body, time.monotonic()
            if "--once" in sys.argv or stopped.wait(3):
                return
    finally:
        if bridge:
            bridge.close()


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
