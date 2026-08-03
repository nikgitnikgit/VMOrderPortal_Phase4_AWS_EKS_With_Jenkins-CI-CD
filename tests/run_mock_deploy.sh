#!/bin/bash
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MOCK_LOG=/tmp/mock_deploy.log
: > "$MOCK_LOG"
export PATH="$REPO/tests/mocks:$PATH"
cp "$REPO/terraform/terraform.tfvars.example" "$REPO/terraform/terraform.tfvars"
"$REPO/scripts/deploy.sh" > /tmp/deploy_stdout.log 2>&1
rm -f "$REPO/terraform/terraform.tfvars"
grep -q "Infrastructure + platform ready" /tmp/deploy_stdout.log
