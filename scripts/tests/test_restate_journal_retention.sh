#!/usr/bin/env bash
# ===========================================================================
# test_restate_journal_retention.sh -- offline render proof that the Restate
# completed-invocation journal retention reaches every Restate server's config.
#
# Cases:
#   1. default values -> the hub and every tier restate ConfigMap carry
#      default-journal-retention = "1h", ahead of the first [[ table header
#      (a TOML root key after a table header lands inside that table).
#   2. restate.journalRetention="" -> the line is absent from all of them.
#   3. restate.journalRetention=2h -> checksum/restate-config on the hub
#      StatefulSet and on each tier restate pod template differs from default.
#   4. every rendered restate TOML parses.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$HERE/../../openddil-demo}"

command -v python >/dev/null 2>&1 && python -c 'import yaml, tomllib' >/dev/null 2>&1 \
  || { echo "SKIP: need python with PyYAML and tomllib (3.11+)"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0

cat > "$TMP/values.yaml" <<'YAML'
tierNode:
  enabled: true
  tiers: [region-a, edge-a1]
releasability:
  enabled: true
regions:
  - id: region-a
edges:
  - id: edge-a1
    region: region-a
    udpPort: 62040
tiers:
  - {id: region-a, kind: region, parent: root, hasChildren: true, label: region-a, publicOrigin: "", directIngest: false, region: region-a}
  - {id: edge-a1, kind: edge, parent: region-a, hasChildren: false, label: edge-a1, publicOrigin: "", directIngest: true, region: region-a}
YAML

render() {  # $1 = out file, rest = extra --set flags
  local out="$1"; shift
  helm template t "$CHART" -f "$TMP/values.yaml" "$@" > "$out" 2> "$out.err" \
    || { echo "render failed:"; cat "$out.err"; return 1; }
}

# Prints one line per restate server: "<name> <retention-line-index|-> <first-[[-index|-> <parses ok|bad> "
# for ConfigMaps carrying restate.toml (tier) or restate-config.toml (hub).
tomls() {  # $1 = rendered file
  python - "$1" <<'PYEOF'
import sys, yaml, tomllib
n = 0
for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
    if not d or d.get("kind") != "ConfigMap": continue
    dd = d.get("data") or {}
    t = dd.get("restate.toml", dd.get("restate-config.toml"))
    if t is None: continue
    n += 1
    lines = t.splitlines()
    r = next((i for i, l in enumerate(lines) if l.startswith("default-journal-retention")), -1)
    tb = next((i for i, l in enumerate(lines) if l.startswith("[[")), -1)
    try: tomllib.loads(t); ok = "ok"
    except Exception: ok = "bad"
    line = lines[r] if r >= 0 else "-"
    print(d["metadata"]["name"].replace(" ", "_"), r, tb, ok, line.replace(" ", ""))
print("COUNT", n)
PYEOF
}

sums() {  # $1 = rendered file -> "<workload> <checksum>" for pods carrying checksum/restate-config
  python - "$1" <<'PYEOF'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
    if not d or d.get("kind") not in ("StatefulSet", "Deployment"): continue
    a = d["spec"]["template"]["metadata"].get("annotations") or {}
    if "checksum/restate-config" in a:
        print(d["kind"], d["metadata"]["name"], a["checksum/restate-config"])
PYEOF
}

check() {  # $1 = case, $2 = got, $3 = want
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2', want '$3'"; FAIL=1; fi
}

render "$TMP/def.yaml" || exit 1
render "$TMP/off.yaml" --set restate.journalRetention="" || exit 1
render "$TMP/two.yaml" --set restate.journalRetention=2h || exit 1

tomls "$TMP/def.yaml" > "$TMP/def.t"
tomls "$TMP/off.yaml" > "$TMP/off.t"
count="$(awk '$1=="COUNT"{print $2}' "$TMP/def.t")"
# hub + region-a + edge-a1 = 3 servers.
check "0 restate servers rendered" "$count" "3"

# 1. line present, correct value, before first [[
bad="$(awk '$1!="COUNT" && !($2>=0 && $3>$2 && $5=="default-journal-retention=\"1h\""){print $1}' "$TMP/def.t" | tr '\n' ' ')"
check "1 default: every restate TOML has retention=1h before the first [[ ($bad)" "$bad" ""

# 2. empty -> absent everywhere
bad="$(awk '$1!="COUNT" && $2!=-1{print $1}' "$TMP/off.t" | tr '\n' ' ')"
check "2 empty: line absent from all ($bad)" "$bad" ""
check "2 empty: same server count" "$(awk '$1=="COUNT"{print $2}' "$TMP/off.t")" "$count"

# 3. checksums change on every restate pod
sums "$TMP/def.yaml" > "$TMP/def.s"; sums "$TMP/two.yaml" > "$TMP/two.s"
check "3 checksum carriers found" "$(wc -l < "$TMP/def.s" | tr -d ' ')" "3"
same="$(join <(awk '{print $2" "$3}' "$TMP/def.s" | sort) <(awk '{print $2" "$3}' "$TMP/two.s" | sort) | awk '$2==$3{print $1}' | tr '\n' ' ')"
check "3 2h: checksum differs on every restate pod (unchanged: $same)" "$same" ""

# 4. parses
bad="$(awk '$1!="COUNT" && $4!="ok"{print $1}' "$TMP/def.t" "$TMP/off.t" | tr '\n' ' ')"
check "4 every restate TOML parses ($bad)" "$bad" ""

[ "$FAIL" = 0 ] && echo "test_restate_journal_retention.sh: ALL PASS" || echo "test_restate_journal_retention.sh: FAILED"
exit "$FAIL"
