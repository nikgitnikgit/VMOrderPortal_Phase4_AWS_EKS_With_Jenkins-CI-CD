# VM Order Portal — Phase 4: Complete Walkthrough

Every file explained. Files containing logic are covered line by line;
configuration files are covered block by block with every non-obvious setting
explained.

Read Part 1 first — it tells you what happens when, and in what order. Parts 2
onward explain each file in the order it is used.

---

# Part 1 — What happens when you run it

## 1.1 The one command

```bash
./scripts/deploy.sh
```

That runs five steps. Everything else in this document explains what those
five steps touch.

```
./scripts/deploy.sh
  │
  ├─ STEP 1  terraform apply           ~18 min   AWS resources only
  ├─ STEP 2  install-jenkins.sh        ~10 min   cluster contents + Jenkins
  ├─ STEP 3  create-jobs.sh            ~1 min    the two jobs, from code
  ├─ STEP 4  register-webhook.sh       ~10 sec   push → CI
  └─ STEP 5  verify-jenkins.sh         ~30 sec   ~35 assertions
```

At the end you get a URL, a username and a password. **No application is
running yet** — that is deliberate. The application is deployed by the Jenkins
CD pipeline, which is the point of phase 4.

## 1.2 The full chain, from `git push` to a running application

```
 you: git push origin main
   │
   │ GitHub sends a webhook to https://<jenkins-alb>/github-webhook/
   ▼
 application-ci  (Jenkinsfile-ci)
   │  runs in a Pod using ServiceAccount jenkins-agent-ci
   │
   ├─ 1 Checkout          git short SHA becomes the image tag
   ├─ 2 Validate          hadolint, shellcheck, helm lint, helm template
   ├─ 3 Static analysis   flake8
   ├─ 4 Unit tests        pytest → JUnit XML → Jenkins test trend
   ├─ 5 Build ×3          BuildKit → local .tar   (nothing pushed yet)
   ├─ 6 Scan + SBOM       Trivy CycloneDX + CRITICAL gate
   ├─ 7 ECR login         IRSA token → RAM-only config.json
   ├─ 8 Push ×3           tag = git SHA, digest captured
   ├─ 9 Metadata          image-manifest.json archived
   └─ 10 Trigger CD       build job: 'application-cd', passing tag + digests
   │
   ▼
 application-cd  (Jenkinsfile-cd)
   │  runs in a Pod using ServiceAccount jenkins-agent-cd
   │
   ├─ 1 Validate input    rejects empty / 'latest' / non-SHA
   ├─ 2 Verify in ECR     read-only: does this tag really exist?
   ├─ 3 Manifest validate helm lint + server-side dry run
   ├─ 4 APPROVAL          a human clicks Deploy
   ├─ 5 Deploy            helm upgrade --install ×3
   ├─ 6 Rollout           kubectl rollout status ×3
   ├─ 7 Verify version    running image == requested tag
   ├─ 8 Smoke test        /healthz, /api/health, public ALB
   └─ 9 Record            evidence → S3
   │
   ▼
 Application live in namespace devops-app
```

## 1.3 Who is allowed to do what

This is the single most important idea in the project. Three identities:

| Identity | Kubernetes permissions | AWS permissions (IRSA) |
|---|---|---|
| `jenkins` (controller) | create/delete Pods in `jenkins` only | none |
| `jenkins-agent-ci` | **none at all** | push to 4 ECR repos, write `s3://…/builds/*` |
| `jenkins-agent-cd` | manage app objects in `devops-app` | **read-only** ECR, write `s3://…/deployments/*` |

Consequences worth stating out loud:

- **CI cannot deploy.** Not "does not" — *cannot*. It has no Role and no
  RoleBinding. Rewriting `Jenkinsfile-ci` to run `helm upgrade` would fail at
  the API server.
- **CD cannot build.** Its Pod has no BuildKit container and its IAM role has
  no `ecr:PutImage`.
- **Neither can read the database password.** `secrets` is granted to nobody.

## 1.4 Where things live

| Thing | Where | Survives `destroy.sh`? |
|---|---|---|
| Application source | Git | yes |
| Jenkins config, jobs, plugins | Git (`jenkins/`) | yes |
| Infrastructure definition | Git (`terraform/`) | yes |
| Your DB password | `terraform/terraform.tfvars`, your machine only | yes (never committed) |
| Terraform state | local file (or S3 if you enable it) | yes |
| Container images | ECR | **no** |
| Jenkins build history | PVC in the cluster | **no** |
| Build evidence | S3 `builds/`, `deployments/` | **no** — download first |

Because Jenkins is rebuilt from code every cycle, losing build history costs
nothing. That is why nothing is ever configured through the Jenkins UI.

## 1.5 Order matters, and here is why

Several steps look like they could be reordered but cannot:

| Order constraint | Reason |
|---|---|
| Terraform before install-jenkins | the script reads Terraform outputs for every environment value |
| App namespace + Secret before Jenkins | the Secret must exist before CD deploys Pods that mount it; creating it here means Jenkins never handles the password |
| ALB controller restart after its Helm upgrade | the chart regenerates its webhook CA on every upgrade; running Pods keep serving the old cert, and every Service/Ingress then fails with `x509: certificate signed by unknown authority` |
| `create-cert.sh` before the Jenkins Helm install | the certificate ARN is an Ingress annotation, so it must exist first |
| Agent image built and pushed before Jenkins starts | agent Pods pull it; if it is missing every build fails with `ImagePullBackOff` |
| `register-webhook.sh` after Jenkins has an ALB address | the hook URL contains the ALB hostname, which does not exist until the Ingress is provisioned |
| On teardown: frontend uninstalled before `terraform destroy` | its Ingress owns an ALB that Terraform does not know about; leaving it makes VPC deletion hang |

---

# Part 2 — The scripts

Eight scripts. Four have names the assignment requires
(`install-jenkins.sh`, `configure-jenkins.sh`, `create-jobs.sh`,
`verify-jenkins.sh`); the rest support them.

## 2.1 `scripts/deploy.sh` — the orchestrator

```bash
set -euo pipefail
```

Three separate safety settings, and each one prevents a specific disaster:

| Flag | Meaning | What it prevents here |
|---|---|---|
| `-e` | exit on any command failing | Terraform fails but the script carries on and installs Jenkins into a cluster that does not exist |
| `-u` | error on an undefined variable | a typo like `$CLUSTER_NAM` silently becomes an empty string, and `aws eks update-kubeconfig --name ""` does something unexpected |
| `-o pipefail` | a pipeline fails if *any* stage fails | `terraform output \| grep x` reports success because `grep` succeeded, even though `terraform` failed |

```bash
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
```

Read from the inside out: `${BASH_SOURCE[0]}` is this script's own path;
`dirname` gives its directory (`scripts/`); `/..` steps up to the project root;
`cd … && pwd` converts it to an absolute path. The effect is that the script
works no matter where you run it from — `./scripts/deploy.sh` and
`bash /home/you/project/scripts/deploy.sh` behave identically.

```bash
terraform init -input=false
terraform apply -auto-approve
```

`-input=false` means: never stop and ask a human a question. If a variable is
missing, fail immediately rather than hang forever waiting for input that will
never come — which matters when the script is run unattended.

```bash
if [ -n "${GITHUB_TOKEN:-}" ] || [ -f "$HOME/.github_token" ]; then
    ./scripts/register-webhook.sh
else
    echo "  SKIPPED — no GitHub token found."
fi
```

`${GITHUB_TOKEN:-}` is the safe way to read a variable that may not exist:
without the `:-` fallback, `set -u` would abort the script. The webhook is
optional; CI still runs on a 5-minute poll, so a missing token degrades the
system rather than breaking it.

```bash
if [ "${SKIP_VERIFY:-0}" = "1" ]; then
```

An escape hatch used only by the offline test suite. `verify-jenkins.sh`
inspects a live cluster (`kubectl auth can-i`, pod readiness), which mocked
binaries cannot satisfy.

## 2.2 `scripts/install-jenkins.sh` — the platform layer

### Reading configuration

```bash
CLUSTER_NAME=$(terraform output -raw cluster_name)
AWS_REGION=$(terraform output -raw aws_region)
...
```

