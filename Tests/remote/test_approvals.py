import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import queue
import socket
import select
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / "Resources/remote_approvals.py"
spec = importlib.util.spec_from_file_location("remote_approvals", SOURCE)
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)
CONTROLLER = "31f327a2-19f8-4a6c-b365-76dc927fbb57"
OTHER = "82284be7-1aaf-4c16-92d2-70aa0d490281"


class RemoteApprovalsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mr-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.frames = queue.Queue()
        self.bridge = relay.ApprovalBridge(CONTROLLER, self.frames.put, self.home, self.home)
        self.addCleanup(self.bridge.close)

    def install(self, controller=CONTROLLER, enabled=True):
        return relay.configure_approvals(controller, enabled, self.home, self.home)

    def settings(self, agent):
        return self.home / (".codex/hooks.json" if agent == "codex" else ".claude/settings.json")

    def connect(self, agent="codex", sid="session"):
        conn = socket.socket(socket.AF_UNIX)
        conn.settimeout(2)
        conn.connect(str(self.bridge.run / "approvals.sock"))
        conn.sendall((json.dumps({"agent": agent, "event": "PermissionRequest",
                                 "input": {"session_id": sid, "tool_name": "Bash",
                                           "tool_input": {"command": "printf check"}}}) + "\n").encode())
        return conn

    def next_frame(self, event):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            item = self.frames.get(timeout=3)
            if item["event"] == event:
                return item
        self.fail("No " + event + " frame")

    def test_no_opt_in_means_no_socket_or_settings_writes(self):
        self.assertFalse(self.bridge.start())
        self.assertFalse(self.bridge.run.exists())
        self.assertFalse((self.home / ".codex").exists())

    def test_installer_is_idempotent_and_removal_keeps_other_hooks(self):
        p = self.settings("codex")
        p.parent.mkdir()
        original = b'{"keep":true,"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"echo own"}]}]}}\n'
        p.write_bytes(original)
        p.chmod(0o600)
        self.install()
        installed = p.read_bytes()
        self.install()
        self.assertEqual(p.read_bytes(), installed)
        self.assertEqual(Path(str(p) + ".muster-remote-original").read_bytes(), original)
        self.assertEqual(p.stat().st_mode & 0o777, 0o600)
        self.install(enabled=False)
        d = json.loads(p.read_text())
        self.assertTrue(d["keep"])
        self.assertEqual(d["hooks"]["PermissionRequest"][0]["hooks"][0]["command"], "echo own")
        self.assertEqual(len(d["hooks"]["PermissionRequest"]), 1)
        self.assertFalse(self.bridge.enabled)

    def test_settings_symlink_stays_a_symlink(self):
        target = self.home / "dotfiles/claude.json"
        target.parent.mkdir()
        target.write_text('{"model":"keep"}')
        p = self.settings("claude")
        p.parent.mkdir()
        p.symlink_to(target)
        self.install()
        self.assertTrue(p.is_symlink())
        self.assertEqual(json.loads(target.read_text())["model"], "keep")

    def test_uninstall_leaves_unrelated_empty_groups_and_formatting_alone(self):
        p = self.settings("codex")
        p.parent.mkdir()
        original = b'{"hooks":{"PermissionRequest":[{"matcher":"keep", "hooks":[]}]}}'
        p.write_bytes(original)
        self.install(enabled=False)
        self.assertEqual(p.read_bytes(), original)

    def test_disabled_hooks_are_not_silently_enabled(self):
        p = self.settings("claude")
        p.parent.mkdir()
        p.write_text('{"disableAllHooks":true}')
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(p.read_text(), '{"disableAllHooks":true}')
        self.assertFalse(self.settings("codex").exists())

    def test_bad_or_read_only_settings_prevent_partial_install(self):
        for content, mode in (("broken JSON", 0o600), ("{}", 0o444)):
            with self.subTest(content=content):
                p = self.settings("codex")
                p.parent.mkdir(exist_ok=True)
                p.chmod(0o600) if p.exists() else None
                p.write_text(content)
                p.chmod(mode)
                with self.assertRaises((ValueError, OSError)):
                    self.install()
                self.assertFalse(self.settings("claude").exists())
                self.assertFalse(self.bridge.enabled)
                p.chmod(0o600)

    def test_failed_second_write_rolls_back_first(self):
        for agent in ("codex", "claude"):
            p = self.settings(agent)
            p.parent.mkdir()
            p.write_text('{"keep":true}')
        original_replace = relay.replace_file
        def fail_second(path, body, mode=0o600):
            if path == self.settings("codex").resolve() and b'"hooks"' in body:
                raise OSError("simulated failed write")
            original_replace(path, body, mode)
        with patch.object(relay, "replace_file", side_effect=fail_second):
            with self.assertRaises(OSError):
                self.install()
        self.assertEqual(self.settings("claude").read_text(), '{"keep":true}')
        self.assertEqual(self.settings("codex").read_text(), '{"keep":true}')
        self.assertFalse(self.bridge.enabled)

    def test_different_macs_do_not_remove_each_others_hooks(self):
        self.install()
        self.install(OTHER)
        self.install(enabled=False)
        hooks = json.loads(self.settings("codex").read_text())["hooks"]["PermissionRequest"]
        self.assertEqual(len(hooks), 1)
        self.assertIn(OTHER, hooks[0]["hooks"][0]["command"])

    def test_private_socket_and_only_one_receiver(self):
        self.install()
        self.assertTrue(self.bridge.start())
        self.assertEqual(self.bridge.run.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.bridge.run / "approvals.sock").stat().st_mode & 0o777, 0o600)
        second = relay.ApprovalBridge(CONTROLLER, self.frames.put, self.home, self.home)
        self.addCleanup(second.close)
        with self.assertRaises(OSError):
            second.start()
        with self.connect() as conn:
            request = self.next_frame("prompt")
            self.bridge.answer(request["requestID"], {"decision": "still connected"})
            self.assertEqual(json.loads(conn.recv(4096)), {"decision": "still connected"})

    def test_concurrent_decisions_are_matched_to_their_request(self):
        self.install()
        self.bridge.start()
        clients = [self.connect(sid="session-" + str(i)) for i in range(5)]
        self.addCleanup(lambda: [c.close() for c in clients])
        requests = [self.next_frame("prompt") for _ in clients]
        for request in reversed(requests):
            self.bridge.answer(request["requestID"], {"for": request["input"]["session_id"]})
        for i, conn in enumerate(clients):
            self.assertEqual(json.loads(conn.recv(4096)), {"for": "session-" + str(i)})

    def test_native_answer_cancels_only_that_request(self):
        self.install()
        self.bridge.start()
        first, second = self.connect(sid="first"), self.connect(sid="second")
        self.addCleanup(first.close)
        self.addCleanup(second.close)
        requests = [self.next_frame("prompt"), self.next_frame("prompt")]
        by_sid = {r["input"]["session_id"]: r["requestID"] for r in requests}
        first.close()
        self.assertEqual(self.next_frame("cancel")["requestID"], by_sid["first"])
        self.bridge.answer(by_sid["second"], {"decision": "allow"})
        self.assertEqual(json.loads(second.recv(4096)), {"decision": "allow"})

    def test_disconnect_releases_pending_request_without_a_decision(self):
        self.install()
        self.bridge.start()
        with self.connect() as conn:
            self.next_frame("prompt")
            self.bridge.close()
            self.assertEqual(json.loads(conn.recv(4096)), {})

    def test_unresponsive_mac_releases_an_approval_even_if_ssh_stays_open(self):
        self.install()
        self.bridge.start()
        with self.connect() as conn:
            self.next_frame("prompt")
            contact = self.bridge.last_contact
            self.bridge.check_contact(now=contact + 29)
            self.assertFalse(self.bridge.stop.is_set())
            self.bridge.check_contact(now=contact + 31)
            self.assertEqual(json.loads(conn.recv(4096)), {})
            self.assertTrue(self.bridge.stop.is_set())

    def test_client_falls_back_to_agent_when_muster_is_unavailable(self):
        client = self.home / "hook.py"
        client.write_text(relay.CLIENT)
        result = subprocess.run([sys.executable, str(client), str(self.home / "missing.sock"), "codex", "PermissionRequest"],
                                input='{"session_id":"test"}', capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {})

    def test_installed_client_round_trip(self):
        self.install()
        self.bridge.start()
        client = self.bridge.folder / "hook.py"
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(subprocess.run, [sys.executable, str(client), str(self.bridge.run / "approvals.sock"),
                                                 "claude", "PermissionRequest"],
                                 input='{"session_id":"client","tool_name":"Bash"}', capture_output=True, text=True, timeout=4)
            request = self.next_frame("prompt")
            self.assertEqual(request["path"], "/claude/permission")
            self.bridge.answer(request["requestID"], {"hookSpecificOutput": {"decision": {"behavior": "deny"}}})
            self.assertEqual(json.loads(future.result().stdout)["hookSpecificOutput"]["decision"]["behavior"], "deny")

    def test_real_helper_eof_returns_control_to_the_agent(self):
        import uuid
        controller = str(uuid.uuid4())
        relay.configure_approvals(controller, True, self.home)
        folder, run = relay.relay_paths(controller, self.home)
        def cleanup_runtime():
            (run / "owner.lock").unlink(missing_ok=True)
            if run.exists():
                run.rmdir()
        self.addCleanup(cleanup_runtime)
        script = SOURCE.read_text() + "\n" + SOURCE.with_name("remote_sessions.py").read_text()
        env = dict(os.environ, HOME=str(self.home))
        env.pop("CODEX_HOME", None)
        env.pop("CLAUDE_CONFIG_DIR", None)
        process = subprocess.Popen([sys.executable, "-u", "-c", script, "--controller", controller],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        try:
            self.assertTrue(select.select([process.stdout], [], [], 4)[0])
            self.assertTrue(json.loads(process.stdout.readline())["approvals"])
            with concurrent.futures.ThreadPoolExecutor() as pool:
                future = pool.submit(subprocess.run,
                                     [sys.executable, str(folder / "hook.py"), str(run / "approvals.sock"), "codex", "PermissionRequest"],
                                     input='{"session_id":"eof-check","tool_name":"Bash"}', capture_output=True, text=True, timeout=5)
                self.assertTrue(select.select([process.stdout], [], [], 3)[0])
                self.assertEqual(json.loads(process.stdout.readline())["event"], "prompt")
                process.stdin.close()
                self.assertEqual(process.wait(timeout=4), 0)
                self.assertEqual(json.loads(future.result().stdout), {})
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
            process.stderr.close()


if __name__ == "__main__":
    unittest.main()
