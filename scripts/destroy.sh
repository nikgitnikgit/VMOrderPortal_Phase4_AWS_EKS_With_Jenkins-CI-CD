#!/bin/bash
# scripts/destroy.sh
# Phase 4 teardown — hardened by real live runs.
# Added vs phase 3:
#   - Uninstall Jenkins FIRST (stop any mid-build agents)
#   - Delete Jenkins PVC (EBS volume not known to Terraform — costs money if left)
#   - Wait for TWO ALBs (app + Jenkins) to be deleted
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/terraform"
NAMESPACE=$(terraform output -raw k8s_namespace 2>/dev/null || echo devops-app)
S3_BUCKET=$(terraform output -raw s3_bucket_name 2>/dev/null || true)
VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || true)
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo us-east-1)

echo "============================================"
echo "  VM Order Portal — Phase 4 Destroy"
echo "============================================"

# --- 1. Uninstall Jenkins FIRST (stop agents, release PVC) ---
echo ""
echo "Step 1: Uninstalling Jenkins..."
helm uninstall jenkins -n jenkins 2>/dev/null || echo "  (jenkins not installed)"

# Delete the Jenkins PVC — it creates a real EBS volume that Terraform
# doesn't know about. If left, it quietly costs money forever.
echo "  Deleting Jenkins PVC..."
kubectl delete pvc -n jenkins --all --wait=false 2>/dev/null || true

# --- 2. Remove ALB controller webhooks ---
echo ""
echo "Step 2: Removing ALB controller webhook configurations..."
kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook 2>/dev/null || true
kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook 2>/dev/null || true

# --- 3. Uninstall app charts (frontend first — its Ingress owns the ALB) ---
echo ""
echo "Step 3: Uninstalling application charts..."
helm uninstall frontend -n "$NAMESPACE" 2>/dev/null || echo "  (frontend not installed)"
helm uninstall worker   -n "$NAMESPACE" 2>/dev/null || echo "  (worker not installed)"
helm uninstall backend  -n "$NAMESPACE" 2>/dev/null || echo "  (backend not installed)"

# --- 4. Wait until ALL ALBs are deleted (app + Jenkins) ---
echo ""
echo "Step 4: Waiting for ALBs to be deleted (up to 3 minutes)..."
for i in $(seq 1 18); do
    ALBS=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query "LoadBalancers[?contains(LoadBalancerName, \`k8s\`)].LoadBalancerArn" \
        --output text 2>/dev/null || true)
    [ -z "$ALBS" ] && { echo "✅ All ALBs gone"; break; }
    echo "  ... ALB(s) still deleting (attempt $i/18)"
    sleep 10
done

# --- 5. Remove add-ons ---
echo ""
echo "Step 5: Uninstalling add-ons..."
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
helm uninstall metrics-server -n kube-system 2>/dev/null || true

# --- 6. Clean up Jenkins namespace ---
echo ""
echo "Step 6: Deleting Jenkins namespace..."
kubectl delete namespace jenkins --wait=false 2>/dev/null || true

# --- 7. Empty the S3 bucket, INCLUDING versioned objects ---
if [ -n "$S3_BUCKET" ]; then
    echo ""
    echo "Step 7: Emptying S3 bucket ${S3_BUCKET}..."
    aws s3 rm "s3://${S3_BUCKET}" --recursive 2>/dev/null || echo "  (bucket empty or missing — continuing)"
    VERSIONS=$(aws s3api list-object-versions --bucket "$S3_BUCKET" --output json \
        --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' 2>/dev/null || true)
    if [ -n "$VERSIONS" ] && [ "$VERSIONS" != "null" ] && ! echo "$VERSIONS" | grep -q '"Objects": null'; then
        aws s3api delete-objects --bucket "$S3_BUCKET" --delete "$VERSIONS" >/dev/null 2>&1 || true
    fi
fi

# --- 8. Terraform destroy, with orphan-ENI sweep + retry on failure ---
sweep_orphan_enis() {
    [ -z "$VPC_ID" ] && return 0
    echo "Sweeping orphaned network interfaces in ${VPC_ID}..."
    for ENI in $(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=status,Values=available" \
        --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>/dev/null); do
        echo "  deleting orphan ENI: $ENI"
        aws ec2 delete-network-interface --region "$AWS_REGION" --network-interface-id "$ENI" 2>/dev/null || true
    done
}

echo ""
echo "Step 8: terraform destroy (10-15 minutes)..."
if ! terraform destroy -auto-approve; then
    echo ""
    echo "⚠️  Destroy hit a snag (usually orphaned EKS network interfaces)."
    echo "    Sweeping and retrying once..."
    sweep_orphan_enis
    terraform destroy -auto-approve
fi

echo ""
echo "============================================"
echo "✅ Everything destroyed — back to \$0/hour"
echo "   Verify: aws eks list-clusters   (should be empty)"
echo "============================================"
