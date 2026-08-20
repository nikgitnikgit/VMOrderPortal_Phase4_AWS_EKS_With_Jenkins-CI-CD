#!/bin/bash
# scripts/configure-jenkins.sh
#
# Generates the environment-specific Jenkins configuration: the JCasC global
# environment variables, the node selector, the TLS certificate ARN and the
# IP restriction on the Ingress.
#
# Two modes:
#   (default)      apply the configuration to a running Jenkins via helm upgrade
#   --print-file   write the overrides to a temp file and print its path, for
#                  install-jenkins.sh to pass to its own helm invocation
#
# Everything here comes from Terraform outputs or is detected at run time.
# Nothing environment-specific is committed to Git.
#
# Why generated overrides rather than `helm --set`: Helm's --set parser splits
# on commas and mangles multi-line YAML, which the JCasC blocks are full of.
# A real values file does not have that problem.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PRINT_ONLY=false
CERT_ARN=""
TOOLS_IMAGE=""
NODE_GROUP=""

while [ $# -gt 0 ]; do
    case "$1" in
        --print-file)   PRINT_ONLY=true; shift ;;
        --cert-arn)     CERT_ARN="$2"; shift 2 ;;
        --tools-image)  TOOLS_IMAGE="$2"; shift 2 ;;
        --node-group)   NODE_GROUP="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

cd "$REPO_ROOT/terraform"

CLUSTER_NAME=$(terraform output -raw cluster_name)
AWS_REGION=$(terraform output -raw aws_region)
ECR_REGISTRY=$(terraform output -raw ecr_registry)
GITHUB_REPO_URL=$(terraform output -raw github_repo_url)
S3_BUCKET=$(terraform output -raw s3_bucket_name)
VPC_CIDR=$(terraform output -raw vpc_cidr)
# REVIEW FIX 4.6 — `-raw` cannot render a list, so read it as JSON and join it
# with commas. Helm's --set list syntax is {a,b}, which Jenkinsfile-cd builds
# from this. jq is present in the agent image (see jenkins/agent-tools).
DB_SUBNET_CIDRS=$(terraform output -json db_subnet_cidrs | tr -d '[]" ' )
BACKEND_ROLE_ARN=$(terraform output -raw backend_irsa_role_arn)
WORKER_ROLE_ARN=$(terraform output -raw worker_irsa_role_arn)
NOTIFICATION_EMAIL=$(terraform output -raw notification_email)
SNS_TOPIC_ARN=$(terraform output -raw sns_topic_arn)

[ -n "$NODE_GROUP" ]  || NODE_GROUP="${CLUSTER_NAME}-jenkins-nodes"
[ -n "$TOOLS_IMAGE" ] || TOOLS_IMAGE="${ECR_REGISTRY}/vm-order-jenkins-agent:tools-1.1"
if [ -z "$CERT_ARN" ]; then
    CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" \
        --query "CertificateSummaryList[?DomainName=='jenkins.vm-order.internal'].CertificateArn | [0]" \
        --output text)
    [ "$CERT_ARN" = "None" ] && { echo "ERROR: no Jenkins certificate; run scripts/create-cert.sh" >&2; exit 1; }
fi

# The application ALB gets its OWN certificate, not the Jenkins one.
# Jenkins is the admin plane, restricted to one operator IP and holding cluster
# access; the app is on the public internet. Sharing a private key between them
# means a compromise in either context is a compromise in both, and it couples
# two rotation schedules that have no reason to be linked.
#
# Empty is tolerated: helm/frontend falls back to an HTTP-only listener, so a
# cluster without an app certificate still deploys rather than failing with an
# opaque ALB error.
APP_CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" \
    --query "CertificateSummaryList[?DomainName=='app.vm-order.internal'].CertificateArn | [0]" \
    --output text 2>/dev/null || true)
[ "$APP_CERT_ARN" = "None" ] && APP_CERT_ARN=""
if [ -z "$APP_CERT_ARN" ]; then
    echo "  NOTE: no app certificate found — the app ALB will serve HTTP only." >&2
    echo "        Run: ./scripts/create-cert.sh --purpose app" >&2
fi

