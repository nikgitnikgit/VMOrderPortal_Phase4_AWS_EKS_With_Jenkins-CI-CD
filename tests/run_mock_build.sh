#!/bin/bash
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MOCK_LOG=/tmp/mock_build.log
: > "$MOCK_LOG"
export PATH="$REPO/tests/mocks:$PATH"
"$REPO/scripts/build-images.sh" 9.9.9 > /tmp/build_stdout.log 2>&1
grep -q "All images built and pushed" /tmp/build_stdout.log
grep -c "docker build" "$MOCK_LOG" | grep -q "^3$"
