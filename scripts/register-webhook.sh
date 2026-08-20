#!/bin/bash
# scripts/register-webhook.sh
#
# Registers (or updates) a GitHub webhook pointing at this cluster's Jenkins,
# so a push to main triggers the CI pipeline automatically.
#
# WHY THIS EXISTS: the cluster is destroyed and rebuilt on every cycle, so the
# ALB hostname changes each time and a webhook configured by hand goes stale.
# This script deletes any previous hook for this repository and creates a new
# one with the current URL, which makes the webhook survive a rebuild.
#
# The GitHub token is read from the environment or ~/.github_token and is
# never written to Git, Terraform state or the Jenkins configuration.
#
#   export GITHUB_TOKEN=ghp_xxx        # or: echo ghp_xxx > ~/.github_token
#   ./scripts/register-webhook.sh
#
# Required token scope: `admin:repo_hook` (a fine-grained token needs
# "Webhooks: read and write" on this repository only).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ------------------------------------------------------------------- token
TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$HOME/.github_token" ]; then
    TOKEN=$(tr -d '[:space:]' < "$HOME/.github_token")
fi
if [ -z "$TOKEN" ]; then
    cat >&2 <<'MSG'
ERROR: no GitHub token found.

  export GITHUB_TOKEN=ghp_xxxxxxxx
or
  echo ghp_xxxxxxxx > ~/.github_token && chmod 600 ~/.github_token

Scope required: admin:repo_hook
MSG
    exit 1
fi

# -------------------------------------------------------------------- repo
GITHUB_REPO_URL=$(cd "$REPO_ROOT/terraform" && terraform output -raw github_repo_url)
# https://github.com/owner/repo.git -> owner/repo
REPO_PATH=$(echo "$GITHUB_REPO_URL" | sed -E 's#^https://github.com/##; s#\.git$##')

# ---------------------------------------------------------------- jenkins
JENKINS_HOST=$(kubectl get ingress jenkins -n jenkins \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
[ -n "$JENKINS_HOST" ] || { echo "ERROR: Jenkins ingress has no address yet." >&2; exit 1; }

HOOK_URL="https://${JENKINS_HOST}/github-webhook/"

echo "=================================================="
echo "  Registering GitHub webhook"
echo "  repository : ${REPO_PATH}"
echo "  target     : ${HOOK_URL}"
echo "=================================================="

API="https://api.github.com/repos/${REPO_PATH}/hooks"
AUTH=(-H "Authorization: Bearer ${TOKEN}"
      -H "Accept: application/vnd.github+json"
      -H "X-GitHub-Api-Version: 2022-11-28")

# --------------------------------------------- delete stale Jenkins hooks
echo ""
echo "[1/3] Removing stale hooks from previous cluster builds..."
EXISTING=$(curl -sS "${AUTH[@]}" "$API" \
    | jq -r '.[] | select(.config.url | test("github-webhook")) | .id')
if [ -n "$EXISTING" ]; then
    for id in $EXISTING; do
        curl -sS -X DELETE "${AUTH[@]}" "${API}/${id}" >/dev/null
        echo "  deleted hook ${id}"
    done
else
    echo "  none found"
fi

# ---------------------------------------------------------- create the hook
echo ""
echo "[2/3] Creating the webhook..."
# insecure_ssl=1 because the Jenkins certificate is self-signed. GitHub would
# otherwise refuse to deliver. The payload is not sensitive (a commit SHA and
# a repo name) and the endpoint is IP-restricted, but this is a real trade-off
# and is documented in the README security chapter. A registered domain with a
# publicly trusted certificate would remove the need for it.
RESPONSE=$(curl -sS -X POST "${AUTH[@]}" "$API" -d @- <<JSON
{
  "name": "web",
  "active": true,
  "events": ["push", "pull_request"],
  "config": {
    "url": "${HOOK_URL}",
    "content_type": "json",
    "insecure_ssl": "1"
  }
}
JSON
)

HOOK_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
if [ -z "$HOOK_ID" ]; then
    echo "ERROR: webhook creation failed:" >&2
    echo "$RESPONSE" | jq -r '.message // .' >&2
    exit 1
fi
echo "  created hook ${HOOK_ID}"

# ------------------------------------------------------------------- test
#
# This block used to read last_response, print it, and then announce success
# regardless. A real run reported
#     last response: connection_error
#     Webhook registered. A push to main will now trigger application-ci.
# which was false: GitHub could not reach the ALB at all, the hook never
# delivered, and CI quietly ran off the 5-minute poll instead. Creating a hook
# in GitHub proves nothing about whether it can be delivered.
echo ""
echo "[3/3] Sending a test delivery..."
curl -sS -X POST "${AUTH[@]}" "${API}/${HOOK_ID}/tests" >/dev/null
sleep 3
LAST=$(curl -sS "${AUTH[@]}" "${API}/${HOOK_ID}" | jq -r '.last_response.status // "unknown"')
echo "  last response: ${LAST}"

case "$LAST" in
    2*|active)
        echo ""
        echo "Webhook registered and delivering. A push to main triggers application-ci."
        echo "Evidence: GitHub > Settings > Webhooks > Recent Deliveries"
        ;;
    connection_error|timeout|unknown|"")
        echo "" >&2
        echo "ERROR: the webhook was created but GitHub could NOT reach Jenkins." >&2
        echo "" >&2
        echo "  Almost always the ALB allowlist: inbound-cidrs must include GitHub's" >&2
        echo "  webhook ranges, not just your own IP. configure-jenkins.sh composes" >&2
        echo "  that list; re-run it and confirm the 'allowlist' line names more than" >&2
        echo "  one CIDR:" >&2
        echo "" >&2
        echo "      ./scripts/configure-jenkins.sh" >&2
        echo "      curl -s https://api.github.com/meta | jq -r '.hooks[]'" >&2
        echo "" >&2
        echo "  Until this is fixed CI still builds, but only via the 5-minute poll," >&2
        echo "  and no build will be attributable to a push." >&2
        exit 1
        ;;
    *)
        echo "" >&2
        echo "ERROR: unexpected webhook response '${LAST}'. The hook exists but its" >&2
        echo "       first delivery did not succeed. Check GitHub > Settings >" >&2
        echo "       Webhooks > Recent Deliveries before relying on it." >&2
        exit 1
        ;;
esac
