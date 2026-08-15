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
#
# __pycache__/*.pyc are excluded for a subtler reason: tar exits 1 with
# "file changed as we read it" if a file is written mid-copy, and CPython
# writes .pyc files lazily after the suite's pytest step. That made this test
# fail intermittently for reasons unrelated to deploy.sh. Bytecode has no
# business in the sandbox copy anyway — deploy.sh should exercise the source.
tar -C "$REPO" \
    --exclude='./.git' \
    --exclude='./terraform/.terraform' \
    --exclude='./terraform/terraform.tfvars' \
    --exclude='./terraform/terraform.tfstate*' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='./.pytest_cache' \
    -cf - . | tar -C "$WORK" -xf -

cp "$WORK/terraform/terraform.tfvars.example" "$WORK/terraform/terraform.tfvars"

# Isolate the run from the developer's environment. Without this, a shell that
# happens to have GITHUB_TOKEN exported takes the webhook branch and calls the
# real GitHub API, so the test passes or fails depending on who runs it.
# HOME is redirected too, so ~/.github_token is not picked up either.
unset GITHUB_TOKEN
export HOME="$WORK/fakehome"
mkdir -p "$HOME"

export MOCK_LOG=/tmp/mock_deploy.log
: > "$MOCK_LOG"
export PATH="$WORK/tests/mocks:$PATH"
# verify-jenkins.sh inspects a LIVE cluster (kubectl auth can-i, pod readiness)
# and cannot be satisfied by mocks. It is exercised for real by deploy.sh, and
# its own logic is tested by tests/check_verify_script.sh.
export SKIP_VERIFY=1

"$WORK/scripts/deploy.sh" > /tmp/deploy_stdout.log 2>&1
grep -q "Infrastructure and Jenkins are ready" /tmp/deploy_stdout.log
