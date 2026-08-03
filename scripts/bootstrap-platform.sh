#!/bin/bash
# scripts/bootstrap-platform.sh — Phase 4 platform layer
# Runs AFTER terraform apply, on YOUR machine. Creates the app namespace and
# Secret, installs cluster add-ons, and installs Jenkins fully configured
# via JCasC — no UI clicking.
#
# Why this is a script and not Terraform's kubernetes/helm providers:
#   Both providers need the cluster endpoint at provider-configuration time,
#   but the cluster does not exist on the first apply. It appears to work on
#   create and then breaks on destroy. (See cookbook section 5.1)
#
# Security note: the DB password passes through THIS script, which runs on
# your trusted machine. Jenkins never receives it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/terraform"

# --- Read Terraform outputs ---
CLUSTER_NAME=$(terraform output -raw cluster_name)
AWS_REGION=$(terraform output -raw aws_region)
VPC_ID=$(terraform output -raw vpc_id)
ALB_ROLE_ARN=$(terraform output -raw alb_controller_role_arn)
JENKINS_AGENT_ROLE_ARN=$(terraform output -raw jenkins_agent_role_arn)
BACKEND_ROLE_ARN=$(terraform output -raw backend_irsa_role_arn)
WORKER_ROLE_ARN=$(terraform output -raw worker_irsa_role_arn)
ECR_REGISTRY=$(terraform output -raw ecr_registry)
GITHUB_REPO_URL=$(terraform output -raw github_repo_url)
NAMESPACE=$(terraform output -raw k8s_namespace)
S3_BUCKET=$(terraform output -raw s3_bucket_name)
RDS_ADDRESS=$(terraform output -raw rds_address)
SNS_TOPIC_ARN=$(terraform output -raw sns_topic_arn)
SES_SENDER=$(terraform output -raw ses_sender)

JENKINS_NODE_GROUP="${CLUSTER_NAME}-jenkins-nodes"
TOOLS_IMAGE="${ECR_REGISTRY}/vm-order-jenkins-agent:tools-1.0"

echo "============================================"
echo "  VM Order Portal — Phase 4 Platform Bootstrap"
echo "============================================"

# --- 1. Connect kubectl ---
echo ""
echo "Step 1: Connecting kubectl to ${CLUSTER_NAME}..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
kubectl get nodes

# --- 2. App namespace + Secret ---
# The DB password is read from terraform.tfvars on THIS machine and never
# leaves it. Jenkins has no RBAC permission to read Secrets, so it deploys
# an application whose credentials it cannot see.
echo ""
echo "Step 2: Creating namespace and app Secret..."
DB_PASSWORD=$(grep -E '^\s*db_password' terraform.tfvars | cut -d'"' -f2)
if [ -z "$DB_PASSWORD" ]; then
    echo "ERROR: could not read db_password from terraform/terraform.tfvars" >&2
    exit 1
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic app-secrets \
    --namespace "$NAMESPACE" \
    --from-literal=DB_HOST="$RDS_ADDRESS" \
    --from-literal=DB_PASSWORD="$DB_PASSWORD" \
    --from-literal=SNS_TOPIC_ARN="$SNS_TOPIC_ARN" \
    --from-literal=SES_SENDER="$SES_SENDER" \
    --dry-run=client -o yaml | kubectl apply -f -
unset DB_PASSWORD

# --- 3. Cluster add-ons ---
echo ""
echo "Step 3: Installing cluster add-ons..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo add jenkins https://charts.jenkins.io 2>/dev/null || true
helm repo update

helm upgrade --install metrics-server metrics-server/metrics-server \
    --namespace kube-system

ALB_VERSION=$(cat "$REPO_ROOT/terraform/modules/irsa/ALB_CONTROLLER_VERSION")
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --version "$ALB_VERSION" \
    --namespace kube-system \
    --set clusterName="$CLUSTER_NAME" \
    --set region="$AWS_REGION" \
    --set vpcId="$VPC_ID" \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ALB_ROLE_ARN"

echo "Waiting for the load balancer controller..."
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=180s

# --- 4. Jenkins namespace, RBAC, agent ServiceAccount ---
echo ""
echo "Step 4: Jenkins namespace, RBAC and agent ServiceAccount..."
kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$REPO_ROOT/jenkins/rbac.yaml"

