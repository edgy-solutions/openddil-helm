"""Offline self-test for tak_probe.py.

Spins up a local TCP server on loopback that plays back canned CoT events —
built with the REAL `egress/cot_adapter.build_event`, not hand-written XML,
so this test fails if the probe's parsing ever drifts from what the adapter
actually emits — and drives `tak_probe.main()` against it directly (no
subprocess, no real tak-server). `cot_adapter` is only reachable from the
sibling `openddil-demo` checkout (this repo, openddil-helm, does not carry
egress's source); if that checkout is not present alongside this one, the
whole module is skipped rather than failed, since a missing sibling repo is
an environment fact, not a bug in this probe.
"""
from __future__ import annotations

import contextlib
import io
import socket
import sys
import threading
import time
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

_HERE = Path(__file__).resolve().parent

# The sibling openddil-demo checkout's egress/ directory: this repo and
# openddil-demo checked out next to each other in one workspace, the layout
# the bundle and egress image builds also use.
_CANDIDATES = [
    _HERE.parents[1] / "openddil-demo" / "egress",  # <workspace>/openddil-demo/egress
]


def _find_egress_dir() -> Path | None:
    for cand in _CANDIDATES:
        cand = cand.resolve()
        if (cand / "cot_adapter.py").is_file():
            return cand
    return None


_EGRESS_DIR = _find_egress_dir()
if _EGRESS_DIR is None:
    pytest.skip(
        "sibling openddil-demo/egress not found; skipping tak_probe self-test",
        allow_module_level=True,
    )

sys.path.insert(0, str(_HERE))
sys.path.insert(0, str(_EGRESS_DIR))

import tak_probe  # noqa: E402
from cot_adapter import build_event  # noqa: E402
from gate import Label  # noqa: E402

# Eight canned assets, spanning: an aggregate with no originator (EL-02,
# EL-05, EL-08 carry releasable_to but no author — ADR-0029's aggregate
# case), a releasable_to of exactly one nation, two nations, and none at
# all (labelled-but-author-only).
EVENT_SPEC = [
    ("EL-01", "USA", ["GBR", "CAN"]),
    ("EL-02", "GBR", []),
    ("EL-03", "USA", ["AUS"]),
    ("EL-04", "CAN", ["USA", "GBR"]),
    ("EL-05", "AUS", []),
    ("EL-06", "USA", ["CAN"]),
    ("EL-07", "GBR", ["USA"]),
    ("EL-08", "CAN", []),
]


def _event_bytes(uid: str, originator: str, releasable_to: list[str]) -> bytes:
    record = {
        "status": {
            "asset_id": uid,
            "platform_variant": "GRIFFON",
            "overall_severity": "NOMINAL",
            "computed_at": "2026-10-01T00:00:00.000Z",
            "status_revision": "1",
        }
    }
    label = Label(originator_nation=originator, releasable_to=tuple(releasable_to))
    event = build_event(record, uid, label)
    assert event is not None, "build_event refused a labelled record"
    return ET.tostring(event, encoding="utf-8")


def _expect_uids_arg(specs) -> str:
    return ",".join(uid for uid, _, _ in specs)


def _expect_release_arg(specs) -> str:
    parts = []
    for uid, orig, rel in specs:
        rel_str = "+".join(rel) if rel else "-"
        parts.append(f"{uid}={orig}|{rel_str}")
    return ",".join(parts)


def _serve(chunks: list[bytes], port_holder: list[int], ready: threading.Event, linger_s: float) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port_holder.append(srv.getsockname()[1])
    ready.set()
    conn, _ = srv.accept()
    try:
        for chunk in chunks:
            conn.sendall(chunk)
        time.sleep(linger_s)
    finally:
        conn.close()
        srv.close()


def _run_probe(
    chunks: list[bytes], extra_args: list[str], linger_s: float = 0.4, timeout_s: float = 3.0
) -> tuple[int, str]:
    port_holder: list[int] = []
    ready = threading.Event()
    thread = threading.Thread(target=_serve, args=(chunks, port_holder, ready, linger_s), daemon=True)
    thread.start()
    assert ready.wait(timeout=5), "test server never bound a port"
    port = port_holder[0]

    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = tak_probe.main(
            [
                "--host", "127.0.0.1",
                "--port", str(port),
                "--quiet-s", "0.3",
                "--timeout-s", str(timeout_s),
                *extra_args,
            ]
        )
    thread.join(timeout=5)
    return code, buf.getvalue()


def test_pass_with_right_sets():
    chunks = [_event_bytes(uid, orig, rel) for uid, orig, rel in EVENT_SPEC]
    code, out = _run_probe(
        chunks,
        ["--expect-uids", _expect_uids_arg(EVENT_SPEC), "--expect-release", _expect_release_arg(EVENT_SPEC)],
    )
    assert code == 0, out
    assert "PROBE events=8 uids=8" in out
    assert "PASS uids" in out
    for uid, _, _ in EVENT_SPEC:
        assert f"PASS release uid={uid}" in out


def test_fail_on_extra_uid():
    chunks = [_event_bytes(uid, orig, rel) for uid, orig, rel in EVENT_SPEC]
    chunks.append(_event_bytes("EL-09", "USA", []))
    code, out = _run_probe(chunks, ["--expect-uids", _expect_uids_arg(EVENT_SPEC)])
    assert code == 1, out
    assert "FAIL uids" in out
    assert "extra=['EL-09']" in out
    assert "missing=[]" in out


def test_fail_on_release_mismatch():
    chunks = [_event_bytes(uid, orig, rel) for uid, orig, rel in EVENT_SPEC]
    # EL-01 really carries releasable_to=[GBR, CAN]; assert a wrong one.
    wrong = [("EL-01", "USA", ["GBR"])]
    code, out = _run_probe(chunks, ["--expect-release", _expect_release_arg(wrong)])
    assert code == 1, out
    assert "FAIL release uid=EL-01" in out
    assert "expected=USA|GBR" in out
    assert "actual=USA|GBR+CAN" in out


def test_fail_on_release_for_absent_uid():
    # The picture lacks EL-08; a release expectation for it must fail, not be skipped.
    chunks = [_event_bytes(uid, orig, rel) for uid, orig, rel in EVENT_SPEC if uid != "EL-08"]
    code, out = _run_probe(chunks, ["--expect-release", _expect_release_arg(EVENT_SPEC)])
    assert code == 1, out
    assert "FAIL release uid=EL-08" in out
    assert "actual=MISSING" in out


def test_fail_on_zero_events():
    code, out = _run_probe([], [], linger_s=0.0, timeout_s=0.5)
    assert code == 1, out
    assert "PROBE events=0 uids=0" in out