Twelve values, all read back from Terraform rather than hard-coded. `-raw`
strips the surrounding quotes that Terraform would otherwise print. This is
the single-source-of-truth rule: `terraform.tfvars` is the only place a human
edits, and everything downstream derives from it. A second contributor
changes one file and every script follows.

```bash
JENKINS_NODE_GROUP="${CLUSTER_NAME}-jenkins-nodes"
TOOLS_IMAGE="${ECR_REGISTRY}/vm-order-jenkins-agent:tools-1.0"
JENKINS_CHART_VERSION=$(tr -d '[:space:]' < "$REPO_ROOT/jenkins/CHART_VERSION")
```

The node group name is *derived*, not configured, so it cannot drift from what
Terraform actually created. `tr -d '[:space:]'` strips the trailing newline
from the version file — without it the value would be `"5.9.45\n"` and the
`helm --version` flag would fail with a confusing error.

### Step 2 — the Secret, and why it is created here

```bash
DB_PASSWORD=$(grep -E '^\s*db_password' terraform.tfvars | cut -d'"' -f2)
[ -n "$DB_PASSWORD" ] || { echo "ERROR: ..." >&2; exit 1; }
```

`cut -d'"' -f2` splits the line on double quotes and takes the second field —
for `db_password = "hunter2"` that is `hunter2`. The guard on the next line
fails loudly if the value is empty, rather than creating a Secret with a blank
password and failing much later with an unexplained database connection error.

```bash
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
```

This idiom is how you make `kubectl create` idempotent. `create` alone fails
with `AlreadyExists` on a second run. `--dry-run=client -o yaml` generates the
object without sending it, and `apply` then creates *or updates* it. The whole
script can be re-run safely.

```bash
# REVIEW FIX 2.2 — one Secret per workload, not one shared object.
kubectl create secret generic backend-secrets \
    --from-literal=DB_HOST="$RDS_ADDRESS" \
    --from-literal=DB_PASSWORD="$DB_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic worker-secrets \
    --from-literal=DB_HOST="$RDS_ADDRESS" \
    --from-literal=DB_PASSWORD="$DB_PASSWORD" \
    --from-literal=SNS_TOPIC_ARN="$SNS_TOPIC_ARN" \
    --from-literal=SES_SENDER="$SES_SENDER" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl delete secret app-secrets --ignore-not-found   # remove the old shared object
unset DB_PASSWORD
```

The backend never calls SNS or SES, so it no longer holds those values. The
worker does need all four — it emails the customer *and* updates
`sns_sent`/`ses_sent` on the order row — so the split narrows the backend's
view rather than both.

**This is the security-critical part of the project.** The password is read on
*your* machine, sent straight to the Kubernetes API, and the variable is unset
immediately. Jenkins is never involved. Combined with the RBAC rule that grants
`secrets` to nobody, the result is: *Jenkins can deploy an application whose
database password it is unable to read.*

### Step 3 — add-ons, and the webhook certificate trap

```bash
kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=300s
sleep 10
```

This restart looks redundant and is not. The ALB controller chart generates a
self-signed CA for its admission webhook, and **regenerates it on every `helm
upgrade`**. The new CA goes into the webhook configuration, but Pods already
running keep serving the *old* certificate. The API server then rejects every
Service and Ingress creation with `x509: certificate signed by unknown
authority`. Restarting forces the Pods onto the current certificate. The
`sleep 10` gives the webhook endpoints time to register before anything tries
to create an Ingress.

```bash
kubectl set env daemonset aws-node -n kube-system ENABLE_NETWORK_POLICY=true
```

The AWS VPC CNI accepts NetworkPolicy objects but does not *enforce* them
unless this flag is set. Without it the policies in
`jenkins/networkpolicy.yaml` exist and do nothing — protection you would
believe you had but did not.

### Step 4 — RBAC and the IRSA annotations

```bash
kubectl annotate serviceaccount jenkins-agent-ci -n jenkins \
    "eks.amazonaws.com/role-arn=${CI_ROLE_ARN}" --overwrite
```

The annotation is applied here rather than written into `rbac.yaml` because
the role ARN contains your AWS account ID. Hard-coding it would break the
repository for anyone else. `--overwrite` makes the command idempotent.

This annotation is the whole of IRSA from the Kubernetes side: EKS sees it,
injects a projected service-account token into the Pod, and the AWS SDK
exchanges that token for temporary credentials for exactly that role. **No
access key exists anywhere.**

### Step 6 — the agent image

```bash
if aws ecr describe-images --repository-name "vm-order-jenkins-agent" \
     --image-ids imageTag="tools-1.0" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "  already in ECR — skipping build"
```

Saves ~3 minutes on re-runs. **Known limitation, stated in the script:** it
checks whether the *tag* exists, not whether the Dockerfile changed. After
editing `agent-tools/Dockerfile` you must bump the tag or delete the image, or
the stale one keeps being used.

```bash
trivy image --severity CRITICAL --exit-code 1 --no-progress "$TOOLS_IMAGE"
```

`--exit-code 1` is what turns Trivy from a report into a gate: without it,
Trivy prints vulnerabilities and exits 0, and `set -e` never fires. The agent
image is scanned before it is pushed, as the spec requires for both agent and
controller images.

### Step 7 — installing Jenkins

```bash
if ! helm search repo "jenkins/jenkins" --version "$JENKINS_CHART_VERSION" 2>/dev/null \
        | grep -q "$JENKINS_CHART_VERSION"; then
    echo "ERROR: chart version '${JENKINS_CHART_VERSION}' not found." >&2
    helm search repo jenkins/jenkins --versions 2>/dev/null | head -6 >&2
    exit 1
fi
```

Fail fast with a useful message. Without this guard, a stale pinned version
produces a Helm error five minutes into the install, or worse, installs a chart
whose Jenkins core is too old for the plugins and crash-loops for ten minutes
before anyone sees why.

```bash
OVERRIDES=$("$REPO_ROOT/scripts/configure-jenkins.sh" --print-file ... )
helm upgrade --install jenkins jenkins/jenkins \
    -f "$REPO_ROOT/jenkins/values.yaml" \
    -f "$OVERRIDES"
rm -f "$OVERRIDES"
```

Two values files, applied in order: the committed static configuration, then
generated environment-specific overrides. Later files win. The generated file
is deleted immediately because it contains your public IP and the certificate
ARN.

**Why a generated file and not `--set`:** Helm's `--set` parser splits on
commas and cannot carry multi-line YAML, and the JCasC blocks are full of it.
A real values file has no such limitation.

### Step 8 — waiting for the ALB

```bash
for i in $(seq 1 36); do
    JENKINS_HOST=$(kubectl get ingress jenkins -n jenkins \
        -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>/dev/null || true)
    [ -n "$JENKINS_HOST" ] && break
    sleep 10
done
```

Six minutes of polling. `|| true` prevents `set -e` from killing the script on
the early attempts when the Ingress has no address yet — here a failure is
*expected*, which is the narrow case where suppressing it is correct.


## 2.3 `scripts/configure-jenkins.sh` — generating the environment config

Two modes, selected by a flag:

```bash
while [ $# -gt 0 ]; do
    case "$1" in
        --print-file)   PRINT_ONLY=true; shift ;;
        --cert-arn)     CERT_ARN="$2"; shift 2 ;;
        ...
    esac
done
```

`shift` consumes one argument, `shift 2` consumes a flag and its value. In
`--print-file` mode the script writes the overrides to a temp file and prints
its path, for `install-jenkins.sh` to feed into its own `helm` call. Called
with no arguments it applies the configuration itself — which is how you fix
Jenkins after your IP changes, without reinstalling anything.

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)
```

Your public IP, detected at run time. This is why no IP is ever committed to
Git, and why re-running this one script restores access after your ISP
reassigns your address.

```yaml
      alb.ingress.kubernetes.io/inbound-cidrs: "${MY_IP}/32"
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443},{"HTTP":80}]'
      alb.ingress.kubernetes.io/certificate-arn: "${CERT_ARN}"
      alb.ingress.kubernetes.io/ssl-redirect: "443"
      alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
