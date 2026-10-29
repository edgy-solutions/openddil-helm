#!/usr/bin/env python3
"""tier-realm-import.py <bundle-realm> <tier-client.json> <known-tiers.json> <overlay.json|-> <out>

The import step of a tier identity replica (ADR-0045, next increment, items 1
and 2). It turns the SAME realm artefact the root Keycloak imports into the
realm ONE tier's Keycloak imports, or it refuses and the tier's Keycloak does
not start.

Environment:
  OPENDDIL_TIER_ID             the tier this replica serves
  OPENDDIL_PEP_CLIENT_SECRET   the tier PEP's client secret (same Secret the root uses)
  OPENDDIL_SSO_TTL_SECONDS     the SSO idle and max lifetime (the chart owns it)
  OPENDDIL_LOGIN_THEME         the login theme name

WHAT A TIER'S REALM HOLDS (ADR-0045 §2's table, the rows this step builds):
  - every user, with their pinned id, so `sub` names one person at every tier;
  - a credential only for a user whose `home_tiers` names this tier. A user
    homed elsewhere, or with no assignment, is a known user without a local
    credential here. The root keeps every credential; this step never runs
    at the root;
  - this tier's own confidential client, and no other client. The bundle's
    root `openddil-pep` client and every other tier's client are dropped;
  - `home_tiers` itself is removed. It is an input to this step, not
    something the tier's Keycloak reads.

WHAT IT REFUSES, each with the reason printed, so a realm that would fork or
admit nobody never reaches Keycloak:
  1. a user with a required action. They would change their credential at
     whichever tier they first signed in, and fork the realm (ADR-0045 §3);
  2. a user with no pinned id. Each tier would mint a different `sub` for the
     same person, and the corpus, keyed on `sub`, would admit nobody (§2);
  3. a `home_tiers` entry naming no tier this release declares. A home that
     names nothing is a typo or a stale assignment; either way the person
     would hold a credential nowhere but the root without anyone being told;
  4. a user with a temporary credential. They would set a new one at whichever
     tier they first signed in, and fork the realm, as a required action does.
     Checked on the merged set before credentials are filtered by home_tiers,
     so a visitor's temporary credential is refused too.

Every refusal is collected before exiting, so one run names every defect.

The overlay is releasability.deploymentLayer.realmUsersJson, merged by the
same rule as merge-realm-users.py (an overlay user REPLACES the bundle user
with the same id, a new id is APPENDED, everything else is KEPT). It is
checked here BEFORE the merge, because an overlay user with no id cannot be
merged at all and the refusal must say why rather than fail on a KeyError.
The render already refuses such an overlay; this step does not rely on it.

Stdlib only, run by the same stock python image as the PEP.
"""
import json
import os
import re
import sys

MARKER = "__TIER_CLIENTS__"


