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
BACKEND_ROLE_ARN=$(terraform output -raw backend_irsa_role_arn)
WORKER_ROLE_ARN=$(terraform output -raw worker_irsa_role_arn)
NOTIFICATION_EMAIL=$(terraform output -raw notification_email)
SES_SENDER=$(terraform output -raw ses_sender)

[ -n "$NODE_GROUP" ]  || NODE_GROUP="${CLUSTER_NAME}-jenkins-nodes"
[ -n "$TOOLS_IMAGE" ] || TOOLS_IMAGE="${ECR_REGISTRY}/vm-order-jenkins-agent:tools-1.1"
if [ -z "$CERT_ARN" ]; then
    CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" \
        --query "CertificateSummaryList[?DomainName=='jenkins.vm-order.internal'].CertificateArn | [0]" \
        --output text)
    [ "$CERT_ARN" = "None" ] && { echo "ERROR: no certificate found; run scripts/create-cert.sh" >&2; exit 1; }
fi

# Your public IP, detected now rather than committed to Git. Re-running this
# script after your ISP reassigns your address restores access in ~1 minute.
MY_IP=$(curl -s https://checkip.amazonaws.com)

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
      alb.ingress.kubernetes.io/inbound-cidrs: "${MY_IP}/32"
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
                  - key: GITHUB_REPO_URL
                    value: "${GITHUB_REPO_URL}"
                  - key: NOTIFICATION_EMAIL
                    value: "${NOTIFICATION_EMAIL}"
      # Email notifications (bonus). SES SMTP credentials are supplied as a
      # Kubernetes Secret by create-smtp-secret.sh, never stored in Git.
      mail: |
        unclassified:
          # NOTE: adminAddress does NOT belong here. The mailer plugin
          # deprecated it and JCasC now refuses to start with
          # "Failed to configure 'mailer': 'adminAddress' is deprecated".
          # The admin address moved to unclassified.location, below.
          mailer:
            smtpHost: "email-smtp.${AWS_REGION}.amazonaws.com"
            smtpPort: "587"
            useTls: true
            charset: "UTF-8"
            replyToAddress: "${SES_SENDER}"
          location:
            adminAddress: "${SES_SENDER}"
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
