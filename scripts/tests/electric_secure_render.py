#!/usr/bin/env python3
"""Render proof for electric.secure (Electric requires a secret on /v1/shape).

Runs `helm template` through a pipe and parses the YAML in memory: no render
is ever written to disk. Failures name kind/name/field only, never values.
Exit 0 when every case passes, 1 otherwise.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

import yaml

CHART = os.environ.get("CHART") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "openddil-demo")
REL = "t"
DIGEST = "sha256:efb6fa43859d67cb8c73439e0c8bc0f7a3daa467500fb06f2a924bcb2070c139"
IMAGE = "electricsql/electric@" + DIGEST
BASE = ["--set", "releasability.enabled=true", "--set", "tierNode.enabled=true"]
SECURE = BASE + ["--set", "electric.secure.enabled=true"]
NO_PEP = ["--set", "tierNode.enabled=true", "--set", "electric.secure.enabled=true"]


def render(args):
    return render_chart(CHART, args)


def render_chart(chart, args):
    p = subprocess.run(["helm", "template", REL, chart] + args,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out = p.stdout.decode("utf-8", "replace")
    docs = [d for d in yaml.safe_load_all(out) if d] if p.returncode == 0 else []
    return p.returncode, docs, p.stderr.decode("utf-8", "replace")


def pods(docs):
    """Yield (kind, name, podspec) for every workload and bare pod."""
    for d in docs:
        k = d.get("kind")
        if k == "Pod":
            yield k, d["metadata"]["name"], d["spec"]
        elif k in ("Deployment", "StatefulSet", "Job", "DaemonSet"):
            yield k, d["metadata"]["name"], d["spec"]["template"]["spec"]


def containers(docs):
    for k, n, spec in pods(docs):
        for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
            yield k, n, c


def envmap(c):
    return {e["name"]: e for e in c.get("env") or []}


def by_container(docs, cname, hub_name, tier_prefix):
    """Deployment name -> (instance key, container) for containers named cname."""
    out = {}
    for k, n, spec in pods(docs):
        if k != "Deployment":
            continue
        for c in spec["containers"]:
            if c["name"] == cname:
                out[n] = ("hub", c) if n == hub_name else (n[len(tier_prefix):], c)
    return out


def electric_deploys(docs):
    return by_container(docs, "electric", REL + "-electric-sync", REL + "-tier-electric-")


def peps(docs):
    return by_container(docs, "pep", REL + "-pep", REL + "-tier-pep-")


def named(docs, kind):
    return {d["metadata"]["name"]: d for d in docs if d.get("kind") == kind}


def ref_ok(e, secret, key):
    r = ((e.get("valueFrom") or {}).get("secretKeyRef")) or {}
    return r.get("name") == secret and r.get("key") == key and "value" not in e


def direct_test_pod(docs):
    return REL + "-test-electric-sync" in named(docs, "Pod")


def electric_secrets(docs):
    return {n: d for n, d in named(docs, "Secret").items() if n.endswith("-electric-secret")}


RESULTS = []


def case(name, problems):
    ok = not problems
    RESULTS.append(ok)
    print(("PASS " if ok else "FAIL ") + name)
    for p in problems:
        print("  - " + p)


def must_render(args):
    rc, docs, err = render(args)
    if rc != 0:
        raise SystemExit("render failed (exit %d) for %s: %s" % (rc, args, err.strip().splitlines()[-1:]))
    return docs


def t1():
    docs = must_render(BASE)
    p = []
    ed = electric_deploys(docs)
    if len(ed) < 3:
        p.append("expected hub + tier Electrics, found %d" % len(ed))
    for n, (key, c) in ed.items():
        env = envmap(c)
        if env.get("ELECTRIC_INSECURE", {}).get("value") != "true":
            p.append("%s: ELECTRIC_INSECURE not true" % n)
    for k, n, c in containers(docs):
        env = envmap(c)
        if "ELECTRIC_SECRET" in env or "OPENDDIL_ELECTRIC_SECRET" in env:
            p.append("%s/%s: secret env present" % (k, n))
    for n in electric_secrets(docs):
        p.append("Secret %s rendered" % n)
    for n in named(docs, "NetworkPolicy"):
        if "electric-pep-only" in n:
            p.append("NetworkPolicy %s rendered" % n)
    if not direct_test_pod(docs):
        p.append("direct electric test pod missing")
    case("T1 default", p)


def t2():
    docs = must_render(BASE + ["--set", "electric.clearToken.hub=x",
                               "--set", "exerciseControl.enabled=true",
                               "--set", "exerciseControl.resetJob.enabled=true",
                               "--set", "exerciseControl.adapter.endpoint=http://x"])
    docs += must_render(SECURE)
    p = []
    seen = 0
    for k, n, c in containers(docs):
        if "electric" in c.get("image", "").lower():
            seen += 1
            if c["image"] != IMAGE:
                p.append("%s/%s/%s: image is not the pinned digest" % (k, n, c["name"]))
        e = envmap(c).get("ELECTRIC_IMAGE")
        if e:
            seen += 1
            if e.get("value") != IMAGE:
                p.append("%s/%s: ELECTRIC_IMAGE is not the pinned digest" % (k, n))
    # The reset runner's Job template is JSON inside a ConfigMap.
    reset_env = 0
    for n, cm in named(docs, "ConfigMap").items():
        raw = (cm.get("data") or {}).get("job.json")
        if not raw:
            continue
        job = json.loads(raw)
        for c in job["spec"]["template"]["spec"]["containers"]:
            e = envmap(c).get("ELECTRIC_IMAGE")
            if e:
                reset_env += 1
                seen += 1
                if e.get("value") != IMAGE:
                    p.append("ConfigMap/%s: ELECTRIC_IMAGE is not the pinned digest" % n)
    if not reset_env:
        p.append("no reset Job ELECTRIC_IMAGE rendered to check")
    names = {c["name"] for _, _, c in containers(docs)}
    if "electric-clear" not in names:
        p.append("no electric-clear init container rendered to check")
    case("T2 image (%d refs)" % seen, p)


def secure_checks(docs, secret, expect_secret_obj):
    p = []
    ed = electric_deploys(docs)
    pp = peps(docs)
    keys = {k for k, _ in ed.values()}
    if len(keys) < 3 or "hub" not in keys:
        p.append("expected hub + at least two tiers, got %d instances" % len(keys))
    for n, (key, c) in ed.items():
        env = envmap(c)
        if "ELECTRIC_INSECURE" in env:
            p.append("%s: ELECTRIC_INSECURE present" % n)
        if not ref_ok(env.get("ELECTRIC_SECRET", {}), secret, key):
            p.append("%s: ELECTRIC_SECRET ref wrong (want %s/%s)" % (n, secret, key))
    if {k for k, _ in pp.values()} != keys:
        p.append("PEP instances differ from Electric instances")
    for n, (key, c) in pp.items():
        if not ref_ok(envmap(c).get("OPENDDIL_ELECTRIC_SECRET", {}), secret, key):
            p.append("%s: OPENDDIL_ELECTRIC_SECRET ref wrong" % n)
    for k, n, c in containers(docs):
        env = envmap(c)
        if c["name"] != "pep" and "OPENDDIL_ELECTRIC_SECRET" in env:
            p.append("%s/%s/%s: has OPENDDIL_ELECTRIC_SECRET" % (k, n, c["name"]))
        if c["name"] != "electric" and "ELECTRIC_SECRET" in env:
            p.append("%s/%s/%s: has ELECTRIC_SECRET" % (k, n, c["name"]))
    secrets = electric_secrets(docs)
    if expect_secret_obj:
        d = secrets.get(secret)
        if d is None:
            p.append("Secret %s missing" % secret)
        else:
            if d.get("type") != "Opaque":
                p.append("Secret %s not Opaque" % secret)
            if set((d.get("data") or {}).keys()) != keys:
                p.append("Secret %s keys differ from instances" % secret)
            if any(not v for v in (d.get("data") or {}).values()):
                p.append("Secret %s has an empty key" % secret)
    elif secrets:
        p.append("Secret(s) rendered: %s" % ",".join(sorted(secrets)))
    return p, ed, pp, keys


def matches(labels, sel):
    return all(labels.get(a) == b for a, b in sel.items())


def t3():
    docs = must_render(SECURE)
    secret = REL + "-electric-secret"
    p, ed, pp, keys = secure_checks(docs, secret, True)
    nps = named(docs, "NetworkPolicy")
    wants = {REL + "-electric-pep-only": ("hub", 5133)}
    for k in keys - {"hub"}:
        wants["%s-tier-electric-pep-only-%s" % (REL, k)] = (k, 3000)
    pod_labels = {}
    for d in docs:
        if d.get("kind") == "Deployment":
            pod_labels[d["metadata"]["name"]] = d["spec"]["template"]["metadata"]["labels"]
    el_name = {k: n for n, (k, _) in ed.items()}
    pep_name = {k: n for n, (k, _) in pp.items()}
    for name, (key, port) in wants.items():
        d = nps.get(name)
        if d is None:
            p.append("NetworkPolicy %s missing" % name)
            continue
        sel = d["spec"]["podSelector"]["matchLabels"]
        if not matches(pod_labels[el_name[key]], sel):
            p.append("%s: podSelector does not select the Electric pods" % name)
        if matches(pod_labels[pep_name[key]], sel):
            p.append("%s: podSelector also selects the PEP" % name)
        for other, ol in pod_labels.items():
            if other != el_name[key] and matches(ol, sel):
                p.append("%s: podSelector also selects %s" % (name, other))
        ing = d["spec"].get("ingress") or []
        if len(ing) != 1 or len(ing[0].get("from") or []) != 1:
            p.append("%s: expected one ingress rule with one source" % name)
            continue
        frm = ing[0]["from"][0]["podSelector"]["matchLabels"]
        if not matches(pod_labels[pep_name[key]], frm):
            p.append("%s: source does not match the PEP labels" % name)
        for other, ol in pod_labels.items():
            if other != pep_name[key] and matches(ol, frm):
                p.append("%s: source also matches %s" % (name, other))
        ports = [x.get("port") for x in ing[0].get("ports") or []]
        if ports != [port]:
            p.append("%s: ports %s, want [%s]" % (name, ports, port))
        cps = [x.get("containerPort") for x in ed[el_name[key]][1].get("ports") or []]
        if port not in cps:
            p.append("%s: port %s is not an Electric containerPort" % (name, port))
    if REL + "-egress-pane-pep-only" in nps:
        p.append("egress-pane policy rendered without lockDownElectric")
    if direct_test_pod(docs):
        p.append("direct electric test pod rendered")
    case("T3 secure on (%d instances)" % len(keys), p)


def t4():
    docs = must_render(SECURE + ["--set", "electric.secure.existingSecret=my-electric"])
    p, _, _, _ = secure_checks(docs, "my-electric", False)
    case("T4 existingSecret", p)


def t5():
    rc, _, err = render(NO_PEP)
    p = []
    if rc == 0:
        p.append("render succeeded without a PEP")
    if "electric.secure.enabled needs a PEP in front of every Electric (releasability.enabled)" not in err:
        p.append("guard message not in stderr")
    case("T5 guard (releasability off)", p)


def t6():
    docs = must_render(BASE + ["--set", "releasability.lockDownElectric=true"])
    p = []
    nps = named(docs, "NetworkPolicy")
    if REL + "-electric-pep-only" not in nps:
        p.append("hub Electric policy missing")
    if not any("tier-electric-pep-only" in n for n in nps):
        p.append("no tier Electric policy")
    if REL + "-egress-pane-pep-only" not in nps:
        p.append("egress-pane policy missing")
    for n, (key, c) in electric_deploys(docs).items():
        env = envmap(c)
        if env.get("ELECTRIC_INSECURE", {}).get("value") != "true" or "ELECTRIC_SECRET" in env:
            p.append("%s: wrong secure/insecure env" % n)
    for k, n, c in containers(docs):
        if "OPENDDIL_ELECTRIC_SECRET" in envmap(c):
            p.append("%s/%s: PEP secret env present" % (k, n))
    if electric_secrets(docs):
        p.append("electric Secret rendered")
    if direct_test_pod(docs):
        p.append("direct electric test pod rendered")
    case("T6 lockDownElectric alone", p)

FLAG = "ELECTRIC_ENABLE_INTEGRATION_TESTING"
ALLOW = ["--set", "electric.allowShapeDeletion=true"]
G1 = "electric.allowShapeDeletion needs electric.secure.enabled: shape DELETE must be reachable only by the PEPs"
G2 = ("releasability.elementShapes.deleteUpstream needs electric.allowShapeDeletion "
      "(Electric answers DELETE with 405 without it)")
G3 = ("releasability.pep.shapeRotation.periodSeconds needs electric.allowShapeDeletion "
      "(Electric answers DELETE with 405 without it)")
G4 = ("releasability.pep.shapeRotation.periodSeconds needs ceilingSeconds above it "
      "(the ceiling is the checked bound)")
G5 = "releasability.pep.shapeRotation.ceilingSeconds must be a number of seconds >= 0"
CEIL_ENV = "OPENDDIL_PEP_SHAPE_CEILING_S"
ROT_ENV = "OPENDDIL_PEP_SHAPE_ROTATE_S"
IDLE_ENV = "OPENDDIL_PEP_SHAPE_IDLE_S"
G6 = ("releasability.pep.shapeRotation.idlePeriodSeconds needs electric.allowShapeDeletion "
      "(Electric answers DELETE with 405 without it)")
G7 = "releasability.pep.shapeRotation.idlePeriodSeconds must be a number of seconds >= 0"
G8 = "releasability.pep.shapeRotation.idlePeriodSeconds (900) must be above the session's inactivity end"
G9 = "releasability.pep.shapeRotation.idlePeriodSeconds (1800) must be above the session's inactivity end (1800 s, from releasability.oidc.sessionIdleSeconds)"
SLIDING = ["--set", "releasability.oidc.sessionMode=sliding", "--set", "releasability.oidc.sessionIdleSeconds=1800",
           "--set", "releasability.oidc.sessionMaxSeconds=28800"]
IDLE = "releasability.pep.shapeRotation.idlePeriodSeconds="
PERIOD = "releasability.pep.shapeRotation.periodSeconds="
CEILING = "releasability.pep.shapeRotation.ceilingSeconds="
DELUP = ["--set", "releasability.elementShapes.deleteUpstream=true"]


def t7():
    docs = must_render(BASE)
    p = []
    for k, n, c in containers(docs):
        if FLAG in envmap(c):
            p.append("%s/%s/%s: has %s" % (k, n, c["name"], FLAG))
        for v in (CEIL_ENV, ROT_ENV, IDLE_ENV):
            if v in envmap(c):
                p.append("%s/%s/%s: has %s" % (k, n, c["name"], v))
    case("T7 deletion default off", p)


def t8():
    docs = must_render(SECURE + ALLOW)
    p = []
    ed = electric_deploys(docs)
    if len(ed) < 3:
        p.append("expected hub + tier Electrics, found %d" % len(ed))
    shown = None
    for n, (key, c) in ed.items():
        e = envmap(c).get(FLAG)
        if e is None or e.get("value") != "true":
            p.append("%s: %s not \"true\"" % (n, FLAG))
        elif shown is None:
            shown = "%s: name=%s value=%s" % (n, e["name"], e["value"])
    for k, n, c in containers(docs):
        if c["name"] != "electric" and FLAG in envmap(c):
            p.append("%s/%s/%s: has %s" % (k, n, c["name"], FLAG))
    nps = named(docs, "NetworkPolicy")
    if REL + "-electric-pep-only" not in nps:
        p.append("hub Electric policy missing")
    if not any("tier-electric-pep-only" in n for n in nps):
        p.append("no tier Electric policy")
    case("T8 secure + allowShapeDeletion (%d Electrics)" % len(ed), p)
    if shown:
        print("  found " + shown)


def expect_refusal(args, msg, p, what):
    rc, _, err = render(args)
    if rc == 0:
        p.append("%s: render succeeded" % what)
    elif msg not in err:
        p.append("%s: guard message not in stderr" % what)


def expect_render(args, p, what):
    rc, _, err = render(args)
    if rc != 0:
        p.append("%s: render failed" % what)


def t9():
    p = []
    expect_refusal(BASE + ALLOW, G1, p, "flag without secure")
    case("T9 allowShapeDeletion without secure", p)


def t10():
    p = []
    expect_refusal(SECURE + DELUP, G2, p, "deleteUpstream without flag")
    expect_render(SECURE + DELUP + ALLOW, p, "deleteUpstream with flag")
    case("T10 deleteUpstream needs the flag", p)


def t11():
    p = []
    base = SECURE + ["--set", CEILING + "5400"]
    expect_refusal(base + ["--set", PERIOD + "3600"], G3, p, "period 3600 without flag")
    expect_render(base + ["--set", PERIOD + "0"], p, "period 0")
    expect_render(base + ALLOW + ["--set", PERIOD + "3600"], p, "period 3600 with flag")
    case("T11 rotation period needs the flag", p)


def shape_env_check(args, want, p):
    """Every PEP, hub and tiers, has exactly the wanted vars; no other container has any."""
    docs = must_render(args)
    pd = peps(docs)
    if len(pd) < 2:
        p.append("expected hub + tier PEPs, found %d" % len(pd))
    for n, (key, c) in pd.items():
        env = envmap(c)
        for v in (CEIL_ENV, ROT_ENV, IDLE_ENV):
            if v in want:
                if env.get(v, {}).get("value") != want[v]:
                    p.append("%s: %s not %s" % (n, v, want[v]))
            elif v in env:
                p.append("%s: has %s" % (n, v))
    for k, n, c in containers(docs):
        if c["name"] != "pep":
            for v in (CEIL_ENV, ROT_ENV, IDLE_ENV):
                if v in envmap(c):
                    p.append("%s/%s/%s: has %s" % (k, n, c["name"], v))
    return len(pd)


def t13():
    p = []
    n = shape_env_check(SECURE + ["--set", CEILING + "5400"], {CEIL_ENV: "5400"}, p)
    case("T13 ceiling alone (%d PEPs)" % n, p)


def t14():
    p = []
    n = shape_env_check(SECURE + ALLOW + ["--set", CEILING + "5400", "--set", PERIOD + "3600"],
                        {CEIL_ENV: "5400", ROT_ENV: "3600"}, p)
    case("T14 ceiling and period (%d PEPs)" % n, p)


def t15():
    p = []
    expect_refusal(SECURE + ALLOW + ["--set", PERIOD + "3600", "--set", CEILING + "0"], G4, p, "period without ceiling")
    expect_refusal(SECURE + ALLOW + ["--set", PERIOD + "5400", "--set", CEILING + "5400"], G4, p, "period equal to ceiling")
    expect_refusal(SECURE + ALLOW + ["--set", CEILING + "-1"], G5, p, "negative ceiling")
    case("T15 shape rotation refusals", p)


def t16():
    p = []
    n = shape_env_check(SECURE + ALLOW + ["--set", IDLE + "1800"], {IDLE_ENV: "1800"}, p)
    case("T16 idle sweep period (%d PEPs)" % n, p)
    p = []
    n = shape_env_check(SECURE + ALLOW + ["--set", IDLE + "0"], {}, p)
    case("T16 idle 0 renders no env (%d PEPs)" % n, p)
    p = []
    n = shape_env_check(SECURE + ALLOW + SLIDING + ["--set", IDLE + "2400"], {IDLE_ENV: "2400"}, p)
    case("T16 sliding idle 2400 (%d PEPs)" % n, p)


def t17():
    p = []
    expect_refusal(SECURE + ["--set", IDLE + "1800"], G6, p, "idle without flag")
    expect_refusal(SECURE + ALLOW + ["--set", IDLE + "abc"], G7, p, "non-number idle")
    expect_refusal(SECURE + ALLOW + ["--set", IDLE + "900"], G8, p, "idle not above the session")
    expect_refusal(SECURE + ALLOW + SLIDING + ["--set", IDLE + "1800"], G9, p, "sliding idle at the inactivity end")
    case("T17 idle sweep refusals", p)


def t12():
    """Flag off: Electric Deployments are the same as with the c0021a1 helpers."""
    p = []
    repo = os.path.abspath(os.path.join(CHART, ".."))
    # The PEP templates call a helper that c0021a1 lacks, so they go back too.
    names = ("_helpers.tpl", "releasability.yaml", "tier-node.yaml")
    olds = {}
    for nm in names:
        o = subprocess.run(["git", "-C", repo, "show", "c0021a1:openddil-demo/templates/" + nm],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if o.returncode != 0:
            p.append("git show c0021a1 %s failed" % nm)
        olds[nm] = o.stdout
    if p:
        pass
    else:
        tmp = tempfile.mkdtemp()
        try:
            copy = os.path.join(tmp, "chart")
            shutil.copytree(CHART, copy)
            for nm in names:
                with open(os.path.join(copy, "templates", nm), "wb") as f:
                    f.write(olds[nm])
            for label, args in (("default", BASE), ("secure", SECURE)):
                new_docs = must_render(args)
                rc, old_docs, err = render_chart(copy, args)
                if rc != 0:
                    p.append("%s: old chart render failed" % label)
                    continue
                a = {n: c.get("env") for n, (_, c) in electric_deploys(new_docs).items()}
                b = {n: c.get("env") for n, (_, c) in electric_deploys(old_docs).items()}
                if not a or a != b:
                    p.append("%s: Electric env lists differ from c0021a1 (%d vs %d)" % (label, len(a), len(b)))
                da = named(new_docs, "Deployment")
                db = named(old_docs, "Deployment")
                for n in a:
                    if da.get(n) != db.get(n):
                        p.append("%s: Deployment %s differs" % (label, n))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    case("T12 byte-identity with flag off", p)


if __name__ == "__main__":
    for t in (t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12, t13, t14, t15, t16, t17):
        t()
    sys.exit(0 if all(RESULTS) else 1)