def main(argv):
    if len(argv) != 6:
        raise SystemExit("usage: tier-realm-import.py <bundle-realm> <tier-client.json> "
                         "<known-tiers.json> <overlay.json|-> <out>")
    realm_path, client_path, known_path, overlay_path, out_path = argv[1:]
    tier = os.environ.get("OPENDDIL_TIER_ID", "")
    secret = os.environ.get("OPENDDIL_PEP_CLIENT_SECRET", "")
    ttl = os.environ.get("OPENDDIL_SSO_TTL_SECONDS", "")
    theme = os.environ.get("OPENDDIL_LOGIN_THEME", "")
    refusals = []

    def refuse(msg):
        refusals.append(msg)

    def halt():
        for r in refusals:
            print("REFUSED (tier %s): %s" % (tier or "?", r), file=sys.stderr)
        print("tier realm import refused %d time(s); this tier's Keycloak does not start"
              % len(refusals), file=sys.stderr)
        sys.exit(1)

    if not tier:
        refuse("OPENDDIL_TIER_ID is empty")
    if not secret or not re.fullmatch(r"[A-Za-z0-9._~-]+", secret):
        refuse("the tier PEP client secret is empty or has a character outside [A-Za-z0-9._~-]")
    if not ttl.isdigit():
        refuse("OPENDDIL_SSO_TTL_SECONDS is not a whole number: %r" % ttl)
    if refusals:
        halt()

    text = open(realm_path, encoding="utf-8").read()
    if text.count(MARKER) != 1:
        refuse("the bundle realm must carry exactly one %s marker (found %d)" % (MARKER, text.count(MARKER)))
        halt()
    # The marker sits ahead of the bundle's own clients; removing it leaves
    # valid JSON. Those clients are dropped below anyway.
    doc = json.loads(text.replace(MARKER, "", 1))

    known = json.load(open(known_path, encoding="utf-8"))
    if tier not in known:
        refuse("this tier %r is not in the release's tier list %s" % (tier, known))

    frag = open(client_path, encoding="utf-8").read().strip().rstrip(",")
    clients = json.loads("[" + frag + "]") if frag else []
    if len(clients) != 1:
        refuse("expected exactly this tier's one client, got %d" % len(clients))

    users = doc.get("users")
    if not isinstance(users, list):
        refuse("the bundle realm has no top-level \"users\" array")
        halt()

    overlay = []
    if overlay_path != "-" and os.path.exists(overlay_path) and open(overlay_path, encoding="utf-8").read().strip():
        overlay = json.load(open(overlay_path, encoding="utf-8"))
        if not isinstance(overlay, list):
            refuse("the realm users overlay is not a JSON array")
            halt()
        for i, u in enumerate(overlay):
            if not isinstance(u, dict) or not u.get("username"):
                refuse("overlay user [%d] is not an object with a username" % i)
            elif not (isinstance(u.get("id"), str) and u["id"]):
                refuse("user %r (overlay [%d]) has no pinned id: each tier would mint a different "
                       "sub for the same person, and the corpus, keyed on sub, would admit nobody"
                       % (u["username"], i))
        if refusals:
            halt()

    merged = list(users)
    pos = {u["id"]: i for i, u in enumerate(merged) if isinstance(u, dict) and u.get("id")}
    for u in overlay:
        if u["id"] in pos:
            merged[pos[u["id"]]] = u
        else:
            pos[u["id"]] = len(merged)
            merged.append(u)

    seen = set()
    kept, withheld = [], []
    for i, u in enumerate(merged):
        name = u.get("username") if isinstance(u, dict) else None
        if not name:
            refuse("realm user [%d] has no username" % i)
            continue
        if name in seen:
            refuse("username %r is used by more than one realm user" % name)
        seen.add(name)
        if not (isinstance(u.get("id"), str) and u["id"]):
            refuse("user %r has no pinned id: each tier would mint a different sub for the same "
                   "person, and the corpus, keyed on sub, would admit nobody" % name)
        actions = u.get("requiredActions") or []
        if actions:
            refuse("user %r carries required action(s) %s: they would change their credential at "
                   "whichever tier they first signed in, and fork the realm" % (name, ", ".join(actions)))
        creds = u.get("credentials") or []
        if any(isinstance(c, dict) and c.get("temporary") is True for c in creds):
            refuse("user %r carries a temporary credential: they would set a new one at whichever "
                   "tier they first signed in, and fork the realm" % name)
        attrs = u.get("attributes") or {}
        homes = attrs.get("home_tiers", [])
        if isinstance(homes, str):
            homes = [homes]
        for h in homes:
            if h not in known:
                refuse("user %r: home_tiers names %r, which is no tier this release declares "
                       "(known: %s)" % (name, h, ", ".join(known)))
        if tier in homes:
            kept.append(name)
        else:
            u.pop("credentials", None)
            withheld.append(name)
        if "home_tiers" in attrs:
            attrs = {k: v for k, v in attrs.items() if k != "home_tiers"}
            if attrs:
                u["attributes"] = attrs
            else:
                u.pop("attributes", None)

    for key in ("ssoSessionIdleTimeout", "ssoSessionMaxLifespan"):
        if key in doc:
            refuse("the bundle realm already sets %s; the chart owns the SSO lifetime" % key)

    if refusals:
        halt()

    client = json.loads(json.dumps(clients[0]).replace("__PEP_CLIENT_SECRET__", secret))
    doc["users"] = merged
    doc["clients"] = [client]
    doc["ssoSessionIdleTimeout"] = int(ttl)
    doc["ssoSessionMaxLifespan"] = int(ttl)
    if theme:
        doc["loginTheme"] = theme

    out = json.dumps(doc, indent=2, ensure_ascii=False)
    left = sorted(set(re.findall(r"__[A-Z0-9_]+__", out)))
    if left:
        refuse("a placeholder survived: %s" % ", ".join(left))
        halt()
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(out)
    os.replace(tmp, out_path)
    print("tier realm prepared for %s: %d users, all with pinned ids" % (tier, len(merged)))
    print("credentials kept (homed here): %s" % (", ".join(kept) or "none"))
    print("credentials withheld (homed elsewhere or unassigned): %s" % (", ".join(withheld) or "none"))
    print("realm clients: %s" % client.get("clientId"))
    print("sso lifetimes: idle=%s max=%s" % (ttl, ttl))


if __name__ == "__main__":
    main(sys.argv)
