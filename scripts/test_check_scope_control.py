"""Offline self-test for check_scope_control.py.

Spins up a loopback HTTP server that plays back a canned ElectricSQL shape
log -- two pages (the second carrying the `up-to-date` control message),
the same wire shape electric-sync/the PEP actually answers with -- and
drives `check_scope_control.main()` against it directly (no subprocess, no
real cluster). Sign-in is stubbed by monkeypatching `login` so these tests
exercise the paging/classification/--expect logic, not OIDC.
"""
from __future__ import annotations

import http.server
import json
import sys
import threading
import urllib.parse
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))

import check_scope_control as csc  # noqa: E402
from oidc_login import COOKIE  # noqa: E402


def _paginate(rows: list[dict]) -> list[list[dict]]:
    """Always two pages, the way the spec describes the canned server:
    page 1 is whatever doesn't fit after the midpoint, page 2 carries the
    rest plus the up-to-date control message -- even when `rows` is empty,
    so the empty-shape case still exercises the two-request paging loop."""
    mid = len(rows) // 2
    page1 = [{"value": r} for r in rows[:mid]]
    page2 = [{"value": r} for r in rows[mid:]] + [{"headers": {"control": "up-to-date"}}]
    return [page1, page2]


class _ShapeHandler(http.server.BaseHTTPRequestHandler):
    pages: list[list[dict]] = []
    require_cookie = True

    def log_message(self, *_a):  # quiet
        pass

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if not parsed.path.endswith("/electric/v1/shape"):
            self.send_response(404)
            self.end_headers()
            return
        if self.require_cookie and f"{COOKIE}=" not in (self.headers.get("Cookie") or ""):
            body = b"unauthorized"
            self.send_response(401)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        qs = urllib.parse.parse_qs(parsed.query)
        offset = qs.get("offset", ["-1"])[0]
        idx = 0 if offset == "-1" else 1
        idx = min(idx, len(self.pages) - 1)
        body = json.dumps(self.pages[idx]).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("electric-handle", "test-handle")
        self.send_header("electric-offset", "1" if idx == 0 else "2")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@contextmanager
def _serve(rows: list[dict]):
    pages = _paginate(rows)
    handler = type("_Handler", (_ShapeHandler,), {"pages": pages})
    httpd = http.server.HTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{httpd.server_port}"
    finally:
        httpd.shutdown()
        thread.join(timeout=5)


def _run(base: str, extra_args: list[str]) -> int:
    with patch.object(csc, "login", return_value="test-token"):
        return csc.main([base, *extra_args])


# --- classify(): the rule, standalone ---------------------------------------

def test_classify_more_than_one_is_selector():
    assert csc.classify(["edge-01", "edge-02"]) == "selector"
    assert csc.classify(["edge-01", "edge-02", "edge-03"]) == "selector"


def test_classify_one_is_label():
    assert csc.classify(["edge-01"]) == "label"


def test_classify_zero_is_empty():
    assert csc.classify([]) == "empty"


# --- end to end against the canned server -----------------------------------

def test_two_edges_end_to_end_selector():
    rows = [{"edge_id": "edge-01"}, {"edge_id": "edge-02"}, {"edge_id": "edge-01"}]
    with _serve(rows) as base:
        assert _run(base, ["--expect", "selector:edge-01+edge-02"]) == csc.PASS


def test_one_edge_end_to_end_label():
    rows = [{"edge_id": "edge-07"}, {"edge_id": "edge-07"}]
    with _serve(rows) as base:
        assert _run(base, ["--expect", "label:edge-07"]) == csc.PASS


def test_zero_edges_end_to_end_empty():
    with _serve([]) as base:
        assert _run(base, ["--expect", "empty"]) == csc.PASS


def test_edge_unspecified_and_empty_excluded():
    rows = [{"edge_id": "edge-01"}, {"edge_id": "edge-unspecified"}, {"edge_id": ""}]
    with _serve(rows) as base:
        assert _run(base, ["--expect", "label:edge-01"]) == csc.PASS


def test_wrong_expect_exits_1():
    rows = [{"edge_id": "edge-01"}, {"edge_id": "edge-02"}]
    with _serve(rows) as base:
        assert _run(base, ["--expect", "label:edge-01"]) == csc.FAIL
