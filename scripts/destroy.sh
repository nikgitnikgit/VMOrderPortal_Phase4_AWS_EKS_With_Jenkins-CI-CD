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
"$REPO_ROOT/scripts/uninstall-jenkins.sh" || echo "  (jenkins not installed)"

# --- 2. Remove ALB controller webhooks ---
echo ""
echo "Step 2: Removing ALB controller webhook configurations..."
kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook 2>/dev/null || true
kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook 2>/dev/null || true

# --- 3. Uninstall app charts (frontend first — its Ingress owns the ALB) ---
# HELM_DRIVER=configmap ONLY for these three: the pipeline installed them with
# the configmap driver (so Jenkins never needed secrets access). With the
# default driver Helm would report "release: not found" and leave them running.
# The add-ons above/below were installed from this machine with the default
# driver, so they must NOT get this variable.
echo ""
echo "Step 3: Uninstalling application charts..."
HELM_DRIVER=configmap helm uninstall frontend -n "$NAMESPACE" 2>/dev/null || echo "  (frontend not installed)"
HELM_DRIVER=configmap helm uninstall worker   -n "$NAMESPACE" 2>/dev/null || echo "  (worker not installed)"
HELM_DRIVER=configmap helm uninstall backend  -n "$NAMESPACE" 2>/dev/null || echo "  (backend not installed)"

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

# The ALB controller creates security groups (k8s-traffic-*, k8s-<ns>-<ing>-*)
# that Terraform does not know about. Deleting the ALB does not always remove
# them, and a VPC cannot be deleted while non-default security groups remain —
# so terraform destroy hangs on the VPC for 10+ minutes with no useful error.
sweep_orphan_sgs() {
    [ -z "$VPC_ID" ] && return 0
    echo "Sweeping orphaned k8s security groups in ${VPC_ID}..."
    SGS=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null)
    [ -z "$SGS" ] && { echo "  none found"; return 0; }

    # Strip rules first: these groups reference each other, so a straight
    # delete fails with DependencyViolation.
    for SG in $SGS; do
        IN=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$SG" \
            --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)
        EG=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$SG" \
            --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)
        if [ -n "$IN" ] && [ "$IN" != "[]" ]; then
            aws ec2 revoke-security-group-ingress --region "$AWS_REGION" \
                --group-id "$SG" --ip-permissions "$IN" >/dev/null 2>&1 || true
        fi
        if [ -n "$EG" ] && [ "$EG" != "[]" ]; then
            aws ec2 revoke-security-group-egress --region "$AWS_REGION" \
                --group-id "$SG" --ip-permissions "$EG" >/dev/null 2>&1 || true
        fi
    done

    for SG in $SGS; do
        echo "  deleting orphan SG: $SG"
        aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$SG" 2>/dev/null || true
    done
}

# Clear ALB-controller security groups BEFORE destroy, not just on retry:
# they are the most common reason the VPC delete stalls for 10+ minutes.
echo ""
echo "Step 8: Sweeping ALB-controller leftovers..."
sweep_orphan_sgs

echo ""
echo "Step 9: terraform destroy (10-15 minutes)..."
if ! terraform destroy -auto-approve; then
    echo ""
    echo "⚠️  Destroy hit a snag (usually orphaned EKS network interfaces)."
    echo "    Sweeping and retrying once..."
    sweep_orphan_enis
    sweep_orphan_sgs
    terraform destroy -auto-approve
fi

echo ""
echo "============================================"
echo "✅ Everything destroyed — back to \$0/hour"
echo "   Verify: aws eks list-clusters   (should be empty)"
echo "============================================"
