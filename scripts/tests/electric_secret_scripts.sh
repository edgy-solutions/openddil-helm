#!/usr/bin/env bash
# ===========================================================================
# electric_secret_scripts.sh -- offline proof that the in-pod Electric reads
# carry the pod's own secret in secure mode and nothing otherwise.
#
# The two functions (electric_shape, electric_shape_rows) are cut out of the
# script by their exact `name() {` ... `}` boundaries, so the whole script is
# never sourced. The pre-change copy comes from git (BASE, default abc9329).
# kubectl is a shell function that drops `exec [-i] -n NS POD --` and runs the
# rest locally with a controlled env; curl is a PATH shim that logs its argv.
# Nothing is rendered; everything lives in a mktemp dir that is removed.
# ===========================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/../reset-scenario.sh}"
CHECK="$HERE/../check-shape-sizes.sh"
BASE="${BASE:-abc9329}"
PY="${PY:-python3}"; command -v "$PY" >/dev/null 2>&1 || PY="py -3"
DUMMY="dummy-test-value"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'SHIM'
#!/usr/bin/env bash
url="${@: -1}"; hd=""; out=""
while [ $# -gt 1 ]; do
  case "$1" in -D) hd="$2"; shift ;; -o) out="$2"; shift ;; esac; shift
done
printf '%s\n' "$url" >> "$CURL_LOG"
if [[ "$url" == *offset=-1* ]]; then
  hdrs=$'HTTP/1.1 200 OK\r\nelectric-handle: h1\r\nelectric-offset: 0_1\r\n'
  body='[{"operation":"insert"}]'
else
  hdrs=$'HTTP/1.1 200 OK\r\nelectric-handle: h1\r\nelectric-offset: 0_2\r\nelectric-up-to-date:\r\n'
  body='[{"operation":"insert"},{"control":"up-to-date"}]'
fi
if [ "$hd" = /dev/stderr ]; then printf '%s' "$hdrs" >&2; elif [ -n "$hd" ]; then printf '%s' "$hdrs" > "$hd"; fi
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; printf 200; else printf '%s' "$body"; fi
SHIM
chmod +x "$T/bin/curl"

# cut <file> <name>: print `name() {` through the first column-0 `}`.
cut_fn() { awk -v n="$2" '$0==n"() {"{p=1} p{print} p&&$0=="}"{exit}' "$1"; }

git -C "$HERE" show "$BASE:scripts/reset-scenario.sh" > "$T/old.sh" 2>/dev/null || { echo "FAIL cannot read $BASE"; exit 1; }
for v in old new; do
  src="$T/old.sh"; [ $v = new ] && src="$SCRIPT"
  { cut_fn "$src" electric_shape; cut_fn "$src" electric_shape_handle; cut_fn "$src" electric_shape_rows; } > "$T/fn-$v.sh"
  [ "$(grep -c '^electric_shape' "$T/fn-$v.sh")" = 3 ] || bad "extract $v"
done

# Run one variant. $1 old|new  $2 secret-or-empty-for-unset  -> $T/log-$1-$3, $T/out-$1-$3
run() {
  local v="$1" sec="$2" tag="$3"
  : > "$T/log-$v-$tag"; : > "$T/kargv-$v-$tag"
  (
    export PATH="$T/bin:$PATH" CURL_LOG="$T/log-$v-$tag"
    NS=ns; ELECTRIC_SHAPE_TABLE=telemetry_latest_state
    kubectl() {  # exec [-i] -n NS POD -- cmd...
      printf '%s\n' "$*" >> "$T/kargv-$v-$tag"
      while [ "$1" != -- ]; do shift; done; shift
      if [ -n "$sec" ]; then env ELECTRIC_SECRET="$sec" "$@"; else env -u ELECTRIC_SECRET "$@"; fi
    }
    . "$T/fn-$v.sh"
    echo "handle=$(electric_shape_handle pod 3000)"
    echo "rows=$(electric_shape_rows pod 3000)"
  ) > "$T/out-$v-$tag" 2>&1
}
run old "" unset; run new "" unset; run new "$DUMMY" set

# Old versus new, secret unset: curl URLs byte-identical.
if [ -s "$T/log-old-unset" ] && cmp -s "$T/log-old-unset" "$T/log-new-unset"; then ok "unset: curl URLs identical to $BASE"; else bad "unset: curl URLs identical to $BASE"; fi
grep -q 'secret' "$T/log-new-unset" && bad "unset: no secret in URL" || ok "unset: no secret in URL"

