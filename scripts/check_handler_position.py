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
newest completed invocation.

A handler's position belongs to a KEY, not to a tier. Positions on one
partition were measured 28,000 offsets apart (2026-11-03): three keys 7 s
behind and three keys 6.5 h behind, on the same handler at the same moment.
The first version of this check took the maximum across three sampled keys and
passed that partition; its proof run found that. Keys appear to drain in
groups; that they are Restate's partitions is not established.

So every distinct key in the last HEAD_WINDOW offsets of each partition is
read, and each is compared to ITS OWN newest record in that window, never to
the partition's high (the head is another key's record). Per key:

    OK      a reading, and key last - position <= tolerance
    BEHIND  a reading, and key last - position >  tolerance
    IDLE    no reading, the key's own last record older than 3600 s
    UNREAD  no reading and a younger record, or a journal query error

Per (subscription, partition) the worst key decides, in the order BEHIND,
UNREAD, OK, IDLE: any BEHIND key fails the row.

    EMPTY   no records on the partition                          pass
    OK/IDLE as above                                             pass
    BEHIND  any key behind                                       FAIL
    UNREAD  any key unread, a node-level read failure, or no     FAIL
            key readable and a young or unknown head

Event topics (effector-events, cm-events) have no tolerance: their records are
not snapshots and nothing re-sends one, so a key even 1 behind is BEHIND. An
event key caught mid-handling fails that run and a re-run settles it. IDLE on an
event topic cannot tell a key handled long ago from one never handled; those keys
are listed by name after the counts.

IDLE exists because completed invocations are retained about 2 h, so a quiet
key's last handled record has no journal left. It cannot be proven, so it is
declared, never silently passed.

It reads twice, --interval seconds apart. It also fails as BEHIND a key that
was OK on pass 1, whose own last record advanced by more than the tolerance,
while its position did not move at all.

Every subprocess has two timeouts. The remote one is the rule
(`kubectl exec ... -- timeout N cmd`): a local timeout kills kubectl and
leaves the process running in the pod. The local one (N+10) is the backstop.

    python scripts/check_handler_position.py [namespace]
        [--tolerance N]   offsets, default 100; snapshot topics only
        [--interval S]    seconds between the passes, default 60 (min 30)

WHAT THIS DOES NOT ESTABLISH:
  * That a handler's work is correct, only how far it has got.
  * That a quiet partition's handler is alive: IDLE is declared because it
    cannot be read.
  * That an IDLE key on an event topic was ever handled: a key handled long
    ago and one never handled read the same.
  * That nothing was lost to a Restate wipe: the journals go with it, so an
    event that was handled and one that was not both read UNREAD for the
    record's first hour and then IDLE, which passes. Read this before a wipe.
    After one it says only that handlers run at the head.
  * That the group's own lag is low; check-advancing and the group's
    describe read that.
  * Anything about a stage after the handler (the store, the projector, the
    screen).
  * That the position holds: it is a reading at two moments, and a passing
    tier can fall behind afterwards.
  * Every key: a key with no record in the last HEAD_WINDOW offsets of a
    partition is not read, so a key that has gone quiet can sit behind
    unseen. The window's coverage is the count printed, and it is not a
    census of the tier's keys.
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
HEAD_WINDOW = 400
RPK_REMOTE = 20
PY_REMOTE = 150
JOB_CHUNK = 40
STATES = ("EMPTY", "OK", "BEHIND", "IDLE", "UNREAD")
FAILING = ("BEHIND", "UNREAD")
# Not snapshots: nothing re-sends one of these records, so no tolerance applies.
EVENT_TOPICS = ("effector-events", "cm-events")

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


class KeyLasts(dict):
    """key -> (last_offset, last_ms), newest first; `skipped` counts records
    whose key was unusable."""
    skipped = 0


def parse_consume(text: str) -> tuple[KeyLasts, int | None]:
    """`rpk topic consume -f '%p %o %d %k\\n'` -> (key_lasts, head_ms).

    key_lasts maps every distinct key matching KEY_RE to (its own newest
    offset, its own newest timestamp in ms), newest first, with no cap.
    head_ms is the last line's timestamp. Records whose key does not match
    KEY_RE (the key goes into SQL) or is empty are skipped and counted in
    key_lasts.skipped."""
    recs = []
    for line in text.replace("\r", "").splitlines():
        f = line.split()
        if len(f) >= 3 and f[1].isdigit() and f[2].isdigit():
            recs.append((int(f[1]), int(f[2]), f[3] if len(f) > 3 else ""))
    out = KeyLasts()
    if not recs:
        return out, None
    for off, ms, k in reversed(recs):
        if not (k and KEY_RE.fullmatch(k)):
            out.skipped += 1
        elif k not in out:
            out[k] = (off, ms)
    return out, recs[-1][1]


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


