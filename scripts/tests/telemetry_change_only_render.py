#!/usr/bin/env python3
"""Render proof for projector.telemetryChangeOnly and the position deadband.

Runs `helm template` through a pipe and parses the YAML in memory: no render
is ever written to disk. Failures name kind/name/field only, never values.
Exit 0 when every case passes, 1 otherwise.
"""
import json
import os
import subprocess
import sys

import yaml

CHART = os.environ.get("CHART") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "openddil-demo")
REL = "t"
BASE = ["--set", "tierNode.enabled=true"]
# edge.yaml's per-edge projectors render only without the tier nodes
EDGE = []
HB = "TELEMETRY_CHANGE_ONLY_HEARTBEAT_S"
DB = "TELEMETRY_POSITION_DEADBAND_M"
ON = BASE + [
    "--set-json", "projector.telemetryChangeOnly.heartbeatS=15",
    "--set-json", "movement.standards.V1.positionDeadbandM=50",
    "--set-json", "movement.standards.V2.marchOrderS=60",
]
ON_DEFAULT = ON + ["--set-json", "movement.positionDeadbandDefaultM=25"]
failed = []


def render(args):
    p = subprocess.run(["helm", "template", REL, CHART] + args,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out = p.stdout.decode("utf-8", "replace")
    docs = [d for d in yaml.safe_load_all(out) if d] if p.returncode == 0 else []
    return p.returncode, docs, p.stderr.decode("utf-8", "replace")


def projectors(docs):
    """Yield (kind, name, container) for every container whose image is the projector."""
    for d in docs:
        if d.get("kind") != "Deployment":
            continue
        for c in d["spec"]["template"]["spec"].get("containers") or []:
            if c.get("name") == "projector" and "projector" in (c.get("image") or ""):
                yield d["kind"], d["metadata"]["name"], c


def envmap(c):
    return {e["name"]: e.get("value") for e in c.get("env") or []}


def check(case, ok, where):
    if ok:
        print("PASS %s" % case)
    else:
        print("FAIL %s: %s" % (case, where))
        failed.append(case)


def renders(args, case):
    """Render the tier-node shape and the root/edge shape; return both docs lists joined."""
    rc, docs, err = render(args)
    rc2, docs2, err2 = render(without_tiers(args))
    if rc != 0 or rc2 != 0:
        check(case, False, "render failed")
        return None
    seen, out = set(), []
    for d in docs + docs2:  # the hub projector renders in both
        key = (d.get("kind"), d["metadata"]["name"])
        if key not in seen:
            seen.add(key)
            out.append(d)
    return out


def without_tiers(args):
    out, i = [], 0
    while i < len(args):
        if args[i] == "--set" and args[i + 1] == "tierNode.enabled=true":
            i += 2
            continue
        out.append(args[i])
        i += 1
    return out


# A default
docs = renders(BASE, "A")
if docs is not None:
    bad = [(k, n, f) for k, n, c in projectors(docs) for f in (HB, DB) if f in envmap(c)]
    check("A default: no change-only env", not bad and any(True for _ in projectors(docs)),
          "; ".join("%s/%s %s" % b for b in bad) or "no projector found")

# B on, G count
docs = renders(ON_DEFAULT, "B")
if docs is not None:
    bad, total, withenv = [], 0, 0
    for k, n, c in projectors(docs):
        total += 1
        e = envmap(c)
        if HB in e and DB in e:
            withenv += 1
        if e.get(HB) != "15":
            bad.append("%s/%s %s" % (k, n, HB))
        try:
            ok = json.loads(e.get(DB, "")) == {"V1": 50, "*": 25}
        except ValueError:
            ok = False
        if not ok:
            bad.append("%s/%s %s" % (k, n, DB))
    check("B on: every projector has both env", total > 0 and not bad, "; ".join(bad) or "no projector")
    print("G count: %d containers with env, %d projector containers" % (withenv, total))
    check("G count equal", total > 0 and withenv == total, "%d of %d" % (withenv, total))
    for k, n, c in projectors(docs):
        print("  %s/%s" % (k, n))

# C no default
docs = renders(ON, "C")
if docs is not None:
    bad = []
    for k, n, c in projectors(docs):
        try:
            ok = json.loads(envmap(c).get(DB, "")) == {"V1": 50}
        except ValueError:
            ok = False
        if not ok:
            bad.append("%s/%s %s" % (k, n, DB))
    check("C no default", not bad and any(True for _ in projectors(docs)), "; ".join(bad) or "no projector")

# D heartbeat 16
rc, _, err = render(BASE + ["--set-json", "projector.telemetryChangeOnly.heartbeatS=16"])
check("D heartbeat 16 fails naming heartbeatS", rc != 0 and "heartbeatS" in err, "rc=%d" % rc)

# E bad deadband
rc, _, err = render(BASE + ["--set-json", "projector.telemetryChangeOnly.heartbeatS=15",
                            "--set-json", "movement.standards.V1.positionDeadbandM=-1"])
check("E bad deadband names V1 not the value", rc != 0 and "V1" in err and "-1" not in err, "rc=%d" % rc)

# F panel unchanged
rc, docs, err = render(ON_DEFAULT)
seen = None
for d in docs:
    if d.get("kind") == "ConfigMap":
        raw = (d.get("data") or {}).get("deployment.json")
        if raw:
            try:
                std = json.loads(raw).get("movement", {}).get("standards", {})
            except ValueError:
                continue
            if "V1" in std:
                seen = (d["metadata"]["name"], std["V1"])
                break
check("F panel deployment.json carries V1.positionDeadbandM",
      seen is not None and "positionDeadbandM" in seen[1], "not found")
if seen:
    print("  F saw %s V1 keys: %s" % (seen[0], sorted(seen[1])))

sys.exit(1 if failed else 0)
