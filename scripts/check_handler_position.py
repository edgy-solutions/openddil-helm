#!/usr/bin/env python3
"""check_handler_position.py -- how far has each Restate handler actually got?

THE RULE: a Restate subscription's consumer group offset is INTAKE. Restate
has taken the record; its handler may not have run it. A lag gate that reads
the group therefore says nothing about the handler.

Measured 2026-11-03: CM's `observe` was handling records 12 h 47 m old while
that group's lag read 6, so every lag gate passed over a row half a day
stale. The position is `kafka.offset` on the Input entry of a completed
invocation's journal, and that is what this reads.

For every node (the hub, and each tier from check_tier_feed.tiers) it reads
the subscriptions from that node's Restate admin API, the partitions and head
keys from the source broker, and then, per handler and key, the journal of the
newest completed invocation. A handler's position on a partition is the
maximum offset across its readings.

    EMPTY   no records on the partition                          pass
    OK      a reading, and last - position <= tolerance          pass
    BEHIND  a reading, and last - position >  tolerance          FAIL
    IDLE    no reading, head older than 3600 s                   pass, named
    UNREAD  no reading and a young head, an unknown head, or     FAIL
            any node-level read failure

IDLE exists because completed invocations are retained about 2 h, so a quiet
partition's last handled record has no journal left. It cannot be proven, so
it is declared, never silently passed.

It reads twice, --interval seconds apart. It also fails as BEHIND a partition
that was OK on pass 1, whose high advanced by more than the tolerance, while
the handler's position did not move at all.

Every subprocess has two timeouts. The remote one is the rule
(`kubectl exec ... -- timeout N cmd`): a local timeout kills kubectl and
leaves the process running in the pod. The local one (N+10) is the backstop.

    python scripts/check_handler_position.py [namespace]
        [--tolerance N]   offsets, default 100
        [--interval S]    seconds between the passes, default 60 (min 30)

WHAT THIS DOES NOT ESTABLISH:
  * That a handler's work is correct, only how far it has got.
  * That a quiet partition's handler is alive: IDLE is declared because it
    cannot be read.
  * That the group's own lag is low; check-advancing and the group's
    describe read that.
  * Anything about a stage after the handler (the store, the projector, the
    screen).
  * That the position holds: it is a reading at two moments, and a passing
    tier can fall behind afterwards.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field

from check_tier_feed import kubectl, require_cluster, tiers

KEY_RE = re.compile(r"[A-Za-z0-9:._-]+")
NAME_RE = re.compile(r"[A-Za-z0-9_.-]+")
IDLE_AFTER_S = 3600
HEAD_WINDOW = 30
MAX_KEYS = 3
RPK_REMOTE = 20
PY_REMOTE = 120
STATES = ("EMPTY", "OK", "BEHIND", "IDLE", "UNREAD")
FAILING = ("BEHIND", "UNREAD")

# In-pod scripts (standard library only), fed to `python -u -` on stdin.
SUBS_SCRIPT = """\
import json, sys, urllib.request
try:
    d = json.load(urllib.request.urlopen(sys.argv[1] + "/subscriptions", timeout=15))
    rows = d.get("subscriptions", []) if isinstance(d, dict) else d
    print(json.dumps([{"source": r["source"], "sink": r["sink"]} for r in rows]))
except Exception as e:
    print(json.dumps({"error": type(e).__name__}))
    sys.exit(1)
"""

POS_SCRIPT = """\
import json, sys, urllib.request
admin = sys.argv[1]
def q(sql):
    req = urllib.request.Request(admin + "/query",
        data=json.dumps({"query": sql}).encode(),
        headers={"content-type": "application/json", "accept": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=12))["rows"]
