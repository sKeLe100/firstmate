#!/usr/bin/env python3
"""Disposable localhost emulator of the GitHub Actions + GitLab APIs the
router (bin/fm-test-compute.sh) calls, so the real router can be driven
end-to-end with real HTTP, real JSON, and real artifact zips.

State lives in EMU_STATE:
  scenario      scenario name (rewritten before every drive)
  dispatch.json the dispatch request body the emulator accepted
  cancelled     marker written by a cancel request
  run.json      the run record the emulator created at dispatch
  requests.log  every request line
"""
import io, json, os, pathlib, sys, threading, zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = pathlib.Path(os.environ["EMU_STATE"])


def scenario():
    try:
        return (STATE / "scenario").read_text().strip()
    except FileNotFoundError:
        return "success"


def load(name, default=None):
    try:
        return json.loads((STATE / name).read_text())
    except FileNotFoundError:
        return default


def cancelled():
    return (STATE / "cancelled").exists()


def payload():
    d = load("dispatch.json") or {}
    return json.loads(d["inputs"]["snapshot"])


def run_state(s):
    """(status, conclusion) for the run this emulator created."""
    if s == "queued-cancel-refused":
        return ("queued", None)
    if s in ("queued-cancel", "gitlab-status-fault"):
        return ("completed", "cancelled") if cancelled() else ("queued", None)
    if s == "completed-cancelled-green":
        return ("completed", "cancelled")
    return ("completed", "success")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def _log(self, line):
        with open(STATE / "requests.log", "a") as f:
            f.write(line + "\n")

    def _send(self, code, body=b"", ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def do_POST(self):
        self._dispatch("POST")

    def do_GET(self):
        self._dispatch("GET")

    def _dispatch(self, method):
        s = scenario()
        path, _, query = self.path.partition("?")
        body = self._body()
        self._log(f"{method} {self.path}")
        # ---- GitHub Actions ----
        if path == "/repos/example/firstmate":
            return self._send(200, {"private": False, "default_branch": "main"})
        if path == "/repos/example/firstmate/actions/workflows/test-compute.yml":
            return self._send(200, {"state": "active"})
        if path == "/repos/example/firstmate/actions/workflows/test-compute.yml/dispatches":
            if s == "ambiguous":
                # Accepted by the server but the response never arrives: a real
                # transport ambiguity, not an HTTP rejection.
                self.close_connection = True
                self.wfile.flush()
                return
            req = json.loads(body)
            (STATE / "dispatch.json").write_text(json.dumps(req))
            (STATE / "run.json").write_text(json.dumps({
                "id": 123,
                "display_title": "fm-test-compute-" + req["inputs"]["request_id"],
                "status": "queued",
                "conclusion": None,
            }))
            return self._send(204)
        if path == "/repos/example/firstmate/actions/workflows/test-compute.yml/runs":
            if s in ("ambiguous", "accepted-undiscovered"):
                return self._send(200, {"workflow_runs": []})
            r = load("run.json")
            if not r:
                return self._send(200, {"workflow_runs": []})
            status, conclusion = run_state(s)
            return self._send(200, {"workflow_runs": [dict(r, status=status, conclusion=conclusion)]})
        if path == "/repos/example/firstmate/actions/runs/123":
            status, conclusion = run_state(s)
            return self._send(200, {"id": 123, "status": status, "conclusion": conclusion})
        if path == "/repos/example/firstmate/actions/runs/123/cancel":
            if s == "queued-cancel-refused":
                return self._send(500, {"message": "cancel refused"})
            (STATE / "cancelled").touch()
            return self._send(202, {})
        if path == "/repos/example/firstmate/actions/runs/123/artifacts":
            buf = io.BytesIO()
            p = payload()
            with zipfile.ZipFile(buf, "w") as z:
                for k, scripts in p["partitions"].items():
                    rc = 0
                    if s == "receipt-failure" and k == sorted(p["partitions"])[0]:
                        rc = 1
                    z.writestr(f"compute-{k}/result.json", json.dumps(
                        dict(version=1, sha=p["sha"], partition=k, scripts=scripts, exit=rc)))
                    z.writestr(f"compute-{k}/run.log", f"hosted evidence for {k}\n")
            return self._send(200, buf.getvalue(), "application/zip")
        # ---- GitLab ----
        if path == "/api/v4/projects/sean.morden1993%2Ffirstmate-ci":
            return self._send(200, {"empty_repo": False, "default_branch": "main"})
        if path == "/api/v4/projects/sean.morden1993%2Ffirstmate-ci/repository/branches/firstmate-compute":
            return self._send(200, {"name": "firstmate-compute"})
        if path == "/api/v4/projects/sean.morden1993%2Ffirstmate-ci/pipeline":
            (STATE / "gitlab-pipeline.json").write_bytes(body)
            return self._send(201, {"id": 456})
        if path == "/api/v4/projects/sean.morden1993%2Ffirstmate-ci/pipelines/456":
            if s == "gitlab-status-fault":
                return self._send(500, {"message": "500 Internal Server Error"})
            return self._send(200, {"id": 456, "status": "success"})
        return self._send(404, {"message": f"unhandled {method} {self.path}"})


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    (STATE / "port").write_text(str(srv.server_address[1]))
    srv.serve_forever()
