#!/usr/bin/env python3
"""Check every workload's openddil.io/produces-topics annotation against the producing repos' produces.yaml.

For each Deployment/StatefulSet in a render: map it to a (repo, manifest key), cross-check the image, expand the
key's topic templates with the workload's own rendered env (and its mounted config file for @config: templates),
and compare the topic NAMES with the annotation as sets. Broker placement is the chart's; this check compares
names.

  check-produces-declarations.py                       default + guard-13 fixture renders of ./openddil-demo
  check-produces-declarations.py --chart DIR           the same, on another chart tree
  check-produces-declarations.py --rendered F [F ...]  pre-rendered YAML instead (red-checks)

Manifests: <PRODUCES_REPOS_ROOT>/<repo>/produces.yaml (default root: this repo's parent directory), loaded with
each repo's own produces_manifest.py. A missing manifest is a FAIL, never a skip. Exit 1 on any FAIL.
Stdlib + PyYAML only.
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
HELM_REPO = HERE.parent
ANNOTATION = "openddil.io/produces-topics"

# Workload name (release prefix stripped) -> (repo, manifest key). First match wins, so the longer
# tier-cm-intake- sits above tier-cm-.
PATTERNS = [
    (r"faust-edge-.+",              "openddil-tactical-agents", "faust-edge"),
    (r"faust-regional-.+",          "openddil-tactical-agents", "faust-regional"),
    (r"tier-cm-intake-.+",          "openddil-demo",            "cm-intake"),
    (r"cm-intake",                  "openddil-demo",            "cm-intake"),
    (r"tier-declaration-intake-.+", "openddil-demo",            "declaration-intake"),
    (r"declaration-intake",         "openddil-demo",            "declaration-intake"),
    (r"tier-cm-.+",                 "openddil-cm-service",      "cm-service"),
    (r"cm-service",                 "openddil-cm-service",      "cm-service"),
    (r"tier-fusion-.+",             "openddil-logistics-fusion-service", "fusion"),
    (r"logistics-fusion-service",   "openddil-logistics-fusion-service", "fusion"),
    (r"sensor-ingest-.+",           "openddil-sensor-ingest",   "sensor-ingest"),
    (r"tier-projector-.+",          "openddil-projector",       "projector"),
    (r"projector(-.+)?",            "openddil-projector",       "projector"),
    (r"logistics-sim",              "openddil-logistics-sim",   "logistics-sim"),
    (r"asset-registry-service",     "openddil-stack",           "asset-registry"),
    (r"egress-gate-.+",             "openddil-demo",            "egress-gate-c2"),
    (r"egress-assembler",           "openddil-demo",            "egress-assembler"),
    (r"egress-intake",              "openddil-demo",            "egress-intake"),
    (r"egress-pane-api",            "openddil-demo",            "egress-pane-api"),
    (r"redpanda-connect-.+",        "openddil-demo",            "connect-edge"),
]


def load_manifests(root, repos):
    """-> ({repo: (module, workloads)}, [problem strings])"""
    out, problems = {}, []
    for repo in repos:
        d = Path(root) / repo
        mf, mod_path = d / "produces.yaml", d / "produces_manifest.py"
        if not mf.is_file():
            problems.append(f"manifest missing: {mf}")
            continue
        if not mod_path.is_file():
            problems.append(f"produces_manifest.py missing: {mod_path}")
            continue
        spec = importlib.util.spec_from_file_location("produces_manifest__" + repo.replace("-", "_"), mod_path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        out[repo] = (mod, mod.load(mf) or {})
    return out, problems


def image_path(image):
    """Registry prefix kept, tag and digest stripped."""
    image = image.split("@", 1)[0]
    last = image.rsplit("/", 1)[-1]
    if ":" in last:
        image = image[: len(image) - len(last)] + last.split(":", 1)[0]
    return image


def image_ends(image, want):
    p = image_path(image)
    return p == want or p.endswith("/" + want)


def run_helm(chart, values):
    cmd = ["helm", "template", "t", str(chart)]
    for v in values:
        cmd += ["-f", str(v)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"helm template failed ({' '.join(cmd)}):\n{r.stderr[-2000:]}")
    return r.stdout


def map_workload(name, release):
    base = name[len(release) + 1:] if name.startswith(release + "-") else name
    for pat, repo, key in PATTERNS:
        if re.fullmatch(pat, base):
            return repo, key
    return None


def resolve_config(path, container, podspec, configmaps):
    """File path in the container -> parsed document, via volumeMount -> volume -> ConfigMap data key."""
    for vm in container.get("volumeMounts") or []:
        mp = vm["mountPath"].rstrip("/")
        if vm.get("subPath") and mp == path:
            key = vm["subPath"]
        elif not vm.get("subPath") and path.startswith(mp + "/"):
            key = path[len(mp) + 1:]
        else:
            continue
        vol = next((v for v in podspec.get("volumes") or [] if v["name"] == vm["name"]), None)
        if vol is None:
            raise LookupError(f"{path}: volume {vm['name']!r} not in pod spec")
        cm = (vol.get("configMap") or {}).get("name")
        if not cm:
            raise LookupError(f"{path}: volume {vm['name']!r} is not a ConfigMap")
        if cm not in configmaps:
            raise LookupError(f"{path}: ConfigMap {cm!r} not in render")
        data = configmaps[cm].get("data") or {}
        if key not in data:
            raise LookupError(f"{path}: ConfigMap {cm!r} has no key {key!r}")
        text = data[key]
        return yaml.safe_load(text) if key.lower().endswith((".yaml", ".yml")) else json.loads(text)
    raise LookupError(f"{path}: no volumeMount covers it")


def producible(mod, wl, env, container, podspec, configmaps):
    """-> (set of topic names, [problems])"""
    topics, problems = set(), []
    for tpl in wl["topics"]:
        cond = (wl.get("when") or {}).get(tpl)
        if cond and cond.startswith("@config:"):
            # met when the config file at env KEY's path has a non-empty value at the dotted path
            key, _, dotted = cond[len("@config:"):].partition(":")
            if not env.get(key):
                continue
            try:
                node = resolve_config(env[key], container, podspec, configmaps)
            except LookupError as ex:
                problems.append(f"cannot evaluate when {cond!r}: {ex}")
                continue
            for part in dotted.split("."):
                node = node.get(part) if isinstance(node, dict) else None
            if not node:
                continue
        elif cond:
            var, _, val = cond.partition("=")
            if env.get(var, "").lower() != val:
                continue
        try:
            if tpl.startswith("@config:"):
                key, _, field = tpl[len("@config:"):].partition(".")
                if not env.get(key):
                    continue  # optional file unset: nothing from it (the env fallback template applies)
                doc = resolve_config(env[key], container, podspec, configmaps)
                if not isinstance(doc, list):
                    raise LookupError(f"{env[key]}: not a list of entries")
                for i, e in enumerate(doc):
                    if not isinstance(e, dict) or not isinstance(e.get(field), str) or not e[field]:
                        raise LookupError(f"{env[key]}: entry {i} has no {field!r}")
                    topics.add(e[field])
            else:
                topics.add(mod.expand(tpl, env))
        except (KeyError, LookupError, ValueError) as ex:
            problems.append(f"cannot expand {tpl!r}: {ex}")
    return topics, problems


def check_render(label, text, manifests, release):
    docs = [d for d in yaml.safe_load_all(text) if d]
    configmaps = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "ConfigMap"}
    # Rule 6's image fallback applies only to images no key identifies by a `config:` pipeline file.
    all_images = sorted({wl["image"] for _, w in manifests.values() for wl in w.values()}
                        - {wl["image"] for _, w in manifests.values() for wl in w.values() if wl.get("config")})
    by_config = {wl["config"]: (r, k) for r, (_, w) in manifests.items() for k, wl in w.items() if wl.get("config")}
    fails = oks = n = 0
    noted, chart_owned, seen_keys = [], [], set()
    for d in docs:
        if d.get("kind") not in ("Deployment", "StatefulSet"):
            continue
        n += 1
        md = d["metadata"]
        name = md["name"]
        pod = d["spec"]["template"]["spec"]
        ann = (md.get("annotations") or {}).get(ANNOTATION)
        containers = pod.get("containers") or []
        problems = []
        okmsg = None
        m = map_workload(name, release)
        # A Connect workload is identified by the pipeline file it copies from the bundle (demo/<file>).
        podtext = json.dumps(pod)
        copied = sorted(f for f in by_config if re.search(r"demo/" + re.escape(f) + r"(?![\w.\-])", podtext))
        if len(copied) > 1:
            problems.append(f"copies several manifest pipeline files: {copied}")
        elif copied and m is None:
            m = by_config[copied[0]]
        elif copied and m != by_config[copied[0]]:
            problems.append(f"name pattern maps to {m[0]}/{m[1]} but the pod copies {copied[0]} ({by_config[copied[0]][1]})")
        elif not copied and m is not None and manifests.get(m[0], ({}, {}))[1].get(m[1], {}).get("config"):
            problems.append(f"name pattern maps to {m[0]}/{m[1]} but the pod copies {manifests[m[0]][1][m[1]]['config']} from nowhere")
        if problems:
            pass
        elif m is None:
            if ann is not None:
                problems.append("annotated workload with no manifest")
            else:
                hit = [c["image"] for c in containers if any(image_ends(c["image"], i) for i in all_images)]
                if hit:
                    problems.append(f"unmapped workload with a manifest image ({image_path(hit[0])}); no pattern maps it")
                elif any(image_path(c["image"]).endswith("redpandadata/connect") for c in containers):
                    chart_owned.append(name)
                    continue
                else:
                    noted.append(name)
                    continue
        else:
            repo, key = m
            if repo not in manifests:
                problems.append(f"manifest for {repo} not loaded")
            elif key not in manifests[repo][1]:
                problems.append(f"{repo} manifest has no key {key!r}")
            else:
                mod, wls = manifests[repo]
                wl = wls[key]
                seen_keys.add((repo, key))
                main = next((c for c in containers if image_ends(c["image"], wl["image"])), None)
                if main is None:
                    problems.append(f"no container image ends with {wl['image']!r} "
                                    f"(has {[image_path(c['image']) for c in containers]})")
                else:
                    env = {e["name"]: str(e["value"]) for e in main.get("env") or [] if "value" in e}
                    prod, pp = producible(mod, wl, env, main, pod, configmaps)
                    problems += pp
                    if not pp:
                        decl = {p.split("/", 1)[-1] for p in (ann or "").split()}
                        for t in sorted(decl - prod):
                            problems.append(f"over-declared: {name} {t}")
                        for t in sorted(prod - decl):
                            problems.append(f"under-declared: {name} {t}")
                        if not problems:
                            okmsg = (f"{repo}/{key}: no annotation, nothing producible" if not prod
                                     else f"{repo}/{key}: {len(prod)} topic(s) match")
        if problems:
            print(f"FAIL : [{label}] {name}: " + "; ".join(problems))
            fails += 1
        else:
            print(f"ok   : [{label}] {name} -> {okmsg}")
            oks += 1
    missing = sorted(f"{r}/{k}" for r, (_, w) in manifests.items() for k in w if (r, k) not in seen_keys)
    if missing:
        print(f"note : [{label}] key produces, no workload rendered: " + ", ".join(missing))
    if chart_owned:
        print(f"note : [{label}] chart-owned pipeline, no repo manifest: " + ", ".join(chart_owned))
    if noted:
        print(f"note : [{label}] neither annotation nor manifest image: " + ", ".join(noted))
    print(f"summary: [{label}] {n} workload(s), {oks} ok, {fails} FAIL")
    return fails


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--chart", default=str(HELM_REPO / "openddil-demo"))
    ap.add_argument("--rendered", nargs="+", metavar="FILE")
    ap.add_argument("--release", default="t", help="release name prefix to strip from workload names")
    a = ap.parse_args()
    root = os.environ.get("PRODUCES_REPOS_ROOT") or str(HELM_REPO.parent)
    repos = [l.strip().split("/", 1)[-1] for l in (HERE / "produces-repos.txt").read_text().splitlines() if l.strip()]
    manifests, problems = load_manifests(root, repos)
    fails = 0
    for p in problems:
        print(f"FAIL : {p}")
        fails += 1
    if a.rendered:
        renders = [(Path(f).name, Path(f).read_text(encoding="utf-8")) for f in a.rendered]
    else:
        renders = [("default", run_helm(a.chart, [])),
                   ("fixture", run_helm(a.chart, [HERE / "produces-fixture-values.yaml"]))]
    for label, text in renders:
        fails += check_render(label, text, manifests, a.release)
    print(f"{'FAIL' if fails else 'ok'}: produces declarations, {fails} failure(s)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
