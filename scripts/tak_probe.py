"""tak_probe — measure what a TAK client sees from a running tak-server.

WHY IT SENDS NOTHING
---------------------
taky (the TAK server this probe talks to) replays every tracked non-stale
`a-*` event to a client the moment it connects (taky's router.send_persist)
and then broadcasts every new event to every connected socket. A TAK client
does not ask for data — connecting IS the request. So this probe opens one
plaintext TCP socket, reads whatever arrives until the stream goes quiet (or
a timeout elapses), and reports what it saw. It never writes a byte to the
socket: there is nothing to send, and sending anything would not be
measuring the adapter/server, it would be injecting into the destination's
picture.

WHAT IT MEASURES
-----------------
Per connected TAK endpoint, this answers: which asset uids are currently on
the picture, what CoT type each carries, and what releasability claim
(`detail/openddil_release`'s `originator_nation` attribute and its
`releasable_to` children) each one's last event carried. Optionally it
checks that against an expected uid set and/or expected per-uid release
claims, for use as a pass/fail gate in a deployment check.

HOW IT RUNS
-----------
Deliberately dependency-free (stdlib only, Python 3.11) because it is meant
to run INSIDE a pod that has no checkout of this repo and no PyPI reach.
Under releasability.lockDownElectric only the adapter and pods labelled
openddil.io/tak-reader=true reach the server, hence the label:

    kubectl run tak-probe --rm -i --image python:3.11-slim --restart Never \\
        --labels openddil.io/tak-reader=true \\
        -- python - --host <rel>-tak-server --port 8087 \\
        < scripts/tak_probe.py

No imports from this repository. The element and attribute names below
(`event`'s `uid`/`type`, `detail/openddil_release`'s `originator_nation`,
and its `releasable_to` children's `nation`) are read off
`egress/cot_adapter.py`'s `build_event`, not guessed — a probe that invented
its own schema could pass against a server that was silently sending the
wrong thing.

OUTPUT
------
    PROBE CONNECT_FAIL <err>              (exit 3, nothing else printed)
    PROBE events=<n> uids=<distinct n>
    UID <uid> type=<t> release=<originator>|<releasable_to joined with '+', or '-' if empty>
    PASS uids                             (only with --expect-uids)
    FAIL uids missing=[..] extra=[..]
    PASS release uid=<uid>                (one line per uid, only with --expect-release)
    FAIL release uid=<uid> expected=<..> actual=<..>

EXIT CODES
----------
    0   every requested check (--expect-uids, each uid in --expect-release)
        PASSed, and at least one event arrived.
    1   any requested check FAILed, OR zero events arrived at all (even
        with no expectations given — a quiet picture is never a pass).
    3   the TCP connect itself failed.
"""
from __future__ import annotations

import argparse
import re
import socket
import sys
import time
import xml.etree.ElementTree as ET

# Non-greedy on bytes, same approach as
# tests/hero_scenario_v3/test_51_egress_cot_counts.py's collect_events: CoT
# events arrive back to back on one stream with no framing of their own, and
# a greedy match would swallow from the first `<event` to the LAST `</event>`
# in the buffer instead of stopping at each one's own close tag.
EVENT_RE = re.compile(rb"<event\b.*?</event>", re.DOTALL)


class ParsedEvent:
    __slots__ = ("uid", "type", "originator_nation", "releasable_to")

    def __init__(self, uid: str, type_: str, originator_nation: str, releasable_to: list[str]):
        self.uid = uid
        self.type = type_
        self.originator_nation = originator_nation
        self.releasable_to = releasable_to


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Measure what a TAK client sees from tak-server.")
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, default=8087)
    p.add_argument("--quiet-s", type=float, default=6.0)
    p.add_argument("--timeout-s", type=float, default=30.0)
    p.add_argument("--expect-uids", default=None, help="comma-separated list of uids")
    p.add_argument(
        "--expect-release",
        default=None,
        help="comma-separated uid=ORIG|R1+R2 (or uid=ORIG|- for an empty releasable_to)",
    )
    return p.parse_args(argv)


