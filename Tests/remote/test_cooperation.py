"""One native hook, two real transports, and either receiver can finish it."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import select
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from test_approvals import relay, CONTROLLER


def answer(behavior="allow", event="PermissionRequest"):
    output = {"hookEventName": event}
    output.update({"decision": {"behavior": behavior}} if event == "PermissionRequest"
                  else {"permissionDecision": behavior})
    return {"hookSpecificOutput": output}


class CooperationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mc-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.frames, self.requests, self.cancelled = queue.Queue(), queue.Queue(), queue.Queue()
        self.bridge = relay.ApprovalBridge(CONTROLLER, self.frames.put, self.home, self.home)
        self.addCleanup(self.bridge.close)
        self.processes = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                slot = {"input": body, "ready": threading.Event(), "body": {}}
                owner.requests.put(slot)
                while not slot["ready"].wait(.02):
                    if select.select([self.connection], [], [], 0)[0] and not self.connection.recv(1, socket.MSG_PEEK):
                        owner.cancelled.put(body["session_id"])
                        return
                try:
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(json.dumps(slot["body"]).encode())
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": .02}, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.stop_processes)
        self.peer = self.home / ".local/share/agent-relay/connector/hook-client.py"
        self.peer.parent.mkdir(parents=True)
        self.peer.write_text("import sys,urllib.request\n"
                             "raw=sys.stdin.buffer.read()\n"
                             "request=urllib.request.Request('http://127.0.0.1:" + str(self.server.server_port) +
                             "/hooks',data=raw)\n"
                             "with urllib.request.urlopen(request,timeout=30) as response: print(response.read().decode())\n")
        self.originals = {}
        for agent in ("claude", "codex"):
            groups = {"PermissionRequest": [{"hooks": [self.handler(agent)]}]}
            if agent == "claude":
                groups["PreToolUse"] = [{"matcher": "AskUserQuestion|ExitPlanMode", "hooks": [self.handler(agent)]}]
            value = {"keep": True, "hooks": groups}
            self.originals[agent] = value
            path = self.settings(agent)
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(value))
            path.chmod(0o600)

    def handler(self, agent):
        return {"type": "command", "command": " ".join(shlex.quote(x) for x in
                (sys.executable, str(self.peer), agent, "default")), "timeout": 570}

    def settings(self, agent):
        return self.home / (".codex/hooks.json" if agent == "codex" else ".claude/settings.json")

    def install(self, enabled=True, shared=True):
        return relay.configure_approvals(CONTROLLER, enabled, self.home, self.home, shared)

    def stop_processes(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream and not stream.closed:
                    stream.close()

    def start(self, sid="test", agent="codex", event="PermissionRequest", extra=None):
        payload = {"session_id": sid, "hook_event_name": event, "tool_name": "Bash",
                   "tool_input": {"command": "printf check"}}
        payload.update(extra or {})
        process = subprocess.Popen([sys.executable, str(self.bridge.folder / "hook.py"),
                                    str(self.bridge.run / "approvals.sock"), agent, event],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(process)
        process.stdin.write(json.dumps(payload).encode())
        process.stdin.close()
        return process

    def frame(self, event):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            frame = self.frames.get(timeout=4)
            if frame["event"] == event:
                return frame
        self.fail("Missing " + event)

    def finish(self, process):
        self.assertEqual(process.wait(timeout=3), 0, process.stderr.read().decode())
        return json.loads(process.stdout.read())

    def reply(self, slot, body):
        slot["body"] = body
        slot["ready"].set()

    def test_sharing_is_opt_in_and_removal_restores_exact_relay_definitions(self):
        self.install(shared=False)
        self.assertEqual(len(json.loads(self.settings("codex").read_text())["hooks"]["PermissionRequest"]), 2)
        self.install()
        first = {a: self.settings(a).read_bytes() for a in self.originals}
        peers = (self.bridge.folder / "peers.json").read_bytes()
        self.assertEqual((self.bridge.folder / "peers.json").stat().st_mode & 0o777, 0o600)
        self.install()
        self.assertEqual(peers, (self.bridge.folder / "peers.json").read_bytes())
        for agent in first:
            self.assertEqual(first[agent], self.settings(agent).read_bytes())
            for groups in json.loads(self.settings(agent).read_text())["hooks"].values():
                self.assertTrue(all(not relay.relay_handler(h, self.home, agent) for g in groups for h in g["hooks"]))
        self.install(enabled=False)
        for agent in self.originals:
            self.assertEqual(json.loads(self.settings(agent).read_text()), self.originals[agent])
        self.assertFalse((self.bridge.folder / "peers.json").exists())

    def test_muster_answer_finishes_the_hook_and_cancels_relay(self):
        self.install()
        self.bridge.start()
        process = self.start()
        request = self.frame("prompt")
        self.requests.get(timeout=3)
        started = time.monotonic()
        self.bridge.answer(request["requestID"], answer())
        self.assertEqual(self.finish(process), answer())
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(self.cancelled.get(timeout=3), "test")

    def test_relay_answer_finishes_the_hook_and_cancels_muster(self):
        self.install()
        self.bridge.start()
        process = self.start()
        request = self.frame("prompt")
        self.reply(self.requests.get(timeout=3), answer("deny"))
        self.assertEqual(self.finish(process), answer("deny"))
        self.assertEqual(self.frame("cancel")["requestID"], request["requestID"])

    def test_relay_still_answers_when_muster_is_not_running(self):
        self.install()
        process = self.start()
        self.reply(self.requests.get(timeout=3), answer("deny"))
        self.assertEqual(self.finish(process), answer("deny"))

    def test_no_decision_from_relay_does_not_win(self):
        self.install()
        self.bridge.start()
        process = self.start()
        request = self.frame("prompt")
        self.reply(self.requests.get(timeout=3), {})
        self.assertIsNone(process.poll())
        self.bridge.answer(request["requestID"], answer("deny"))
        self.assertEqual(self.finish(process), answer("deny"))

    def test_failed_receiver_cannot_win_with_valid_looking_output(self):
        self.install()
        self.peer.write_text(self.peer.read_text() + "\nraise SystemExit(7)\n")
        self.bridge.start()
        process = self.start()
        request = self.frame("prompt")
        self.reply(self.requests.get(timeout=3), answer())
        with self.assertRaises(subprocess.TimeoutExpired):
            process.wait(timeout=.3)
        self.bridge.answer(request["requestID"], answer("deny"))
        self.assertEqual(self.finish(process), answer("deny"))

    def test_disconnected_mac_leaves_relay_available(self):
        self.install()
        self.bridge.start()
        process = self.start()
        self.frame("prompt")
        slot = self.requests.get(timeout=3)
        self.bridge.close()
        self.reply(slot, answer())
        self.assertEqual(self.finish(process), answer())

    def test_receiver_with_closed_stdout_must_exit_before_its_answer_can_win(self):
        self.install()
        self.peer.write_text(self.peer.read_text() +
                             "\nimport os,time\nsys.stdout.flush()\nos.close(1)\ntime.sleep(60)\n")
        self.bridge.start()
        process = self.start()
        request = self.frame("prompt")
        self.reply(self.requests.get(timeout=3), answer())
        with self.assertRaises(subprocess.TimeoutExpired):
            process.wait(timeout=.3)
        self.bridge.answer(request["requestID"], answer("deny"))
        self.assertEqual(self.finish(process), answer("deny"))

    def test_explicit_jump_to_native_releases_both_receivers(self):
        self.install()
        self.bridge.start()
        process = self.start()
        request = self.frame("prompt")
        self.requests.get(timeout=3)
        self.bridge.answer(request["requestID"], {})
        self.assertEqual(self.finish(process), {})
        self.assertEqual(self.cancelled.get(timeout=3), "test")

    def test_cancelling_one_native_request_keeps_the_other_request_live(self):
        self.install()
        self.bridge.start()
        first, second = self.start("first"), self.start("second")
        prompts = [self.frame("prompt"), self.frame("prompt")]
        by_sid = {p["input"]["session_id"]: p for p in prompts}
        slots = [self.requests.get(timeout=3), self.requests.get(timeout=3)]
        first.terminate()
        self.assertEqual(first.wait(timeout=3), 0)
        self.assertEqual(self.cancelled.get(timeout=3), "first")
        self.assertEqual(self.frame("cancel")["requestID"], by_sid["first"]["requestID"])
        self.assertIsNone(second.poll())
        self.reply(next(s for s in slots if s["input"]["session_id"] == "second"), answer())
        self.assertEqual(self.finish(second), answer())

    def test_peer_that_never_reads_stdin_cannot_block_a_muster_answer(self):
        self.install()
        self.peer.write_text("import time\ntime.sleep(60)\n")
        self.bridge.start()
        process = self.start(extra={"padding": "x" * 400000})
        request = self.frame("prompt")
        self.bridge.answer(request["requestID"], answer("deny"))
        self.assertEqual(self.finish(process), answer("deny"))

    def test_oversized_or_malformed_peer_output_cannot_block_muster(self):
        self.install()
        self.bridge.start()
        for code in ("print('invalid')", "print('x' * ((1 << 20) + 1))"):
            with self.subTest(code=code):
                self.peer.write_text(code)
                process = self.start()
                request = self.frame("prompt")
                self.bridge.answer(request["requestID"], answer())
                self.assertEqual(self.finish(process), answer())

    def test_question_answer_payload_is_preserved(self):
        self.install()
        self.bridge.start()
        process = self.start(agent="claude", event="PreToolUse", extra={"tool_name": "AskUserQuestion"})
        request = self.frame("prompt")
        self.requests.get(timeout=3)
        response = answer(event="PreToolUse")
        response["hookSpecificOutput"]["updatedInput"] = {"answers": {"Which region?": "Europe"}}
        self.bridge.answer(request["requestID"], response)
        self.assertEqual(self.finish(process), response)
        self.assertEqual(self.cancelled.get(timeout=3), "test")

    def test_mixed_groups_restore_without_losing_later_policy_hooks(self):
        path = self.settings("codex")
        original = self.originals["codex"]
        original["hooks"]["PermissionRequest"][0]["hooks"].append({"type": "command", "command": "echo policy"})
        path.write_text(json.dumps(original))
        self.install()
        current = json.loads(path.read_text())
        current["hooks"]["PermissionRequest"].append({"hooks": [{"type": "command", "command": "echo later"}]})
        path.write_text(json.dumps(current))
        self.install(enabled=False)
        restored = json.loads(path.read_text())
        self.assertEqual(restored["hooks"]["PermissionRequest"][0], original["hooks"]["PermissionRequest"][0])
        self.assertEqual(restored["hooks"]["PermissionRequest"][1]["hooks"][0]["command"], "echo later")

    def test_another_installer_readded_relay_is_not_duplicated_on_removal(self):
        self.install()
        path = self.settings("codex")
        current = json.loads(path.read_text())
        handler = dict(self.handler("codex"), timeout=123)
        current["hooks"]["PermissionRequest"].append({"hooks": [handler]})
        path.write_text(json.dumps(current))
        self.install(enabled=False)
        groups = json.loads(path.read_text())["hooks"]["PermissionRequest"]
        self.assertEqual(groups, [{"hooks": [handler]}])

    def test_reenabling_consolidates_a_reinstalled_relay_hook(self):
        self.install()
        path = self.settings("codex")
        current = json.loads(path.read_text())
        handler = dict(self.handler("codex"), timeout=123)
        current["hooks"]["PermissionRequest"].append({"hooks": [handler]})
        path.write_text(json.dumps(current))
        self.install(shared=False)
        self.assertEqual(len(json.loads(path.read_text())["hooks"]["PermissionRequest"]), 1)
        self.install(enabled=False)
        self.assertEqual(json.loads(path.read_text())["hooks"]["PermissionRequest"], [{"hooks": [handler]}])

    def test_malformed_or_public_peer_settings_are_not_executed_or_replaced(self):
        self.install()
        path = self.bridge.folder / "peers.json"
        before = {a: self.settings(a).read_bytes() for a in self.originals}
        for content, mode in ((b'{"version":1,"entries":[{}]}', 0o600), (path.read_bytes(), 0o644)):
            path.write_bytes(content)
            path.chmod(mode)
            with self.assertRaises(ValueError):
                self.install()
            process = self.start()
            self.assertEqual(self.finish(process), {})
            for agent in before:
                self.assertEqual(self.settings(agent).read_bytes(), before[agent])
        path.chmod(0o600)

    def test_failed_settings_write_restores_peer_config_and_all_agent_settings(self):
        original_replace = relay.replace_file
        def fail_codex(path, body, mode=0o600):
            if path == self.settings("codex").resolve():
                raise OSError("simulated write failure")
            original_replace(path, body, mode)
        with patch.object(relay, "replace_file", side_effect=fail_codex):
            with self.assertRaises(OSError):
                self.install()
        for agent in self.originals:
            self.assertEqual(json.loads(self.settings(agent).read_text()), self.originals[agent])
        self.assertFalse((self.bridge.folder / "peers.json").exists())
        self.assertFalse(self.bridge.enabled)

    def test_scoped_policy_groups_are_not_silently_broadened(self):
        path = self.settings("codex")
        original = self.originals["codex"]
        original["hooks"]["PermissionRequest"][0]["matcher"] = "Write"
        path.write_text(json.dumps(original))
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(json.loads(path.read_text()), original)
        self.assertFalse(self.bridge.enabled)


if __name__ == "__main__":
    unittest.main()
