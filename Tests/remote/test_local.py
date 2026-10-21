"""Muster and Agent Relay sharing one approval hook on this Mac, over real HTTP."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
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

from test_approvals import relay

TOKEN = "F6A75C6A90644D9982171A9FA3A2F2F3"
RELAY_CLIENT = "Library/Application Support/AgentRelay/connector/hook-client.py"


def answer(behavior="allow", event="PermissionRequest"):
    output = {"hookEventName": event}
    output.update({"decision": {"behavior": behavior}} if event == "PermissionRequest"
                  else {"permissionDecision": behavior})
    return {"hookSpecificOutput": output}


def holding_server(requests, cancelled, check_token=False):
    """Holds each POST until the test answers it; a client hanging up first is a cancel."""
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if check_token and self.headers.get("X-Muster-Token") != TOKEN:
                self.send_response(200)
                self.end_headers()
                return
            slot = {"path": self.path, "input": body, "ready": threading.Event(), "body": b"", "headers": {}}
            requests.put(slot)
            while not slot["ready"].wait(.02):
                if select.select([self.connection], [], [], 0)[0] and not self.connection.recv(1, socket.MSG_PEEK):
                    cancelled.put(body.get("session_id"))
                    return
            try:
                self.send_response(200)
                for k, v in slot["headers"].items():
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(slot["body"])))
                self.end_headers()
                self.wfile.write(slot["body"])
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .02}, daemon=True).start()
    return server


class LocalSharingTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ml-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.muster_requests, self.muster_cancelled = queue.Queue(), queue.Queue()
        self.relay_requests, self.relay_cancelled = queue.Queue(), queue.Queue()
        self.muster = holding_server(self.muster_requests, self.muster_cancelled, check_token=True)
        self.relay = holding_server(self.relay_requests, self.relay_cancelled)
        for server in (self.muster, self.relay):
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
        self.processes = []
        self.addCleanup(self.stop_processes)
        self.peer = self.home / RELAY_CLIENT
        self.peer.parent.mkdir(parents=True)
        self.peer.write_text("import sys,urllib.request\n"
                             "raw=sys.stdin.buffer.read()\n"
                             "request=urllib.request.Request('http://127.0.0.1:" + str(self.relay.server_port) +
                             "/hooks',data=raw)\n"
                             "try:\n"
                             " with urllib.request.urlopen(request,timeout=30) as response: print(response.read().decode())\n"
                             "except Exception: print('{}')\n")
        unrelated = {"type": "command", "command": "/usr/local/bin/state.sh waiting"}
        direct = {"type": "http", "url": "http://127.0.0.1:47621/claude/permission", "timeout": 3600,
                  "headers": {"X-Muster-Token": TOKEN}}
        question = dict(direct, url="http://127.0.0.1:47621/claude/question")
        curl = {"type": "command", "timeout": 630, "command": "/usr/bin/curl -s --max-time 600 -X POST -H 'Content-Type: application/json' "
                "-H 'X-Muster-Token: " + TOKEN + "' --data-binary @- http://127.0.0.1:47621/codex/permission || true"}
        self.originals = {
            "claude": {"model": "opus", "hooks": {
                "PermissionRequest": [{"matcher": "*", "hooks": [unrelated]}, {"hooks": [self.handler("claude")]},
                                      {"matcher": "*", "hooks": [direct]}],
                "PreToolUse": [{"matcher": "AskUserQuestion|ExitPlanMode", "hooks": [self.handler("claude")]},
                               {"matcher": "AskUserQuestion|ExitPlanMode", "hooks": [question]}]}},
            "codex": {"hooks": {"PermissionRequest": [{"hooks": [self.handler("codex")]}, {"hooks": [curl]}]}},
        }
        for agent, value in self.originals.items():
            path = self.settings(agent)
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(value))
            path.chmod(0o600)

    def handler(self, agent):
        return {"type": "command", "command": " ".join(shlex.quote(x) for x in
                (sys.executable, str(self.peer), agent, "default")), "timeout": 570}

    def settings(self, agent):
        return self.home / (".codex/hooks.json" if agent == "codex" else ".claude/settings.json")

    def install(self, enabled=True):
        changed = relay.configure_approvals(None, enabled, self.home, None, True, local=True)
        if enabled:
            endpoint = relay.local_folder(self.home) / "muster.json"
            endpoint.write_text(json.dumps({"port": self.muster.server_port, "token": TOKEN}))
            endpoint.chmod(0o600)
        return changed

    def stop_processes(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
                process.wait()
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream and not stream.closed:
                    stream.close()

    def hook(self, agent="claude", event="PermissionRequest", sid="s1"):
        """Runs the hook exactly as the agent's settings name it."""
        groups = json.loads(self.settings(agent).read_text())["hooks"][event]
        command = next(h["command"] for g in groups for h in g["hooks"] if "approvals/hook.py" in h.get("command", ""))
        process = subprocess.Popen(shlex.split(command), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(process)
        payload = {"session_id": sid, "hook_event_name": event, "tool_name": "Bash", "tool_input": {"command": "printf check"}}
        process.stdin.write(json.dumps(payload).encode())
        process.stdin.close()
        return process

    def finish(self, process):
        self.assertEqual(process.wait(timeout=5), 0, process.stderr.read().decode())
        return json.loads(process.stdout.read())

    def reply(self, slot, body=None, headers=None):
        slot["body"] = b"" if body is None else json.dumps(body).encode()
        slot["headers"] = headers or {}
        slot["ready"].set()

    def test_sharing_takes_relays_hook_replaces_muster_direct_ones_and_removal_restores_relay(self):
        self.install()
        for agent in ("claude", "codex"):
            text = self.settings(agent).read_text()
            self.assertNotIn("X-Muster-Token", text, "Muster's direct hook would ask Muster twice")
            self.assertNotIn(RELAY_CLIENT, text, "Relay's own hook would hold the agent after an answer")
            commands = [h["command"] for g in json.loads(text)["hooks"]["PermissionRequest"] for h in g["hooks"]]
            runner = next(c for c in commands if "approvals/hook.py" in c)
            self.assertEqual(shlex.split(runner)[0], sys.executable, "runs with the Python Relay's hook used")
            self.assertEqual(shlex.split(runner)[2:], ["local", agent, "PermissionRequest"])
        self.assertIn("/usr/local/bin/state.sh waiting", self.settings("claude").read_text())
        peers = relay.local_folder(self.home) / "peers.json"
        self.assertEqual(peers.stat().st_mode & 0o777, 0o600)
        self.install(enabled=False)
        for agent in ("claude", "codex"):
            restored = json.loads(self.settings(agent).read_text())
            text = json.dumps(restored)
            self.assertIn(RELAY_CLIENT, text)
            self.assertNotIn("approvals/hook.py", text)
        self.assertIn("/usr/local/bin/state.sh waiting", self.settings("claude").read_text())
        self.assertFalse(peers.exists())

    def test_muster_answer_wins_and_withdraws_relays_copy(self):
        self.install()
        process = self.hook()
        slot = self.muster_requests.get(timeout=3)
        self.assertEqual(slot["path"], "/claude/permission")
        self.relay_requests.get(timeout=3)
        self.reply(slot, answer())
        self.assertEqual(self.finish(process), answer())
        self.assertEqual(self.relay_cancelled.get(timeout=3), "s1")

    def test_relay_answer_wins_and_withdraws_musters_alert(self):
        self.install()
        process = self.hook(agent="codex")
        self.assertEqual(self.muster_requests.get(timeout=3)["path"], "/codex/permission")
        self.reply(self.relay_requests.get(timeout=3), answer("deny"))
        self.assertEqual(self.finish(process), answer("deny"))
        self.assertEqual(self.muster_cancelled.get(timeout=3), "s1")

    def test_question_goes_to_musters_question_route(self):
        self.install()
        process = self.hook(event="PreToolUse")
        slot = self.muster_requests.get(timeout=3)
        self.assertEqual(slot["path"], "/claude/question")
        self.reply(slot, answer("allow", "PreToolUse"))
        self.assertEqual(self.finish(process), answer("allow", "PreToolUse"))

    def test_going_to_the_agent_releases_both_copies(self):
        self.install()
        process = self.hook(agent="codex")
        slot = self.muster_requests.get(timeout=3)
        self.relay_requests.get(timeout=3)
        started = time.monotonic()
        self.reply(slot, None, {"X-Muster": "release"})
        self.assertEqual(self.finish(process), {})
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(self.relay_cancelled.get(timeout=3), "s1")

    def test_muster_passing_without_releasing_leaves_relay_to_answer(self):
        self.install()
        process = self.hook()
        self.reply(self.muster_requests.get(timeout=3))
        time.sleep(.3)
        self.assertIsNone(process.poll(), "an empty reply alone must not end Relay's copy")
        self.reply(self.relay_requests.get(timeout=3), answer())
        self.assertEqual(self.finish(process), answer())

    def test_relay_still_answers_when_muster_is_not_running(self):
        self.install()
        self.muster.shutdown()
        self.muster.server_close()
        process = self.hook()
        self.reply(self.relay_requests.get(timeout=3), answer("deny"))
        self.assertEqual(self.finish(process), answer("deny"))

    def test_wrong_token_cannot_end_relays_copy(self):
        self.install()
        endpoint = relay.local_folder(self.home) / "muster.json"
        endpoint.write_text(json.dumps({"port": self.muster.server_port, "token": "0" * 32}))
        process = self.hook()
        self.reply(self.relay_requests.get(timeout=3), answer())
        self.assertEqual(self.finish(process), answer())

    def test_public_port_file_is_not_trusted(self):
        self.install()
        (relay.local_folder(self.home) / "muster.json").chmod(0o644)
        process = self.hook()
        self.assertTrue(self.muster_requests.empty())
        self.reply(self.relay_requests.get(timeout=3), answer())
        self.assertEqual(self.finish(process), answer())
        self.assertTrue(self.muster_requests.empty())


if __name__ == "__main__":
    unittest.main()
