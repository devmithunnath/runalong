#!/usr/bin/env python3
"""Exercise the real stdio MCP server from a Python client (stdlib only).

Usage: python3 tool/mcp_smoke.py [--dart /path/to/dart]
This creates a temporary project and subprocesses; it does not need Flutter or
a device. Device-level collection is validated by the separate fixture tests.
"""

import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time


class Client:
    def __init__(self, command, directory):
        self.process = subprocess.Popen(
            command, cwd=directory, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", bufsize=1,
        )
        self.messages = queue.Queue()
        self.errors = []
        self.sequence = 0
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self):
        try:
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        except Exception as error:
            self.messages.put(error)
        finally:
            self.messages.put(EOFError("MCP stdout closed"))

    def _read_stderr(self):
        self.errors.extend(self.process.stderr)

    def send(self, method, params=None, request_id=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if request_id is not None:
            message["id"] = request_id
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def request(self, method, params=None, timeout=10):
        self.sequence += 1
        request_id = self.sequence
        self.send(method, params, request_id)
        deadline = time.monotonic() + timeout
        while True:
            message = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            if isinstance(message, Exception):
                raise AssertionError(str(message) + "\n" + "".join(self.errors))
            if message.get("id") == request_id:
                assert "error" not in message, message
                return message["result"]

    def tool(self, name, arguments=None):
        result = self.request("tools/call", {
            "name": name, "arguments": arguments or {},
        })
        # Test both representations: older clients can consume the text block.
        assert json.loads(result["content"][0]["text"]) == result["structuredContent"], result
        return result

    def initialize(self):
        result = self.request("initialize", {
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "clientInfo": {"name": "runalong-python-smoke", "version": "1.0"},
        }, timeout=60)
        assert result["protocolVersion"] == "2025-11-25", result
        assert result["serverInfo"]["name"] == "runalong", result
        assert "tools" in result["capabilities"], result
        self.send("notifications/initialized")

    def close(self):
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise AssertionError("Server did not stop after stdin EOF")


def data(result):
    assert not result.get("isError", False), result
    return result["structuredContent"]


def wait_until_finished(client, run_id):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        state = data(client.tool("get_run", {"runId": run_id}))
        if state["state"] in ("completed", "failed", "cancelled", "timed_out"):
            return state
        time.sleep(0.05)
    raise AssertionError("Run did not finish after cancellation")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dart", default=os.environ.get("DART", "dart"))
    args = parser.parse_args()
    package = Path(__file__).resolve().parent.parent
    command = [args.dart, str(package / "bin" / "runalong.dart"), "mcp"]
    with tempfile.TemporaryDirectory(prefix="runalong-mcp-") as directory:
        project = Path(directory)
        (project / "automation-workspace").mkdir()
        # JSON is valid YAML and preserves argument boundaries on all hosts.
        config = {"version": 1, "profiles": {"sleep": {
            "working_directory": "automation-workspace", "command": [
            sys.executable, "-c",
            "import time; print('child output must not enter protocol', flush=True); time.sleep(20)",
        ]}}}
        (project / "runalong.yaml").write_text(json.dumps(config), encoding="utf-8")
        client = Client(command, directory)
        try:
            client.initialize()
            tools = client.request("tools/list")["tools"]
            assert {tool["name"] for tool in tools} == {
                "list_profiles", "start_run", "get_run", "cancel_run", "get_report", "compare_runs",
                "list_journey", "get_finding_evidence",
            }, tools
            profiles = data(client.tool("list_profiles"))["profiles"]
            assert profiles == [{"name": "sleep"}], profiles
            invalid_config = {"version": 1, "profiles": {"invalid": {
                "command": ["unused"], "unknown": "private-auth-token",
            }}}
            (project / "runalong.yaml").write_text(json.dumps(invalid_config), encoding="utf-8")
            invalid = client.tool("list_profiles")
            assert invalid["isError"] and invalid["structuredContent"]["code"] == "invalid_configuration", invalid
            assert "private-auth-token" not in json.dumps(invalid), invalid
            (project / "runalong.yaml").write_text(json.dumps(config), encoding="utf-8")
            missing = client.tool("start_run", {"profile": "missing"})
            assert missing["isError"] and missing["structuredContent"]["code"] == "unknown_profile", missing
            injected = client.request("tools/call", {"name": "start_run", "arguments": {
                "profile": "sleep", "command": ["not-allowed"],
            }})
            assert injected["isError"], injected
            traversal = client.tool("get_report", {"runId": "../../secret"})
            assert traversal["isError"] and traversal["structuredContent"]["code"] == "invalid_run_id", traversal

            started = time.monotonic()
            run_id = data(client.tool("start_run", {"profile": "sleep"}))["runId"]
            assert time.monotonic() - started < 5, "start_run waited for completion"
            active = data(client.tool("get_run", {"runId": run_id}))
            assert active["state"] not in ("completed", "failed", "cancelled", "timed_out"), active
            duplicate = client.tool("start_run", {"profile": "sleep"})
            assert duplicate["isError"] and duplicate["structuredContent"]["code"] == "run_active", duplicate
            pending = client.tool("get_report", {"runId": run_id})
            assert pending["isError"] and pending["structuredContent"]["code"] == "run_in_progress", pending
            data(client.tool("cancel_run", {"runId": run_id}))
            data(client.tool("cancel_run", {"runId": run_id}))
            finished = wait_until_finished(client, run_id)
            assert finished["state"] == "cancelled", finished
            assert finished["exitCode"] == 130, finished
            assert not (project / "automation-workspace" / ".runalong").exists()
            report = data(client.tool("get_report", {"runId": run_id}))
            assert report["report"], report
            assert report["report"]["exitCode"] == 130, report
            assert report["report"]["capture"]["status"] == "unavailable", report
            assert "child output must not enter protocol" not in json.dumps(report), report
            journey = data(client.tool("list_journey", {"runId": run_id}))
            assert journey["items"] == [], journey
            comparison = data(client.tool("compare_runs", {
                "baselineRunId": run_id, "candidateRunId": run_id,
            }))
            assert comparison["status"] == "inconclusive", comparison

            # Large reports should expose bounded evidence instead of flooding
            # the agent context with every frame or navigation event.
            large = project / ".runalong" / "runs" / "large"
            large.mkdir()
            (large / "report.json").write_text(json.dumps({
                "schemaVersion": 1,
                "frames": [{"number": i, "buildMicros": i * 1000, "rasterMicros": 1}
                           for i in range(25)],
                "navigation": [{"routeName": "/route"} for _ in range(201)],
            }), encoding="utf-8")
            compact = data(client.tool("get_report", {"runId": "large"}))["report"]
            assert "frames" not in compact, compact
            assert len(compact["slowestFrames"]) == 20 and compact["omittedFrameCount"] == 5, compact
            assert compact["slowestFrames"][0]["number"] == 24, compact
            assert len(compact["navigation"]) == 200 and compact["omittedNavigationCount"] == 1, compact

            contextual = project / ".runalong" / "runs" / "contextual"
            contextual.mkdir()
            (contextual / "report.json").write_text(json.dumps({
                "schemaVersion": 2, "capture": {"status": "complete"},
                "journey": {"version": 1, "items": [{
                    "id": "operation-1", "stableId": "login.submit", "type": "operation",
                    "label": "Submit login", "durationMs": 300,
                    "metrics": {"sourceCandidates": [{"uri": "package:app/login.dart", "line": 10,
                         "provenance": "local_candidate"} for _ in range(45)]},
                }]},
            }), encoding="utf-8")
            items = data(client.tool("list_journey", {"runId": "contextual", "limit": 1}))
            assert items["total"] == 1 and items["items"][0]["stableId"] == "login.submit", items
            evidence = data(client.tool("get_finding_evidence", {"runId": "contextual", "itemId": "operation-1"}))
            assert len(evidence["item"]["metrics"]["sourceCandidates"]) == 40, evidence
            missing_item = client.tool("get_finding_evidence", {"runId": "contextual", "itemId": "missing"})
            assert missing_item["isError"], missing_item

            # A historical symlink must not expose files outside the runs root.
            if os.name != "nt":
                outside = project / "outside"
                outside.mkdir()
                (outside / "report.json").write_text('{"secret":true}', encoding="utf-8")
                (project / ".runalong" / "runs" / "escape").symlink_to(outside, target_is_directory=True)
                escaped = client.tool("get_report", {"runId": "escape"})
                assert escaped["isError"], escaped

            # Closing transport while a second run is alive must finalize it.
            eof_run = data(client.tool("start_run", {"profile": "sleep"}))["runId"]
            client.close()
            assert client.process.returncode == 0, "".join(client.errors)
            eof_report = project / ".runalong" / "runs" / eof_run / "report.json"
            assert eof_report.exists(), "EOF cancellation lost report artifacts"
            assert json.loads(eof_report.read_text(encoding="utf-8"))["exitCode"] == 130
        finally:
            client.close()

        # Completed reports survive MCP restarts, but a new server may not
        # cancel processes it did not create.
        reopened = Client(command, directory)
        try:
            reopened.initialize()
            restored = data(reopened.tool("get_run", {"runId": run_id}))
            assert restored["state"] == "cancelled" and restored["exitCode"] == 130, restored
            assert data(reopened.tool("get_report", {"runId": run_id}))["report"]["exitCode"] == 130
            unowned = reopened.tool("cancel_run", {"runId": run_id})
            assert unowned["isError"] and unowned["structuredContent"]["code"] == "not_owned", unowned
        finally:
            reopened.close()
    print("PASS: MCP 2025-11-25 negotiation, eight tools, structured output, async runs, "
          "cancellation, report retrieval, path boundaries, and EOF finalization")


if __name__ == "__main__":
    main()
