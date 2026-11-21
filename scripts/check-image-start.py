#!/usr/bin/env python3
"""Start each of our service images under the environment the chart renders for it.

An image can build, pass its own tests and still refuse to start under the
environment a deployment gives it: an env var the chart sets that the image now
rejects, or one the image now requires that the chart never sets. Nothing in an
image repo sees the chart, and nothing in this repo runs the images. This check
renders the chart, then starts every container of ours from that render in
docker, with the render's command, args, env, user and volumes, and reports
which ones stay up.

What is run
  * `helm template` output, held in memory only (a pipe, never a file).
  * Every Deployment and StatefulSet with a container or initContainer whose
    image starts with ghcr.io/edgy-solutions/openddil/. Each such container is
    a "unit" named <kind>/<name>/<container>. Third-party containers in the
    same pod are skipped and listed. Jobs and bare Pods are out of scope.
  * Image refs are exactly as rendered. The chart pins none of our images:
    global.imageTag is "latest", so the default render runs `:latest` of every
    image: whatever build each image repo last published under that tag.
    (For faust-edge, the tactical-agents docker-build workflow adds :latest
    only on a push or dispatch on master; not every image repo restricts it
    that way, so :latest is not always a master build.) Use
    `--override NAME=REF` (repeatable) to run one image from another ref, for
    example a candidate build or a digest, and `--values-extra FILE`
    (repeatable, applied after `-f`) to render under a deployment's own pins.

How a pod is emulated
  * Volumes: emptyDir and PVC -> a fresh named docker volume; configMap ->
    temp dir of the rendered ConfigMap data (items and subPath honoured);
    secret -> temp dir of placeholder files (never any Secret data);
    projected -> the union of its sources; hostPath -> an empty temp dir.
  * initContainers of ours run first, in order; each must exit 0 in 120 s.
  * Main containers run detached with `--network none`; after --wait seconds a
    container still running passes, one that exited 0 passes, one that exited
    non-zero fails unless an entry in the expect file matches it.
  * Secret env values are the literal `start-check-placeholder`.

Exit status: 0 all pass, 1 any FAIL, 2 bad input or failed render.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

import yaml

PREFIX = "ghcr.io/edgy-solutions/openddil/"
PLACEHOLDER = "start-check-placeholder"
INIT_TIMEOUT = 120
WORKLOAD_KINDS = ("Deployment", "StatefulSet")


class InputError(Exception):
    """Bad input or a failed render (exit 2)."""


class ConfigError(Exception):
    """A reference in the render that cannot be resolved (unit fails `config`)."""


# --------------------------------------------------------------------------
# Render and selection
# --------------------------------------------------------------------------

def which(name):
    path = shutil.which(name)
    if not path:
        raise InputError("%s not found on PATH" % name)
    return path


def render(chart, values, extra):
    helm = which("helm")
    cmd = [helm, "template", "t", chart]
    for v in values:
        cmd += ["-f", v]
    for v in extra:
        cmd += ["-f", v]
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except OSError as e:
        raise InputError("cannot run helm: %s" % e)
    if p.returncode != 0:
        raise InputError("helm template failed (exit %d): %s" % (p.returncode, p.stderr.strip()[-600:]))
    try:
        docs = [d for d in yaml.safe_load_all(p.stdout) if isinstance(d, dict)]
    except yaml.YAMLError as e:
        raise InputError("render is not valid YAML: %s" % e)
    return docs


class Render:
    """Index of the rendered objects. Secret values are dropped on load; only
    their key names are kept."""

    def __init__(self, docs):
        self.configmaps = {}
        self.secrets = {}
        self.workloads = []
        for d in docs:
            kind = d.get("kind")
            name = (d.get("metadata") or {}).get("name")
            if kind == "ConfigMap":
                data = dict(d.get("data") or {})
                for k, v in (d.get("binaryData") or {}).items():
                    try:
                        data[k] = base64.b64decode(v).decode("utf-8", "replace")
                    except Exception:
                        data[k] = ""
                self.configmaps[name] = data
            elif kind == "Secret":
                self.secrets[name] = set((d.get("data") or {})) | set((d.get("stringData") or {}))
            elif kind in WORKLOAD_KINDS:
                self.workloads.append(d)


def image_name(ref):
    """Short name of one of our images: the part after the registry prefix."""
    rest = ref[len(PREFIX):]
    return re.split(r"[:@]", rest, maxsplit=1)[0]


def is_ours(ref):
    return isinstance(ref, str) and ref.startswith(PREFIX)


def effective_ref(ref, overrides):
    return overrides.get(image_name(ref), ref)


def pod_spec(w):
    return ((w.get("spec") or {}).get("template") or {}).get("spec") or {}


def select(rend, overrides):
    """Return (workloads, skipped). Each workload is a dict with name/kind, the
    pod spec, ordered `inits` and `mains` (ours only) and skip lines."""
    out, skipped = [], []
    for w in rend.workloads:
        spec = pod_spec(w)
        kind, name = w["kind"], w["metadata"]["name"]
        inits, mains, any_ours = [], [], False
        for key, bucket in (("initContainers", inits), ("containers", mains)):
            for c in spec.get(key) or []:
                if is_ours(c.get("image")):
                    any_ours = True
                    bucket.append(c)
                else:
                    skipped.append("%s/%s/%s %s" % (kind, name, c.get("name"), c.get("image")))
        if any_ours:
            out.append({"kind": kind, "name": name, "spec": spec, "inits": inits, "mains": mains})
    return out, skipped


def check_overrides(workloads, overrides):
    present = set()
    for w in workloads:
        for c in w["inits"] + w["mains"]:
            present.add(image_name(c["image"]))
    for n in overrides:
        if n not in present:
            raise InputError("--override %s matches no image in the render (have: %s)" % (n, ", ".join(sorted(present))))


# --------------------------------------------------------------------------
# Env, command and volumes
# --------------------------------------------------------------------------

def expand(s, env):
    """k8s-style $(VAR) expansion: $$ is a literal $, unknown names stay."""
    out, i = [], 0
    while i < len(s):
        if s[i] == "$" and i + 1 < len(s):
            if s[i + 1] == "$":
                out.append("$")
                i += 2
                continue
            if s[i + 1] == "(":
                j = s.find(")", i + 2)
                if j != -1:
                    n = s[i + 2:j]
                    out.append(env[n] if n in env else s[i:j + 1])
                    i = j + 1
                    continue
        out.append(s[i])
        i += 1
    return "".join(out)


def field_value(path, workload_name):
    if path == "metadata.name":
        return "%s-start-check" % workload_name
    if path == "metadata.namespace":
        return "default"
    if path == "status.podIP":
        return "127.0.0.1"
    return "start-check"


def resolve_env(c, rend, workload_name):
    """Ordered list of (name, value). envFrom first, then env, each able to
    use $(VAR) of what came before."""
    pairs, known = [], {}

    def put(n, v):
        pairs[:] = [p for p in pairs if p[0] != n]
        pairs.append((n, v))
        known[n] = v

    for ef in c.get("envFrom") or []:
        prefix = ef.get("prefix") or ""
        if "configMapRef" in ef:
            ref = ef["configMapRef"]
            cm = rend.configmaps.get(ref.get("name"))
            if cm is None:
                if ref.get("optional"):
                    continue
                raise ConfigError("envFrom configMap %s is not in the render" % ref.get("name"))
            for k, v in cm.items():
                put(prefix + k, str(v))
        elif "secretRef" in ef:
            ref = ef["secretRef"]
            for k in sorted(rend.secrets.get(ref.get("name"), ())):
                put(prefix + k, PLACEHOLDER)
    for e in c.get("env") or []:
        n = e["name"]
        vf = e.get("valueFrom")
        if not vf:
            put(n, expand(str(e.get("value", "")), known))
        elif "configMapKeyRef" in vf:
            ref = vf["configMapKeyRef"]
            cm = rend.configmaps.get(ref.get("name"))
            if cm is None or ref.get("key") not in cm:
                if ref.get("optional"):
                    continue
                raise ConfigError("env %s: configMap %s key %s is not in the render" % (n, ref.get("name"), ref.get("key")))
            put(n, str(cm[ref["key"]]))
        elif "secretKeyRef" in vf:
            put(n, PLACEHOLDER)
        elif "fieldRef" in vf:
            put(n, field_value(vf["fieldRef"].get("fieldPath", ""), workload_name))
        elif "resourceFieldRef" in vf:
            put(n, "1")
        else:
            put(n, "start-check")
    return pairs


def resolve_command(c, env_pairs):
    env = dict(env_pairs)
    cmd = [expand(str(x), env) for x in c.get("command") or []]
    args = [expand(str(x), env) for x in c.get("args") or []]
    return cmd, args


def safe_rel(path):
    """A relative path from a volume item, with no way out of the volume dir."""
    parts = [p for p in path.replace("\\", "/").split("/") if p not in ("", ".", "..")]
    return "/".join(parts)


def _write(root, rel, text):
    rel = safe_rel(rel)
    if not rel:
        return
    full = os.path.join(root, *rel.split("/"))
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    os.chmod(full, 0o644)


def fill_configmap(root, src, rend):
    cm = rend.configmaps.get(src.get("name"))
    if cm is None:
        if src.get("optional"):
            return
        raise ConfigError("volume configMap %s is not in the render" % src.get("name"))
    items = src.get("items")
    if items:
        for it in items:
            if it["key"] not in cm:
                if src.get("optional"):
                    continue
                raise ConfigError("configMap %s has no key %s" % (src.get("name"), it["key"]))
            _write(root, it.get("path") or it["key"], str(cm[it["key"]]))
    else:
        for k, v in cm.items():
            _write(root, k, str(v))


def fill_secret(root, src, rend):
    """Placeholder files only. Secret data is never read, let alone written."""
    items = src.get("items")
    if items:
        for it in items:
            _write(root, it.get("path") or it["key"], PLACEHOLDER)
    else:
        for k in sorted(rend.secrets.get(src.get("secretName") or src.get("name"), ())):
            _write(root, k, PLACEHOLDER)


def fill_dir(root, vol, rend):
    if "configMap" in vol:
        fill_configmap(root, vol["configMap"], rend)
    elif "secret" in vol:
        fill_secret(root, vol["secret"], rend)
    elif "projected" in vol:
        for s in vol["projected"].get("sources") or []:
            if "configMap" in s:
                fill_configmap(root, s["configMap"], rend)
            elif "secret" in s:
                fill_secret(root, s["secret"], rend)
            elif "downwardAPI" in s:
                for it in s["downwardAPI"].get("items") or []:
                    _write(root, it.get("path", ""), "start-check")
            elif "serviceAccountToken" in s:
                _write(root, s["serviceAccountToken"].get("path", "token"), PLACEHOLDER)
    elif "downwardAPI" in vol:
        for it in vol["downwardAPI"].get("items") or []:
            _write(root, it.get("path", ""), "start-check")


def volume_kind(vol):
    if "emptyDir" in vol or "persistentVolumeClaim" in vol or "ephemeral" in vol:
        return "named"
    return "dir"


def user_args(c, spec):
    sc = c.get("securityContext") or {}
    psc = spec.get("securityContext") or {}
    uid = sc.get("runAsUser", psc.get("runAsUser"))
    gid = sc.get("runAsGroup", psc.get("runAsGroup"))
    if uid is None:
        return []
    return ["--user", "%s:%s" % (uid, gid) if gid is not None else str(uid)]


def mount_paths(c):
    return [m["mountPath"] for m in c.get("volumeMounts") or []]


# --------------------------------------------------------------------------
# Expect entries
# --------------------------------------------------------------------------

def load_expect(path):
    try:
        with open(path, encoding="utf-8") as f:
            doc = yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError) as e:
        raise InputError("cannot read expect file %s: %s" % (path, e))
    allowed = doc.get("allowed") if isinstance(doc, dict) else None
    if not isinstance(allowed, list):
        raise InputError("expect file %s needs a list under `allowed`" % path)
    for e in allowed:
        for k in ("image", "container", "exit", "log", "reason"):
            if not isinstance(e, dict) or k not in e:
                raise InputError("expect entry %r is missing %s" % (e, k))
        try:
            re.compile(e["log"])
        except re.error as err:
            raise InputError("expect entry regex %r: %s" % (e["log"], err))
    return allowed


def match_expect(allowed, image, container, code, log):
    for e in allowed:
        if (e["image"] == image and e["container"] == container and int(e["exit"]) == code
                and re.search(e["log"], log)):
            return e
    return None


# --------------------------------------------------------------------------
# docker
# --------------------------------------------------------------------------

class Docker:
    def __init__(self):
        self.bin = which("docker")

    def run(self, args, timeout=None):
        p = subprocess.run([self.bin] + args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, errors="replace", timeout=timeout)
        return p.returncode, p.stdout

    def pull(self, ref):
        rc, out = self.run(["pull", ref])
        return rc == 0, out

    def digest(self, ref):
        rc, out = self.run(["image", "inspect", "--format", "{{index .RepoDigests 0}}", ref])
        out = out.strip()
        return out if rc == 0 and out else "-"


class Cleanup:
    def __init__(self, docker):
        self.docker = docker
        self.containers, self.volumes, self.dirs = [], [], []

    def run(self):
        for n in self.containers:
            self.docker.run(["rm", "-f", n])
        for v in self.volumes:
            self.docker.run(["volume", "rm", "-f", v])
        for d in self.dirs:
            shutil.rmtree(d, ignore_errors=True)


class Pod:
    """Volumes of one workload, created on first use."""

    def __init__(self, w, rend, docker, cleanup, tag):
        self.w, self.rend, self.docker, self.cleanup, self.tag = w, rend, docker, cleanup, tag
        self.vols = {v["name"]: v for v in w["spec"].get("volumes") or []}
        self.handles = {}

    def handle(self, name):
        if name in self.handles:
            return self.handles[name]
        vol = self.vols.get(name)
        if vol is None:
            raise ConfigError("volumeMount names unknown volume %s" % name)
        if volume_kind(vol) == "named":
            vn = "%s-%s" % (self.tag, re.sub(r"[^a-zA-Z0-9_.-]", "-", name))
            rc, out = self.docker.run(["volume", "create", vn])
            if rc != 0:
                raise ConfigError("docker volume create failed: %s" % out.strip()[-200:])
            self.cleanup.volumes.append(vn)
            h = ("named", vn)
        else:
            d = tempfile.mkdtemp(prefix="start-check-")
            self.cleanup.dirs.append(d)
            os.chmod(d, 0o755)
            fill_dir(d, vol, self.rend)
            h = ("dir", d)
        self.handles[name] = h
        return h

    def mount_args(self, c):
        args = []
        for m in sorted(c.get("volumeMounts") or [], key=lambda m: m["mountPath"]):
            kind, ref = self.handle(m["name"])
            ro = bool(m.get("readOnly"))
            sub = safe_rel(m.get("subPath") or "")
            if kind == "dir":
                host = os.path.join(ref, *sub.split("/")) if sub else ref
                if sub and not os.path.exists(host):
                    os.makedirs(host, exist_ok=True)
                args += ["-v", "%s:%s%s" % (host, m["mountPath"], ":ro" if ro else "")]
            elif sub:
                spec = "type=volume,src=%s,dst=%s,volume-subpath=%s" % (ref, m["mountPath"], sub)
                args += ["--mount", spec + (",readonly" if ro else "")]
            else:
                args += ["-v", "%s:%s%s" % (ref, m["mountPath"], ":ro" if ro else "")]
        return args


def container_args(c, w, pod, ref, rend, label):
    env = resolve_env(c, rend, w["name"])
    cmd, args = resolve_command(c, env)
    a = ["--network", "none", "--label", "startcheck.image=%s" % label]
    a += user_args(c, w["spec"])
    if c.get("workingDir"):
        a += ["-w", c["workingDir"]]
    if (c.get("securityContext") or {}).get("readOnlyRootFilesystem"):
        a.append("--read-only")
    for n, v in env:
        a += ["-e", "%s=%s" % (n, v)]
    a += pod.mount_args(c)
    if cmd:
        a += ["--entrypoint", cmd[0]]
    return a, cmd[1:] + args


# --------------------------------------------------------------------------
# The check
# --------------------------------------------------------------------------

def check(workloads, rend, overrides, allowed, wait, docker):
    results = []
    cleanup = Cleanup(docker)
    pulled = {}
    started = []   # (result, container name, image short name, container)
    pid = os.getpid()
    try:
        def pull(ref):
            if ref not in pulled:
                ok, out = docker.pull(ref)
                pulled[ref] = (ok, docker.digest(ref) if ok else "-", out)
            return pulled[ref]

        for wi, w in enumerate(workloads):
            tag = "startcheck-%d-%d" % (pid, wi)
            pod = Pod(w, rend, docker, cleanup, tag)
            init_failed = None
            for c in w["inits"]:
                ref = effective_ref(c["image"], overrides)
                r = {"unit": "%s/%s/%s" % (w["kind"], w["name"], c["name"]), "ref": ref,
                     "digest": "-", "verdict": "", "state": "", "log": ""}
                results.append(r)
                if init_failed:
                    r.update(verdict="FAIL init-failed", state="FAIL", log="not run: init %s failed" % init_failed)
                    continue
                ok, digest, out = pull(ref)
                r["digest"] = digest
                if not ok:
                    r.update(verdict="FAIL pull", state="FAIL", log=out)
                    init_failed = c["name"]
                    continue
                try:
                    a, rest = container_args(c, w, pod, ref, rend, ref)
                    name = "%s-i%s" % (tag, re.sub(r"[^a-zA-Z0-9_.-]", "-", c["name"]))
                    cleanup.containers.append(name)
                    try:
                        rc, out = docker.run(["run", "--name", name] + a + [ref] + rest, timeout=INIT_TIMEOUT)
                    except subprocess.TimeoutExpired:
                        rc, out = 124, "init container exceeded %d s" % INIT_TIMEOUT
                except ConfigError as e:
                    r.update(verdict="FAIL config", state="FAIL", log=str(e))
                    init_failed = c["name"]
                    continue
                if rc == 0:
                    r.update(verdict="PASS exit0", state="PASS", log=out)
                else:
                    r.update(verdict="FAIL init-failed exit=%d" % rc, state="FAIL", log=out)
                    init_failed = c["name"]
            for ci, c in enumerate(w["mains"]):
                ref = effective_ref(c["image"], overrides)
                r = {"unit": "%s/%s/%s" % (w["kind"], w["name"], c["name"]), "ref": ref,
                     "digest": "-", "verdict": "", "state": "", "log": ""}
                results.append(r)
                if init_failed:
                    r.update(verdict="FAIL init-failed", state="FAIL", log="not run: init %s failed" % init_failed)
                    continue
                ok, digest, out = pull(ref)
                r["digest"] = digest
                if not ok:
                    r.update(verdict="FAIL pull", state="FAIL", log=out)
                    continue
                try:
                    a, rest = container_args(c, w, pod, ref, rend, ref)
                except ConfigError as e:
                    r.update(verdict="FAIL config", state="FAIL", log=str(e))
                    continue
                name = "%s-m%d" % (tag, ci)
                cleanup.containers.append(name)
                rc, out = docker.run(["run", "-d", "--name", name] + a + [ref] + rest)
                if rc != 0:
                    r.update(verdict="FAIL run", state="FAIL", log=out)
                    continue
                started.append((r, name, image_name(c["image"]), c))

        # One shared wait: every container has been up for at least `wait` s
        # by the time the deadline passes.
        deadline = time.monotonic() + wait
        pending = list(started)
        status = {}
        while True:
            for item in list(pending):
                rc, out = docker.run(["inspect", "--format", "{{.State.Status}} {{.State.ExitCode}}", item[1]])
                parts = out.split()
                if rc == 0 and len(parts) == 2 and parts[0] in ("exited", "dead"):
                    status[item[1]] = int(parts[1])
                    pending.remove(item)
            left = deadline - time.monotonic()
            if not pending or left <= 0:
                break
            time.sleep(min(1.0, left))

        for r, name, iname, c in started:
            if name not in status:
                r.update(verdict="PASS running", state="PASS")
                continue
            code = status[name]
            rc, full = docker.run(["logs", name])
            r["log"] = full
            if code == 0:
                r.update(verdict="PASS exit0", state="PASS")
                continue
            e = match_expect(allowed, iname, c["name"], code, full)
            if e:
                r.update(verdict="ALLOWED %s" % e["reason"], state="ALLOWED")
            else:
                r.update(verdict="FAIL exit=%d" % code, state="FAIL")
    finally:
        cleanup.run()
    return results


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

def counts(results):
    n = len(results)
    p = sum(1 for r in results if r["state"] == "PASS")
    a = sum(1 for r in results if r["state"] == "ALLOWED")
    f = sum(1 for r in results if r["state"] == "FAIL")
    return n, p, a, f


def summary_line(results):
    return "image-start: units=%d pass=%d allowed=%d fail=%d" % counts(results)


def table(results):
    rows = [("unit", "image ref", "digest", "verdict")]
    rows += [(r["unit"], r["ref"], r["digest"], r["verdict"]) for r in results]
    widths = [max(len(row[i]) for row in rows) for i in range(4)]
    return "\n".join(" | ".join(c.ljust(widths[i]) for i, c in enumerate(row)).rstrip() for row in rows)


def markdown(results):
    lines = ["### image-start", "", "| unit | image ref | digest | verdict |", "|---|---|---|---|"]
    for r in results:
        lines.append("| `%s` | `%s` | `%s` | %s |" % (r["unit"], r["ref"], r["digest"], r["verdict"]))
    lines += ["", summary_line(results), ""]
    return "\n".join(lines)


def print_plan(workloads, rend, overrides, skipped):
    n = 0
    for w in workloads:
        for role, group in (("init", w["inits"]), ("main", w["mains"])):
            for c in group:
                n += 1
                unit = "%s/%s/%s" % (w["kind"], w["name"], c["name"])
                print("unit %s (%s)" % (unit, role))
                print("  image:   %s" % effective_ref(c["image"], overrides))
                print("  command: %s" % json.dumps((c.get("command") or []) + (c.get("args") or [])))
                try:
                    names = [p[0] for p in resolve_env(c, rend, w["name"])]
                    print("  env:     %s" % " ".join(names))
                except ConfigError as e:
                    print("  env:     UNRESOLVED %s" % e)
                print("  mounts:  %s" % " ".join(mount_paths(c)))
    for s in skipped:
        print("skip %s" % s)
    print("image-start plan: units=%d skipped=%d" % (n, len(skipped)))


def parse_args(argv):
    ap = argparse.ArgumentParser(description="Start each of our images under the chart's rendered environment.")
    ap.add_argument("--chart", required=True)
    ap.add_argument("-f", dest="values", action="append", default=[])
    ap.add_argument("--values-extra", action="append", default=[], metavar="FILE")
    ap.add_argument("--override", action="append", default=[], metavar="NAME=REF")
    ap.add_argument("--expect")
    ap.add_argument("--wait", type=float, default=20)
    ap.add_argument("--plan", action="store_true")
    ap.add_argument("--summary")
    return ap.parse_args(argv)


def main(argv=None):
    try:
        args = parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    try:
        overrides = {}
        for o in args.override:
            n, sep, ref = o.partition("=")
            if not sep or not n or not ref:
                raise InputError("--override wants NAME=REF, got %r" % o)
            overrides[n] = ref
        allowed = load_expect(args.expect) if args.expect else []
        rend = Render(render(args.chart, args.values, args.values_extra))
        workloads, skipped = select(rend, overrides)
        if not workloads:
            raise InputError("the render has no Deployment or StatefulSet running an image of ours")
        check_overrides(workloads, overrides)
        if args.plan:
            print_plan(workloads, rend, overrides, skipped)
            return 0
        results = check(workloads, rend, overrides, allowed, args.wait, Docker())
    except InputError as e:
        print("image-start: %s" % e, file=sys.stderr)
        return 2

    print(table(results))
    if skipped:
        print("\nskipped (third-party):")
        for s in skipped:
            print("  " + s)
    for r in results:
        if r["state"] == "FAIL":
            tail = r["log"].rstrip().splitlines()[-20:]
            print("\n--- %s: %s (last %d log lines)" % (r["unit"], r["verdict"], len(tail)))
            for line in tail:
                print(line)
    print()
    print(summary_line(results))
    if args.summary:
        try:
            with open(args.summary, "a", encoding="utf-8") as f:
                f.write(markdown(results))
        except OSError as e:
            print("image-start: cannot write summary: %s" % e, file=sys.stderr)
            return 2
    return 1 if counts(results)[3] else 0


if __name__ == "__main__":
    sys.exit(main())
