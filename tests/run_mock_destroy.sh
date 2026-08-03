#!/bin/bash
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MOCK_LOG=/tmp/mock_destroy.log
: > "$MOCK_LOG"
export PATH="$REPO/tests/mocks:$PATH"
"$REPO/scripts/destroy.sh" > /tmp/destroy_stdout.log 2>&1
grep -q "Everything destroyed" /tmp/destroy_stdout.log