def collect_events(sock: socket.socket, quiet_s: float, timeout_s: float) -> list[bytes]:
    """Read raw CoT off the wire until it goes quiet, or until timeout_s.

    Returns the raw matched `<event>...</event>` byte blocks, in arrival
    order, DUPLICATES INCLUDED — a later event for a uid already seen
    supersedes the earlier one in the caller's per-uid view, the same way a
    real TAK client's picture updates in place rather than accumulating
    history.
    """
    sock.settimeout(1.0)
    buf = b""
    blocks: list[bytes] = []
    deadline = time.time() + timeout_s
    last_data = time.time()
    while time.time() < deadline:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            chunk = b""
        if chunk:
            buf += chunk
            last_data = time.time()
            for match in EVENT_RE.finditer(buf):
                blocks.append(match.group(0))
            buf = EVENT_RE.sub(b"", buf)
        elif time.time() - last_data >= quiet_s and blocks:
            break
    return blocks


def parse_event(raw: bytes) -> ParsedEvent | None:
    try:
        el = ET.fromstring(raw)
    except ET.ParseError:
        return None
    uid = el.get("uid", "")
    type_ = el.get("type", "")
    release_el = el.find("detail/openddil_release")
    originator = release_el.get("originator_nation", "") if release_el is not None else ""
    releasable_to = (
        [child.get("nation", "") for child in release_el.findall("releasable_to")]
        if release_el is not None
        else []
    )
    return ParsedEvent(uid, type_, originator, releasable_to)


def format_release(originator: str, releasable_to: list[str]) -> str:
    rel = "+".join(releasable_to) if releasable_to else "-"
    return f"{originator}|{rel}"


def parse_expect_release(spec: str) -> list[tuple[str, str, list[str]]]:
    """Parse `uid=ORIG|R1+R2,uid2=ORIG|-` into [(uid, orig, [r1, r2]), ...]."""
    out: list[tuple[str, str, list[str]]] = []
    for item in spec.split(","):
        item = item.strip()
        if not item:
            continue
        uid, _, rest = item.partition("=")
        orig, _, rel = rest.partition("|")
        releasable_to = [] if rel == "-" else rel.split("+")
        out.append((uid, orig, releasable_to))
    return out


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)

    try:
        sock = socket.create_connection((args.host, args.port), timeout=args.timeout_s)
    except OSError as err:
        print(f"PROBE CONNECT_FAIL {err}")
        return 3

    try:
        raw_blocks = collect_events(sock, args.quiet_s, args.timeout_s)
    finally:
        sock.close()

    # LAST EVENT PER UID WINS, in arrival order — a TAK client's picture is
    # the current state of each uid, not its history.
    by_uid: dict[str, ParsedEvent] = {}
    order: list[str] = []
    for raw in raw_blocks:
        ev = parse_event(raw)
        if ev is None:
            continue
        if ev.uid not in by_uid:
            order.append(ev.uid)
        by_uid[ev.uid] = ev

    print(f"PROBE events={len(raw_blocks)} uids={len(by_uid)}")
    for uid in sorted(by_uid):
        ev = by_uid[uid]
        print(f"UID {uid} type={ev.type} release={format_release(ev.originator_nation, ev.releasable_to)}")

    all_pass = True

    if args.expect_uids is not None:
        expected = {u.strip() for u in args.expect_uids.split(",") if u.strip()}
        actual = set(by_uid)
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        if not missing and not extra:
            print("PASS uids")
        else:
            print(f"FAIL uids missing={missing} extra={extra}")
            all_pass = False

    if args.expect_release is not None:
        for uid, exp_orig, exp_rel in parse_expect_release(args.expect_release):
            expected_str = format_release(exp_orig, exp_rel)
            ev = by_uid.get(uid)
            if ev is None:
                print(f"FAIL release uid={uid} expected={expected_str} actual=MISSING")
                all_pass = False
                continue
            actual_str = format_release(ev.originator_nation, ev.releasable_to)
            if ev.originator_nation == exp_orig and set(ev.releasable_to) == set(exp_rel):
                print(f"PASS release uid={uid}")
            else:
                print(f"FAIL release uid={uid} expected={expected_str} actual={actual_str}")
                all_pass = False

    if not by_uid:
        # Zero events is never a pass, even with no expectations at all —
        # a probe that silently "succeeds" against a quiet connection would
        # hide the one failure mode (nothing is reaching the picture) that
        # has no other signal.
        all_pass = False

    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())
