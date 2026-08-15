#!/bin/bash
# scripts/install-jenkins.sh
#
# Installs Jenkins into the EKS cluster. Idempotent: safe to re-run.
#
# Runs AFTER `terraform apply`. Reads every environment-specific value from
# Terraform outputs, so nothing is hard-coded and a second contributor gets
# their own account's values automatically.
#
# Why a script and not Terraform's helm provider: both the helm and kubernetes
# providers need the cluster endpoint at provider-configuration time, but the
# cluster does not exist on the first apply. It appears to work on create and
# then breaks on destroy.
#
# Order: cluster add-ons -> app namespace + Secret -> Jenkins namespace, RBAC,
# ServiceAccounts, NetworkPolicy -> TLS cert -> agent image -> Jenkins.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/terraform"

# ---------------------------------------------------------------- outputs
CLUSTER_NAME=$(terraform output -raw cluster_name)
AWS_REGION=$(terraform output -raw aws_region)
VPC_ID=$(terraform output -raw vpc_id)
VPC_CIDR=$(terraform output -raw vpc_cidr)
ALB_ROLE_ARN=$(terraform output -raw alb_controller_role_arn)
CI_ROLE_ARN=$(terraform output -raw jenkins_ci_role_arn)
CD_ROLE_ARN=$(terraform output -raw jenkins_cd_role_arn)
ECR_REGISTRY=$(terraform output -raw ecr_registry)
NAMESPACE=$(terraform output -raw k8s_namespace)
RDS_ADDRESS=$(terraform output -raw rds_address)
SNS_TOPIC_ARN=$(terraform output -raw sns_topic_arn)
SES_SENDER=$(terraform output -raw ses_sender)

JENKINS_NODE_GROUP="${CLUSTER_NAME}-jenkins-nodes"
TOOLS_IMAGE="${ECR_REGISTRY}/vm-order-jenkins-agent:tools-1.1"
JENKINS_CHART_VERSION=$(tr -d '[:space:]' < "$REPO_ROOT/jenkins/CHART_VERSION")

echo "=================================================="
echo "  Installing Jenkins on ${CLUSTER_NAME}"
echo "  chart version: ${JENKINS_CHART_VERSION}"
echo "=================================================="

# ---------------------------------------------------- 1. connect kubectl
echo ""
echo "[1/8] Connecting kubectl..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
kubectl get nodes

# ------------------------------------------------ 2. app namespace + Secret
# The DB password is read from terraform.tfvars on THIS machine and never
# leaves it. Jenkins has no RBAC permission to read Secrets, so it deploys an
# application whose credentials it cannot see.
echo ""
echo "[2/8] Application namespace and Secret..."
# REVIEW FIX 2.3 — was:
#   DB_PASSWORD=$(grep -E '^\s*db_password' terraform.tfvars | cut -d'"' -f2)
# That silently returned the wrong value for a password containing a double
# quote, a single-quoted value, a heredoc, or a commented-out earlier line —
# and a wrong password fails later, at pod start, as an opaque auth error.
# Read it the same way as every other value in this script instead: from
# Terraform's own state, through the type system rather than through text.
DB_PASSWORD=$(terraform output -raw db_password)
[ -n "$DB_PASSWORD" ] || { echo "ERROR: db_password output is empty — is terraform.tfvars filled in?" >&2; exit 1; }

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" "kubernetes.io/metadata.name=${NAMESPACE}" --overwrite >/dev/null
# REVIEW FIX 2.2 — one shared "app-secrets" object was replaced by one Secret
# per workload. Previously both Deployments pulled the whole thing in via
# `envFrom: secretRef`, so the backend held SNS_TOPIC_ARN and SES_SENDER
# despite never touching SNS or SES.
#
# The gain is one-directional and worth stating plainly: the WORKER still needs
# all four values, because it emails the customer AND updates sns_sent/ses_sent
# on the order row. Only the backend's view actually narrows. That is still
# worth doing — a compromised backend pod no longer leaks the notification
# topic ARN (which embeds the account ID) or the verified sender address.
kubectl create secret generic backend-secrets \
    --namespace "$NAMESPACE" \
    --from-literal=DB_HOST="$RDS_ADDRESS" \
    --from-literal=DB_PASSWORD="$DB_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic worker-secrets \
    --namespace "$NAMESPACE" \
    --from-literal=DB_HOST="$RDS_ADDRESS" \
    --from-literal=DB_PASSWORD="$DB_PASSWORD" \
    --from-literal=SNS_TOPIC_ARN="$SNS_TOPIC_ARN" \
    --from-literal=SES_SENDER="$SES_SENDER" \
    --dry-run=client -o yaml | kubectl apply -f -

