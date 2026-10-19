#!/usr/bin/env python3
"""Enable or remove optional remote approval hooks for this Mac's Muster."""

import argparse
import json
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("enable", "disable"))
    parser.add_argument("host", help="An enabled Muster SSH alias or user@hostname")
    parser.add_argument("--share-with-agent-relay", action="store_true",
                        help="Present approvals in Muster and the existing Agent Relay receiver; the first answer wins")
    args = parser.parse_args()
    if args.action == "disable" and args.share_with_agent_relay:
        parser.error("Sharing is enabled during setup; disable restores Agent Relay's original hooks.")
    if not re.fullmatch(r"[A-Za-z0-9._:@-]{1,128}", args.host) or any(
            not p or p.startswith("-") for p in args.host.split("@")) or args.host.count("@") > 1:
        parser.error("Use an SSH alias or user@hostname, without SSH options.")
    prefs = plistlib.loads(subprocess.check_output(["/usr/bin/defaults", "export", "dev.muster.app", "-"]))
    hosts = json.loads(prefs.get("ssh.hosts", b"[]"))
    if args.action == "enable" and not any(h.get("name") == args.host and h.get("enabled") for h in hosts):
        parser.error("Enable this exact host in Muster Settings first.")
    try:
        controller = str(uuid.UUID(prefs["ssh.controller"]))
    except (KeyError, ValueError):
        parser.error("Start the updated Muster app before connecting approvals.")
    script = (Path(__file__).resolve().parents[1] / "Resources/remote_approvals.py").read_text()
    command = "python3 -u -c " + shlex.quote(script) + (
        " --install-approvals" if args.action == "enable" else " --remove-approvals") + " --controller " + controller
    if args.share_with_agent_relay:
        command += " --share-with-agent-relay"
    subprocess.run(["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                    "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes", "-o", "ControlMaster=no",
                    "-o", "ControlPath=none", "--", args.host, command], check=True)
    if args.action == "enable":
        print("Review and trust the new Muster PermissionRequest hook in Codex (/hooks).")
        print("Recent Claude Code versions reload hooks automatically; older clients may need a new session.")
        print("Muster connects the relay automatically while this host is enabled.")
    else:
        print("Removed this Mac's remote hooks. Other agent settings are preserved.")


if __name__ == "__main__":
    main()