# Set: every URL (shape read and every rows chunk) ends with the secret.
# The rows chunks append &offset=/&handle= after the secret, so for them the
# secret is a parameter, not the last one; the plain shape read ends with it.
n=$(wc -l < "$T/log-new-set"); m=$(grep -c "&secret=$DUMMY\(&\|\$\)" "$T/log-new-set")
if [ "$n" -ge 3 ] && [ "$n" = "$m" ]; then ok "set: all $n curl URLs carry &secret=<value>"; else bad "set: $m of $n curl URLs carry &secret"; fi
grep -q "offset=-1&secret=$DUMMY\$" "$T/log-new-set" && grep -q "secret=$DUMMY&offset=0_1&handle=h1\$" "$T/log-new-set" && ok "set: query forms valid (single ?)" || bad "set: query forms valid"
[ "$(grep -o '?' "$T/log-new-set" | wc -l)" = "$n" ] && ok "set: one ? per URL" || bad "set: one ? per URL"
grep -qx 'handle=h1' "$T/out-new-set" && ok "set: handle returned" || bad "set: handle returned"
grep -qx 'rows=2' "$T/out-new-set" && ok "set: row count returned" || bad "set: row count returned"
grep -qx 'rows=2' "$T/out-new-unset" && grep -qx 'handle=h1' "$T/out-new-unset" && ok "unset: handle and rows returned" || bad "unset: handle and rows returned"

# No leak: functions' output and the kubectl argv.
grep -q "$DUMMY" "$T/out-new-set" && bad "no leak: output" || ok "no leak: output"
grep -q "$DUMMY" "$T/kargv-new-set" && bad "no leak: kubectl argv" || ok "no leak: kubectl argv"
[ -s "$T/kargv-new-set" ] && ok "kubectl stub was used" || bad "kubectl stub was used"

# check-shape-sizes: pull the embedded python out of the script and run it
# against a fake urlopen, with and without the PEP's env secret.
awk '/python -c "$/{p=1;next} p&&/^" 2>/{exit} p' "$CHECK" > "$T/embedded.py"
[ -s "$T/embedded.py" ] && ok "embedded python extracted" || bad "embedded python extracted"
cat > "$T/drive.py" <<'PYEOF'
import os, sys, urllib.request, urllib.error, io
seen = []
class R(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): pass
def fake(u, timeout=0):
    seen.append(u)
    if os.environ.get('FAIL'):
        raise urllib.error.HTTPError(u, 401, 'Unauthorized', {}, None)
    return R(b'x')
urllib.request.urlopen = fake
exec(compile(open(sys.argv[1]).read(), 'embedded', 'exec'))
sys.stderr.write('\n'.join(seen) + '\n')
PYEOF
for case in with without fail; do
  env -u OPENDDIL_ELECTRIC_SECRET -u FAIL OPENDDIL_ELECTRIC_URL=http://e:3000/ \
    $( [ $case != without ] && echo OPENDDIL_ELECTRIC_SECRET=$DUMMY ) $( [ $case = fail ] && echo FAIL=1 ) \
    $PY -I "$T/drive.py" "$T/embedded.py" > "$T/o-$case" 2> "$T/e-$case"
done
nu=$(grep -c "offset=-1" "$T/e-without")
[ "$nu" -ge 8 ] && [ "$(grep -c "offset=-1&secret=$DUMMY\$" "$T/e-with")" = "$nu" ] && ok "check-shape-sizes: secret appended on all $nu URLs" || bad "check-shape-sizes: secret appended"
grep -q secret "$T/e-without" && bad "check-shape-sizes: unset adds no secret" || ok "check-shape-sizes: unset adds no secret"
grep -q 'offset=-1$' "$T/e-without" && ok "check-shape-sizes: unset URL unchanged form" || bad "check-shape-sizes: unset URL unchanged form"
grep -q "ERR HTTPError 401" "$T/o-fail" && ok "check-shape-sizes: error line is class and code" || bad "check-shape-sizes: error line"
grep -q "$DUMMY" "$T/o-fail" "$T/o-with" && bad "check-shape-sizes: no leak in stdout" || ok "check-shape-sizes: no leak in stdout"

[ $fails = 0 ] && echo "ALL PASS" || { echo "FAILURES: $fails"; exit 1; }
