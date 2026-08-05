#!/bin/bash
# scripts/verify-jenkins.sh
#
# Asserts that the Jenkins installation matches what the design claims.
# Read-only: changes nothing, safe to run at any time.
#
# The interesting checks are the negative ones. It is easy to prove Jenkins
# CAN deploy; the security argument depends on proving the CI agent CANNOT,
# and that nothing can read the application Secret. Those are checks 12-15.
#
# Output doubles as submission evidence:
#   ./scripts/verify-jenkins.sh | tee evidence/verify-jenkins.txt
# SC2016 is disabled for the whole file deliberately: the single-quoted
# strings below are passed to `bash -c` and MUST be expanded in that subshell,
# not here. Expanding them now would evaluate cluster state at parse time.
# shellcheck disable=SC2016

set -uo pipefail

PASS=0
FAIL=0
FAILED=()

check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  \033[32mPASS\033[0m  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  \033[31mFAIL\033[0m  %s\n' "$name"
        FAIL=$((FAIL + 1))
        FAILED+=("$name")
    fi
}

# Inverted check: passes when the command FAILS. Used to prove an identity
# does NOT have a permission.
check_denied() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  \033[31mFAIL\033[0m  %s (permission was granted!)\n' "$name"
        FAIL=$((FAIL + 1))
        FAILED+=("$name")
    else
        printf '  \033[32mPASS\033[0m  %s\n' "$name"
        PASS=$((PASS + 1))
    fi
}

echo "=================================================="
echo "  Jenkins installation verification"
echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=================================================="

# ------------------------------------------------------------- namespaces
echo ""
echo "Namespaces"
check "jenkins namespace exists"    kubectl get namespace jenkins
check "devops-app namespace exists" kubectl get namespace devops-app
check_denied "nothing deployed to default namespace" \
    bash -c 'kubectl get deployments -n default --no-headers 2>/dev/null | grep -q .'

# ------------------------------------------------------------- controller
echo ""
echo "Controller"
check "StatefulSet jenkins exists" kubectl get statefulset jenkins -n jenkins
check "controller pod is Ready" bash -c \
    '[ "$(kubectl get pod jenkins-0 -n jenkins -o jsonpath="{.status.containerStatuses[*].ready}")" = "true true" ]'
check "controller runs ZERO executors (no builds on the controller)" bash -c \
    'kubectl exec -n jenkins jenkins-0 -c jenkins -- cat /var/jenkins_home/config.xml 2>/dev/null | grep -q "<numExecutors>0</numExecutors>"'
check "PVC is bound" bash -c \
    '[ "$(kubectl get pvc -n jenkins -o jsonpath="{.items[0].status.phase}")" = "Bound" ]'
check "controller image is pinned (not :latest)" bash -c \
    'kubectl get statefulset jenkins -n jenkins -o jsonpath="{.spec.template.spec.containers[0].image}" | grep -qv ":latest$"'

# --------------------------------------------------------------- exposure
echo ""
echo "Exposure"
check "Service exists"  kubectl get service jenkins -n jenkins
check "Ingress exists"  kubectl get ingress jenkins -n jenkins
check "Ingress uses HTTPS" bash -c \
    'kubectl get ingress jenkins -n jenkins -o jsonpath="{.metadata.annotations}" | grep -q certificate-arn'
check "Ingress is IP-restricted (not open to the world)" bash -c \
    'kubectl get ingress jenkins -n jenkins -o jsonpath="{.metadata.annotations}" | grep inbound-cidrs | grep -qv "0.0.0.0/0"'
check "pathType is Prefix (ALB treats / as exact otherwise)" bash -c \
    '[ "$(kubectl get ingress jenkins -n jenkins -o jsonpath="{.spec.rules[0].http.paths[0].pathType}")" = "Prefix" ]'

# --------------------------------------------------------- ServiceAccounts
echo ""
echo "ServiceAccounts and IRSA"
check "SA jenkins exists"          kubectl get sa jenkins -n jenkins
check "SA jenkins-agent-ci exists" kubectl get sa jenkins-agent-ci -n jenkins
check "SA jenkins-agent-cd exists" kubectl get sa jenkins-agent-cd -n jenkins
check "CI agent has an IRSA role" bash -c \
    'kubectl get sa jenkins-agent-ci -n jenkins -o jsonpath="{.metadata.annotations}" | grep -q role-arn'
check "CD agent has an IRSA role" bash -c \
    'kubectl get sa jenkins-agent-cd -n jenkins -o jsonpath="{.metadata.annotations}" | grep -q role-arn'
check "CI and CD use DIFFERENT IAM roles" bash -c \
    '[ "$(kubectl get sa jenkins-agent-ci -n jenkins -o jsonpath="{.metadata.annotations.eks\.amazonaws\.com/role-arn}")" \
    != "$(kubectl get sa jenkins-agent-cd -n jenkins -o jsonpath="{.metadata.annotations.eks\.amazonaws\.com/role-arn}")" ]'

# ------------------------------------------------------------------- RBAC
echo ""
echo "RBAC — positive checks"
check "controller can create agent pods" \
    kubectl auth can-i create pods -n jenkins --as=system:serviceaccount:jenkins:jenkins
check "CD agent can create deployments in devops-app" \
    kubectl auth can-i create deployments -n devops-app --as=system:serviceaccount:jenkins:jenkins-agent-cd
check "CD agent can read pods (rollout status)" \
    kubectl auth can-i get pods -n devops-app --as=system:serviceaccount:jenkins:jenkins-agent-cd

echo ""
echo "RBAC — negative checks (the security argument)"
check_denied "CI agent CANNOT create deployments" \
    kubectl auth can-i create deployments -n devops-app --as=system:serviceaccount:jenkins:jenkins-agent-ci
check_denied "CI agent CANNOT create pods" \
    kubectl auth can-i create pods -n devops-app --as=system:serviceaccount:jenkins:jenkins-agent-ci
check_denied "CD agent CANNOT read Secrets (the DB password)" \
    kubectl auth can-i get secrets -n devops-app --as=system:serviceaccount:jenkins:jenkins-agent-cd
check_denied "CD agent CANNOT list Secrets" \
    kubectl auth can-i list secrets -n devops-app --as=system:serviceaccount:jenkins:jenkins-agent-cd
check_denied "controller CANNOT deploy to devops-app" \
    kubectl auth can-i create deployments -n devops-app --as=system:serviceaccount:jenkins:jenkins
check_denied "no ClusterRoleBinding grants Jenkins cluster-admin" bash -c \
    'kubectl get clusterrolebindings -o json | grep -A5 "cluster-admin" | grep -q "jenkins"'

# --------------------------------------------------------- NetworkPolicy
echo ""
echo "Network"
check "NetworkPolicies exist in jenkins namespace" bash -c \
    '[ "$(kubectl get networkpolicy -n jenkins --no-headers 2>/dev/null | wc -l)" -ge 3 ]'
check "NetworkPolicy enforcement enabled in the VPC CNI" bash -c \
    'kubectl get daemonset aws-node -n kube-system -o jsonpath="{.spec.template.spec.containers[0].env}" | grep -q ENABLE_NETWORK_POLICY'

# ------------------------------------------------------------------- jobs
echo ""
echo "Jobs"
JPASS=$(kubectl get secret jenkins -n jenkins -o jsonpath='{.data.jenkins-admin-password}' 2>/dev/null | base64 -d)
check "job application-ci exists" bash -c \
    "kubectl exec -n jenkins jenkins-0 -c jenkins -- curl -sS -g --user 'admin:${JPASS}' \
     'http://localhost:8080/api/json?tree=jobs[name]' | grep -q application-ci"
check "job application-cd exists" bash -c \
    "kubectl exec -n jenkins jenkins-0 -c jenkins -- curl -sS -g --user 'admin:${JPASS}' \
     'http://localhost:8080/api/json?tree=jobs[name]' | grep -q application-cd"

# ------------------------------------------------------------- pipelines
echo ""
echo "Pipeline separation"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check "Jenkinsfile-ci exists" test -f "$REPO_ROOT/Jenkinsfile-ci"
check "Jenkinsfile-cd exists" test -f "$REPO_ROOT/Jenkinsfile-cd"
# Comment lines are stripped first: both files DISCUSS the other pipeline's
# forbidden command in their header comments, and grepping raw text would
# report a violation that does not exist.

check_denied "CI pipeline contains NO helm upgrade (no deploy)" \
    bash -c 'grep -v "^\s*//" "$0" | grep -q "helm upgrade"' "$REPO_ROOT/Jenkinsfile-ci"
check_denied "CI pipeline contains NO kubectl apply/create" \
    bash -c 'grep -v "^\s*//" "$0" | grep -qE "kubectl (apply|create|rollout)"' "$REPO_ROOT/Jenkinsfile-ci"
check_denied "CD pipeline contains NO buildctl (no build)" \
    bash -c 'grep -v "^\s*//" "$0" | grep -q "buildctl"' "$REPO_ROOT/Jenkinsfile-cd"
check_denied "CD pipeline has NO buildkit container" \
    bash -c 'grep -v "^\s*//" "$0" | grep -q "name: buildkit"' "$REPO_ROOT/Jenkinsfile-cd"
check "CD rejects the tag 'latest'" \
    grep -q "is not immutable" "$REPO_ROOT/Jenkinsfile-cd"

# ---------------------------------------------------------------- summary
echo ""
echo "=================================================="
printf "  RESULT: %d passed, %d failed\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '  FAILED: %s\n' "${FAILED[@]}"
fi
echo "=================================================="
exit "$FAIL"
