#!/bin/bash
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MOCK_LOG=/tmp/mock_destroy.log
: > "$MOCK_LOG"
export PATH="$REPO/tests/mocks:$PATH"
"$REPO/scripts/destroy.sh" > /tmp/destroy_stdout.log 2>&1

# REVIEW FIX 4.7 — the success banner changed from "Everything destroyed" to
# "Nothing left", because the script now VERIFIES rather than asserts.
grep -q "Nothing left" /tmp/destroy_stdout.log

# The verification must be scoped to this project. An account-wide check would
# report a colleague's cluster as our leftover, and miss nothing of ours.
grep -q "tag:Project" "$MOCK_LOG" || {
    echo "destroy.sh verification is not tag-scoped" >&2; exit 1; }

# The two resources that actually keep billing after a partial destroy.
for q in "describe-nat-gateways" "rds describe-db-instances"; do
    grep -q "$q" "$MOCK_LOG" || {
        echo "destroy.sh never checked for leftover: $q" >&2; exit 1; }
done