for job in json.loads(sys.argv[2]):
    out = {"service": job["service"], "handler": job["handler"], "key": job["key"],
           "topic": job["topic"], "partition": None, "offset": None, "timestamp": None}
    try:
        ids = q("select id from sys_invocation where target_service_key='%s' "
                "and target_service_name='%s' and target_handler_name='%s' "
                "and status='completed' order by created_at desc limit 1"
                % (job["key"], job["service"], job["handler"]))
        if ids:
            ents = q("select index, entry_json from sys_journal where id='%s' "
                     "order by index limit 1" % ids[0]["id"])
            if ents:
                e = ents[0]["entry_json"]
                e = json.loads(e) if isinstance(e, str) else e
                hs = {h["name"]: h["value"] for h in e["Command"]["Input"]["headers"]}
                if "kafka.offset" in hs and hs.get("kafka.topic") == job["topic"]:
                    out["offset"] = int(hs["kafka.offset"])
                    out["partition"] = int(hs["kafka.partition"]) if "kafka.partition" in hs else None
                    out["timestamp"] = int(hs["kafka.timestamp"]) if "kafka.timestamp" in hs else None
    except Exception as ex:
        out = {"service": job["service"], "handler": job["handler"], "key": job["key"],
               "topic": job["topic"], "error": type(ex).__name__}
    print(json.dumps(out))
