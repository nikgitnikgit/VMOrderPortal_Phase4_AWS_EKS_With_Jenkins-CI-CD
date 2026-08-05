#!/bin/bash
# scripts/create-cert.sh
#
# Creates a self-signed certificate and imports it into ACM so the ALB can
# serve HTTPS. Prints the certificate ARN on stdout (and nothing else, so it
# can be captured by the caller).
#
# WHY SELF-SIGNED: an ALB can only terminate TLS with an ACM certificate, and
# a publicly trusted ACM certificate requires a domain name you control. This
# project has no domain, so we generate one and import it. The result is a
# real TLS 1.3 listener with real encryption; the only difference from a
# public certificate is that browsers cannot verify the issuer, so they warn
# once. Registering a domain (~$12/year) would remove the warning; that is a
# cost decision, not a technical limitation, and is documented in the README.
#
# Idempotent: reuses the existing certificate if one is already imported.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_REGION=$(cd "$REPO_ROOT/terraform" && terraform output -raw aws_region)
CN="jenkins.vm-order.internal"

EXISTING=$(aws acm list-certificates --region "$AWS_REGION" \
    --query "CertificateSummaryList[?DomainName=='${CN}'].CertificateArn | [0]" \
    --output text 2>/dev/null)

if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
    echo "$EXISTING"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout "$WORK/tls.key" -out "$WORK/tls.crt" \
    -subj "/CN=${CN}/O=VM Order Portal/OU=DevOps Phase 4" \
    -addext "subjectAltName=DNS:${CN},DNS:*.elb.amazonaws.com" \
    2>/dev/null

ARN=$(aws acm import-certificate \
    --region "$AWS_REGION" \
    --certificate "fileb://${WORK}/tls.crt" \
    --private-key "fileb://${WORK}/tls.key" \
    --tags Key=Project,Value=vm-order Key=Purpose,Value=jenkins-ui \
    --query CertificateArn --output text)

echo "$ARN"
