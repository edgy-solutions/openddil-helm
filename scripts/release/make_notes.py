#!/usr/bin/env python3
"""Write release notes (markdown) to stdout.

  make_notes.py retag --repo R --tag T --results results.jsonl
  make_notes.py suite --repo R --tag T --manifest FILE
"""
import argparse
import json

import yaml

REG = "ghcr.io/edgy-solutions/openddil"
TAIL = "Retagged, not rebuilt. `:latest` was not changed."


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["retag", "suite"])
    ap.add_argument("--repo", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--results")
    ap.add_argument("--manifest")
    a = ap.parse_args()
    out = ["# " + a.tag, ""]
    if a.mode == "retag":
        out += ["| Image | Digest | Built from | Build run | Pull reference |", "|---|---|---|---|---|"]
        with open(a.results, encoding="utf-8") as f:
            for line in f:
                if not line.strip():
                    continue
                r = json.loads(line)
                out.append("| `%s/%s` | `%s` | [%s](https://github.com/%s/commit/%s) "
                           "| [run %s](https://github.com/%s/actions/runs/%s) | `%s/%s@%s` |"
                           % (REG, r["image"], r["digest"], r["commit"][:7], a.repo, r["commit"],
                              r["run_id"], a.repo, r["run_id"], REG, r["image"], r["digest"]))
    else:
        with open(a.manifest, encoding="utf-8") as f:
            m = yaml.safe_load(f)
        out += ["Chart: `%s` %s" % (m["chart"]["name"], m["chart"]["version"]), "",
                "Bundle: `%s@%s`" % (m["bundle"]["image"], m["bundle"]["digest"]), "",
                "| Image | Digest | Repo | Commit | Tag |", "|---|---|---|---|---|"]
        for i in m["images"]:
            out.append("| `%s` | `%s` | %s | [%s](https://github.com/%s/commit/%s) | `%s` |"
                       % (i["image"], i["digest"], i["repo"], i["commit"][:7], i["repo"], i["commit"], i["tag"]))
        if m.get("thirdParty"):
            out += ["", "## Third-party images", ""]
            for t in m["thirdParty"]:
                out.append("- %s: `%s:%s` @ `%s` %s"
                           % (t["name"], t["image"], t["tag"], t["digest"],
                              "(pinned by the chart)" if t["pinned"]
                              else "(pulled by tag; digest as of the manifest)"))
    out += ["", TAIL]
    print("\n".join(out))


if __name__ == "__main__":
    main()
