#!/bin/bash
# scripts/create-jobs.sh
#
# Creates (or refreshes) the two Jenkins jobs from code.
#
# The job definitions live in jenkins/jobs/seed.groovy and are applied through
# JCasC + the job-dsl plugin. This script re-renders the JCasC config and
# nudges Jenkins to reload it, which is what makes the jobs appear.
#
# Idempotent: running it twice leaves exactly two jobs, not four.
#
# Neither job is ever created through the Jenkins UI. That is the point: the
# cluster can be destroyed and rebuilt and both jobs return identically.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=================================================="
echo "  Creating Jenkins jobs from code"
echo "=================================================="

kubectl get statefulset jenkins -n jenkins >/dev/null 2>&1 \
    || { echo "ERROR: Jenkins is not installed. Run scripts/install-jenkins.sh first." >&2; exit 1; }

# Re-apply the JCasC configuration, which contains the Job DSL seed.
echo ""
echo "[1/3] Applying JCasC configuration (includes jenkins/jobs/seed.groovy)..."
"$REPO_ROOT/scripts/configure-jenkins.sh"

# The config-reload sidecar watches the ConfigMap and reloads Jenkins on its
# own, but on a timer. We trigger a reload explicitly so this script is
# deterministic rather than racy.
#
# NOTE: /reload-configuration-as-code/ expects a shared token, NOT basic auth,
# and silently logs "Invalid token received" if given credentials instead. The
# supported route with an admin password is the Jenkins CLI reload, below.
echo ""
echo "[2/3] Reloading configuration..."
PASS=$(kubectl get secret jenkins -n jenkins \
    -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)

kubectl exec -n jenkins jenkins-0 -c jenkins -- bash -c "
    curl -sS -o /tmp/cli.jar http://localhost:8080/jnlpJars/jenkins-cli.jar &&
    java -jar /tmp/cli.jar -s http://localhost:8080/ \
        -auth admin:${PASS} reload-jcasc-configuration
" 2>/dev/null || echo "  (explicit reload unavailable; the sidecar will pick it up within ~1 min)"

sleep 20

# Verify both jobs exist.
echo ""
echo "[3/3] Verifying..."
PASS=$(kubectl get secret jenkins -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)
JOBS=$(kubectl exec -n jenkins jenkins-0 -c jenkins -- \
    curl -sS -g --user "admin:${PASS}" \
    "http://localhost:8080/api/json?tree=jobs[name]" 2>/dev/null || echo '{}')

for job in application-ci application-cd; do
    if echo "$JOBS" | grep -q "\"$job\""; then
        echo "  OK      $job"
    else
        echo "  MISSING $job"
        echo ""
        echo "  Check the JCasC log for a Job DSL error:"
        echo "    kubectl logs -n jenkins jenkins-0 -c jenkins | grep -i 'casc\\|dsl'"
        exit 1
    fi
done

echo ""
echo "Both jobs created from jenkins/jobs/seed.groovy."
echo "Next: ./scripts/register-webhook.sh   # trigger CI on push"
