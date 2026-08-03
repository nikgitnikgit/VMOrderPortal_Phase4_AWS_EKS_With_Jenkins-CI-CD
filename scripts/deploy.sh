#!/bin/bash
# scripts/deploy.sh
# Phase 4 deployment: terraform (infrastructure) + bootstrap (platform).
# The APPLICATION is deployed by Jenkins, not by this script.
#
# Order:
#   1. terraform apply  — VPC, EKS, RDS, S3, SNS, ECR, IRSA, app Secret
#   2. bootstrap-platform.sh — add-ons, RBAC, Jenkins
#   3. You open Jenkins and click Build (or it polls SCM)
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "============================================"
echo "  VM Order Portal — Phase 4 Deploy"
echo "============================================"

# --- Step 1: Infrastructure (~15-20 min — EKS control plane is slow) ---
echo ""
echo "Step 1: terraform apply (EKS takes 15-20 minutes — this is normal)..."
cd "$REPO_ROOT/terraform"
terraform init -input=false
terraform apply -auto-approve

# --- Step 2: Platform layer (add-ons + Jenkins) ---
echo ""
echo "Step 2: Bootstrapping platform layer..."
cd "$REPO_ROOT"
./scripts/bootstrap-platform.sh

echo ""
echo "============================================"
echo "✅ Infrastructure + platform ready!"
echo "   Open Jenkins and run the pipeline to deploy the application."
echo "============================================"
