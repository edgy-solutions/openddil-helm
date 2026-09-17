#!/usr/bin/env python3
"""Parse every inline shell script the chart renders, with a real shell.

WHY THIS EXISTS
---------------
On 2026-09-17 a comment block was placed between `for spec in \\` and the
first item of its word list in the topic-init Job:

    for spec in \\
        # compression.type=lz4 ON EVERY TOPIC RESTATE SUBSCRIBES TO
        ...
        "raw-sensor-stream|-p 1 -r 1 ..." \\

The backslash joins the next line; `#` then eats the rest of that joined
line; the `for` loses its word list, and the WHOLE script is a parse error.
Not the loop -- the script. Nothing in the Job runs, including the fix the
comment was written to document.

Every layer upstream said yes. The YAML was valid. `helm template` rendered
it. `helm lint` passed. The manifest applied. The Job was created, the image
pulled, the container started. The only thing that ever objects is a shell
asked to parse it, and nothing in the pipeline was asking one.

WHAT IT COST, because the shape matters more than the typo:
  * topic-init failed 7 times and hit BackoffLimitExceeded;
  * the post-upgrade hook therefore failed, wedging the release in
    `pending-upgrade` for eight hours;
  * so the OTHER post-upgrade hook -- the bootstrap that registers Restate's
    deployments and Kafka subscriptions -- never ran either;
  * and the compression fix that the comment described never applied, so the
    defect it was written to fix stayed live underneath it.

A comment explaining a fix prevented the fix. That is the same family as
"a wrong accessor that compiles is a check that only reports success": the
artifact looks like the thing it is supposed to be, and every automated
reader agrees, because none of them is the reader that matters.

WHAT IT CHECKS
--------------
`sh -n` -- parse only, execute nothing. It catches unbalanced quotes, an
unterminated here-doc, a missing `fi`/`done`, and this continuation case. It
does NOT catch a script that parses and then does the wrong thing; that is
what the advancing/feed checks are for.

Helm templating runs FIRST, so what gets parsed is what the cluster gets,
not the template source. `{{ }}` in the source would not parse as shell.

USAGE
    python scripts/check_shell_syntax.py [chart-dir] [-n namespace]

Exit 0 = every rendered script parses. Exit 1 = at least one does not, named
with its Job/Deployment, container, and the shell's own error.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write("PyYAML required: pip install pyyaml\n")
    raise SystemExit(2)

SHELLS = {"sh", "bash", "ash", "dash"}


def render(chart: str, namespace: str, release: str, extra: list) -> str:
    r = subprocess.run(
        ["helm", "template", release, chart, "-n", namespace] + list(extra),
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        sys.stderr.write("helm template failed:\n" + (r.stderr or "")[:2000] + "\n")
        raise SystemExit(2)
    return r.stdout


def collect_configmap(doc, out: list) -> None:
    """ConfigMap keys that ship a shell script.

    A script mounted from a ConfigMap is not a `command:` array, so the
    container walk below never sees it -- and `relay-stall-probe.sh` (4.6 KB,
    the liveness probe for every relay) lives exactly there. Missing it would
    make this guard the same shape as the hook it was written after: covering
    one place a thing lives while the chart puts it in two.
    """
    if doc.get("kind") != "ConfigMap":
        return
    name = (doc.get("metadata") or {}).get("name", "?")
    for k, v in (doc.get("data") or {}).items():
        if not isinstance(v, str):
            continue
        if k.endswith((".sh", ".bash")) or v.lstrip().startswith(("#!/bin/sh", "#!/bin/bash", "#!/usr/bin/env sh", "#!/usr/bin/env bash")):
            out.append((f"ConfigMap/{name}", k, v))


def collect(node, kind: str, name: str, out: list) -> None:
    """Walk a manifest for containers whose command is `<shell> -c <script>`."""
    if isinstance(node, dict):
        for key in ("containers", "initContainers"):
            for c in node.get(key) or []:
                if not isinstance(c, dict):
                    continue
                cmd = list(c.get("command") or [])
                # Some charts put the script in args with `command: [sh, -c]`.
                for seq in (cmd, cmd + list(c.get("args") or [])):
                    if (
                        len(seq) >= 3
                        and os.path.basename(str(seq[0])) in SHELLS
                        and seq[1] == "-c"
                        and isinstance(seq[2], str)
                    ):
                        out.append((f"{kind}/{name}", c.get("name", "?"), seq[2]))
                        break
        for v in node.values():
            collect(v, kind, name, out)
    elif isinstance(node, list):
        for v in node:
            collect(v, kind, name, out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("chart", nargs="?", default="openddil-demo")
    ap.add_argument("-n", "--namespace", default="openddil")
    ap.add_argument("-r", "--release", default="openddil")
    ap.add_argument("--set", dest="sets", action="append", default=[],
                    help="passed through to helm template; repeatable")
    args = ap.parse_args()

    extra = []
    for kv in args.sets:
        extra += ["--set", kv]

    # OPTIONAL BLOCKS ARE NOT OPTIONAL FOR THIS GUARD. `tierNode.enabled`
    # defaults to FALSE, so a plain render omits every script in
    # tier-node.yaml -- and the first version of this checker reported
    # "34 scripts, 0 failures" having never parsed one of them. The chart's
    # other guards already render a [tiernode] variant for exactly this
    # reason; this one inherits the discipline rather than rediscovering it.
    docs = [d for d in yaml.safe_load_all(render(args.chart, args.namespace, args.release, extra)) if d]

    found: list = []
    for d in docs:
        collect(d, d.get("kind", "?"), (d.get("metadata") or {}).get("name", "?"), found)
        collect_configmap(d, found)

    seen, failures = set(), 0
    for owner, cname, src in found:
        key = (owner, cname, hash(src))
        if key in seen:
            continue
        seen.add(key)

        fd, tmp = tempfile.mkstemp(suffix=".sh")
        os.close(fd)
        with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(src)
        try:
            r = subprocess.run(["sh", "-n", tmp], capture_output=True, text=True)
        finally:
            os.unlink(tmp)

        if r.returncode != 0:
            failures += 1
            print(f"FAIL  {owner}  [container: {cname}]")
            for line in (r.stderr or "").strip().splitlines()[:6]:
                print("      " + line.replace(tmp, "<script>"))
            print()

    print(f"checked {len(seen)} rendered shell script(s); {failures} failed to parse")
    if failures:
        print("\nA script that does not parse runs NOTHING -- not the failing line,")
        print("the whole Job. Fix before upgrading.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
