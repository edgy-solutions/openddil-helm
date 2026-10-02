#!/usr/bin/env python3
"""Sign in, sign out, and check the sign-out held. One browser per profile.

    python oidc_signout_check.py http://<ingress host> operator.atlantia [user ...]

For each profile, with one cookie jar standing in for one browser:

  1. sign in            /auth/login -> the provider's form -> a session cookie
  2. who am I           /auth/me is 200 and names this user
  3. sign out           /auth/logout, every redirect followed
  4. signed out held    the browser lands on the provider's LOGIN FORM, and
                        /auth/me is 401
  5. sign in again      the same browser signs back in, and /auth/me names
                        the user again

Exit 0 only if every step passed for every profile. Steps 1, 2 and 5 are the
"profiles unaffected" half: a sign-out fix that broke sign-in fails here, not
on someone's screen. Standard library only.

WHY STEP 4 READS WHERE THE BROWSER LANDED. Clearing the gateway's cookie is
not a sign-out while the identity provider still holds its own session: the
gate sends the browser to /auth/login, the provider recognises it, and the
user is back in without seeing a form. The defect looks like "the button
does nothing". So the check follows the redirects to the end, the way a
browser does, and asks whether a password is being asked for.
"""
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
import http.cookiejar
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from oidc_login import COOKIE, login  # noqa: E402


class _Hops(urllib.request.HTTPRedirectHandler):
    """Follow redirects like a browser, and remember where they went."""

    def __init__(self):
        self.hops: list[str] = []

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self.hops.append(f"{code} {newurl.split('?')[0]}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _me(opener, base: str) -> tuple[int, dict]:
    try:
        with opener.open(f"{base}/auth/me", timeout=20) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, {}


def check(base: str, user: str, password: str) -> list[str]:
    """Return the failures for one profile; empty means it passed."""
    base = base.rstrip("/")
    jar = http.cookiejar.CookieJar()
    hops = _Hops()
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(jar), hops)
    fails: list[str] = []

    try:
        login(base, user, password, opener)
    except SystemExit as e:
        return [f"sign in: {e}"]
    code, me = _me(opener, base)
    if code != 200 or me.get("username") != user:
        return [f"who am I after sign in: HTTP {code}, "
                f"username {me.get('username')!r}"]

    hops.hops.clear()
    try:
        with opener.open(f"{base}/auth/logout", timeout=20) as r:
            landed, page = r.geturl(), r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        landed, page = e.url, ""
        fails.append(f"sign out: HTTP {e.code} at {e.url}")
    chain = " -> ".join(hops.hops) or "(no redirects)"
    on_form = 'id="kc-form-login"' in page
    code, me = _me(opener, base)
    if not on_form or code != 401:
        fails.append(
            "signed out held: " + ("login form" if on_form else
                                   f"NO login form, landed at {landed.split('?')[0]}")
            + f"; /auth/me {code}"
            + (f" as {me.get('username')!r}" if me.get("username") else "")
            + f"; redirects {chain}")
    if fails:
        return fails

    try:
        login(base, user, password, opener)
    except SystemExit as e:
        return [f"sign in again: {e}"]
    code, me = _me(opener, base)
    if code != 200 or me.get("username") != user:
        return [f"who am I after signing in again: HTTP {code}, "
                f"username {me.get('username')!r}"]
    return []


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    base, users = sys.argv[1], sys.argv[2:]
    failed = 0
    for user in users:
        fails = check(base, user, "demo")
        print(f"{'PASS' if not fails else 'FAIL'} {user}"
              + "".join(f"\n     {f}" for f in fails))
        failed += bool(fails)
    print(f"signout {len(users) - failed}/{len(users)}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