def key_verdict(position: int | None, key_last: int, key_last_ms: int | None,
                now_ms: int, tolerance: int) -> str:
    """One key on one partition, against that key's OWN last record."""
    if position is not None:
        return "OK" if max(0, key_last - position) <= tolerance else "BEHIND"
    if key_last_ms is not None and (now_ms - key_last_ms) / 1000.0 > IDLE_AFTER_S:
        return "IDLE"
    return "UNREAD"


def partition_state(key_rows: list, start: int, high: int, head_ms: int | None,
                    now_ms: int, node_failed: bool = False) -> str:
    """One (subscription, partition). key_rows: dicts with "state" (or bare
    state strings). The worst key decides: BEHIND, UNREAD, OK, IDLE."""
    if node_failed:
        return "UNREAD"
    if high <= start:
        return "EMPTY"
    sts = {(r["state"] if isinstance(r, dict) else r) for r in key_rows}
    if not sts:
        if head_ms is not None and (now_ms - head_ms) / 1000.0 > IDLE_AFTER_S:
            return "IDLE"
        return "UNREAD"
    for st in ("BEHIND", "UNREAD", "OK", "IDLE"):
        if st in sts:
            return st
    return "UNREAD"


def nodes_for(tier_names: list[str]) -> list[str] | None:
    """The hub plus every tier; None (a failure) when there are no tiers."""
    return ["hub"] + list(tier_names) if tier_names else None


@dataclass
class NodeRead:
    failed: list[str] = field(default_factory=list)
    subs: list[tuple[str, str, str, str]] = field(default_factory=list)  # svc, handler, broker, topic
    # (broker, topic) -> {p: (start, high, head_ms, key_lasts, keys_skipped)}
    parts: dict = field(default_factory=dict)
    # (svc, handler, topic, p, key) -> (offset, ts)
    positions: dict = field(default_factory=dict)
    # (svc, handler, topic, key) -> error type name from the journal query
    key_errors: dict = field(default_factory=dict)
    jobs: int = 0
    positions_seconds: float = 0.0


def summarize(key_rows: list[dict]) -> dict:
    """Row fields taken from the worst key, plus the key counts."""
    behind = sorted((r for r in key_rows if r["state"] == "BEHIND"),
                    key=lambda r: -r["behind"])
    oks = sorted((r for r in key_rows if r["state"] == "OK"),
                 key=lambda r: -r["behind"])
    rest = [r for r in key_rows if r["state"] in ("UNREAD", "IDLE")]
    w = (behind or oks or rest or [None])[0]

    def n(st):
        return sum(1 for r in key_rows if r["state"] == st)
    return {"key": w["key"] if w else None, "position": w["position"] if w else None,
            "last": w["last"] if w else None, "behind": w["behind"] if w else None,
            "age_ms": w["age_ms"] if w else None, "note": w["note"] if w else "",
            "keys_read": len(key_rows), "keys_behind": n("BEHIND"),
            "keys_idle": n("IDLE"), "keys_unread": n("UNREAD"),
            "behind_keys": [r["key"] for r in behind], "key_rows": key_rows}


def failed_row(node: str, why: str) -> dict:
    return {"node": node, "service": "-", "handler": "-", "topic": "-",
            "partition": -1, "key": None, "position": None, "last": None, "high": None,
            "start": None, "head_ms": None, "behind": None, "age_ms": None,
            "state": "UNREAD", "note": why, "keys_read": 0, "keys_behind": 0,
            "keys_idle": 0, "keys_unread": 0, "keys_skipped": 0, "behind_keys": [],
            "key_rows": []}


def evaluate_node(node: str, read: NodeRead, tolerance: int, now_ms: int) -> list[dict]:
    rows = [failed_row(node, why) for why in read.failed]
    if not read.subs and not read.failed:
        rows.append(failed_row(node, "zero subscriptions"))
    for svc, handler, broker, topic in read.subs:
        for p, (start, high, head_ms, key_lasts, skipped) in sorted(
                read.parts.get((broker, topic), {}).items()):
            key_rows = []
            for key, (klast, kms) in key_lasts.items():
                pos = read.positions.get((svc, handler, topic, p, key))
                err = read.key_errors.get((svc, handler, topic, key))
                position = pos[0] if pos else None
                note = ""
                if position is None and err:
                    state, note = "UNREAD", err
                else:
                    state = key_verdict(position, klast, kms, now_ms,
                                        0 if topic in EVENT_TOPICS else tolerance)
                ts = pos[1] if pos else None
                key_rows.append({
                    "key": key, "position": position, "last": klast,
                    "behind": (max(0, klast - position) if position is not None else None),
                    "age_ms": (now_ms - ts) if ts else None, "state": state, "note": note})
            state = partition_state(key_rows, start, high, head_ms, now_ms,
                                    bool(read.failed))
            row = {"node": node, "service": svc, "handler": handler, "topic": topic,
                   "partition": p, "high": high, "start": start, "head_ms": head_ms,
                   "state": state, "keys_skipped": skipped}
            row.update(summarize(key_rows))
            if not key_rows:
                row["last"] = high - 1
            rows.append(row)
    return rows


