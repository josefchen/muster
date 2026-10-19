import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest
from contextlib import closing
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / "Resources/remote_sessions.py"
spec = importlib.util.spec_from_file_location("remote_sessions", SOURCE)
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)


class RemoteSessionsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="muster-remote-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.now = time.time()
        self.reader = remote.Reader(self.home)

    def write(self, name, records):
        path = self.home / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(r) + "\n" for r in records))
        return path

    def event(self, kind, **fields):
        return {"timestamp": self.now, "payload": dict(type=kind, **fields)}

    def database(self, path, schema, rows):
        path = self.home / path
        path.parent.mkdir(parents=True, exist_ok=True)
        with closing(sqlite3.connect(path)) as db:
            db.execute(schema)
            for statement, values in rows:
                db.execute(statement, values)
            db.commit()
        return path

    def codex(self, records, legacy=False, milliseconds=True):
        path = self.write(".codex/sessions/test.jsonl", records)
        schema = "CREATE TABLE threads (id TEXT,rollout_path TEXT,cwd TEXT,title TEXT,updated_at INT,archived INT"
        schema += ")" if legacy else ",name TEXT,updated_at_ms INT)"
        values = ["test", str(path), "/work/lexer", "Lexer work", int(self.now), 0]
        if not legacy:
            values += ["", int(self.now*1000) if milliseconds else None]
        db = self.database(".codex/state_5.sqlite", schema,
                           [("INSERT INTO threads VALUES (" + ",".join("?" for _ in values) + ")", values)])
        return path, db

    def question(self, call="call_question", title="Which store?"):
        return self.event("function_call", name="request_user_input_async", call_id=call,
                          arguments=json.dumps({"questions": [{"title": title}]}))

    def test_async_acknowledgement_keeps_question_pending(self):
        self.codex([self.event("task_started"), self.question(),
                    self.event("function_call_output", call_id="call_question", output='{"accepted":true}'),
                    self.event("task_complete")])
        session = self.reader.scan(self.now)["sessions"][0]
        self.assertEqual(session["status"], "needsYou")
        self.assertEqual(session["asking"], "Which store?")

    def test_user_reply_clears_question(self):
        self.codex([self.question(), self.event("task_complete"),
                    self.event("message", role="user", content=[{"text": '<send_user_message_question_reply>call_question</send_user_message_question_reply>'}])])
        self.assertEqual(self.reader.scan(self.now)["sessions"][0]["status"], "done")

    def test_older_unanswered_question_survives_a_new_turn(self):
        self.codex([self.question("call_first", "Still waiting"), self.event("task_complete"),
                    self.event("task_started"), self.question("call_second"),
                    self.event("message", role="user", content=[{"text": '<send_user_message_question_reply>call_second</send_user_message_question_reply>'}])])
        self.assertEqual(self.reader.scan(self.now)["sessions"][0]["asking"], "Still waiting")

    def test_sync_question_output_resolves_it(self):
        question = self.question()
        question["payload"]["name"] = "request_user_input"
        self.codex([question, self.event("function_call_output", call_id="call_question", output='{"answers":{"store":"SQLite"}}'), self.event("task_complete")])
        self.assertEqual(self.reader.scan(self.now)["sessions"][0]["status"], "done")

    def test_token_activity_keeps_status_timestamp_separate(self):
        started = self.event("task_started")
        started["timestamp"] -= 1800
        self.codex([started, self.event("token_count")])
        session = self.reader.scan(self.now)["sessions"][0]
        self.assertEqual(session["since"], self.now-1800)
        self.assertEqual(session["lastActivity"], self.now)

    def test_large_tool_output_cannot_displace_pending_question(self):
        path, _ = self.codex([self.event("task_started"), self.question()])
        self.reader.scan(self.now)
        with path.open("a") as stream:
            stream.write(json.dumps(self.event("function_call_output", call_id="call_command", output="x"*(2*remote.TAIL))) + "\n")
            stream.write(json.dumps(self.event("token_count")) + "\n")
        for reader in [self.reader, remote.Reader(self.home)]:
            frame = reader.scan(self.now)
            self.assertEqual(frame["sessions"][0]["asking"], "Which store?")
            self.assertFalse(frame["errors"])

    def test_replaced_rollout_clears_old_question(self):
        path, _ = self.codex([self.event("task_started"), self.question()])
        self.reader.scan(self.now)
        replacement = path.with_suffix(".new")
        replacement.write_text(json.dumps(self.event("task_complete")) + "\n")
        replacement.replace(path)
        session = self.reader.scan(self.now)["sessions"][0]
        self.assertEqual(session["status"], "done")
        self.assertIsNone(session["asking"])

    def test_thread_without_rollout_does_not_drop_healthy_threads(self):
        _, path = self.codex([self.event("task_started")])
        with closing(sqlite3.connect(path)) as db:
            db.execute("INSERT INTO threads SELECT 'missing',NULL,cwd,title,updated_at,archived,name,updated_at_ms FROM threads LIMIT 1")
            db.commit()
        frame = self.reader.scan(self.now)
        self.assertEqual([s["sid"] for s in frame["sessions"]], ["test"])
        self.assertTrue(frame["errors"])

    def test_older_codex_schema(self):
        self.codex([self.event("task_started")], legacy=True)
        self.assertEqual(self.reader.scan(self.now)["sessions"][0]["title"], "Lexer work")

    def test_nullable_millisecond_timestamp(self):
        self.codex([self.event("task_started")], milliseconds=False)
        self.assertEqual(len(self.reader.scan(self.now)["sessions"]), 1)

    def test_incomplete_last_line_is_retried(self):
        path, _ = self.codex([self.event("task_started")])
        line = json.dumps(self.event("task_complete")) + "\n"
        with path.open("a") as stream:
            stream.write(line[:len(line)//2])
        self.assertEqual(self.reader.scan(self.now)["sessions"][0]["status"], "working")
        with path.open("a") as stream:
            stream.write(line[len(line)//2:])
        self.assertEqual(self.reader.scan(self.now)["sessions"][0]["status"], "done")

    def test_locked_database_recovers_without_a_write(self):
        _, path = self.codex([self.event("task_started")])
        writer = sqlite3.connect(path)
        try:
            writer.execute("BEGIN EXCLUSIVE")
            self.assertTrue(self.reader.scan(self.now)["errors"])
            writer.rollback()
            frame = self.reader.scan(self.now)
            self.assertFalse(frame["errors"])
            self.assertEqual(len(frame["sessions"]), 1)
        finally:
            writer.close()

    def test_cached_sessions_survive_read_error(self):
        _, path = self.codex([self.event("task_started")])
        self.reader.scan(self.now)
        writer = sqlite3.connect(path)
        try:
            writer.execute("BEGIN EXCLUSIVE")
            os.utime(path, (self.now+2, self.now+2))
            frame = self.reader.scan(self.now)
            self.assertTrue(frame["errors"])
            self.assertEqual(len(frame["sessions"]), 1)
            writer.rollback()
            self.assertFalse(self.reader.scan(self.now)["errors"])
        finally:
            writer.close()

    def test_missing_rollout_keeps_last_summary_and_reports_problem(self):
        path, _ = self.codex([self.event("task_started")])
        self.reader.scan(self.now)
        path.unlink()
        frame = self.reader.scan(self.now)
        self.assertEqual(len(frame["sessions"]), 1)
        self.assertTrue(frame["errors"])

    def test_malformed_transcript_does_not_hide_other_sessions(self):
        self.write(".claude/projects/atlas/good.jsonl", [{"type": "assistant", "timestamp": self.now,
                   "message": {"stop_reason": "end_turn", "content": []}}])
        self.write(".claude/projects/atlas/bad.jsonl", [{"type": "assistant", "message": []}])
        frame = self.reader.scan(self.now)
        self.assertEqual([s["sid"] for s in frame["sessions"]], ["good"])
        self.assertTrue(frame["errors"])

    def test_claude_question_and_subagent_exclusion(self):
        record = {"type": "assistant", "timestamp": self.now, "cwd": "/work/atlas", "message": {"stop_reason": "tool_use", "content": [{"type": "tool_use", "name": "AskUserQuestion", "input": {"questions": [{"question": "Which database?"}]}}]}}
        self.write(".claude/projects/atlas/main.jsonl", [record])
        self.write(".claude/projects/atlas/agent-child.jsonl", [record])
        frame = self.reader.scan(self.now)
        self.assertEqual(len(frame["sessions"]), 1)
        self.assertEqual(frame["sessions"][0]["asking"], "Which database?")

    def test_export_contains_no_tool_command_or_transcript(self):
        secret = "private-command-body-that-must-not-be-exported"
        self.codex([self.event("task_started"), self.event("function_call", name="exec_command", arguments=json.dumps({"cmd": secret}))])
        self.assertNotIn(secret, json.dumps(self.reader.scan(self.now)))

    def test_fixture_home_ignores_real_agent_home_environment(self):
        with patch.dict(os.environ, {"CODEX_HOME": "/not-the-fixture", "CLAUDE_CONFIG_DIR": "/not-the-fixture"}):
            reader = remote.Reader(self.home)
        self.assertEqual(reader.codex_home, self.home / ".codex")
        self.assertEqual(reader.claude_home, self.home / ".claude")

    def test_cursor_blocking_header(self):
        header = {"name": "A Cursor task", "hasBlockingPendingActions": True, "lastUpdatedAt": self.now*1000}
        self.database(".config/Cursor/User/globalStorage/state.vscdb",
                      "CREATE TABLE composerHeaders (composerId TEXT,value TEXT,isSubagent INT,isArchived INT,lastUpdatedAt INT,checkpointAt INT)",
                      [("INSERT INTO composerHeaders VALUES (?,?,0,0,?,NULL)", ["cursor", json.dumps(header), int(self.now*1000)])])
        self.assertEqual(self.reader.scan(self.now)["sessions"][0]["status"], "needsYou")

    def test_cursor_limit_keeps_newest_sessions_and_reports_truncation(self):
        rows = []
        for i in range(remote.LIMIT+2):
            at = int((self.now-1000+i)*1000)
            rows.append(("INSERT INTO composerHeaders VALUES (?,?,0,0,?,NULL)",
                         ["cursor-"+str(i), json.dumps({"lastUpdatedAt": at}), at]))
        self.database(".config/Cursor/User/globalStorage/state.vscdb",
                      "CREATE TABLE composerHeaders (composerId TEXT,value TEXT,isSubagent INT,isArchived INT,lastUpdatedAt INT,checkpointAt INT)", rows)
        frame = self.reader.scan(self.now)
        self.assertEqual(len(frame["sessions"]), remote.LIMIT)
        self.assertEqual(frame["sessions"][0]["sid"], "cursor-501")
        self.assertTrue(frame["limited"])


if __name__ == "__main__":
    unittest.main()
