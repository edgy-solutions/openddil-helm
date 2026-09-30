#!/usr/bin/env python3
"""The egress admission pane, read the way an operator reads it: through the
ingress host, signed in.

    python check_egress_pane.py http://<ingress host> \
        [--user operator.atlantia] [--destination system:c2-stand-in-atl] \
        [--expect-admitted 8] [--expect-refused 7]

Exit 0 PASS, 1 FAIL, 3 NOT RUN.

WHY BY HOST. On 2026-09-29 the pane was read through a port-forward to
localhost:8090, and Docker Desktop's compose pane answered on that port with a
valid, empty verdict ("admitted 0 refused 0"). Valid JSON from the wrong
deployment reads exactly like a real result. A check addressed by the
deployment's own host name cannot reach another deployment's pane.

WHAT FAILS IT
  * an UNAUTHENTICATED request that gets decisions back. The pane returns
    per-record release decisions (asset ids, originator nations); reaching it
    without a session is a releasability bypass, and this is checked first;
  * a signed-in request that gets an error, or counts that differ from the
    --expect-* values given.

WHAT IS NOT RUN, NOT FAILED
  * sign-in did not yield a session (nothing was read);
  * the host has no /egress/ route yet: a frontend image older than the route
    answers with the app shell (text/html), not with decisions. That says
    nothing about the pane, so it is not reported as one.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from oidc_login import COOKIE, login  # noqa: E402

PASS, FAIL, NOT_RUN = 0, 1, 3


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):  # surface the 302 itself
        return None


def fetch(url: str, cookie: str | None):
    opener = urllib.request.build_opener(_NoRedirect)
    req = urllib.request.Request(url)
    if cookie:
        req.add_header("Cookie", f"{COOKIE}={cookie}")
    try:
        with opener.open(req, timeout=30) as r:
            return r.status, r.headers.get("Content-Type", ""), r.read(), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Type", ""), e.read(), e.headers


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("host")
    ap.add_argument("--user", default="operator.atlantia")
    ap.add_argument("--password", default="demo")
    ap.add_argument("--destination", default="system:c2-stand-in-atl")
    ap.add_argument("--expect-admitted", type=int)
    ap.add_argument("--expect-refused", type=int)
    a = ap.parse_args()
    base = a.host.rstrip("/")
    url = f"{base}/egress/decisions?destination={urllib.parse.quote(a.destination)}"
    print(f"egress pane check: {url}")

    # 1. Unauthenticated: must NOT return decisions.
    st, ct, body, hdrs = fetch(url, None)
    if st == 200 and "json" in ct:
        print(f"FAIL: unauthenticated request got {st} {ct} -- decisions served "
              "without a session (releasability bypass)")
        return FAIL
    print(f"  unauthenticated: {st} {hdrs.get('Location', '')} (no decisions served)")

    # 2. Sign in.
    try:
        cookie = login(base, a.user, a.password)
    except SystemExit as e:
        print(f"NOT RUN: sign-in as {a.user} gave no session: {e}")
        return NOT_RUN
    st, ct, body, _ = fetch(f"{base}/auth/me", cookie)
    print(f"  signed in as {a.user}: /auth/me {st} {body[:160].decode('utf-8', 'replace')}")

    # 3. Signed in: the decisions.
    st, ct, body, _ = fetch(url, cookie)
    if st == 200 and "html" in ct:
        print("NOT RUN: /egress/ answered with the app shell (text/html). This "
              "frontend image predates the /egress/ route; nothing about the pane "
              "was read.")
        return NOT_RUN
    if st != 200 or "json" not in ct:
        print(f"FAIL: signed-in read got {st} {ct}: {body[:300]!r}")
        return FAIL
    d = json.loads(body)
    admitted, refused = d.get("admitted"), d.get("refused")
    recs = d.get("records", [])
    print(f"  destination={d.get('destination')} policy={d.get('policy_version')} "
          f"corpus={d.get('corpus_version')}")
    print(f"  admitted={admitted} refused={refused} records={len(recs)}")
    by_reason: dict[str, list[str]] = {}
    for r in recs:
        by_reason.setdefault(r.get("reason", "?"), []).append(r.get("asset_id", "?"))
    for reason, ids in sorted(by_reason.items()):
        print(f"    {reason:<20} {len(ids):>3}  {' '.join(sorted(ids))}")

    bad = []
    if a.expect_admitted is not None and admitted != a.expect_admitted:
        bad.append(f"admitted {admitted} != expected {a.expect_admitted}")
    if a.expect_refused is not None and refused != a.expect_refused:
        bad.append(f"refused {refused} != expected {a.expect_refused}")
    if bad:
        print("FAIL: " + "; ".join(bad))
        return FAIL
    print("PASS")
    return PASS


if __name__ == "__main__":
    sys.exit(main())
