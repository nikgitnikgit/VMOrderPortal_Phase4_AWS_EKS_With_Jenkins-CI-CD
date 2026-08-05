#!/bin/bash
# tests/check_verify_script.sh — tests the tests.
#
# verify-jenkins.sh makes ~39 assertions about a live cluster. A check that
# always passes is worse than no check: it reports safety that was never
# measured. This harness runs verify-jenkins.sh against a mock kubectl,
# breaking exactly one condition at a time, and asserts that the check
# covering that condition FAILS.
#
# Every entry below is (broken-condition, text-that-must-appear-in-FAILED).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Fail with an explanation rather than a wall of confusing check failures.
if [ ! -x "$REPO/tests/mocks-verify/kubectl" ]; then
    echo "ERROR: tests/mocks-verify/kubectl is missing or not executable." >&2
    echo "This harness needs it to simulate cluster states. Fix with:" >&2
    echo "  chmod +x tests/mocks-verify/*" >&2
    exit 1
fi

export PATH="$REPO/tests/mocks-verify:$PATH"

PASS=0
FAIL=0
FAILED=()

run() {
    BREAK="$1" bash "$REPO/scripts/verify-jenkins.sh" 2>&1
}

expect_flip() {
    local condition="$1" expect="$2"
    local out
    out=$(run "$condition")
    if echo "$out" | grep -q "FAILED:.*${expect}" || \
       echo "$out" | sed -n '/FAILED:/,$p' | grep -q "${expect}"; then
        printf '  \033[32mOK\033[0m    breaking %-32s -> "%s" fails\n' "$condition" "$expect"
        PASS=$((PASS + 1))
    else
        printf '  \033[31mBAD\033[0m   breaking %-32s -> "%s" still PASSED\n' "$condition" "$expect"
        FAIL=$((FAIL + 1))
        FAILED+=("$condition")
    fi
}

echo "=================================================="
echo "  Testing verify-jenkins.sh — does each check flip?"
echo "=================================================="

echo ""
echo "Baseline: a correct cluster must produce zero failures"
BASE=$(BREAK=none bash "$REPO/scripts/verify-jenkins.sh" 2>&1 | grep "RESULT:")
if echo "$BASE" | grep -q "0 failed"; then
    printf '  \033[32mOK\033[0m    %s\n' "$BASE"
    PASS=$((PASS + 1))
else
    printf '  \033[31mBAD\033[0m   %s\n' "$BASE"
    FAIL=$((FAIL + 1))
    FAILED+=("baseline")
fi

echo ""
echo "Existence and controller state"
expect_flip no-ns-jenkins                "jenkins namespace exists"
expect_flip no-ns-app                    "devops-app namespace exists"
expect_flip deploy-in-default            "nothing deployed to default"
expect_flip no-sts                       "StatefulSet jenkins exists"
expect_flip pod-not-ready                "controller pod is Ready"
expect_flip executors-nonzero            "ZERO executors"
expect_flip pvc-pending                  "PVC is bound"
expect_flip image-latest                 "controller image is pinned"

echo ""
echo "Exposure"
expect_flip no-https                     "Ingress uses HTTPS"
expect_flip open-world                   "IP-restricted"
expect_flip pathtype-wrong               "pathType is Prefix"

echo ""
echo "Identity"
expect_flip no-ci-sa                     "SA jenkins-agent-ci exists"
expect_flip ci-no-irsa                   "CI agent has an IRSA role"
expect_flip ci-cd-same-role              "DIFFERENT IAM roles"

echo ""
echo "RBAC — the security argument"
expect_flip controller-cannot-create-pods "controller can create agent pods"
expect_flip cd-cannot-deploy              "CD agent can create deployments"
expect_flip ci-CAN-deploy                 "CI agent CANNOT create deployments"
expect_flip ci-CAN-create-pods            "CI agent CANNOT create pods"
expect_flip cd-CAN-read-secrets           "CANNOT read Secrets"
expect_flip cd-CAN-list-secrets           "CANNOT list Secrets"
expect_flip controller-CAN-deploy         "controller CANNOT deploy"
expect_flip jenkins-IS-cluster-admin      "cluster-admin"

echo ""
echo "Network and jobs"
expect_flip no-netpol                     "NetworkPolicies exist"
expect_flip netpol-not-enforced           "NetworkPolicy enforcement"
expect_flip no-ci-job                     "job application-ci exists"
expect_flip no-cd-job                     "job application-cd exists"

echo ""
echo "=================================================="
printf "  RESULT: %d checks verified, %d not wired up\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '  NOT WIRED: %s\n' "${FAILED[@]}"
fi
echo "=================================================="
exit "$FAIL"