```

Five annotations that the ALB controller turns into real load balancer
configuration:

| Annotation | Effect |
|---|---|
| `inbound-cidrs` | security group rule: only your `/32` may connect |
| `listen-ports` | open both 443 and 80 |
| `certificate-arn` | the ACM certificate to serve on 443 |
| `ssl-redirect: 443` | anything arriving on 80 is redirected to 443 |
| `ssl-policy` | TLS 1.3 / 1.2 only; older protocols refused |

Together these satisfy two spec requirements at once: HTTPS, and "the Jenkins
UI must not be open to the whole internet."

```bash
      jobs: |
        jobs:
          - script: >
$(sed 's/^/              /' "$REPO_ROOT/jenkins/jobs/seed.groovy")
```

This is the trick that lets the job definitions live in a real `.groovy` file
instead of being buried inside a YAML string. `sed 's/^/ /'` prefixes every
line with 14 spaces so the Groovy lands at the correct YAML indentation, and
command substitution splices it in. The result: `seed.groovy` is syntax
highlighted, reviewable and diffable like any other source file.

## 2.4 `scripts/create-cert.sh` — HTTPS without a domain

```bash
EXISTING=$(aws acm list-certificates --region "$AWS_REGION" \
    --query "CertificateSummaryList[?DomainName=='${CN}'].CertificateArn | [0]" \
    --output text)
if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
    echo "$EXISTING"; exit 0
fi
```

Idempotency: re-running returns the existing certificate instead of importing
a second one. The `--query` is JMESPath — filter the list to entries whose
domain matches, take the ARN, take the first result.

```bash
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
```

`trap … EXIT` guarantees the temp directory is deleted when the script exits
**by any route** — success, error, or Ctrl-C. That directory holds a private
key, so this is not merely tidiness.

```bash
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout "$WORK/tls.key" -out "$WORK/tls.crt" \
    -subj "/CN=${CN}/O=VM Order Portal/OU=DevOps Phase 4" \
    -addext "subjectAltName=DNS:${CN},DNS:*.elb.amazonaws.com"
```

| Flag | Meaning |
|---|---|
| `-x509` | produce a self-signed certificate, not a signing request |
| `-nodes` | do not encrypt the private key — ACM cannot accept a passphrase-protected key |
| `-newkey rsa:2048` | generate a fresh 2048-bit key |
| `-days 365` | validity; longer than any cluster will live |
| `-subj` | fills in the certificate fields non-interactively, so no prompts |
| `-addext subjectAltName` | modern clients ignore the CN and read the SAN; without this the certificate is rejected outright rather than merely warned about |

```bash
ARN=$(aws acm import-certificate ... --query CertificateArn --output text)
echo "$ARN"
```

The script prints the ARN and nothing else, so the caller can capture it
cleanly with `CERT_ARN=$(./scripts/create-cert.sh)`.

**Why self-signed at all:** an ALB can only terminate TLS with an ACM
certificate, and a publicly trusted ACM certificate requires a domain you
control. This gives real TLS 1.3 encryption with one browser warning, at zero
cost. A registered domain (~$12/year) would remove the warning.

## 2.5 `scripts/create-jobs.sh`

```bash
kubectl get statefulset jenkins -n jenkins >/dev/null 2>&1 \
    || { echo "ERROR: Jenkins is not installed..." >&2; exit 1; }
```

A precondition check that turns a confusing downstream failure into a clear
message.

```bash
kubectl exec -n jenkins jenkins-0 -c jenkins -- \
    curl -sS -X POST "http://localhost:8080/reload-configuration-as-code/" \
    --user "admin:$(kubectl get secret jenkins -n jenkins \
        -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)"
```

The `config-reload` sidecar watches the ConfigMap and reloads Jenkins on its
own, but on a timer. Triggering the reload explicitly makes the script
deterministic instead of racy. Note the call is made *inside* the Pod via
`kubectl exec`, so the request goes to `localhost` and never crosses the
network — the admin password is not sent over the wire.

```bash
for job in application-ci application-cd; do
    if echo "$JOBS" | grep -q "\"$job\""; then
        echo "  OK      $job"
    else
        echo "  MISSING $job"
        exit 1
