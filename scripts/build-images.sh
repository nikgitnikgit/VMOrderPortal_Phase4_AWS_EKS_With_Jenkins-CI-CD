#!/bin/bash
# scripts/build-images.sh
# Builds all three service images, scans them with Trivy (bonus),
# and pushes them to ECR.
#
# Prerequisites:
#   - Docker running locally
#   - AWS CLI configured
#   - ECR repositories already created (run terraform apply first —
#     our deploy.sh does everything in the right order)
#
# Usage:  ./scripts/build-images.sh [VERSION]
#         VERSION defaults to 1.0.0. Bump it on every image change —
#         ECR repos are IMMUTABLE, a used tag cannot be overwritten.
set -e

VERSION="${1:-1.0.0}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SERVICES="frontend backend worker"

# Resolve repo root so the script works from any directory
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "============================================"
echo "  Build & Push Images — version ${VERSION}"
echo "  Registry: ${ECR_REGISTRY}"
echo "============================================"

# --- 1. Login: authenticate local Docker to the private ECR registry ---
echo ""
echo "Step 1: Docker login to ECR..."
aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# --- 2. Build / scan / push each service ---
for SVC in $SERVICES; do
    LOCAL_TAG="vm-order-${SVC}:${VERSION}"
    REMOTE_TAG="${ECR_REGISTRY}/vm-order-${SVC}:${VERSION}"

    echo ""
    echo "--------------------------------------------"
    echo "  ${SVC}"
    echo "--------------------------------------------"

    # Verify the ECR repository exists (created by Terraform)
    if ! aws ecr describe-repositories --repository-names "vm-order-${SVC}" \
         --region "$AWS_REGION" >/dev/null 2>&1; then
        echo "❌ ECR repository vm-order-${SVC} not found."
        echo "   Run 'terraform apply' first (or ./scripts/deploy.sh which does it all)."
        exit 1
    fi

    # Build from the REPO ROOT so Dockerfiles can COPY from app/
    echo "Building ${LOCAL_TAG}..."
    docker build -f "docker/${SVC}/Dockerfile" -t "$LOCAL_TAG" .

    # Bonus: Trivy vulnerability scan (report saved as submission evidence)
    if command -v trivy >/dev/null 2>&1; then
        echo "Scanning ${LOCAL_TAG} with Trivy (HIGH/CRITICAL)..."
        mkdir -p docs
        trivy image --severity HIGH,CRITICAL --format table "$LOCAL_TAG" \
            | tee -a "docs/trivy-report-${VERSION}.txt"
    else
        echo "⚠️  Trivy not installed — skipping scan."
        echo "   Install: sudo apt install trivy  (or see aquasecurity.github.io/trivy)"
    fi

    # Skip push if this exact immutable tag already exists in ECR
    if aws ecr describe-images --repository-name "vm-order-${SVC}" \
         --image-ids imageTag="$VERSION" --region "$AWS_REGION" >/dev/null 2>&1; then
        echo "⚠️  Tag ${VERSION} already exists in ECR (immutable) — skipping push."
        echo "   Changed the code? Re-run with a new version: ./scripts/build-images.sh 1.0.1"
        continue
    fi

    echo "Pushing ${REMOTE_TAG}..."
    docker tag "$LOCAL_TAG" "$REMOTE_TAG"
    docker push "$REMOTE_TAG"
    echo "✅ ${SVC} pushed"
done

echo ""
echo "============================================"
echo "✅ All images built and pushed (version ${VERSION})"
echo "   Deploy them with: helm upgrade --install ... --set image.tag=${VERSION}"
echo "============================================"