# Remove the old shared object if this is an upgrade of an existing cluster.
# Left in place it would keep the wide-open credentials readable by anything
# with get-secrets in this namespace, so the fix would be cosmetic.
# --ignore-not-found so a clean install does not fail here.
kubectl delete secret app-secrets --namespace "$NAMESPACE" --ignore-not-found

unset DB_PASSWORD

# ------------------------------------------------------- 3. cluster add-ons
echo ""
echo "[3/8] Cluster add-ons..."
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

# The chart regenerates its self-signed webhook CA on every upgrade, which
# updates the caBundle in the webhook configuration. Pods already running keep
# serving the OLD certificate, so the API server then rejects every
# Service/Ingress with "x509: certificate signed by unknown authority".
# Restarting forces the pods onto the current cert.
kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=300s
sleep 10   # let the webhook endpoints register

# Enable NetworkPolicy enforcement in the VPC CNI. Without this the policies
# in jenkins/networkpolicy.yaml exist but are not enforced.
echo "  enabling NetworkPolicy enforcement in the VPC CNI..."
kubectl set env daemonset aws-node -n kube-system ENABLE_NETWORK_POLICY=true >/dev/null
kubectl rollout status daemonset/aws-node -n kube-system --timeout=300s

# ------------------------------- 4. jenkins namespace, RBAC, ServiceAccounts
echo ""
echo "[4/8] Jenkins namespace, RBAC and ServiceAccounts..."
kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace jenkins "kubernetes.io/metadata.name=jenkins" --overwrite >/dev/null
kubectl apply -f "$REPO_ROOT/jenkins/rbac.yaml"

# IRSA annotations carry the account ID, so they are applied here from
# Terraform outputs rather than hard-coded into rbac.yaml.
kubectl annotate serviceaccount jenkins-agent-ci -n jenkins \
    "eks.amazonaws.com/role-arn=${CI_ROLE_ARN}" --overwrite
kubectl annotate serviceaccount jenkins-agent-cd -n jenkins \
    "eks.amazonaws.com/role-arn=${CD_ROLE_ARN}" --overwrite

# The policy file is a template: the VPC CIDR differs per environment and
# hardcoding it silently blocks ALB traffic (504s with healthy pods).
#
# Guard against an empty substitution. default-deny-all contains no CIDR, so it
# applies successfully even when the allow rules are rejected as invalid — the
# result is a namespace that denies everything with no way back in. Refuse to
# apply anything unless the value is present and looks like a CIDR.
if [ -z "$VPC_CIDR" ] || ! echo "$VPC_CIDR" | grep -qE '^[0-9.]+/[0-9]+$'; then
    echo "ERROR: vpc_cidr is '${VPC_CIDR}', which is not a CIDR." >&2
    echo "Run 'terraform apply' so the output exists, then re-run this script." >&2
    exit 1
fi

# Render first, validate server-side, and only then apply — so a rejected
# allow rule can never leave default-deny in place on its own.
RENDERED=$(sed "s|__VPC_CIDR__|${VPC_CIDR}|g" "$REPO_ROOT/jenkins/networkpolicy.yaml")
if ! echo "$RENDERED" | kubectl apply --dry-run=server -f - >/dev/null; then
    echo "ERROR: NetworkPolicy manifests are invalid; nothing applied." >&2
    exit 1
fi
echo "$RENDERED" | kubectl apply -f -

# ------------------------------------------------------ 5. TLS certificate
echo ""
echo "[5/8] TLS certificate for the Jenkins Ingress..."
CERT_ARN=$("$REPO_ROOT/scripts/create-cert.sh")
echo "  certificate: ${CERT_ARN}"

