#!/usr/bin/env python3
"""One profile signs out; every other profile stays signed in. All at once.

    python oidc_signout_isolation_check.py http://<ingress host> USER USER [USER ...]
    python oidc_signout_isolation_check.py --red-control http://<ingress host> USER USER [...]

oidc_signout_check.py runs one profile at a time, so it cannot see a sign-out
that reaches past its own browser. This one keeps every profile signed in at
once, one cookie jar each, and takes each profile in turn as the one who signs
out:

  1. all sign in        every jar holds a session; /auth/me names each user
  2. one signs out      /auth/logout, every redirect followed: it must land on
                        the provider's LOGIN FORM and its /auth/me must be 401
  3. others held        every other jar: /auth/me is still 200 and names that
                        user (the gateway session survived), AND /auth/login
                        completes WITHOUT a login form (the provider session
                        survived; a realm-wide logout would show the form here)
  4. signer back in     the signer signs in again before the next round

Exit 0 only if every round passed. Prints `isolation N/N`, one per round.

--red-control signs out one OBSERVER too in each round, before step 3. Every
round must then FAIL on that observer. It shows step 3 can see a session that
is gone; without it a step 3 that always passed would look the same as this
check passing. Standard library only.
"""
from __future__ import annotations

import sys

from oidc_signout_check import _Hops, _me  # noqa: E402  (same directory)
from oidc_login import login  # noqa: E402

import http.cookiejar
import urllib.error
import urllib.request

FORM = 'id="kc-form-login"'


def _browser():
    jar = http.cookiejar.CookieJar()
    hops = _Hops()
    return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), hops)


def _follow(opener, url: str) -> tuple[str, str, int]:
    try:
        with opener.open(url, timeout=20) as r:
            return r.geturl(), r.read().decode("utf-8", "replace"), r.status
    except urllib.error.HTTPError as e:
        return e.url, "", e.code


def _signed_in(opener, base: str, user: str) -> str | None:
    """None if this browser is signed in as user at gateway AND provider."""
    code, me = _me(opener, base)
    if code != 200 or me.get("username") != user:
        return f"gateway session: /auth/me {code} {me.get('username')!r}"
    landed, page, status = _follow(opener, f"{base}/auth/login")
    if FORM in page:
        return "provider session: /auth/login showed the login form"
    if status != 200:
        return f"provider session: /auth/login ended HTTP {status} at {landed.split('?')[0]}"
    code, me = _me(opener, base)
    if code != 200 or me.get("username") != user:
        return f"after /auth/login: /auth/me {code} {me.get('username')!r}"
    return None


def _sign_out(opener, base: str) -> str | None:
    landed, page, _ = _follow(opener, f"{base}/auth/logout")
    code, _ = _me(opener, base)
    if FORM not in page or code != 401:
        return (f"sign out: {'login form' if FORM in page else 'NO login form at ' + landed.split('?')[0]}"
                f"; /auth/me {code}")
    return None


def main() -> None:
    args = sys.argv[1:]
    red = bool(args) and args[0] == "--red-control"
    if red:
        args = args[1:]
    if len(args) < 3:
        raise SystemExit(__doc__)
    base, users = args[0].rstrip("/"), args[1:]

    browsers = {u: _browser() for u in users}
    for u, b in browsers.items():
        try:
            login(base, u, "demo", b)
        except SystemExit as e:
            print(f"FAIL setup: sign in {u}: {e}")
            sys.exit(1)
        bad = _signed_in(browsers[u], base, u)
        if bad:
            print(f"FAIL setup: {u}: {bad}")
            sys.exit(1)

    passed = 0
    for signer in users:
        fails: list[str] = []
        bad = _sign_out(browsers[signer], base)
        if bad:
            fails.append(f"{signer} {bad}")
        observers = [u for u in users if u != signer]
        if red:
            victim = observers[0]
            _sign_out(browsers[victim], base)
        for u in observers:
            bad = _signed_in(browsers[u], base, u)
            if bad:
                fails.append(f"{u} not held: {bad}")
        for u in [signer] + ([observers[0]] if red else []):
            try:
                login(base, u, "demo", browsers[u])
            except SystemExit as e:
                fails.append(f"{u} sign in again: {e}")
        print(f"{'PASS' if not fails else 'FAIL'} {signer} signs out; "
              f"{len(observers)} others checked" + "".join(f"\n     {f}" for f in fails))
        passed += not fails
    print(f"isolation {passed}/{len(users)}" + (" (red-control)" if red else ""))
    sys.exit(0 if passed == len(users) else 1)


if __name__ == "__main__":
    main()
