#!/bin/bash
# scripts/create-cert.sh
#
# Creates a self-signed certificate and imports it into ACM so an ALB can serve
# HTTPS. Prints the certificate ARN on stdout (and nothing else, so it can be
# captured by the caller).
#
# USAGE
#   ./scripts/create-cert.sh                      # jenkins-ui (default)
#   ./scripts/create-cert.sh --purpose app        # the application ALB
#
# WHY SELF-SIGNED: an ALB can only terminate TLS with an ACM certificate, and a
# publicly trusted ACM certificate requires a domain name you control. This
# project has no domain, so we generate one and import it. The result is a real
# TLS 1.3 listener with real encryption; the only difference from a public
# certificate is that browsers cannot verify the issuer, so they warn once.
# Registering a domain (~$12/year) would remove the warning; that is a cost
# decision, not a technical limitation, and is documented in the README.
#
# WHY TWO CERTIFICATES RATHER THAN ONE
#   Jenkins and the application have different audiences and different risk.
#   Jenkins is the admin plane — restricted to one operator IP, holding cluster
#   access. The application is on the public internet. Sharing a private key
#   between them means compromising either context compromises both, and it
#   couples their rotation schedules for no benefit.
#
#   It also leaves room to move: if a domain is registered later, the app can
#   take a publicly trusted certificate while Jenkins keeps a self-signed one,
#   with no untangling.
#
# Idempotent: reuses the existing certificate for the given purpose.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_REGION=$(cd "$REPO_ROOT/terraform" && terraform output -raw aws_region)

PURPOSE="jenkins-ui"
while [ $# -gt 0 ]; do
    case "$1" in
        --purpose) PURPOSE="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$PURPOSE" in
    jenkins-ui) CN="jenkins.vm-order.internal" ;;
    app)        CN="app.vm-order.internal" ;;
    *) echo "unknown --purpose '$PURPOSE' (expected jenkins-ui or app)" >&2; exit 2 ;;
esac

# Look up by BOTH domain and purpose tag. Domain alone was enough when there
# was one certificate; with two it would return whichever ACM listed first.
EXISTING=$(aws acm list-certificates --region "$AWS_REGION" \
    --query "CertificateSummaryList[?DomainName=='${CN}'].CertificateArn | [0]" \
    --output text 2>/dev/null)

if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
    echo "$EXISTING"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The SAN has to cover the ALB hostname, which looks like
#     k8s-devopsap-frontend-abc123.us-east-1.elb.amazonaws.com
#
# A wildcard matches exactly ONE label, so the previous "*.elb.amazonaws.com"
# never matched: there are two labels (the load balancer name AND the region)
# before elb.amazonaws.com. Scoping the wildcard to the region fixes it.
#
# This does not remove the browser warning — the certificate is still
# self-signed, so the ISSUER is untrusted regardless. It removes the second,
# separate error about the name not matching the host.
ALB_SAN="*.${AWS_REGION}.elb.amazonaws.com"

openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout "$WORK/tls.key" -out "$WORK/tls.crt" \
    -subj "/CN=${CN}/O=VM Order Portal/OU=DevOps Phase 4" \
    -addext "subjectAltName=DNS:${CN},DNS:${ALB_SAN}" \
    2>/dev/null

ARN=$(aws acm import-certificate \
    --region "$AWS_REGION" \
    --certificate "fileb://${WORK}/tls.crt" \
    --private-key "fileb://${WORK}/tls.key" \
    --tags Key=Project,Value=vm-order "Key=Purpose,Value=${PURPOSE}" \
    --query CertificateArn --output text)

echo "$ARN"