# ------------------------------------------------- 6. build the agent image
echo ""
echo "[6/8] Agent tools image..."
if aws ecr describe-images --repository-name "vm-order-jenkins-agent" \
     --image-ids imageTag="tools-1.1" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "  already in ECR — skipping build"
    echo "  (bump the tag in this script after editing agent-tools/Dockerfile)"
else
    aws ecr get-login-password --region "$AWS_REGION" \
        | docker login --username AWS --password-stdin "$ECR_REGISTRY"
    docker build -f "$REPO_ROOT/jenkins/agent-tools/Dockerfile" \
        -t "$TOOLS_IMAGE" "$REPO_ROOT/jenkins/agent-tools"

    # The spec requires agent and controller images to be scanned.
    #
    # --ignore-unfixed is deliberate, not a workaround. A Debian base image
    # always carries CRITICALs with no patched version in existence (perl,
    # zlib and sqlite3 are marked "affected", "fix_deferred" or
    # "will_not_fix"). Failing on those means the gate can NEVER pass, and the
    # usual outcome is that someone disables scanning altogether. We fail on
    # anything that HAS a fix, and record the rest in the report.
    echo "  scanning agent image..."
    if command -v trivy >/dev/null 2>&1; then
        trivy image --severity CRITICAL --ignore-unfixed --exit-code 1 \
            --no-progress "$TOOLS_IMAGE"
    else
        docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
            aquasec/trivy:0.58.2 image --severity CRITICAL --ignore-unfixed \
            --exit-code 1 --no-progress "$TOOLS_IMAGE"
    fi

    docker push "$TOOLS_IMAGE"
    echo "  pushed and scanned"
fi

# ------------------------------------------------------- 7. install Jenkins
echo ""
echo "[7/8] Installing Jenkins..."
if ! helm search repo "jenkins/jenkins" --version "$JENKINS_CHART_VERSION" 2>/dev/null \
        | grep -q "$JENKINS_CHART_VERSION"; then
    echo "ERROR: chart version '${JENKINS_CHART_VERSION}' not found." >&2
    echo "Pick a current one and write it to jenkins/CHART_VERSION:" >&2
    helm search repo jenkins/jenkins --versions 2>/dev/null | head -6 >&2
    exit 1
fi

# configure-jenkins.sh generates the environment-specific overrides.
OVERRIDES=$("$REPO_ROOT/scripts/configure-jenkins.sh" \
    --print-file \
    --cert-arn "$CERT_ARN" \
    --tools-image "$TOOLS_IMAGE" \
    --node-group "$JENKINS_NODE_GROUP")

helm upgrade --install jenkins jenkins/jenkins \
    --namespace jenkins \
    --version "$JENKINS_CHART_VERSION" \
    -f "$REPO_ROOT/jenkins/values.yaml" \
    -f "$OVERRIDES"
rm -f "$OVERRIDES"

echo "  waiting for Jenkins (first boot installs plugins — 3-6 min)..."
kubectl rollout status statefulset/jenkins -n jenkins --timeout=900s

# ----------------------------------------------------------- 8. access info
echo ""
echo "[8/8] Waiting for the Jenkins ALB..."
JENKINS_HOST=""
for i in $(seq 1 36); do
    JENKINS_HOST=$(kubectl get ingress jenkins -n jenkins \
        -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>/dev/null || true)
    [ -n "$JENKINS_HOST" ] && break
    echo "  ... not ready yet ($i/36)"
    sleep 10
done

JENKINS_PASS=$(kubectl get secret jenkins -n jenkins \
    -o jsonpath="{.data.jenkins-admin-password}" | base64 -d)

echo ""
echo "=================================================="
echo "Jenkins installed."
echo ""
echo "  URL:      https://${JENKINS_HOST:-<pending>}"
echo "  User:     admin"
echo "  Password: ${JENKINS_PASS}"
echo ""
echo "  The certificate is self-signed, so the browser will warn once."
echo "  Access is restricted to your current public IP."
echo ""
echo "Next:  ./scripts/create-jobs.sh     # create the two jobs"
echo "       ./scripts/verify-jenkins.sh  # assert the install is correct"
echo "=================================================="
