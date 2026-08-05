#!/bin/bash
# scripts/uninstall-jenkins.sh
#
# Removes Jenkins and everything it created, leaving the cluster and the
# application untouched. Use this to reinstall Jenkins cleanly without
# destroying the whole environment.
#
# For a full teardown of all AWS resources, use scripts/destroy.sh instead.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_REGION=$(cd "$REPO_ROOT/terraform" && terraform output -raw aws_region 2>/dev/null || echo us-east-1)

echo "=================================================="
echo "  Uninstalling Jenkins"
echo "=================================================="

echo ""
echo "[1/5] Removing the Helm release..."
helm uninstall jenkins -n jenkins 2>/dev/null || echo "  (not installed)"

# The PVC creates a real EBS volume that Terraform does not know about. If it
# is left behind it quietly costs money forever.
echo ""
echo "[2/5] Deleting the PVC (and its EBS volume)..."
kubectl delete pvc -n jenkins --all --ignore-not-found --timeout=120s

echo ""
echo "[3/5] Waiting for the Jenkins ALB to be released..."
for i in $(seq 1 18); do
    ALB=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query "LoadBalancers[?contains(LoadBalancerName,'jenkins')].LoadBalancerArn" \
        --output text 2>/dev/null)
    [ -z "$ALB" ] && { echo "  released"; break; }
    echo "  ... still deleting ($i/18)"
    sleep 10
done

echo ""
echo "[4/5] Removing RBAC, ServiceAccounts and NetworkPolicies..."
kubectl delete -f "$REPO_ROOT/jenkins/networkpolicy.yaml" --ignore-not-found
kubectl delete -f "$REPO_ROOT/jenkins/rbac.yaml" --ignore-not-found

echo ""
echo "[5/5] Deleting the namespace..."
kubectl delete namespace jenkins --ignore-not-found --timeout=120s

echo ""
echo "Jenkins removed. The application in devops-app is untouched."
echo "Reinstall with: ./scripts/install-jenkins.sh"