kubectl create serviceaccount jenkins-agent -n jenkins \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount jenkins-agent -n jenkins \
    "eks.amazonaws.com/role-arn=${JENKINS_AGENT_ROLE_ARN}" --overwrite

# --- 5. Build and push the agent-tools image ---
echo ""
echo "Step 5: Building agent-tools image..."
if aws ecr describe-images --repository-name "vm-order-jenkins-agent" \
     --image-ids imageTag="tools-1.0" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "  Already in ECR — skipping build."
else
    aws ecr get-login-password --region "$AWS_REGION" \
        | docker login --username AWS --password-stdin "$ECR_REGISTRY"
    docker build -f "$REPO_ROOT/jenkins/agent-tools/Dockerfile" \
        -t "$TOOLS_IMAGE" "$REPO_ROOT/jenkins/agent-tools"
    docker push "$TOOLS_IMAGE"
    echo "  agent-tools pushed to ECR"
fi

# --- 6. Install Jenkins ---
echo ""
echo "Step 6: Installing Jenkins (chart pinned)..."
JENKINS_CHART_VERSION="5.7.14"   # PINNED — same lesson as the ALB controller

MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "  Restricting Jenkins ALB to your IP: ${MY_IP}/32"

# Generated overrides go in a real values file, not --set-string. Helm's
# --set parser splits on commas and mangles multi-line YAML; a file does not.
OVERRIDES=$(mktemp)
trap 'rm -f "$OVERRIDES"' EXIT
cat > "$OVERRIDES" <<EOF
controller:
  nodeSelector:
    eks.amazonaws.com/nodegroup: "${JENKINS_NODE_GROUP}"
  ingress:
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/healthcheck-path: /login
      alb.ingress.kubernetes.io/inbound-cidrs: "${MY_IP}/32"
  JCasC:
    configScripts:
      env: |
        jenkins:
          globalNodeProperties:
            - envVars:
                env:
                  - key: AWS_REGION
                    value: "${AWS_REGION}"
                  - key: ECR_REGISTRY
                    value: "${ECR_REGISTRY}"
                  - key: AGENT_TOOLS_IMAGE
                    value: "${TOOLS_IMAGE}"
                  - key: JENKINS_NODE_GROUP
                    value: "${JENKINS_NODE_GROUP}"
                  - key: BACKEND_ROLE_ARN
                    value: "${BACKEND_ROLE_ARN}"
                  - key: WORKER_ROLE_ARN
                    value: "${WORKER_ROLE_ARN}"
                  - key: S3_BUCKET
                    value: "${S3_BUCKET}"
      job: |
        jobs:
          - script: >
              pipelineJob('vm-order-cicd') {
                definition {
                  cpsScm {
                    scm {
                      git {
                        remote { url('${GITHUB_REPO_URL}') }
                        branches('*/main')
                      }
                    }
                    scriptPath('Jenkinsfile')
                  }
                }
              }
EOF

helm upgrade --install jenkins jenkins/jenkins \
    --namespace jenkins \
    --version "$JENKINS_CHART_VERSION" \
    -f "$REPO_ROOT/jenkins/values.yaml" \
    -f "$OVERRIDES"

echo "Waiting for Jenkins to start (first boot installs plugins — ~3 min)..."
kubectl rollout status statefulset/jenkins -n jenkins --timeout=600s

# --- 7. Wait for the ALB and print access info ---
echo ""
echo "Waiting for Jenkins ALB address (can take 2-3 minutes)..."
JENKINS_URL=""
for i in $(seq 1 30); do
    JENKINS_URL=$(kubectl get ingress -n jenkins \
        -o jsonpath="{.items[0].status.loadBalancer.ingress[0].hostname}" 2>/dev/null || true)
    [ -n "$JENKINS_URL" ] && break
    echo "  ... not ready yet (attempt $i/30)"
    sleep 10
done

JENKINS_PASS=$(kubectl get secret jenkins -n jenkins \
    -o jsonpath="{.data.jenkins-admin-password}" | base64 -d)

echo ""
echo "============================================"
echo "Platform bootstrap complete."
echo ""
echo "Jenkins:"
echo "  URL:      http://${JENKINS_URL:-<pending, run: kubectl get ingress -n jenkins>}"
echo "  User:     admin"
echo "  Password: ${JENKINS_PASS}"
echo ""
echo "Next: open the URL -> click 'vm-order-cicd' -> Build"
echo "============================================"