"""


# ---------------------------------------------------------------- pure parts

def parse_describe(text: str) -> list[tuple[int, int, int]]:
    """`rpk topic describe T -p` -> [(partition, log_start, high_watermark)].

    Columns: PARTITION LEADER EPOCH REPLICAS LOG-START-OFFSET HIGH-WATERMARK.
    The high watermark is the LAST column (f[5]), not f[4]."""
    out = []
    for line in text.replace("\r", "").splitlines():
        f = line.split()
        if len(f) >= 6 and f[0].isdigit() and f[4].lstrip("-").isdigit() \
                and f[5].lstrip("-").isdigit():
            out.append((int(f[0]), int(f[4]), int(f[5])))
    return out


def parse_consume(text: str) -> tuple[list[str], int | None]:
    """`rpk topic consume -f '%p %o %d %k\\n'` -> (newest distinct safe keys,
    the last line's timestamp in ms). Keys not matching KEY_RE are skipped:
    the key goes into SQL."""
    recs = []
    for line in text.replace("\r", "").splitlines():
        f = line.split()
        if len(f) >= 3 and f[1].isdigit() and f[2].isdigit():
            recs.append((int(f[2]), f[3] if len(f) > 3 else ""))
    if not recs:
        return [], None
    keys: list[str] = []
    for _, k in reversed(recs):
        if k and KEY_RE.fullmatch(k) and k not in keys:
            keys.append(k)
            if len(keys) == MAX_KEYS:
                break
    return keys, recs[-1][0]


def parse_journal(entry) -> dict | None:
    """Journal entry_json (string or object) -> {offset, partition,
    timestamp, topic}, or None when it carries no kafka.offset."""
    try:
        e = json.loads(entry) if isinstance(entry, str) else entry
        hs = {h["name"]: h["value"] for h in e["Command"]["Input"]["headers"]}
        if "kafka.offset" not in hs:
            return None
        return {"offset": int(hs["kafka.offset"]),
                "partition": int(hs["kafka.partition"]) if "kafka.partition" in hs else None,
                "timestamp": int(hs["kafka.timestamp"]) if "kafka.timestamp" in hs else None,
                "topic": hs.get("kafka.topic")}
    except (ValueError, KeyError, TypeError):
        return None


def parse_source(source: str) -> tuple[str, str] | None:
    """kafka://openddil-<broker>/<topic> -> (broker, topic)."""
    m = re.fullmatch(r"kafka://openddil-([A-Za-z0-9.-]+)/([A-Za-z0-9._-]+)", source)
    return (m.group(1), m.group(2)) if m else None


def parse_sink(sink: str) -> tuple[str, str] | None:
    m = re.fullmatch(r"service://([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)", sink)
    return (m.group(1), m.group(2)) if m else None


def verdict(position: int | None, start: int, high: int, head_ms: int | None,
            now_ms: int, tolerance: int, node_failed: bool = False) -> str:
    """One (subscription, partition). last = high - 1."""
    if node_failed:
        return "UNREAD"
    if high <= start:
        return "EMPTY"
    last = high - 1
    if position is not None:
        return "OK" if max(0, last - position) <= tolerance else "BEHIND"
    if head_ms is not None and (now_ms - head_ms) / 1000.0 > IDLE_AFTER_S:
        return "IDLE"
    return "UNREAD"


def nodes_for(tier_names: list[str]) -> list[str] | None:
    """The hub plus every tier; None (a failure) when there are no tiers."""
    return ["hub"] + list(tier_names) if tier_names else None


@dataclass
class NodeRead:
    failed: list[str] = field(default_factory=list)
    subs: list[tuple[str, str, str, str]] = field(default_factory=list)  # svc, handler, broker, topic
    parts: dict = field(default_factory=dict)      # (broker, topic) -> {p: (start, high, head_ms)}
    positions: dict = field(default_factory=dict)  # (svc, handler, topic, p) -> (offset, ts)


def evaluate_node(node: str, read: NodeRead, tolerance: int, now_ms: int) -> list[dict]:
    rows = []
    for why in read.failed:
        rows.append({"node": node, "service": "-", "handler": "-", "topic": "-",
                     "partition": -1, "position": None, "last": None, "high": None,
                     "behind": None, "age_ms": None, "state": "UNREAD", "note": why})
    if not read.subs and not read.failed:
        rows.append({"node": node, "service": "-", "handler": "-", "topic": "-",
                     "partition": -1, "position": None, "last": None, "high": None,
                     "behind": None, "age_ms": None, "state": "UNREAD",
                     "note": "zero subscriptions"})
    for svc, handler, broker, topic in read.subs:
        for p, (start, high, head_ms) in sorted(read.parts.get((broker, topic), {}).items()):
            pos = read.positions.get((svc, handler, topic, p))
            position = pos[0] if pos else None
            state = verdict(position, start, high, head_ms, now_ms, tolerance,
                            bool(read.failed))
            last = high - 1
            ts = pos[1] if pos else None
            rows.append({"node": node, "service": svc, "handler": handler, "topic": topic,
                         "partition": p, "position": position, "last": last, "high": high,
                         "behind": (max(0, last - position) if position is not None else None),
                         "age_ms": (now_ms - ts) if ts else None, "state": state,
                         "note": ""})
    return rows


def row_key(r: dict) -> tuple:
    return (r["node"], r["service"], r["handler"], r["topic"], r["partition"])


def compare_passes(first: list[dict], second: list[dict], tolerance: int) -> list[dict]:
    """A row OK on pass 1 whose high advanced by more than tolerance while the
    handler's position did not move at all becomes BEHIND on pass 2."""
    old = {row_key(r): r for r in first}
    for r in second:
        o = old.get(row_key(r))
        if (o and o["state"] == "OK" and r["state"] == "OK"
                and r["high"] - o["high"] > tolerance and r["position"] == o["position"]):
            r["state"] = "BEHIND"
            r["note"] = "position unmoved while high advanced"
    return second


def counts(rows: list[dict]) -> dict:
    return {s: sum(1 for r in rows if r["state"] == s) for s in STATES}


def passes(rows: list[dict]) -> bool:
    """False over no rows at all: a run that read nothing is not a pass."""
    return bool(rows) and not any(r["state"] in FAILING for r in rows)


# ------------------------------------------------------------- cluster reads

def run_remote(cmd: list[str], remote: int, stdin: bytes | None = None):
    """Returns (returncode, text) or None on TimeoutExpired."""
    try:
        r = subprocess.run(cmd, input=stdin,
                           capture_output=True, timeout=remote + 10)
    except subprocess.TimeoutExpired:
        return None
    return r.returncode, r.stdout.decode("utf-8", errors="replace").replace("\r", "")


def exec_in(ns: str, pod: str, container: str, remote: int, cmd: list[str],
            stdin: bytes | None = None):
    args = ["kubectl", "exec", "-n", ns, "-c", container]
    if stdin is not None:
        args.append("-i")
    args += [pod, "--", "timeout", str(remote)] + cmd
    return run_remote(args, remote, stdin)


def find_pod(ns: str, pattern: str) -> str | None:
    raw = kubectl("get", "pod", "-n", ns, "--field-selector=status.phase=Running",
                  "-o", "jsonpath={range .items[*]}{.metadata.name} "
                  "{.metadata.creationTimestamp}{\"\\n\"}{end}")
    found = []
    for line in raw.splitlines():
        f = line.split()
        if len(f) == 2 and re.fullmatch(pattern, f[0]):
            found.append((f[1], f[0]))
    return max(found)[1] if found else None


def read_node(ns: str, node: str) -> NodeRead:
    read = NodeRead()
    if node == "hub":
        pat, admin = r"openddil-cm-service-[a-z0-9]+-[a-z0-9]+", "http://openddil-restate-server:9070"
    else:
        pat = "openddil-tier-cm-" + re.escape(node) + r"-[a-z0-9]+-[a-z0-9]+"
        admin = "http://openddil-tier-restate-" + node + ":9070"
    pod = find_pod(ns, pat)
    if not pod:
        read.failed.append("no running cm-service pod")
        return read

    res = exec_in(ns, pod, "cm-service", PY_REMOTE,
                  ["python", "-u", "-", admin], SUBS_SCRIPT.encode())
    try:
        rows = json.loads(res[1].strip().splitlines()[-1]) if res and res[0] == 0 else None
    except (ValueError, IndexError):
        rows = None
    if not isinstance(rows, list):
        read.failed.append("subscriptions unreadable")
        return read
    for r in rows:
        src, snk = parse_source(r.get("source", "")), parse_sink(r.get("sink", ""))
        if src and snk:
            read.subs.append((snk[0], snk[1], src[0], src[1]))
        else:
            read.failed.append("subscription not parseable")
    if not read.subs:
        return read

    keys: dict = {}  # (broker, topic) -> {p: keys}
    for broker, topic in sorted({(b, t) for _, _, b, t in read.subs}):
        bpod, parts = "openddil-redpanda-" + broker + "-0", {}
        d = exec_in(ns, bpod, "redpanda", RPK_REMOTE,
                    ["rpk", "topic", "describe", topic, "-p"])
        desc = parse_describe(d[1]) if d and d[0] == 0 else []
        if not desc:
            read.failed.append("partitions unreadable: " + topic)
            continue
        keys[(broker, topic)] = {}
        for p, start, high in desc:
            ks, head = [], None
            if high > start:
                lo = max(start, high - HEAD_WINDOW)
                c = exec_in(ns, bpod, "redpanda", RPK_REMOTE,
                            ["rpk", "topic", "consume", topic, "-p", str(p), "-o",
                             "%d:%d" % (lo, high), "-f", "%p %o %d %k\\n"])
                if c and c[0] == 0:
                    ks, head = parse_consume(c[1])
            parts[p] = (start, high, head)
            keys[(broker, topic)][p] = ks
        read.parts[(broker, topic)] = parts

    jobs, seen = [], set()
    for svc, handler, broker, topic in read.subs:
        for p, ks in keys.get((broker, topic), {}).items():
            for k in ks:
                if (svc, handler, topic, k) not in seen:
                    seen.add((svc, handler, topic, k))
                    jobs.append({"service": svc, "handler": handler, "key": k, "topic": topic})
    if jobs:
        res = exec_in(ns, pod, "cm-service", PY_REMOTE,
                      ["python", "-u", "-", admin, json.dumps(jobs)], POS_SCRIPT.encode())
        if not res or res[0] != 0:
            read.failed.append("positions unreadable")
            return read
        for line in res[1].splitlines():
            try:
                j = json.loads(line)
            except ValueError:
                continue
            if j.get("error"):
                read.failed.append("journal read error: " + str(j["error"]))
            elif j.get("offset") is not None and j.get("partition") is not None:
                k = (j["service"], j["handler"], j["topic"], j["partition"])
                if k not in read.positions or j["offset"] > read.positions[k][0]:
                    read.positions[k] = (j["offset"], j.get("timestamp"))
    return read


# -------------------------------------------------------------------- output

def fmt_age(ms) -> str:
    if ms is None:
        return "-"
    m = max(0, int(ms // 60000))
    return "%dh%02dm" % (m // 60, m % 60) if m >= 60 else "%dm" % m


def print_pass(n: int, rows: list[dict]) -> None:
    print("pass %d" % n)
    for r in rows:
        if r["state"] in ("EMPTY",):
            continue
        print("  %-8s %s/%s %s/%s position=%s last=%s behind=%s age=%s %s%s" % (
            r["node"], r["service"], r["handler"], r["topic"],
            r["partition"] if r["partition"] >= 0 else "-", r["position"], r["last"],
            r["behind"], fmt_age(r["age_ms"]), r["state"],
            (" (" + r["note"] + ")") if r["note"] else ""))
    c = counts(rows)
    print("  counts: " + " ".join("%s=%d" % (s, c[s]) for s in STATES)
          + " rows=%d" % len(rows))
    idle = [r for r in rows if r["state"] == "IDLE"]
    for r in idle:
        print("  IDLE (declared, not read): %s %s/%s %s/%d" % (
            r["node"], r["service"], r["handler"], r["topic"], r["partition"]))


def print_not_established() -> None:
    print()
    print("WHAT THIS DOES NOT ESTABLISH:")
    print("  * That a handler's work is correct, only how far it has got.")
    print("  * That a quiet partition's handler is alive: IDLE is declared")
    print("    because it cannot be read.")
    print("  * That the group's own lag is low; check-advancing and the")
    print("    group's describe read that.")
    print("  * Anything about a stage after the handler (the store, the")
    print("    projector, the screen).")
    print("  * That the position holds: it is a reading at two moments, and")
    print("    a passing tier can fall behind afterwards.")


def one_pass(ns: str, nodes: list[str], tolerance: int) -> list[dict]:
    rows = []
    for node in nodes:
        rows += evaluate_node(node, read_node(ns, node), tolerance, int(time.time() * 1000))
    return rows


def summary(rows: list[dict]) -> str:
    c = counts(rows)
    return ", ".join("%s %d" % (s, c[s]) for s in STATES)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Read each Restate handler's position.")
    ap.add_argument("namespace", nargs="?", default="openddil")
    ap.add_argument("--tolerance", type=int, default=100)
    ap.add_argument("--interval", type=int, default=60)
    a = ap.parse_args(argv)
    if a.interval < 30:
        print("REFUSING: --interval below 30 s is not a second reading.", file=sys.stderr)
        return 2
    ns = a.namespace
    ctx = kubectl("config", "current-context").strip()
    require_cluster(ctx)
    print("handler position check -- namespace " + ns)
    print("  cluster: " + ctx + " (asserted)")
    print()

    nodes = nodes_for(tiers(ns))
    if not nodes:
        print("FAIL: no tier nodes found. Refusing to report a handler position",
              file=sys.stderr)
        print("      over zero nodes.", file=sys.stderr)
        print_not_established()
        print("handler position: FAIL (no tier nodes)")
        return 1

    first = one_pass(ns, nodes, a.tolerance)
    print_pass(1, first)
    if not passes(first):
        print_not_established()
        print("handler position: FAIL (pass 1: %s)" % summary(first))
        return 1

    time.sleep(a.interval)
    second = compare_passes(first, one_pass(ns, nodes, a.tolerance), a.tolerance)
    print_pass(2, second)
    if not passes(second):
        print_not_established()
        print("handler position: FAIL (pass 2: %s)" % summary(second))
        return 1
    print("handler position: PASS (pass 1: %s; pass 2: %s)" % (summary(first), summary(second)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
