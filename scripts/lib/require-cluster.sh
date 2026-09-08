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
# UNSET IS A REFUSAL, NOT A DEFAULT. If neither is present the script stops.
# Defaulting to "whatever is current" would restore precisely the behaviour
# this file exists to remove, while appearing to have a guard.
# ===========================================================================

openddil_require_cluster() {
    local expect actual root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    expect="${OPENDDIL_EXPECT_CONTEXT:-}"
    if [ -z "$expect" ] && [ -f "$root/.expected-context" ]; then
        expect="$(tr -d '[:space:]' < "$root/.expected-context")"
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

    actual="$(kubectl config current-context 2>/dev/null)"
    if [ -z "$actual" ]; then
        echo "REFUSING TO RUN: kubectl reports no current-context." >&2
        echo "  Expected '$expect'. An empty context is not a match for" >&2
        echo "  anything; it is a kubeconfig that cannot answer." >&2
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
