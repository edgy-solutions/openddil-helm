# ===========================================================================
# require-cluster.sh — refuse to run against a cluster nobody named.
# ===========================================================================
# Source this near the top of any script that touches a cluster:
#
#     . "$(dirname "$0")/lib/require-cluster.sh"
#
# WHY THIS IS A MECHANISM AND NOT A LINE IN THE README
# ---------------------------------------------------
# Bare `kubectl` resolves against whatever ~/.kube/config names as
# current-context. On a workstation with more than one cluster in scope that
# is a coin toss, and it has come up wrong three times. The third time,
# `check_consumer_census.py` ran against a cluster with no `openddil`
# namespace at all and reported "no per-tier brokers found" — a sentence
# INDISTINGUISHABLE from a torn-down deployment. A read that lands on the
# wrong cluster costs a minute of confusion.
#
# `sever-tier.sh` applies NetworkPolicies and deletes pods. A WRITE that
# lands on the wrong cluster is not a misread; it is an incident, and it is
# an incident in someone else's namespace. Prose asking the operator to
# check first has now failed three times, so the check stops being asked for
# and starts being enforced.
#
# NO --force, NO ESCAPE HATCH. A flag to skip this would be reached for at
# exactly the moment it is load-bearing — late, under time pressure, on the
# assumption that this once the context is obviously right. That assumption
# is the thing that failed. Changing clusters means changing the expected
# context on purpose, in a file, which is a different act from typing a flag.
#
# WHERE THE EXPECTED NAME COMES FROM. Not hardcoded: this chart is deployed
# by people whose cluster is not ours, and baking one lab's context name into
# it would make the guard wrong for everyone else and therefore the first
# thing they delete. In precedence order:
#
#   1. $OPENDDIL_EXPECT_CONTEXT      — for CI and one-off overrides
#   2. <repo>/.expected-context      — operator states it once, locally
#
# .expected-context FORMAT: one entry per line; blank lines and # comments
# (whole-line or trailing) are ignored; whitespace is trimmed. A plain line
# is an ALLOWED context; a line "!<ctx>" is a BARRED context. A file holding
# one plain line behaves as it always has.
#
#   - Exactly one allowed entry and no env: that entry is the expectation.
#   - Two or more allowed entries and no env: REFUSED. With two labs in one
#     checkout there is no implicit pick; a run must name its cluster with
#     OPENDDIL_EXPECT_CONTEXT, so a fresh install cannot land on the lab that
#     is busy with something else because it was listed first.
#   - A barred context is refused even when OPENDDIL_EXPECT_CONTEXT names it
#     and even when it is the current context: "!" outranks the env and the
#     equality check. The env is otherwise not checked against the allowed
#     list (CI, in-pod use and offline tests export synthetic names).
#   - A file of only "!" lines declares no expectation.
#
# UNSET IS A REFUSAL, NOT A DEFAULT. If neither is present the script stops.
# Defaulting to "whatever is current" would restore precisely the behaviour
# this file exists to remove, while appearing to have a guard.
# ===========================================================================

openddil_require_cluster() {
    local expect actual root line
    local -a allowed=() barred=()
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    if [ -f "$root/.expected-context" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"
            line="${line//[[:space:]]/}"   # context names hold no whitespace
            [ -n "$line" ] || continue
            if [ "${line:0:1}" = "!" ]; then
                line="${line:1}"
                if [ -n "$line" ]; then barred+=("$line"); fi
            else
                allowed+=("$line")
            fi
        done < "$root/.expected-context"
    fi
    _in_barred() {
        local x
        for x in ${barred[@]+"${barred[@]}"}; do
            if [ "$x" = "$1" ]; then return 0; fi
        done
        return 1
    }

    expect="${OPENDDIL_EXPECT_CONTEXT:-}"
    if [ -n "$expect" ]; then
        if _in_barred "$expect"; then
            echo "REFUSING TO RUN: '$expect' is barred by .expected-context." >&2
            echo "  Nothing has been read and nothing has been written." >&2
            exit 78
        fi
    elif [ "${#allowed[@]}" -eq 1 ]; then
        expect="${allowed[0]}"
    elif [ "${#allowed[@]}" -ge 2 ]; then
        echo "REFUSING TO RUN: this checkout allows ${#allowed[@]} clusters ($(IFS=,; echo "${allowed[*]}" | sed 's/,/, /g'));" >&2
        echo "  name the one for this run: OPENDDIL_EXPECT_CONTEXT=<one of them> $0 ..." >&2
        echo "  Nothing has been read and nothing has been written." >&2
        exit 78
    fi

    if [ -z "$expect" ]; then
        echo "REFUSING TO RUN: no expected kube-context is declared." >&2
        echo "  This script touches a cluster, and which cluster is not" >&2
        echo "  something it will infer from current-context." >&2
        echo "  Declare it once:" >&2
        echo "      kubectl config current-context > $root/.expected-context" >&2
        echo "  or per-invocation: OPENDDIL_EXPECT_CONTEXT=<ctx> $0 ..." >&2
        exit 78   # EX_CONFIG
    fi

    # kubectl exits 1 when no context is set; a caller under `set -e` would
    # die here silently, before either refusal below could print.
    actual="$(kubectl config current-context 2>/dev/null)" || actual=""
    # Inside a pod there is no kubeconfig context, and the service account's
    # namespace is the only cluster identity the pod has. The chart declares
    # the expectation as in-cluster:<namespace>. No kubeconfig is synthesised,
    # because that would fake a context; this branch fires only when the
    # context is empty and the pod really is in a cluster.
    local sa_ns="${OPENDDIL_SA_DIR:-/var/run/secrets/kubernetes.io/serviceaccount}/namespace"
    if [ -z "$actual" ] && [ -f "$sa_ns" ] && [ -n "${KUBERNETES_SERVICE_HOST:-}" ]; then
        actual="in-cluster:$(tr -d '[:space:]' < "$sa_ns")"
    fi
    if [ -z "$actual" ]; then
        echo "REFUSING TO RUN: kubectl reports no current-context." >&2
        echo "  Expected '$expect'. An empty context is not a match for" >&2
        echo "  anything; it is a kubeconfig that cannot answer." >&2
        exit 78
    fi

    if _in_barred "$actual"; then
        echo "REFUSING TO RUN: current context '$actual' is barred." >&2
        echo "  Nothing has been read and nothing has been written." >&2
        exit 78
    fi

    if [ "$actual" != "$expect" ]; then
        echo "REFUSING TO RUN: wrong cluster." >&2
        echo "    expected context : $expect" >&2
        echo "    current context  : $actual" >&2
        echo "  Nothing has been read and nothing has been written." >&2
        echo "  If '$actual' is genuinely the intended target, say so in" >&2
        echo "  $root/.expected-context — deliberately, not with a flag." >&2
        exit 78
    fi

    echo "cluster: $actual (asserted)"
}

openddil_require_cluster