# Your public IP, detected now rather than committed to Git. Re-running this
# script after your ISP reassigns your address restores access in ~1 minute.
MY_IP=$(curl -s https://checkip.amazonaws.com)

# GitHub's webhook senders have to reach the ALB too, or the hook is created and
# never delivers. The allowlist was MY_IP/32 alone, so GitHub's POST was dropped
# at the security group: register-webhook.sh reported
# "last response: connection_error" and CI silently fell back to the 5-minute
# poll. The IP restriction that satisfies the security requirement was quietly
# breaking the webhook requirement.
#
# Fetched at run time rather than hardcoded: GitHub rotates these ranges and
# publishes the current set at /meta. IPv6 entries are FILTERED OUT --
# inbound-cidrs takes IPv4 only (IPv6 belongs in inbound-ipv6-cidrs) and the AWS
# Load Balancer Controller rejects the whole Ingress if they are mixed, which
# would leave the security group stale and lock you out with no obvious error.
#
# This widens access from one address to GitHub's ranges, which can reach the
# login page and /github-webhook/ only. inbound-cidrs is a security-group rule,
# so it cannot be scoped to a single path. Still closed to the world: see T15.11.
GITHUB_HOOK_CIDRS=$(curl -s https://api.github.com/meta \
    | jq -r '.hooks[] | select(test(":") | not)' 2>/dev/null | paste -sd, - || true)
if [ -z "$GITHUB_HOOK_CIDRS" ]; then
    echo "  WARNING: could not fetch GitHub webhook ranges from api.github.com/meta." >&2
    echo "           The webhook will NOT deliver; CI falls back to the 5-minute poll." >&2
    ALLOWED_CIDRS="${MY_IP}/32"
else
    ALLOWED_CIDRS="${MY_IP}/32,${GITHUB_HOOK_CIDRS}"
fi

OVERRIDES=$(mktemp /tmp/jenkins-overrides-XXXXXX.yaml)

cat > "$OVERRIDES" <<EOF
controller:
  nodeSelector:
    eks.amazonaws.com/nodegroup: "${NODE_GROUP}"
  ingress:
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/healthcheck-path: /login
      alb.ingress.kubernetes.io/inbound-cidrs: "${ALLOWED_CIDRS}"
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443},{"HTTP":80}]'
      alb.ingress.kubernetes.io/certificate-arn: "${CERT_ARN}"
      alb.ingress.kubernetes.io/ssl-redirect: "443"
      alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
  JCasC:
    configScripts:
      # Only keys the chart does not already own may appear here. Anything the
      # chart also sets (numExecutors, securityRealm, authorizationStrategy,
      # clouds) causes ConfiguratorConflictException and Jenkins refuses to
      # start.
      env: |
        jenkins:
          globalNodeProperties:
            - envVars:
                env:
                  - key: AWS_REGION
                    value: "${AWS_REGION}"
                  - key: CLUSTER_NAME
                    value: "${CLUSTER_NAME}"
                  - key: ECR_REGISTRY
                    value: "${ECR_REGISTRY}"
                  - key: AGENT_TOOLS_IMAGE
                    value: "${TOOLS_IMAGE}"
                  - key: JENKINS_NODE_GROUP
                    value: "${NODE_GROUP}"
                  - key: BACKEND_ROLE_ARN
                    value: "${BACKEND_ROLE_ARN}"
                  - key: WORKER_ROLE_ARN
                    value: "${WORKER_ROLE_ARN}"
                  - key: S3_BUCKET
                    value: "${S3_BUCKET}"
                  - key: VPC_CIDR
                    value: "${VPC_CIDR}"
                  - key: DB_SUBNET_CIDRS
                    value: "${DB_SUBNET_CIDRS}"
                  # REVIEW FIX 4.4 — the same ACM certificate that fronts
                  # Jenkins also fronts the application ALB. Jenkinsfile-cd
                  # passes it to the frontend chart; empty means HTTP only.
                  - key: APP_CERT_ARN
                    value: "${APP_CERT_ARN:-}"
                  - key: GITHUB_REPO_URL
                    value: "${GITHUB_REPO_URL}"
                  - key: NOTIFICATION_EMAIL
                    value: "${NOTIFICATION_EMAIL}"
                  # Build notifications (bonus) go to this SNS topic, which
                  # already carries the email subscription. See the notify()
                  # helper at the foot of both Jenkinsfiles for why this
                  # replaced SES SMTP: the mailer needed port 587, which the
                  # jenkins-controller NetworkPolicy has never permitted (only
                  # 443 leaves the controller), and it had no credential
                  # either — the create-smtp-secret.sh once referenced here
                  # does not exist, and Terraform creates no SES resources.
                  # Every send failed with "SMTP connection error" while the
                  # stage stayed green, because email-ext does not fail a
                  # build over a delivery failure.
                  #
                  # SNS needs no SMTP username or password at all: the agents
                  # publish over HTTPS 443 authorised by IRSA, which is what
                  # the bonus asks for — notifications without exposing
                  # secrets.
                  - key: SNS_TOPIC_ARN
                    value: "${SNS_TOPIC_ARN}"
      # The two jobs, defined as code via Job DSL. The seed script lives in
      # jenkins/jobs/ so it can be reviewed like any other source file.
      jobs: |
        jobs:
          # MUST be a literal block scalar, never a folded one. Folding joins
          # every line with a space, collapsing the whole Groovy file onto one
          # line -- at which point the first slash-slash comment hides all the
          # code after it and the script fails to compile.
          - script: |
$(sed -e "s|__GITHUB_REPO_URL__|${GITHUB_REPO_URL}|g" \
       -e 's/^/              /' "$REPO_ROOT/jenkins/jobs/seed.groovy")
EOF

if [ "$PRINT_ONLY" = true ]; then
    echo "$OVERRIDES"
    exit 0
fi

echo "Applying configuration to the running Jenkins..."
echo "  cluster    : ${CLUSTER_NAME}"
echo "  node group : ${NODE_GROUP}"
echo "  your IP    : ${MY_IP}/32"
echo "  allowlist  : ${ALLOWED_CIDRS}"
echo "  certificate: ${CERT_ARN}"
echo "  notify     : ${NOTIFICATION_EMAIL}"

JENKINS_CHART_VERSION=$(tr -d '[:space:]' < "$REPO_ROOT/jenkins/CHART_VERSION")
helm upgrade jenkins jenkins/jenkins \
    --namespace jenkins \
    --version "$JENKINS_CHART_VERSION" \
    -f "$REPO_ROOT/jenkins/values.yaml" \
    -f "$OVERRIDES" \
    --reuse-values

rm -f "$OVERRIDES"

echo "Waiting for the config-reload sidecar to pick up the change..."
sleep 15
echo "Done. JCasC configuration applied."
