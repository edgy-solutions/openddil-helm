#!/usr/bin/env python3
"""The maintainer view's edge-scope control, read the way the frontend reads
it: the ElectricSQL shape behind `useFleetAssets()`, through the session.

    python check_scope_control.py http://<ingress host> --user U \
        [--expect label:edge-01 | selector:edge-01+edge-02 | empty]

Exit 0 PASS, 1 FAIL, 3 NOT RUN.

WHAT THIS CHECKS. The scope control's shape is decided ONLY by the
COUNT of distinct edges in the `telemetry_latest_state` shape the signed-in
subject's session actually receives, never by tier name:
  * more than one edge  -> the frontend renders a <select> (control=selector)
  * exactly one edge    -> the frontend renders a static label (control=label)
  * no edges yet        -> the frontend renders the empty-state label
    (control=empty)
This script reads the same shape over the same relative path the browser
uses (`/electric/v1/shape?table=telemetry_latest_state`, same-origin behind
the ingress -- see frontend/nginx.conf's `/electric/` block and
openddil-helm's hub.yaml, which route it to electric-sync directly or to the
PEP depending on whether releasability enforcement is on), follows
Electric's shape-log paging the same way the `@electric-sql/react` client
does (`electric-handle` / `electric-offset` response headers fed back as
`handle=` / `offset=` on the next request, until a `{"headers": {"control":
"up-to-date"}}` entry appears in the body), collects the distinct `edge_id`
values, and applies the same count rule the component does.

WHAT FAILS IT
  * an UNAUTHENTICATED request that gets rows back. telemetry_latest_state
    carries per-asset state across the whole deployment; a viewer with no
    session seeing any of it is a scope bypass, and this is checked first;
  * a signed-in read that errors, or whose control/edge list does not match
    --expect.

WHAT IS NOT RUN, NOT FAILED
  * sign-in did not yield a session (nothing was read);
  * the shape URL answers with the app shell (text/html) instead of the
    Electric wire format: a frontend/ingress older than the `/electric/`
    route, or a host that isn't an OpenDDIL deployment at all. Same "wrong
    deployment answers like the right one" risk check_egress_pane.py's
    docstring describes -- read by host, signed in, never by assumption.
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

TABLE = "telemetry_latest_state"
MAX_PAGES = 200  # paging safety net; a real shape converges in a handful


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):  # surface the 302 itself
        return None


class ShapeUnavailable(Exception):
    """The shape URL did not answer with a page of the Electric log."""

    def __init__(self, status: int, content_type: str, body: bytes):
        super().__init__(f"{status} {content_type}")
        self.status = status
        self.content_type = content_type
        self.body = body


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


def shape_url(base: str, table: str, offset: str, handle: str | None = None) -> str:
    params = {"table": table, "offset": offset}
    if handle:
        params["handle"] = handle
    return f"{base.rstrip('/')}/electric/v1/shape?{urllib.parse.urlencode(params)}"


def collect_edges(base: str, cookie: str | None, table: str = TABLE) -> tuple[int, list[str]]:
    """Page through the Electric shape for `table` and return
    (rows_seen, sorted distinct edge_ids), excluding empty/`edge-unspecified`.
    Raises ShapeUnavailable if any page doesn't answer as a shape (wrong
    host, no session, stale frontend, etc.) -- the caller decides what that
    means."""
    offset = "-1"
    handle: str | None = None
    keys: set[str] = set()
    edges: set[str] = set()
    for _ in range(MAX_PAGES):
        url = shape_url(base, table, offset, handle)
        status, ct, body, headers = fetch(url, cookie)
        if status != 200 or "json" not in ct:
            raise ShapeUnavailable(status, ct, body)
        try:
            entries = json.loads(body)
        except ValueError:
            raise ShapeUnavailable(status, ct, body)
        up_to_date = False
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            control = (entry.get("headers") or {}).get("control") \
                if isinstance(entry.get("headers"), dict) else None
            if control == "up-to-date":
                up_to_date = True
                continue
            if control:
                # Other control messages (snapshot-end, must-refetch) are not rows.
                continue
            value = entry.get("value")
            if not isinstance(value, dict):
                continue
            keys.add(entry.get("key") or json.dumps(value, sort_keys=True))
            edge_id = value.get("edge_id") or ""
            if edge_id and edge_id != "edge-unspecified":
                edges.add(edge_id)
        offset = headers.get("electric-offset", offset)
        handle = headers.get("electric-handle", handle)
        if up_to_date:
            break
    return len(keys), sorted(edges)


def classify(edges: list[str]) -> str:
    """The rule, in one place: COUNT of scopes decides the control shape."""
    if len(edges) > 1:
        return "selector"
    if len(edges) == 1:
        return "label"
    return "empty"


def _check_expect(expect: str, control: str, edges: list[str]) -> bool:
    if expect == "empty":
        return control == "empty"
    kind, _, rest = expect.partition(":")
    if kind == "label":
        return control == "label" and edges == [rest]
    if kind == "selector":
        return control == "selector" and edges == sorted(rest.split("+"))
    return False


def parse_args(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser()
    ap.add_argument("host")
    ap.add_argument("--user", default="operator.atlantia")
    ap.add_argument("--password", default="demo")
    ap.add_argument("--expect")
    return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    a = parse_args(sys.argv[1:] if argv is None else argv)
    base = a.host.rstrip("/")
    print(f"scope control check: {shape_url(base, TABLE, '-1')}")

    # 1. Unauthenticated: must NOT return rows.
    try:
        n_rows, _ = collect_edges(base, None)
    except ShapeUnavailable as e:
        print(f"  unauthenticated: {e.status} {e.content_type} (no rows served)")
    else:
        print(f"FAIL unauthenticated rows={n_rows}")
        return FAIL

    # 2. Sign in.
    try:
        cookie = login(base, a.user, a.password)
    except SystemExit as e:
        print(f"NOT RUN: sign-in as {a.user} gave no session: {e}")
        return NOT_RUN
    print(f"  signed in as {a.user}")

    # 3. Signed-in read.
    try:
        n_rows, edges = collect_edges(base, cookie)
    except ShapeUnavailable as e:
        if "html" in e.content_type:
            print("NOT RUN: /electric/v1/shape answered with the app shell "
                  "(text/html). This host predates the route, or isn't an "
                  "OpenDDIL deployment; nothing about the control was read.")
            return NOT_RUN
        print(f"FAIL: signed-in read got {e.status} {e.content_type}: "
              f"{e.body[:300]!r}")
        return FAIL

    control = classify(edges)
    print(f"SCOPE user={a.user} host={base} rows={n_rows} "
          f"edges={','.join(edges) if edges else '-'} control={control}")

    if a.expect:
        if _check_expect(a.expect, control, edges):
            print("PASS")
            return PASS
        actual = f"{control}:{'+'.join(edges)}" if edges else control
        print(f"FAIL expected={a.expect} actual={actual}")
        return FAIL

    print("PASS")
    return PASS


if __name__ == "__main__":
    sys.exit(main())