def row_key(r: dict) -> tuple:
    return (r["node"], r["service"], r["handler"], r["topic"], r["partition"])


def compare_passes(first: list[dict], second: list[dict], tolerance: int,
                   now_ms: int | None = None) -> list[dict]:
    """Per key: a key OK on both passes whose own last record advanced by more
    than tolerance while its position did not move at all becomes BEHIND, and
    the row is decided again. Keys present on only one pass are not compared."""
    now_ms = int(time.time() * 1000) if now_ms is None else now_ms
    old = {row_key(r): r for r in first}
    for r in second:
        o = old.get(row_key(r))
        if not o:
            continue
        before = {k["key"]: k for k in o["key_rows"]}
        changed = False
        for k in r["key_rows"]:
            b = before.get(k["key"])
            if (b and b["state"] == "OK" and k["state"] == "OK"
                    and k["last"] - b["last"] > (0 if r["topic"] in EVENT_TOPICS
                                                 else tolerance)
                    and k["position"] == b["position"]):
                k["state"] = "BEHIND"
                k["note"] = "position unmoved while high advanced"
                changed = True
        if changed:
            skipped = r["keys_skipped"]
            r["state"] = partition_state(r["key_rows"], r["start"], r["high"],
                                         r["head_ms"], now_ms, False)
            r.update(summarize(r["key_rows"]))
            r["keys_skipped"] = skipped
    return second


def event_idle_keys(rows: list[dict]) -> list[dict]:
    """Keys on event topics whose state is IDLE: passed, but not proven."""
    return [{"node": r["node"], "handler": r["handler"], "topic": r["topic"],
             "partition": r["partition"], "key": k["key"], "last": k["last"]}
            for r in rows if r["topic"] in EVENT_TOPICS
            for k in r["key_rows"] if k["state"] == "IDLE"]


def print_event_idle(rows: list[dict]) -> None:
    idle = event_idle_keys(rows)
    print("event topics, IDLE, handler not proven: %d" % len(idle))
    for i in idle:
        print("  %-8s %s %s/%d key=%s last=%s" % (
            i["node"], i["handler"], i["topic"], i["partition"], i["key"], i["last"]))


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

    keys: dict = {}  # (broker, topic) -> {p: key_lasts}
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
            ks, head = KeyLasts(), None
            if high > start:
                lo = max(start, high - HEAD_WINDOW)
                c = exec_in(ns, bpod, "redpanda", RPK_REMOTE,
                            ["rpk", "topic", "consume", topic, "-p", str(p), "-o",
                             "%d:%d" % (lo, high), "-f", "%p %o %d %k\\n"])
                if c and c[0] == 0:
                    ks, head = parse_consume(c[1])
            parts[p] = (start, high, head, ks, ks.skipped)
            keys[(broker, topic)][p] = ks
        read.parts[(broker, topic)] = parts

    jobs, seen = [], set()
    for svc, handler, broker, topic in read.subs:
        for p, ks in keys.get((broker, topic), {}).items():
            for k in ks:
                if (svc, handler, topic, k) not in seen:
                    seen.add((svc, handler, topic, k))
                    jobs.append({"service": svc, "handler": handler, "key": k, "topic": topic})
    read.jobs = len(jobs)
    t0 = time.time()
    for i in range(0, len(jobs), JOB_CHUNK):
        res = exec_in(ns, pod, "cm-service", PY_REMOTE,
                      ["python", "-u", "-", admin, json.dumps(jobs[i:i + JOB_CHUNK])],
                      POS_SCRIPT.encode())
        if not res or res[0] != 0:
            read.failed.append("positions unreadable")
            break
        apply_job_results(read, res[1])
    read.positions_seconds = time.time() - t0
    return read


