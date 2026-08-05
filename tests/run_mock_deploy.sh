#!/bin/bash
# tests/run_mock_deploy.sh — runs deploy.sh end-to-end against mocked binaries.
#
# IMPORTANT: this test must never touch the developer's real
# terraform/terraform.tfvars. An earlier version copied the example file over
# it and then deleted it, which silently destroyed a real configuration
# containing the database password. A test that damages the working tree is
# worse than no test.
#
# Instead the whole run happens in a temporary COPY of the repository.
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK=$(mktemp -d /tmp/mock-deploy-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Copy the repo, excluding state and the real tfvars — the sandbox gets the
# example values, and the original is never opened.
tar -C "$REPO" \
    --exclude='./.git' \
    --exclude='./terraform/.terraform' \
    --exclude='./terraform/terraform.tfvars' \
    --exclude='./terraform/terraform.tfstate*' \
    -cf - . | tar -C "$WORK" -xf -

cp "$WORK/terraform/terraform.tfvars.example" "$WORK/terraform/terraform.tfvars"

export MOCK_LOG=/tmp/mock_deploy.log
: > "$MOCK_LOG"
export PATH="$WORK/tests/mocks:$PATH"
# verify-jenkins.sh inspects a LIVE cluster (kubectl auth can-i, pod readiness)
# and cannot be satisfied by mocks. It is exercised for real by deploy.sh, and
# its own logic is tested by tests/check_verify_script.sh.
export SKIP_VERIFY=1

"$WORK/scripts/deploy.sh" > /tmp/deploy_stdout.log 2>&1
grep -q "Infrastructure and Jenkins are ready" /tmp/deploy_stdout.log
