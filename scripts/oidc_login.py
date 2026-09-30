#!/usr/bin/env python3
"""Sign in to an OpenDDIL frontend host the way a browser does, and print the
session cookie.

    python oidc_login.py http://<ingress host> operator.atlantia [password]

Walks /auth/login -> the identity provider's login form -> /auth/callback, and
prints `openddil_session=<value>` on success. Exit 1 when the sign-in did not
yield a session, with the step it stopped at. Standard library only.

WHY A SCRIPTED LOGIN. "Four-profile login before any cut" was confirmed by hand
and by reading the PEP log. A check that needs a person at a browser does not
run at 03:00, and one that reads a log accepts whatever the log last said. This
does the round trip and reports what came back: a cookie, or where it stopped.

The demo realm's passwords are published (policy/realm-openddil.json). Any
other realm: pass the password as the third argument, never commit it.
"""
from __future__ import annotations

import html
import http.cookiejar
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

COOKIE = "openddil_session"


def login(base: str, user: str, password: str) -> str:
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    base = base.rstrip("/")

    # 1. /auth/login redirects (followed) to the identity provider's form.
    try:
        with opener.open(f"{base}/auth/login", timeout=20) as r:
            page = r.read().decode("utf-8", "replace")
            form_url = r.geturl()
    except urllib.error.HTTPError as e:
        raise SystemExit(f"step 1 /auth/login: HTTP {e.code}")
    m = re.search(r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"', page) \
        or re.search(r'<form[^>]*action="([^"]+)"', page)
    if not m:
        raise SystemExit(f"step 1: no login form at {form_url}")
    action = urllib.parse.urljoin(form_url, html.unescape(m.group(1)))

    # 2. Post the credentials; the provider redirects to /auth/callback, which
    #    sets the session cookie and redirects on to the app.
    body = urllib.parse.urlencode(
        {"username": user, "password": password, "credentialId": ""}).encode()
    try:
        with opener.open(action, data=body, timeout=20) as r:
            landed = r.geturl()
            after = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        raise SystemExit(f"step 2 credentials/callback: HTTP {e.code} at {e.url}")

    for c in jar:
        if c.name == COOKIE and c.value:
            return c.value
    hint = "the login form came back (wrong password?)" \
        if 'id="kc-form-login"' in after else f"landed at {landed}"
    raise SystemExit(f"step 2: no {COOKIE} cookie; {hint}")


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    base, user = sys.argv[1], sys.argv[2]
    password = sys.argv[3] if len(sys.argv) > 3 else "demo"
    print(f"{COOKIE}={login(base, user, password)}")


if __name__ == "__main__":
    main()
