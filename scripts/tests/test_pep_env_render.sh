#!/usr/bin/env bash
# ===========================================================================
# test_pep_env_render.sh -- offline render proof for releasability.pep.env.
#
# The render is piped into an inline python filter and never written to disk
# (a render carries Secrets). Only stderr of a failed render is kept.
#
# Cases:
#   A. default: every PEP container has MALLOC_ARENA_MAX=2, once.
#   B. two vars set: both present on every PEP, the value overridden, sorted.
#   C. a later -f file nulls MALLOC_ARENA_MAX: no PEP has it, render succeeds.
#   D. a chart-set name (OPENDDIL_*, LOG_LEVEL) fails the render, naming it.
#   E. a bad env var name fails the render, naming it.
#   F. non-PEP python-image containers do not carry it.
#   G. no duplicate env names in any PEP container.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$HERE/../../openddil-demo}"

PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "SKIP: no python with PyYAML"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0

# render MODE NAMES... -- [helm args]. Prints one line per matching container.
# MODE pep: every container named pep running /app/pep.py, env names listed.
# MODE other: every other container whose image is the PEP's python image.
# MODE dup: pep containers, prints "<deployment> <number of duplicate env names>".
filter() {
  "$PY" -c '
import sys, yaml
mode, names = sys.argv[1], sys.argv[2:]
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
def pods(d):
    if d.get("kind") in ("Deployment", "StatefulSet", "Job", "DaemonSet"):
        yield d["metadata"]["name"], d["spec"]["template"]["spec"]
for dname, spec in (p for d in docs for p in pods(d)):
    for c in spec.get("containers", []):
        is_pep = "/app/pep.py" in (c.get("command") or []) + (c.get("args") or [])
        env = [(e["name"], e.get("value", "")) for e in c.get("env", [])]
        if mode == "count" and is_pep:
            print(dname)
        elif mode == "pep" and is_pep:
            print(dname, " ".join("%s=%s" % (n, v) for n, v in env if n in names))
        elif mode == "dup" and is_pep:
            all_n = [n for n, _ in env]
            print(dname, len(all_n) - len(set(all_n)))
        elif mode == "other" and not is_pep and str(c.get("image", "")).startswith("python") :
            print(dname, c["name"], " ".join("%s=%s" % (n, v) for n, v in env if n in names))
' "$@" | tr -d '\r'
}

# run_filter ERRFILE MODE NAMES... -- helm args  (render failure -> exit 1, stderr in ERRFILE)
run_filter() {
  local err="$1"; shift
  local fargs=() hargs=()
  while [ "$1" != "--" ]; do fargs+=("$1"); shift; done; shift
  hargs=("$@")
  helm template t "$CHART" --set releasability.enabled=true --set tierNode.enabled=true "${hargs[@]}" 2> "$err" \
    | filter "${fargs[@]}"
  return "${PIPESTATUS[0]}"
}

check() {  # $1 = case, $2 = got, $3 = want
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1:"; echo "  got:  $(echo "$2" | tr '\n' ' ')"; echo "  want: $(echo "$3" | tr '\n' ' ')"; FAIL=1; fi
}

N=MALLOC_ARENA_MAX

# A
got_a="$(run_filter "$TMP/a.err" pep $N -- )" || { echo "FAIL A: render failed"; cat "$TMP/a.err"; exit 1; }
n_a="$(printf '%s\n' "$got_a" | grep -c .)"
n_all="$(run_filter "$TMP/a2.err" count -- | grep -c .)"
[ "$n_a" -ge 2 ] || { echo "FAIL A: expected the hub PEP and tier PEPs, found $n_a"; FAIL=1; }
[ "$n_a" = "$n_all" ] || { echo "FAIL A: $n_a PEP containers listed, $n_all run /app/pep.py"; FAIL=1; }
check "A default: every PEP ($n_a) has MALLOC_ARENA_MAX=2 once" "$(printf '%s\n' "$got_a" | awk '{print NF, $2}' | sort -u)" "2 MALLOC_ARENA_MAX=2"

# B
got_b="$(run_filter "$TMP/b.err" pep $N PYTHONFAULTHANDLER -- --set releasability.pep.env.MALLOC_ARENA_MAX=4 --set releasability.pep.env.PYTHONFAULTHANDLER=1)" \
  || { echo "FAIL B: render failed"; cat "$TMP/b.err"; exit 1; }
check "B two vars: every PEP has both, sorted, MALLOC_ARENA_MAX=4 once" "$(printf '%s\n' "$got_b" | awk '{print NF, $2, $3}' | sort -u)" "3 MALLOC_ARENA_MAX=4 PYTHONFAULTHANDLER=1"
check "B two vars: same PEPs as the default" "$(printf '%s\n' "$got_b" | awk '{print $1}')" "$(printf '%s\n' "$got_a" | awk '{print $1}')"

# C
cat > "$TMP/null.yaml" <<'YEOF'
releasability: {pep: {env: {MALLOC_ARENA_MAX: null}}}
YEOF
got_c="$(run_filter "$TMP/c.err" pep $N -- -f "$TMP/null.yaml")" || { echo "FAIL C: render failed"; cat "$TMP/c.err"; FAIL=1; }
n_c="$(printf '%s\n' "$got_c" | grep -c .)"
check "C null in a later -f: no PEP ($n_c) has it" "$(printf '%s\n' "$got_c" | awk '{print NF}' | sort -u)" "1"
[ "$n_c" = "$n_a" ] || { echo "FAIL C: $n_c PEP containers, want $n_a"; FAIL=1; }

# D, E
failcase() {  # $1 = case label, $2 = the --set arg, $3 = the text stderr must contain
  if run_filter "$TMP/f.err" pep $N -- --set "$2" >/dev/null; then
    echo "FAIL $1: the render succeeded"; FAIL=1
  elif grep -qF "$3" "$TMP/f.err"; then echo "PASS $1: the render fails and names the key"
  else echo "FAIL $1: failed without naming the key:"; grep -i 'error' "$TMP/f.err" | head -3; FAIL=1; fi
}
failcase "D OPENDDIL_ELECTRIC_URL" releasability.pep.env.OPENDDIL_ELECTRIC_URL=x "releasability.pep.env.OPENDDIL_ELECTRIC_URL"
failcase "D LOG_LEVEL" releasability.pep.env.LOG_LEVEL=DEBUG "releasability.pep.env.LOG_LEVEL"
failcase "E bad-name" releasability.pep.env.bad-name=1 "releasability.pep.env.bad-name"

# F
got_f="$(run_filter "$TMP/g.err" other $N -- )" || { echo "FAIL F: render failed"; exit 1; }
if printf '%s\n' "$got_f" | grep -q "$N="; then echo "FAIL F: a non-PEP python container carries $N"; FAIL=1
else echo "PASS F non-PEP python-image containers ($(printf '%s\n' "$got_f" | grep -c .)) do not carry $N"; fi

# G
got_g="$(run_filter "$TMP/h.err" dup -- )" || { echo "FAIL G: render failed"; exit 1; }
check "G no duplicate env names in any PEP container" "$(printf '%s\n' "$got_g" | awk '{print $2}' | sort -u)" "0"

exit "$FAIL"
