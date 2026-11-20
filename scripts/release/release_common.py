"""Shared by find_build.py and check_suite_published.py.

One function, fetch(kind, key), answers every registry and API question.
With configure(fixtures=DIR) it reads DIR/<kind>__<sanitised key>.json instead
of calling crane or gh, so tests need no network. A missing fixture file
means "does not exist" and returns None.

kinds:
  digest      key = <ref>:<tag>           -> {"digest": "sha256:..."} | None
  manifest    key = <ref>@<digest>        -> manifest JSON
  blob        key = <ref>@<digest>        -> blob JSON
  versions    key = <image>               -> [{"name": digest, "created_at": iso}, ...]
  commitdate  key = <commit>              -> ISO date string
"""
import json
import os
import re
import subprocess

REGISTRY = "ghcr.io/edgy-solutions/openddil"
_STATE = {"fixtures": None, "repo": None}


def configure(fixtures=None, repo=None):
    _STATE["fixtures"] = fixtures
    _STATE["repo"] = repo


def fixture_name(kind, key):
    return kind + "__" + re.sub(r"[^A-Za-z0-9._-]", "_", key) + ".json"


def _run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout


def fetch(kind, key):
    fx = _STATE["fixtures"]
    if fx:
        path = os.path.join(fx, fixture_name(kind, key))
        if not os.path.exists(path):
            return None
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    if kind == "digest":
        rc, out = _run(["crane", "digest", key])
        return {"digest": out.strip()} if rc == 0 and out.strip() else None
    if kind in ("manifest", "blob"):
        rc, out = _run(["crane", kind, key])
        return json.loads(out) if rc == 0 else None
    if kind == "versions":
        rc, out = _run(["gh", "api", "--paginate",
                        "/orgs/edgy-solutions/packages/container/openddil%2F" + key
                        + "/versions?per_page=100",
                        "--jq", ".[] | {name: .name, created_at: .created_at}"])
        if rc != 0:
            return None
        return [json.loads(l) for l in out.splitlines() if l.strip()]
    if kind == "commitdate":
        rc, out = _run(["gh", "api", "repos/%s/commits/%s" % (_STATE["repo"], key),
                        "--jq", ".commit.committer.date"])
        return out.strip() if rc == 0 else None
    raise ValueError("unknown kind " + kind)
