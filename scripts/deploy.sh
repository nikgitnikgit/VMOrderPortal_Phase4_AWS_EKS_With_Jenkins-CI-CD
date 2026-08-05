#!/bin/bash
# scripts/deploy.sh
#
# One command to go from nothing to a running Jenkins.
#
#   1. terraform apply        infrastructure (VPC, EKS, RDS, S3, SNS, ECR, IAM)
#   2. install-jenkins.sh     add-ons, namespaces, RBAC, TLS, agent image, Jenkins
#   3. create-jobs.sh         the two jobs, from jenkins/jobs/seed.groovy
#   4. register-webhook.sh    push-to-main triggers CI (skipped without a token)
#   5. verify-jenkins.sh      assert the result matches the design
#
# The APPLICATION is deployed by the Jenkins CD pipeline, not by this script.
# That separation is the point of phase 4.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=================================================="
echo "  VM Order Portal — Phase 4 deploy"
echo "=================================================="

echo ""
echo "STEP 1/5: terraform apply (EKS takes 15-20 minutes — this is normal)"
cd "$REPO_ROOT/terraform"
terraform init -input=false
terraform apply -auto-approve

echo ""
echo "STEP 2/5: installing Jenkins"
cd "$REPO_ROOT"
./scripts/install-jenkins.sh

echo ""
echo "STEP 3/5: creating jobs from code"
./scripts/create-jobs.sh

echo ""
echo "STEP 4/5: registering the GitHub webhook"
if [ -n "${GITHUB_TOKEN:-}" ] || [ -f "$HOME/.github_token" ]; then
    ./scripts/register-webhook.sh
else
    echo "  SKIPPED — no GitHub token found."
    echo "  CI will still run on a 5-minute SCM poll."
    echo "  For push-triggered builds:"
    echo "    export GITHUB_TOKEN=ghp_xxx && ./scripts/register-webhook.sh"
fi

echo ""
echo "STEP 5/5: verifying"
# SKIP_VERIFY exists for the offline mock test suite: verify-jenkins.sh
# inspects a live cluster (RBAC decisions, running pods) and cannot be
# satisfied by mocked binaries.
if [ "${SKIP_VERIFY:-0}" = "1" ]; then
    echo "  SKIPPED (SKIP_VERIFY=1)"
else
    ./scripts/verify-jenkins.sh
fi

echo ""
echo "=================================================="
echo "Infrastructure and Jenkins are ready."
echo "Open Jenkins, run application-ci, and it will hand off to application-cd."
echo "=================================================="
