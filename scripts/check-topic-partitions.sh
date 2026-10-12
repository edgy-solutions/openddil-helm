#!/usr/bin/env bash
# ===========================================================================
# check-topic-partitions.sh -- does every topic hold the partition count the
# deployed spec asks for?
# ===========================================================================
# topic-init creates a topic with `-p N` and, when the topic already exists,
# leaves its partition count alone: a topic created before the spec said 8
# keeps 1 forever and nothing in the hook's own log survives (a successful
# hook is deleted). Raising the count of a compacted keyed topic restarts
# offsets and needs a cold reset, so this check does not fix anything. It makes
# the drift visible, and makes a deliberately held drift a named, counted state
# rather than a quiet one.
#
# THE SPEC IS READ FROM THE DEPLOYED RELEASE, never from a copy in this file:
# `helm get hooks` -> every topic-init Job -> every "<topic>|-p <n> ..." spec
# string. The Job name gives the tier (`-topic-init` = hq, `-topic-init-<t>` =
# <t>); the HQ-only egress specs live in the hq Job and are read the same way.
#
#   ./scripts/check-topic-partitions.sh <namespace> [--declared <file>] [--release <name>]
#
# Per (tier, topic) one line: ok | DRIFT spec=<n> live=<m> | MISSING |
# HELD spec=<n> live=<m> (<reason>).
#
# Declarations (default none, so a deployment with drift fails until someone
# declares it):
#   version: 1
#   drift:
#     - tier: region-east
#       topic: asset-cm-state
#       spec: 8
#       live: 1
#       status: held
#       reason: >-
#         ...
# An entry matches only that tier, topic, spec AND live count. An entry that
# matches nothing live is STALE and fails the run: remove it when the drift is
# fixed. `status` must be `held`; anything else refuses the run.
#
# Exit 0 = nothing DRIFT/MISSING/stale (held is allowed and counted).
# Exit 1 = at least one DRIFT, MISSING or stale declaration.
# Exit 3 = GATE NOT RUN: kubectl/helm missing, namespace or release missing,
#          zero specs parsed, a tier's broker could not be listed, or a bad
#          declarations file. A check that compared nothing never passes.
# ===========================================================================
set -uo pipefail

NS="${1:-}"
[ -n "$NS" ] && [ "${NS#-}" = "$NS" ] || { echo "usage: $0 <namespace> [--declared <file>] [--release <name>]" >&2; exit 3; }
shift
DECL=""; REL="openddil"
while [ $# -gt 0 ]; do
  case "$1" in
    --declared) DECL="${2:-}"; shift 2 ;;
    --release)  REL="${2:-}"; shift 2 ;;
    *) echo "GATE NOT RUN: unknown argument $1" >&2; exit 3 ;;
  esac
done

PY=; for c in python3 python "py -3"; do $c -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null && PY=$c && break; done
[ -n "$PY" ] || { echo "GATE NOT RUN: no Python 3.8+ found" >&2; exit 3; }
for t in kubectl helm; do
  command -v "$t" >/dev/null 2>&1 || { echo "GATE NOT RUN: $t not found" >&2; exit 3; }
done
[ -z "$DECL" ] || [ -f "$DECL" ] || { echo "GATE NOT RUN: declarations file not found: $DECL" >&2; exit 3; }

