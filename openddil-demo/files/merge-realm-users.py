#!/usr/bin/env python3
"""merge-realm-users.py <realm-template> <overlay.json>

Merges releasability.deploymentLayer.realmUsersJson into the bundle realm's
"users" array, in place, before substitutions.sh splices and substitutes.

  - an overlay user whose `id` matches a bundle user REPLACES it entirely
  - an overlay user with a new `id` is APPENDED
  - bundle users the overlay does not mention are KEPT
  - usernames must be unique after the merge; anything else is a FATAL

Stdlib only, run by the same stock python image as the PEP: the Keycloak
image has no JSON tool and sed cannot merge arrays safely.

The realm template is NOT valid JSON on its own (a bare __TIER_CLIENTS__
marker sits, ahead of a comma-terminated fragment, in the clients array), so the users array is located by parsing
and then spliced back into the original text: every other byte, including the
marker and the `"realm": "openddil",` line substitutions.sh anchors on, is
left exactly as it was.
"""
import json
import re
import sys


def merge(text, overlay):
    # Parse a copy with the marker made legal, to know what the real
    # top-level "users" is; then find that same array in the original text.
    doc = json.loads(text.replace("__TIER_CLIENTS__", "{},"))
    base = doc.get("users")
    if not isinstance(base, list):
        raise SystemExit("FATAL: the bundle realm has no top-level \"users\" array")
    dec = json.JSONDecoder()
    span = None
    for m in re.finditer(r'"users"\s*:\s*', text):
        try:
            val, end = dec.raw_decode(text, m.end())
        except ValueError:
            continue
        if val == base:
            span = (m.end(), end)
            break
    if span is None:
        raise SystemExit("FATAL: could not locate the bundle realm's \"users\" array in the text")

    merged = list(base)
    pos = {u["id"]: i for i, u in enumerate(merged) if isinstance(u, dict) and "id" in u}
    replaced, appended = [], []
    for u in overlay:
        if u["id"] in pos:
            merged[pos[u["id"]]] = u
            replaced.append(u["username"])
        else:
            pos[u["id"]] = len(merged)
            merged.append(u)
            appended.append(u["username"])

    seen = {}
    for u in merged:
        name = u.get("username")
        if name in seen:
            raise SystemExit("FATAL: username %r is used by more than one realm user after the merge" % name)
        seen[name] = True

    body = json.dumps(merged, indent=2, ensure_ascii=False).replace("\n", "\n  ")
    return text[:span[0]] + body + text[span[1]:], replaced, appended, len(merged)


def main(argv):
    if len(argv) != 3:
        raise SystemExit("usage: merge-realm-users.py <realm-template> <overlay.json>")
    text = open(argv[1], encoding="utf-8").read()
    overlay = json.load(open(argv[2], encoding="utf-8"))
    if not isinstance(overlay, list) or not all(
            isinstance(u, dict) and u.get("id") and u.get("username") for u in overlay):
        raise SystemExit("FATAL: realmUsersJson must be a JSON array of objects with id and username")
    out, replaced, appended, n = merge(text, overlay)
    tmp = argv[1] + ".tmp"
    open(tmp, "w", encoding="utf-8").write(out)
    import os
    os.replace(tmp, argv[1])
    print("realm users: %d after merge (replaced by id: %s; appended: %s)"
          % (n, ", ".join(replaced) or "none", ", ".join(appended) or "none"))


if __name__ == "__main__":
    main(sys.argv)
