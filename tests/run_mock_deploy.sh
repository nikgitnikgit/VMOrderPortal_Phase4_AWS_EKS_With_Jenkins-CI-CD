#!/bin/bash
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MOCK_LOG=/tmp/mock_deploy.log
: > "$MOCK_LOG"
export PATH="$REPO/tests/mocks:$PATH"
# verify-jenkins.sh inspects a LIVE cluster (kubectl auth can-i, pod readiness)
# and cannot be satisfied by mocks. It is exercised for real by deploy.sh.
export SKIP_VERIFY=1
cp "$REPO/terraform/terraform.tfvars.example" "$REPO/terraform/terraform.tfvars"
"$REPO/scripts/deploy.sh" > /tmp/deploy_stdout.log 2>&1
rm -f "$REPO/terraform/terraform.tfvars"
grep -q "Infrastructure and Jenkins are ready" /tmp/deploy_stdout.log