MSYS_NO_PATHCONV=1 kubectl get namespace "$NS" >/dev/null 2>&1 \
  || { echo "GATE NOT RUN: namespace $NS not reachable" >&2; exit 3; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
helm get hooks "$REL" -n "$NS" > "$TMP/hooks.yaml" 2>"$TMP/helm.err" \
  || { echo "GATE NOT RUN: release $REL not found in $NS ($(head -c 120 "$TMP/helm.err"))" >&2; exit 3; }

$PY - "$NS" "$REL" "$TMP/hooks.yaml" "${DECL:-}" <<'PYEOF'
import os, re, subprocess, sys

ns, rel, hooks_path, decl_path = sys.argv[1:5]

def gate_not_run(msg):
    print("GATE NOT RUN: " + msg)
    sys.exit(3)

# --- spec, from the deployed hooks -----------------------------------------
text = open(hooks_path, encoding="utf-8").read()
SPEC_RE = re.compile(r'"([a-z0-9][a-z0-9._-]*)\|-p (\d+)[ "]')
specs = {}   # tier -> {topic: n}
for doc in re.split(r"(?m)^---\s*$", text):
    if not re.search(r"(?m)^kind:\s*Job\s*$", doc):
        continue
    m = re.search(r"(?m)^  name:\s*(\S+)", doc)
    if not m:
        continue
    name = m.group(1).strip('"')
    m = re.search(r"-topic-init(?:-(.+))?$", name)
    if not m:
        continue
    tier = m.group(1) or "hq"
    for topic, n in SPEC_RE.findall(doc):
        specs.setdefault(tier, {})[topic] = int(n)
if not specs or not any(specs.values()):
    gate_not_run("zero topic specs parsed from the topic-init Jobs of release %s" % rel)

# --- declarations -----------------------------------------------------------
decls = []
if decl_path:
    entry = None
    in_drift = False
    reason_mode = False
    for raw in open(decl_path, encoding="utf-8"):
        line = raw.rstrip("\r\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if re.match(r"^drift:\s*$", line):
            in_drift = True
            continue
        if re.match(r"^version:\s*1\s*$", line):
            continue
        if not in_drift:
            gate_not_run("declarations: unexpected line before `drift:`: %r" % line)
        m = re.match(r"^  - (\w+):\s*(.*)$", line)
        if m:
            entry = {}
            decls.append(entry)
            key, val = m.group(1), m.group(2)
            reason_mode = False
        else:
            m = re.match(r"^    (\w+):\s*(.*)$", line)
            if m and entry is not None:
                key, val = m.group(1), m.group(2)
                reason_mode = False
            elif entry is not None and reason_mode and line.startswith("      "):
                entry["reason"] = (entry.get("reason", "") + " " + line.strip()).strip()
                continue
            else:
                gate_not_run("declarations: cannot parse line %r" % line)
        if key == "reason":
            if val in (">-", ">", "|", "|-"):
                reason_mode = True
                entry["reason"] = ""
            else:
                entry["reason"] = val.strip("\"'")
        elif key in ("spec", "live"):
            if not val.isdigit():
                gate_not_run("declarations: %s must be an integer, got %r" % (key, val))
            entry[key] = int(val)
        elif key in ("tier", "topic", "status"):
            entry[key] = val.strip("\"'")
        else:
            gate_not_run("declarations: unknown key %r" % key)
    for e in decls:
        for k in ("tier", "topic", "spec", "live", "status"):
            if k not in e:
                gate_not_run("declarations: entry %r lacks %s" % (e, k))
        if e["status"] != "held":
            gate_not_run("declarations: status must be `held`, got %r for %s/%s" % (e["status"], e["tier"], e["topic"]))
        e["used"] = False

# --- live -------------------------------------------------------------------
env = dict(os.environ, MSYS_NO_PATHCONV="1")
live = {}
for tier in sorted(specs):
    pod = "%s-redpanda-%s-0" % (rel, tier)
    r = subprocess.run(["kubectl", "-n", ns, "exec", pod, "-c", "redpanda", "--", "rpk", "topic", "list"],
                       capture_output=True, text=True, env=env)
    rows = {}
    for ln in r.stdout.splitlines():
        parts = ln.split()
        if len(parts) >= 2 and parts[1].isdigit():
            rows[parts[0]] = int(parts[1])
    if r.returncode != 0 or "NAME" not in r.stdout:
        gate_not_run("cannot list topics on %s (%s)" % (pod, (r.stderr or "no output").strip()[:100]))
    live[tier] = rows

# --- compare ----------------------------------------------------------------
checked = drift = held = missing = 0
for tier in sorted(specs):
    for topic in sorted(specs[tier]):
        spec = specs[tier][topic]
        checked += 1
        have = live[tier].get(topic)
        if have is None:
            missing += 1
            print("%-14s %-34s MISSING" % (tier, topic))
        elif have == spec:
            print("%-14s %-34s ok" % (tier, topic))
        else:
            d = next((e for e in decls if e["tier"] == tier and e["topic"] == topic
                      and e["spec"] == spec and e["live"] == have), None)
            if d:
                d["used"] = True
                held += 1
                print("%-14s %-34s HELD spec=%d live=%d (%s)" % (tier, topic, spec, have, d.get("reason", "")[:80]))
            else:
                drift += 1
                print("%-14s %-34s DRIFT spec=%d live=%d" % (tier, topic, spec, have))
stale = [e for e in decls if not e["used"]]
for e in stale:
    print("STALE declaration: %s/%s spec=%d live=%d matches nothing live; remove it" % (e["tier"], e["topic"], e["spec"], e["live"]))
print("topic partitions: %d checked, %d drift, %d held, %d missing, %d stale declaration(s)"
      % (checked, drift, held, missing, len(stale)))
sys.exit(1 if (drift or missing or stale) else 0)
PYEOF