def apply_job_results(read: NodeRead, text: str) -> None:
    """Journal-read output lines -> read.positions / read.key_errors. A job
    that errored makes only its own key UNREAD."""
    for line in text.splitlines():
        try:
            j = json.loads(line)
        except ValueError:
            continue
        if not isinstance(j, dict):
            continue
        if j.get("error"):
            read.key_errors[(j.get("service"), j.get("handler"), j.get("topic"),
                             j.get("key"))] = str(j["error"])
        elif j.get("offset") is not None and j.get("partition") is not None:
            k = (j["service"], j["handler"], j["topic"], j["partition"], j["key"])
            read.positions[k] = (j["offset"], j.get("timestamp"))


# -------------------------------------------------------------------- output

def fmt_age(ms) -> str:
    if ms is None:
        return "-"
    m = max(0, int(ms // 60000))
    return "%dh%02dm" % (m // 60, m % 60) if m >= 60 else "%dm" % m


def key_totals(rows: list[dict]) -> dict:
    return {"read": sum(r["keys_read"] for r in rows),
            "behind": sum(r["keys_behind"] for r in rows),
            "idle": sum(r["keys_idle"] for r in rows),
            "unread": sum(r["keys_unread"] for r in rows),
            "skipped": sum(r["keys_skipped"] for r in rows)}


def print_pass(n: int, rows: list[dict], stats: list | None = None) -> None:
    print("pass %d" % n)
    for r in rows:
        if r["state"] in ("EMPTY",):
            continue
        extra = ""
        if r["key_rows"] or r["keys_skipped"]:
            extra = " keys behind %d/%d" % (r["keys_behind"], r["keys_read"])
            for label, f in (("idle", "keys_idle"), ("unread", "keys_unread"),
                             ("skipped", "keys_skipped")):
                if r[f]:
                    extra += " %s %d" % (label, r[f])
        print("  %-8s %s/%s %s/%s %s key=%s position=%s last=%s behind=%s age=%s%s%s" % (
            r["node"], r["service"], r["handler"], r["topic"],
            r["partition"] if r["partition"] >= 0 else "-", r["state"], r["key"],
            r["position"], r["last"], r["behind"], fmt_age(r["age_ms"]), extra,
            (" (" + r["note"] + ")") if r["note"] else ""))
        if r["state"] == "BEHIND":
            for k in sorted((k for k in r["key_rows"] if k["state"] == "BEHIND"),
                            key=lambda k: -k["behind"]):
                print("      %s position=%s behind=%s age=%s" % (
                    k["key"], k["position"], k["behind"], fmt_age(k["age_ms"])))
    c = counts(rows)
    print("  counts: " + " ".join("%s=%d" % (s, c[s]) for s in STATES)
          + " rows=%d" % len(rows))
    t = key_totals(rows)
    print("  keys: read=%(read)d behind=%(behind)d idle=%(idle)d "
          "unread=%(unread)d skipped=%(skipped)d" % t)
    for node, jobs, secs in (stats or []):
        print("  %-8s positions read: %d jobs, %.1f s" % (node, jobs, secs))
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
    print("  * That an IDLE key on an event topic was ever handled: a key handled")
    print("    long ago and one never handled read the same.")
    print("  * That the group's own lag is low; check-advancing and the")
    print("    group's describe read that.")
    print("  * Anything about a stage after the handler (the store, the")
    print("    projector, the screen).")
    print("  * That the position holds: it is a reading at two moments, and")
    print("    a passing tier can fall behind afterwards.")
    print("  * Every key: a key with no record in the last %d offsets of a" % HEAD_WINDOW)
    print("    partition is not read, so a key that has gone quiet can sit behind")
    print("    unseen. The window's coverage is the count printed, and it is not")
    print("    a census of the tier's keys.")


def one_pass(ns: str, nodes: list[str], tolerance: int) -> tuple[list[dict], list]:
    rows, stats = [], []
    for node in nodes:
        rd = read_node(ns, node)
        rows += evaluate_node(node, rd, tolerance, int(time.time() * 1000))
        stats.append((node, rd.jobs, rd.positions_seconds))
    return rows, stats


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

    first, stats1 = one_pass(ns, nodes, a.tolerance)
    print_pass(1, first, stats1)
    if not passes(first):
        print_event_idle(first)
        print_not_established()
        print("handler position: FAIL (pass 1: %s)" % summary(first))
        return 1

    time.sleep(a.interval)
    rows2, stats2 = one_pass(ns, nodes, a.tolerance)
    second = compare_passes(first, rows2, a.tolerance)
    print_pass(2, second, stats2)
    print_event_idle(second)
    if not passes(second):
        print_not_established()
        print("handler position: FAIL (pass 2: %s)" % summary(second))
        return 1
    print("handler position: PASS (pass 1: %s; pass 2: %s)" % (summary(first), summary(second)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