```

The script verifies its own outcome rather than assuming success, and points
at the JCasC log if a Job DSL error swallowed a job definition.

## 2.6 `scripts/verify-jenkins.sh` — proving the design

```bash
check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  \033[32mPASS\033[0m  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        ...
```

`"$@"` runs the remaining arguments as a command. `\033[32m` is the ANSI
escape for green, `\033[31m` red.

```bash
check_denied() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  \033[31mFAIL\033[0m  %s (permission was granted!)\n' "$name"
```

**The inverted check — this is the interesting one.** It passes when the
command *fails*. Proving Jenkins *can* deploy is easy; the security argument
depends on proving the CI agent *cannot*:

```bash
check_denied "CI agent CANNOT create deployments" \
    kubectl auth can-i create deployments -n devops-app \
    --as=system:serviceaccount:jenkins:jenkins-agent-ci
check_denied "CD agent CANNOT read Secrets (the DB password)" \
    kubectl auth can-i get secrets -n devops-app \
    --as=system:serviceaccount:jenkins:jenkins-agent-cd
```

`kubectl auth can-i --as=` asks the API server the authorisation question
directly, as that identity. This is not a simulation — it is the same decision
path a real request takes. These two lines are the evidence behind the entire
security chapter of the README.

```bash
check "controller runs ZERO executors (no builds on the controller)" bash -c \
    'kubectl exec -n jenkins jenkins-0 -c jenkins -- cat /var/jenkins_home/config.xml \
     | grep -q "<numExecutors>0</numExecutors>"'
```

Checks the *running* configuration, not the values file — proving the setting
actually took effect.

## 2.7 `scripts/register-webhook.sh`

```bash
TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$HOME/.github_token" ]; then
    TOKEN=$(tr -d '[:space:]' < "$HOME/.github_token")
fi
```

Two sources, neither inside the repository. `tr -d '[:space:]'` strips the
newline `echo` leaves behind — a trailing newline in an HTTP header produces a
401 that is genuinely hard to diagnose.

```bash
REPO_PATH=$(echo "$GITHUB_REPO_URL" | sed -E 's#^https://github.com/##; s#\.git$##')
```

Turns `https://github.com/you/repo.git` into `you/repo`, which is what the API
path needs. `#` is used as the delimiter instead of `/` so the URL's own
slashes need no escaping.

```bash
EXISTING=$(curl -sS "${AUTH[@]}" "$API" \
    | jq -r '.[] | select(.config.url | test("github-webhook")) | .id')
for id in $EXISTING; do
    curl -sS -X DELETE "${AUTH[@]}" "${API}/${id}" >/dev/null
done
```

**This is why the script exists.** The cluster is rebuilt every cycle and the
ALB hostname changes, so yesterday's webhook points at a load balancer that no
longer exists. Deleting stale hooks before creating the new one prevents an
accumulating pile of dead webhooks.

```json
"config": { "url": "${HOOK_URL}", "content_type": "json", "insecure_ssl": "1" }
```

`insecure_ssl: 1` tells GitHub not to verify the certificate — necessary
because ours is self-signed, and GitHub would otherwise refuse to deliver. A
genuine trade-off, documented in the README: the payload is a commit SHA and a
repository name, and the endpoint is IP-restricted, but it is a weakening. A
registered domain would remove the need.

```bash
curl -sS -X POST "${AUTH[@]}" "${API}/${HOOK_ID}/tests" >/dev/null
LAST=$(curl -sS "${AUTH[@]}" "${API}/${HOOK_ID}" | jq -r '.last_response.status')
```

Sends a test delivery and reports the result, so you know the webhook works
before relying on it in a demo.

## 2.8 `scripts/uninstall-jenkins.sh` and `scripts/destroy.sh`

```bash
kubectl delete pvc -n jenkins --all --ignore-not-found --timeout=120s
```

A PVC backs a real EBS volume that **Terraform does not know about**. Left
behind, it costs money indefinitely. `--ignore-not-found` keeps the script
idempotent.

`destroy.sh` performs teardown in an order that AWS forces on you:

```bash
sweep_orphan_sgs() {
    SGS=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)
    for SG in $SGS; do
        IN=$(... --query 'SecurityGroups[0].IpPermissions' --output json)
        if [ -n "$IN" ] && [ "$IN" != "[]" ]; then
            aws ec2 revoke-security-group-ingress ... --ip-permissions "$IN"
        fi
    done
    for SG in $SGS; do
        aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$SG"
    done
}
```

Two loops, deliberately. The ALB controller creates security groups that
reference *each other*, so deleting them in one pass fails with
`DependencyViolation`. The first loop strips all rules; the second then
deletes the now-independent groups.

These groups are invisible to Terraform, and a VPC cannot be deleted while
non-default security groups remain — which manifests as `terraform destroy`
hanging on the VPC for 10+ minutes with no useful error. This function was
added after exactly that happened.

```bash
if ! terraform destroy -auto-approve; then
    sweep_orphan_enis
    sweep_orphan_sgs
    terraform destroy -auto-approve
fi
```

One automatic retry after sweeping. Deletion is time-sensitive — resources
that were still detaching on the first attempt have usually finished by the
second.


---

# Part 3 — The two pipelines

This is where the assignment's central rule lives:

> *There is no deploy stage in the CI pipeline.*
> *The image tested in CI is the image deployed in CD. Do not rebuild it.*

## 3.1 `Jenkinsfile-ci` — the agent Pod

```groovy
pipeline {
    agent {
        kubernetes {
            yaml """..."""
        }
    }
```

`agent { kubernetes { yaml ... } }` tells the Kubernetes plugin: for this
build, create a Pod described by this YAML, run the pipeline inside it, then
delete it. Nothing persists between builds.

```yaml
metadata:
  annotations:
    container.apparmor.security.beta.kubernetes.io/buildkit: unconfined
```

AppArmor is a Linux security layer that restricts what a process may do. The
default profile blocks the mount operations rootless BuildKit needs. Note the
annotation names **one container** — `tools` and `trivy` keep the default
profile.

```yaml
spec:
  serviceAccountName: jenkins-agent-ci
```

**One line, and it is the enforcement point for the whole CI/CD separation.**
Every Kubernetes API call this Pod makes is authorised as this identity, which
has no Role and no RoleBinding. Nothing in the pipeline can deploy.

```yaml
  securityContext:
    fsGroup: 1000
    runAsNonRoot: true
```

`fsGroup: 1000` sets group ownership on mounted volumes so a container running
as UID 1000 can write to them. Without it, writing `config.json` fails with
"Permission denied", because `emptyDir` volumes mount root-owned by default.
`runAsNonRoot: true` makes the kubelet *refuse to start* a container whose
image would run as root — a guarantee, not a request.

```yaml
  tolerations:
    - key: "role"
      operator: "Equal"
      value: "jenkins"
      effect: "NoSchedule"
  nodeSelector:
    eks.amazonaws.com/nodegroup: "${env.JENKINS_NODE_GROUP}"
```

The Jenkins node carries a **taint** — a "keep out" sign. A **toleration** is
the pass that permits entry. But a toleration only says *allowed*, not
*preferred*, so the `nodeSelector` pins the Pod to that node group. Together:
build Pods always land on the Jenkins node, and application Pods never can.

The label is `eks.amazonaws.com/nodegroup`. There is no `-name` suffix — using
one makes the Pod permanently unschedulable.

### The containers

```yaml
    - name: tools
      image: "${env.AGENT_TOOLS_IMAGE}"
      command: ["sleep"]
      args: ["infinity"]
```

`sleep infinity` is the standard pattern for a sidecar. The container must stay
alive so the pipeline can `exec` commands into it; without a long-running
command it would exit immediately and the Pod would restart forever.

```yaml
      resources:
        requests: { cpu: "200m", memory: "512Mi" }
        limits:   { cpu: "1",    memory: "1Gi" }
```

**Requests** are what the scheduler reserves — the guarantee. **Limits** are
the ceiling; exceeding memory means the container is killed (OOMKilled).
`200m` is 0.2 of a CPU core. BuildKit gets far more (`1Gi`–`3Gi`) because
image builds are mostly decompression.

```yaml
      securityContext:
        runAsUser: 1000
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: RuntimeDefault
```

| Setting | Effect |
|---|---|
| `runAsUser: 1000` | not root |
| `allowPrivilegeEscalation: false` | a process can never gain more privilege than it started with — blocks setuid escalation |
| `capabilities: drop ALL` | removes every Linux capability (`NET_ADMIN`, `SYS_ADMIN`, …) |
| `seccompProfile: RuntimeDefault` | restricts which syscalls the kernel will accept |

```yaml
    - name: buildkit
      image: moby/buildkit:v0.18.2-rootless
      env:
        - name: BUILDKITD_FLAGS
          value: --oci-worker-no-process-sandbox
      securityContext:
        seccompProfile:
          type: Unconfined
```

Two exceptions, both scoped to this container, both required for rootless
image builds:

- `--oci-worker-no-process-sandbox` — building means running the Dockerfile's
  `RUN` steps, which normally means starting a nested container. An
  unprivileged process cannot create those namespaces, and the step fails with
  `error mounting "proc" to rootfs: operation not permitted`. This flag tells
  BuildKit to run the steps in its own namespace instead.
- `seccompProfile: Unconfined` — the default profile blocks syscalls BuildKit
  still needs.

Weigh this against the alternative: Docker-in-Docker with `privileged: true`
grants **all host devices and kernel capabilities**. This is a far narrower
concession, applied to one container in one namespace.

```yaml
  volumes:
    - name: docker-config
      emptyDir:
        medium: Memory
        sizeLimit: 8Mi
```

`medium: Memory` makes this a tmpfs — the ECR token never touches node disk
and vanishes when the Pod dies.

**No workspace volume is declared**, and that omission is deliberate. The
Kubernetes plugin injects its own `workspace-volume` and shares it across all
containers. Declaring a second volume at the same path gives `jnlp` and the
tool containers *different disks*, so the control files `jnlp` writes are
invisible to `tools`, and every `sh` step fails with the famously unhelpful
`process apparently never started`.

## 3.2 `Jenkinsfile-ci` — the stages

```groovy
    options {
        timeout(time: 45, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '20'))
        timestamps()
    }
```

`timeout` stops a hung build holding an agent Pod forever.
`disableConcurrentBuilds` prevents two builds racing to push the same tag.
`buildDiscarder` caps history so the 8Gi PVC does not fill. `timestamps`
prefixes each log line with the time, which is what makes "why did this take
20 minutes" answerable afterwards.

### Stage 1 — Checkout

```groovy
env.GIT_SHA  = sh(script: 'git rev-parse --short=12 HEAD', returnStdout: true).trim()
env.GIT_FULL = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
env.IMAGE_TAG = env.GIT_SHA
```

`returnStdout: true` captures output instead of printing it; `.trim()` removes
the trailing newline, which would otherwise end up inside the image tag and
produce a baffling error.

**The tag is the git SHA.** Not `latest` (forbidden, and meaningless — which
build is it?). Not `BUILD_NUMBER` either, because that restarts at 1 whenever
Jenkins is rebuilt, and ECR repositories are IMMUTABLE, so build #1 of the
second cluster would collide with build #1 of the first. A commit SHA is
globally unique and points at exactly the source that produced the image.

```groovy
env.IS_PR = (env.CHANGE_ID ?: '') != '' ? 'true' : 'false'
```

`CHANGE_ID` is set by the multibranch plugin only for pull requests. `?:` is
Groovy's Elvis operator — use the left value unless it is null. This flag
gates the push stages later.

### Stage 4 — Unit tests

```groovy
python3 -m pytest app/ -v \
    --junitxml=reports/junit.xml \
    --cov=app --cov-report=xml:reports/coverage.xml
```

```groovy
            post {
                always {
                    junit allowEmptyResults: false, testResults: 'reports/junit.xml'
                }
            }
```

`--junitxml` writes results in the standard JUnit XML format; the `junit` step
imports them so Jenkins shows a test trend graph. `allowEmptyResults: false`
means an empty file fails the build — otherwise a broken pytest invocation
that produced no output would silently "pass". `post { always }` publishes
results even when tests fail, which is exactly when you want to see them.

### Stage 5 and 6 — build, then scan, then push

```groovy
buildctl-daemonless.sh build \
    --frontend=dockerfile.v0 \
    --local context=. \
    --local dockerfile=docker/${svc} \
    --output type=docker,name=vm-order-${svc}:${env.IMAGE_TAG},dest=.../vm-order-${svc}.tar
```

`--output type=docker,dest=...` writes an image **tarball to disk** instead of
pushing. That single choice is what allows scanning before pushing.

```groovy
trivy image --input ${tar} --format cyclonedx --output sbom-${svc}.cdx.json
trivy image --input ${tar} --format table --output trivy-${svc}.txt
trivy image --input ${tar} --severity CRITICAL --exit-code 1
```

Three invocations with different jobs: the SBOM (an inventory of every package
in the image, in the CycloneDX standard), a human-readable report, and the
**gate**. Only the third has `--exit-code 1`, which is what makes a CRITICAL
finding fail the build. Because this runs before the push stage, a vulnerable
image never reaches the registry at all.

### Stage 7 — ECR login

```
TOKEN=$(aws ecr get-login-password --region "$AWS_REGION")
AUTH=$(printf 'AWS:%s' "$TOKEN" | base64 -w0)
umask 077
cat > /home/jenkins/.docker/config.json <<'JSON'
{"auths":{"<registry>":{"auth":"<AUTH>"}}}
JSON
chmod 600 /home/jenkins/.docker/config.json
unset TOKEN AUTH
```

BuildKit knows nothing about AWS — it only understands Docker's `config.json`.
The `auth` field is base64 of `username:password`; for ECR the username is the
literal string `AWS` and the password is a token valid ~12 hours, obtained via
IRSA with no stored credential. `-w0` prevents `base64` inserting line breaks
that would corrupt the JSON. `umask 077` and `chmod 600` keep the file readable
only by its owner, and `unset` clears the values from the shell.

The token lives in a RAM-backed volume, in one Pod, for one build.

### Stage 8 — push and capture the digest

```groovy
buildctl-daemonless.sh build ... \
    --output type=image,name=${img},push=true \
    --metadata-file meta-${svc}.json
```

The second BuildKit run is a cache hit — seconds — and pushes byte-for-byte
the artifact Trivy scanned. `--metadata-file` writes the registry response,
including `containerimage.digest`.

**Tag versus digest:** a tag is a label that *could* be moved (ECR's
immutability prevents it, but that guarantee is registry policy). A digest is
the SHA-256 of the image content — it cannot point at anything else, ever.
Recording both is what lets CD prove it deployed exactly what CI scanned.

### Stage 10 — the hand-off

```groovy
stage('Trigger CD') {
    when {
        allOf {
            expression { env.IS_PR != 'true' }
            branch 'main'
        }
    }
    steps {
        build job: 'application-cd', wait: false,
              parameters: [
                  string(name: 'IMAGE_TAG',      value: env.IMAGE_TAG),
                  string(name: 'BACKEND_DIGEST', value: env.BACKEND_DIGEST),
                  string(name: 'CI_BUILD',       value: env.BUILD_NUMBER),
                  string(name: 'GIT_COMMIT_SHA', value: env.GIT_FULL)
              ]
    }
}
```

Two conditions: not a pull request, and on `main`. `wait: false` lets CI finish
rather than blocking on the approval gate inside CD.

The parameters carry the tag, the three digests, the CI build number and the
commit — which is what makes a deployment traceable in both directions.

### The post block

```groovy
post {
    always {
        container('tools') {
            sh 'rm -f /home/jenkins/.docker/config.json || true'
        }
        archiveArtifacts artifacts: 'trivy-*.txt,sbom-*.cdx.json,image-manifest.json',
                         fingerprint: true
        cleanWs(deleteDirs: true, notFailBuild: true)
    }
    failure {
        emailext(to: "${env.NOTIFICATION_EMAIL}", ...)
    }
}
```

`post { always }` runs on success *and* failure, which satisfies the spec's
requirement to clean up credentials and workspace even when a build fails.
`fingerprint: true` records a checksum of each artifact, so Jenkins can later
tell you which build produced a given file.

Note what the failure email contains: build number, commit, branch, a console
link. **No secret is interpolated into the body.**

## 3.3 `Jenkinsfile-cd` — deploying without building

The agent Pod is deliberately smaller:

```yaml
spec:
  serviceAccountName: jenkins-agent-cd
  containers:
    # Note: no buildkit container. CD physically cannot build.
    - name: tools
```

One container. There is no builder, no ECR push credential, and the IAM role
behind this ServiceAccount has no `ecr:PutImage`. Three independent barriers
to the same mistake.

### Parameters

```groovy
parameters {
    string(name: 'IMAGE_TAG', defaultValue: '',
           description: 'Immutable image tag produced by CI (git short SHA). "latest" is rejected.')
    string(name: 'BACKEND_DIGEST',  defaultValue: '', ...)
    string(name: 'CI_BUILD',        defaultValue: '', ...)
    string(name: 'GIT_COMMIT_SHA',  defaultValue: '', ...)
    choice(name: 'TARGET_NAMESPACE', choices: ['devops-app'], ...)
}
```

`choice` with a single option is not pointless: it makes the namespace
un-typeable, so no one can aim a deployment at `kube-system` by accident. RBAC
would refuse anyway — this fails earlier and more clearly.

### Stage 1 — input validation

```groovy
if (!tag) {
    error('IMAGE_TAG is required. CD deploys an existing image; it does not build one.')
}
if (tag.toLowerCase() in ['latest', 'master', 'main']) {
    error("IMAGE_TAG '${tag}' is not immutable. Supply the git short SHA produced by CI.")
}
if (!(tag ==~ /^[0-9a-f]{7,40}$/)) {
    error("IMAGE_TAG '${tag}' does not look like a git SHA. Refusing to deploy an unverified tag.")
}
```

Three checks, tightening. The regex is the strongest: `^[0-9a-f]{7,40}$` means
hex characters only, 7 to 40 of them. This rejects `latest`, `v1.2.3`,
`my-branch` and anything else that is not a commit SHA. `==~` is Groovy's
full-string regex match.

```groovy
def cause = currentBuild.getBuildCauses()*.shortDescription.join(', ')
echo """
  Triggered by    : ${cause}
  Originating CI  : ${params.CI_BUILD ?: '(manual run)'}
  Git commit      : ${params.GIT_COMMIT_SHA ?: '(not supplied)'}
  Image tag       : ${env.TAG}
  Cluster         : ${env.CLUSTER_NAME}
  Namespace       : ${params.TARGET_NAMESPACE}
"""
currentBuild.description = "tag ${env.TAG} → ${params.TARGET_NAMESPACE} (CI #${params.CI_BUILD ?: '-'})"
```

The spec requires each deployment to show who triggered it, what version, which
cluster and which namespace. `*.` is Groovy's spread operator — collect that
property from every element. Setting `currentBuild.description` puts the
summary on the build list page, so the deployment history is readable at a
glance.

### Stage 2 — verify the image exists

```
for svc in frontend backend worker; do
    aws ecr describe-images \
        --repository-name "vm-order-${svc}" \
        --image-ids imageTag="${TAG}" \
        --region "$AWS_REGION" \
        --query 'imageDetails[0].imageDigest' --output text
done
```

Read-only, and it happens **before anything in the cluster is touched**. A typo
in the tag fails here, changing nothing. It also proves the tag really came
from CI rather than being invented.

### Stage 4 — the approval gate

```groovy
stage('Approval') {
    steps {
        timeout(time: 15, unit: 'MINUTES') {
            input message: "Deploy tag ${env.TAG} to ${params.TARGET_NAMESPACE}?",
                  ok: 'Deploy'
        }
    }
}
```

`input` pauses and waits for a human. The `timeout` wrapper matters: without
it, an unattended pipeline would hold an agent Pod indefinitely. Jenkins
records **who** approved, which is the audit trail.

### Stage 7 — verify the running version

```
for svc in frontend backend worker; do
    RUNNING=$(kubectl get deployment "$svc" -n "$TARGET_NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')
    case "$RUNNING" in
        *:"$TAG") echo "  $svc OK ($RUNNING)" ;;
        *) echo "  $svc MISMATCH: running $RUNNING, expected tag $TAG"; MISMATCH=1 ;;
    esac
done
[ "$MISMATCH" -eq 0 ] || exit 1
```

Asks the cluster what it is *actually* running and compares it to what was
requested. `helm upgrade` succeeding does not by itself prove the right version
is live — a failed rollout can leave the previous ReplicaSet serving traffic.
This closes that gap.

### Stage 8 — the smoke test

```
FRONTEND_IP=$(kubectl get svc frontend -n "$TARGET_NAMESPACE" -o jsonpath='{.spec.clusterIP}')
curl -sf --max-time 10 "http://${FRONTEND_IP}:8080/healthz"
curl -sf --max-time 10 "http://${FRONTEND_IP}:8080/api/health"
```

`-s` silent, `-f` **fail on HTTP error status** — without `-f`, curl exits 0
even on a 500 and the test would pass while the application is broken.

The test goes through the **frontend**, not straight to the backend. The
backend NetworkPolicy accepts traffic only from Pods labelled `app=frontend`,
so a direct call from the build agent is correctly refused. Routing through
nginx also exercises the real request path a user takes: ALB → nginx → backend.

### The failure block

```
kubectl get pods -n "$TARGET_NAMESPACE" -o wide
kubectl get events -n "$TARGET_NAMESPACE" --sort-by=.metadata.creationTimestamp | tail -30
for d in backend worker frontend; do
    kubectl logs "deployment/$d" -n "$TARGET_NAMESPACE" --tail=40
done

for r in frontend worker backend; do
    HELM_DRIVER=configmap helm rollback "$r" -n "$TARGET_NAMESPACE" 2>/dev/null \
        && echo "  rolled back $r" \
        || echo "  $r has no previous revision (first install)"
done
```

**Diagnostics are collected first, then the rollback runs.** Rolling back
destroys the failed ReplicaSet and with it the evidence of what went wrong.
Order matters more than it looks.

The `|| echo` on rollback handles the legitimate case of a first install,
where there is no previous revision — one of the few places `|| true`-style
suppression is correct, because failure there is expected and harmless.


---

# Part 4 — Jenkins configuration as code

## 4.1 `jenkins/rbac.yaml` — the permission model

Four Kubernetes documents, separated by `---`.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins
  namespace: jenkins
```

A ServiceAccount is an identity for a Pod. Every request that Pod makes to the
Kubernetes API is authenticated as this identity and authorised against
whatever Roles are bound to it.

```yaml
kind: Role
metadata:
  name: jenkins-agent-manager
  namespace: jenkins
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "delete", "get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
```

A **Role** is namespaced; a ClusterRole is cluster-wide. This project uses no
ClusterRoles at all. `apiGroups: [""]` is the core API group (pods, services,
secrets, configmaps) — the empty string is its actual name.

Why each rule exists:

| Resource | Why the controller needs it |
|---|---|
| `pods` create/delete | every build creates an agent Pod and deletes it afterwards |
| `pods/exec` create | the pipeline runs steps *inside* the agent's containers |
| `pods/log` get | streaming build output into the Jenkins console |
| `events` watch | so a failing agent shows a real reason instead of hanging silently |

```yaml
kind: RoleBinding
roleRef:
  kind: Role
  name: jenkins-agent-manager
subjects:
  - kind: ServiceAccount
    name: jenkins
    namespace: jenkins
```

A Role grants nothing on its own — it is a set of permissions with no holder.
The **RoleBinding** attaches it to an identity. Role + RoleBinding is always a
pair.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins-agent-ci
  namespace: jenkins
```

**The most important object in the file is the one with nothing after it.**
`jenkins-agent-ci` has no Role and appears in no RoleBinding. Its only
Kubernetes capability is existing as a Pod. This is the spec requirement — *the
CI pipeline needs no deploy permissions* — expressed as an absence.

Everything CI needs comes from AWS through IRSA, not from the Kubernetes API.

```yaml
kind: Role
metadata:
  name: jenkins-deployer
  namespace: devops-app
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  ...
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
```

Note the asymmetry: full CRUD on the objects Helm manages, but **read-only on
Pods**. CD creates Deployments; Kubernetes creates the Pods. CD never needs to
create one.

**`secrets` appears nowhere.** That is the containment argument: Jenkins
deploys an application whose database password it cannot read. It is also why
both pipelines set `HELM_DRIVER=configmap` — Helm's default storage would
require `list` on secrets, and RBAC cannot scope `list` to a single named
object, so granting it would expose the application Secrets.

```yaml
subjects:
  - kind: ServiceAccount
    name: jenkins-agent-cd
    namespace: jenkins
```

Exactly one subject. Neither the CI agent nor the controller is listed.

## 4.2 `jenkins/values.yaml` — the Helm configuration

```yaml
controller:
  image:
    repository: jenkins/jenkins
    tag: "2.568.1-lts-jdk21"
```

Pinned, never `latest`. `lts` is the long-term-support line — quarterly
releases with backported fixes, rather than the weekly stream.

```yaml
  installPlugins:
    - kubernetes
    - workflow-aggregator
    - git
    - github
    - github-branch-source
    - configuration-as-code
    - job-dsl
    - pipeline-stage-view
    - junit
    - mailer
    - email-ext
    - pipeline-utility-steps
```

| Plugin | Why it is needed |
|---|---|
| `kubernetes` | run agents as Pods |
| `workflow-aggregator` | declarative pipeline syntax |
| `git` / `github` | clone, and receive webhooks |
| `github-branch-source` | multibranch discovery, including pull requests |
| `configuration-as-code` | JCasC itself |
| `job-dsl` | provides the `jobs:` root element the seed script uses |
| `junit` | the test results trend graph |
| `mailer` + `email-ext` | the `emailext` step |
| `pipeline-utility-steps` | `readJSON`, used to parse the image manifest |

**Deliberately not version-pinned**, which contradicts normal advice, and the
reason is specific: the plugin installer resolves each plugin's *dependencies*
to their latest versions, and those demand a recent Jenkins core. Pinning
plugin versions against an older core produces a crash-looping init container
full of `requires a greater version of Jenkins`. The version that actually
controls the outcome is the **chart** version, which determines the core image
— and that is pinned, in `jenkins/CHART_VERSION`.

```yaml
  numExecutors: 0
```

Zero build slots on the controller. Every build must therefore run on an agent
Pod. This is the spec's "the controller is not used for builds", and
`verify-jenkins.sh` reads it back from the *running* config.

```yaml
  probes:
    startupProbe:
      httpGet: { path: '/login', port: http }
      periodSeconds: 10
      failureThreshold: 60
    livenessProbe: ...
    readinessProbe: ...
```

Three probes with different jobs. **Startup** allows a slow first boot — 60 ×
10s = 10 minutes — while plugins install. **Liveness** restarts the container
if Jenkins hangs. **Readiness** controls whether the Service sends traffic. The
generous startup threshold is what stops the liveness probe from killing
Jenkins mid-installation.

```yaml
  containerSecurityContext:
    runAsUser: 1000
    readOnlyRootFilesystem: false
    allowPrivilegeEscalation: false
    capabilities:
      drop: ["ALL"]
    seccompProfile:
      type: RuntimeDefault
```

`readOnlyRootFilesystem: false` is the one relaxation, and it is unavoidable:
Jenkins writes to `JENKINS_HOME` constantly. Everything else is locked down.

```yaml
  ingress:
    path: /
    pathType: Prefix
```

`pathType` must be `Prefix`. The default, `ImplementationSpecific`, lets the
ALB controller decide — and it treats `/` as an **exact** match. The result is
that the root URL works while `/login`, `/job/...` and every static asset
return a bare 404 from the load balancer, before ever reaching Jenkins. A
running, reachable, entirely unusable application.

```yaml
  JCasC:
    defaultConfig: true
    configScripts:
      welcome: |
        jenkins:
          systemMessage: >
            VM Order Portal — Phase 4 CI/CD.
```

JCasC applies YAML as if you had clicked every setting in the UI. `defaultConfig: true`
keeps the chart's own generated configuration, and `configScripts` adds to it.

**The critical constraint, stated in the file's own comments:** the chart
generates JCasC from its `controller.*` values. If a custom script sets a key
the chart already sets, JCasC merges both sources, finds a conflict, and
refuses to start with `ConfiguratorConflictException`. So `numExecutors`,
`securityRealm`, `authorizationStrategy` and `clouds` are set through chart
values and must never appear in a script. `tests/check_jcasc.py` enforces this.

```yaml
serviceAccount:
  create: false
  name: jenkins
```

`create: false` because `rbac.yaml` already creates it — with its RoleBinding.
Letting the chart create it too would produce an account with no permissions.

## 4.3 `jenkins/jobs/seed.groovy` — the two jobs as code

```groovy
multibranchPipelineJob('application-ci') {
    branchSources {
        git {
            remote(System.getenv('GITHUB_REPO_URL'))
            includes('main PR-*')
        }
    }
    factory {
        workflowBranchProjectFactory {
            scriptPath('Jenkinsfile-ci')
        }
    }
}
```

A **multibranch** job scans the repository and creates a sub-job per branch and
per pull request. `includes('main PR-*')` limits that to `main` and pull
requests — without it, every feature branch would spawn a build.
`scriptPath` names the pipeline file, which is what makes this the *CI* job.

`System.getenv('GITHUB_REPO_URL')` reads the value JCasC injected from
Terraform, so a second contributor points at their own fork with no edit here.

```groovy
pipelineJob('application-cd') {
    parameters {
        stringParam('IMAGE_TAG', '', 'Immutable image tag produced by CI...')
        choiceParam('TARGET_NAMESPACE', ['devops-app'], ...)
    }
    definition {
        cpsScm {
            scm { git { remote { url(...) } ; branches('*/main') } }
            scriptPath('Jenkinsfile-cd')
        }
    }
}
```

A plain parameterised pipeline, not multibranch: CD always deploys from
`main`, and what varies is the *parameter*, not the branch.

Creating these jobs by hand in the UI would fail the reproducibility
requirement. Because they are code, `uninstall-jenkins.sh` followed by
`install-jenkins.sh` and `create-jobs.sh` restores both identically.

## 4.4 `jenkins/networkpolicy.yaml`

```yaml
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: jenkins
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
```

`podSelector: {}` matches **every** Pod in the namespace. Declaring
`policyTypes` with no rules denies everything in both directions. Subsequent
policies then add narrow allows — deny-by-default, which is the only ordering
that fails safe.

```yaml
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
      ports:
        - port: 443
```

**The `except` is the interesting line.** `169.254.169.254` is the EC2 instance
metadata endpoint, which serves the *node's* IAM role credentials. Blocking it
means a malicious build cannot bypass IRSA and assume the node role — which is
considerably more privileged than `jenkins-agent-ci`.

```yaml
  ingress: []   # (the agents policy declares none)
```

Build Pods accept no inbound connections at all. They initiate outbound
connections to the controller, GitHub and ECR; nothing may connect *to* them.


---

# Part 5 — Terraform

## 5.1 `terraform/main.tf` — the root module

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}
```

`~> 5.0` means "5.x, but not 6.0" — accept bug fixes, refuse breaking changes.

**Note which providers are absent.** There is no `kubernetes` and no `helm`
provider, and that is deliberate. Both need the cluster endpoint at
*provider-configuration* time, but the cluster does not exist during the first
apply. It appears to work on create and then breaks on destroy, leaving state
that must be unpicked by hand. `install-jenkins.sh` does that work instead.

```hcl
module "vpc" {
  source = "./modules/vpc"
  ...
}
```

Modules run in dependency order, inferred from references. `module.eks` uses
`module.vpc.private_subnet_ids`, so VPC is built first. No explicit ordering is
written anywhere.

```hcl
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = module.eks.cluster_name
  service_account_role_arn = module.irsa.ebs_csi_role_arn
}
```

**Why this lives in the root module and not inside `modules/eks`:** it needs
the cluster from `module.eks` *and* an IAM role from `module.irsa`, and
`module.irsa` needs the OIDC provider from `module.eks`. Putting it inside the
EKS module creates the cycle `eks → irsa → eks`, which Terraform refuses to
plan. At the root, both are already resolved.

The addon itself is required because since Kubernetes 1.23 EKS does **not**
ship the EBS CSI driver. Without it, Jenkins's PersistentVolumeClaim stays
`Pending` forever with no useful error, and Jenkins never starts.

## 5.2 `terraform/modules/eks/main.tf` — two node groups

```hcl
resource "aws_eks_node_group" "app" {
  instance_types = [var.node_instance_type]     # t3.small
  scaling_config {
    desired_size = var.node_desired              # 3
  }
}

resource "aws_eks_node_group" "jenkins" {
  instance_types = [var.jenkins_node_instance_type]   # m7i-flex.large
  scaling_config {
    desired_size = 1
    max_size     = 2
  }
  taint {
    key    = "role"
    value  = "jenkins"
    effect = "NO_SCHEDULE"
  }
}
```

**Namespaces do not isolate machines.** A namespace is a logical label; all
namespaces share all nodes by default. To keep Jenkins off the application
nodes you need a **taint**, which is a property of the node itself.

`NO_SCHEDULE` means the scheduler will not place a Pod here unless that Pod
carries a matching toleration. Application Pods have none, so they physically
cannot land on the Jenkins node — and the Jenkins Pods, via their
`nodeSelector`, never land on the app nodes.

Sizing: `t3.small` is 2 GiB, of which ~1.7 GiB is allocatable. The Jenkins
controller alone wants 1–2 GiB, and BuildKit needs more. `m7i-flex.large`
gives 8 GiB.

**Why `m7i-flex.large` specifically:** AWS accounts created on or after
2025-07-15 are hard-restricted to a small list of free-tier-eligible instance
types — `t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`, `c7i-flex.large`,
`m7i-flex.large`. `t3.medium`, the obvious choice, is **not** on that list, and
the failure mode is unhelpful: the node group sits in `CREATING` for ~30
minutes with an empty `health.issues` list, then fails.

```hcl
variable "kubernetes_version" {
  default = "1.35"
}
```

A cost decision as much as a freshness one. A version outside EKS **standard
support** is billed at $0.60 per cluster-hour instead of $0.10, and EKS enrols
you automatically with no opt-in. Version 1.31 had quietly moved into extended
support, making the control plane 6× more expensive.

## 5.3 `terraform/modules/irsa/main.tf` — identity without keys

```hcl
data "aws_iam_policy_document" "trust_jenkins_ci" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:jenkins:jenkins-agent-ci"]
    }
  }
}
```

This is the whole of IRSA. The EKS cluster acts as an OpenID Connect identity
provider; each Pod gets a signed token naming its ServiceAccount. The `sub`
condition says: **only** a Pod running as `jenkins-agent-ci` in the `jenkins`
namespace may assume this role. Any other ServiceAccount is refused by AWS.

The result: no access key exists anywhere in the project. Credentials are
minted on demand, last about an hour, and rotate themselves.

```hcl
resource "aws_iam_role_policy" "jenkins_ci" {
  policy = jsonencode({
    Statement = [
      {
        Sid      = "EcrAuth"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrPushScan"
        Action = ["ecr:PutImage", "ecr:UploadLayerPart", ...]
        Resource = var.ecr_repo_arns
      },
      {
        Sid      = "S3BuildEvidenceWrite"
        Action   = ["s3:PutObject"]
        Resource = "${var.s3_bucket_arn}/builds/*"
      }
    ]
  })
}
```

`Resource = "*"` appears exactly once in the project, on
`ecr:GetAuthorizationToken`, because the AWS API requires that action to be
account-wide. Everything else is scoped: ECR actions to the four project
repositories, S3 writes to a single prefix. CI can drop build evidence into
`builds/` and cannot read, overwrite or delete the application's order data
elsewhere in the same bucket.

```hcl
resource "aws_iam_role_policy" "jenkins_cd" {
  policy = jsonencode({
    Statement = [
      { Sid = "EcrReadOnly", Action = ["ecr:DescribeImages", "ecr:BatchGetImage", ...] },
      { Sid = "S3DeploymentEvidenceWrite", Action = ["s3:PutObject"],
        Resource = "${var.s3_bucket_arn}/deployments/*" }
    ]
  })
}
```

Compare the two: **CD has no `ecr:PutImage`.** Even if `Jenkinsfile-cd` were
rewritten to build and push an image, AWS would refuse. The separation is
enforced in three independent places — the pod spec (no builder container),
IAM (no push permission), and RBAC (CI has no deploy permission).

---

# Part 6 — Application and Helm

## 6.1 The three services

| Service | What it is | Port | AWS access |
|---|---|---|---|
| `frontend` | nginx serving static HTML, proxying `/api/` to the backend | 8080 | **none** |
| `backend` | Flask: validates orders, writes to RDS, uploads to S3, calls the worker | 5000 | S3 write |
| `worker` | Flask: sends SNS notification and SES confirmation email | 5001 | SNS publish, SES send |

The frontend deliberately gets **no IAM role at all**. Least privilege includes
granting nothing when nothing is needed.

## 6.2 Helm chart structure

Each of the three charts contains the same set of templates:

| Template | Purpose |
|---|---|
| `deployment.yaml` | the Pods, their image, env, probes, security context |
| `service.yaml` | stable ClusterIP so other Pods can find them |
| `serviceaccount.yaml` | identity, with the IRSA annotation where needed |
| `networkpolicy.yaml` | who may talk to this service |
| `hpa.yaml` | HorizontalPodAutoscaler — scale on CPU |
| `pdb.yaml` | PodDisruptionBudget — keep a minimum available during node drains |
| `configmap.yaml` | non-secret configuration |
| `ingress.yaml` | frontend only — the public ALB |

```yaml
# helm/backend/templates/networkpolicy.yaml
ingress:
  - from:
      - podSelector:
          matchLabels:
            app: frontend
```

**Only frontend Pods may reach the backend.** This is why the CD smoke test
goes through nginx rather than calling the backend directly: a direct call from
the build agent is correctly refused. If it succeeded, the network isolation
would be broken.

```yaml
# helm/frontend/templates/networkpolicy.yaml
ingress:
  - from:
      - ipBlock:
          cidr: {{ .Values.networkPolicy.vpcCidr }}
    ports:
      - port: 8080
```

The ALB targets Pod IPs directly and its traffic originates inside the VPC, so
the tightest workable rule is "VPC sources, on the nginx port only".

## 6.3 The environment contract

```yaml
envFrom:
  - configMapRef:
      name: {{ .Release.Name }}-config
  - secretRef:
      name: {{ .Values.existingSecret }}
```

Non-secret configuration comes from a ConfigMap rendered by the chart; secrets
come from `backend-secrets` or `worker-secrets` (chosen per chart by
`existingSecret`), which **already exist** because `install-jenkins.sh`
created them. Helm references it and never creates it — which is exactly why
Jenkins needs no access to Secrets.

---

# Part 7 — Tests

## 7.1 What runs where

| Command | What it checks | Needs a cluster? |
|---|---|---|
| `bash tests/run_all.sh` | 108 static and mock checks | no |
| `python3 -m pytest app/` | 51 application unit tests | no |
| `flake8 app/ tests/` | Python lint | no |
| `shellcheck scripts/*.sh` | shell lint | no |
| `./scripts/verify-jenkins.sh` | ~35 live assertions | **yes** |

## 7.2 How the mock suite works

```bash
export PATH="$REPO/tests/mocks:$PATH"
```

Putting `tests/mocks` first on `PATH` means every `aws`, `kubectl`, `helm` and
`terraform` call in the scripts hits a fake that logs the invocation and
returns a canned answer. The real scripts run unmodified, end to end, with no
AWS account and no cluster.

```bash
t T8.2 "destroy: jenkins uninstall → app uninstall → ALB wait → terraform destroy" python3 -c "
log = open('/tmp/mock_destroy.log').read().splitlines()
def idx(sub): return next(i for i,l in enumerate(log) if sub in l)
order = [idx('helm uninstall jenkins'), idx('helm uninstall frontend'), ...]
assert order == sorted(order), order"
```

This is the useful part: the mock log records the **order** of calls, so the
suite asserts that teardown happens in the sequence AWS requires — which is the
difference between a clean destroy and a VPC deletion that hangs for twenty
minutes.

## 7.3 The regression groups

**T14** exists because of bugs actually hit while building this project. Each
test corresponds to something that cost real debugging time:

| Test | The bug it prevents returning |
|---|---|
| T14.1 | a Terraform module dependency cycle |
| T14.3 | the CD agent not bound to the deployer Role |
| T14.14 | a non-free-tier instance type |
| T14.16 | JCasC keys conflicting with chart-owned keys |
| T14.17 | Ingress `pathType` defaulting to exact-match |
| T14.18 | agent Pod volumes colliding with the plugin workspace |
| T14.19 | rootless BuildKit missing one of its three required settings |
| T14.22 | `kubectl get all` requesting resources RBAC does not grant |
| T14.24 | `|| true` masking failed S3 uploads |

**T15** checks compliance with the assignment: CI cannot deploy, CD cannot
build, the four named scripts exist, jobs are defined as code, there are three
ServiceAccounts with the right split, both diagrams exist, no Docker socket is
mounted, PR builds never push.

`tests/check_tf_references.py` deserves a mention: it verifies that every
`aws_*.name`, `var.*`, `module.*` and `file()` path in the Terraform resolves.
It was written after an edit silently deleted the ALB controller IAM role while
`outputs.tf` still exported its ARN — a bug that all 107 other tests passed
straight through.

---

# Part 8 — Running it

## 8.1 Before you start

```bash
aws sts get-caller-identity          # must print your account
terraform version                    # >= 1.5
kubectl version --client             # within +/-1 minor of 1.35
helm version
docker --version

aws ses verify-email-identity --email-address you@example.com --region us-east-1
```

Then click the link in the confirmation email AWS sends.

## 8.2 Configure

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars
```

Five values. `s3_bucket_name` must be globally unique across all of AWS.
`github_repo_url` must be **your** fork, because Jenkins clones from it.

## 8.3 Validate before spending anything

```bash
cd terraform && terraform init && terraform validate && cd ..
helm lint helm/backend helm/worker helm/frontend
bash tests/run_all.sh
```

Free, takes about a minute, and catches the errors that would otherwise
surface eighteen minutes into an EKS apply.

## 8.4 Deploy

```bash
export GITHUB_TOKEN=ghp_xxxxxxxx     # optional
./scripts/deploy.sh
```

Roughly 30 minutes. The long silence during `aws_eks_cluster` creation is
normal — the EKS control plane genuinely takes 15–20 minutes. Do not interrupt.

## 8.5 Run the pipelines

1. Push a commit, or open Jenkins and build `application-ci` manually.
2. Watch an agent Pod appear: `kubectl get pods -n jenkins -w`.
3. CI finishes and triggers `application-cd`.
4. Approve the deployment in CD.
5. The application is live at the ALB address CD prints.

## 8.6 Collect evidence, then tear down

```bash
./scripts/verify-jenkins.sh > evidence/08-verify.txt
# download the Trivy reports and SBOMs from the Jenkins build page
./scripts/destroy.sh
```

`destroy.sh` empties the S3 bucket, so anything stored there goes with it.

## 8.7 If something fails

The README troubleshooting table lists every failure encountered while
building this. The three most likely on a first run:

| Symptom | Cause | Fix |
|---|---|---|
| node group `CREATE_FAILED`, "not eligible for Free Tier" | account restricted to specific instance types | already handled — `m7i-flex.large` |
| `failed calling webhook ... x509` | ALB controller webhook CA rotated | already handled — the install script restarts it |
| Jenkins init container `CrashLoopBackOff` | plugin/core version mismatch | update `jenkins/CHART_VERSION` from `helm search repo jenkins/jenkins --versions` |

For anything else: `kubectl describe pod <name> -n <namespace>` and read the
Events at the bottom. That is where Kubernetes puts the real reason.
