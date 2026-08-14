# Review Remediation Plan

Tracking document for the findings raised in the **Phase 3 review**
(`DevOps on AWS – Task 3`, score 83/100, revision `db163bf`), checked against
the **Phase 4** codebase.

Phase 4 was already under way when the review arrived, so some findings were
fixed incidentally by the Phase 4 redesign. This document records all three
categories honestly: what was already fixed, what is fixed now, and what is
still open.

**Status legend**

| Symbol | Meaning |
|---|---|
| ✅ | Done and verified |
| 🔄 | Planned, not started |
| ⬜ | Accepted risk / out of scope (with reasoning) |

---

## 0. Already fixed by the Phase 4 redesign

These were Phase 3 findings that the Phase 4 architecture resolved before the
review was read. Listed for completeness — no action required.

| Review ref | Finding | How Phase 4 resolved it |
|---|---|---|
| §5 HIGH | EKS 1.31 in paid extended support, ends 26 Nov 2026 | `modules/eks/variables.tf` pins `kubernetes_version = "1.35"` (standard support) |
| §5 MEDIUM | CI uses long-lived AWS access keys | Keys removed from GitHub Actions entirely. Jenkins authenticates to AWS with IRSA; the "no static keys" claim is now true end to end |
| §5 MEDIUM | Trivy scans backend image only | `Jenkinsfile-ci` scans all three images, emits a CycloneDX SBOM per image, and gates on fixable CRITICALs **before** the push stage |
| §6.3 | Default tag `1.0.0` silently reuses an old image | Image tag is now the git short SHA; ECR repositories are immutable, so a re-push of the same tag fails loudly |
| §4 bonus | "CI/CD build and deploy" only partial | Full CI → CD split with RBAC enforcement: `jenkins-agent-ci` has no Kubernetes deploy rights, `jenkins-agent-cd` has no ECR push rights |

---

## 1. P0 — Restore a green quality gate ✅ DONE

> Review §5 (HIGH): *"CI is red — Terraform formatting fails and validation
> never runs in the only workflow execution."*
> Review §8.1: *"Restore a green quality gate."*

This was the review's number-one finding. In Phase 4 it had become **worse**:
the last run before this fix (`31046275033`, 5 Aug 2026) had **three** failing
jobs, not one.

| Job | Before | After |
|---|---|---|
| Terraform fmt & validate | ❌ | ✅ |
| YAML validity | ❌ | ✅ |
| Dockerfile lint (hadolint) | ❌ | ✅ |
| Helm lint | ✅ | ✅ |
| flake8 + pytest | ✅ | ✅ |
| Shell script lint | ✅ | ✅ |
| CI/CD separation | ✅ | ✅ |
| Repository test suite | *(did not exist)* | ✅ |

### 1.1 ✅ Terraform formatting drift

**Files:** 13 `.tf` files (see the table at the end of this section)

**What was wrong.** `terraform fmt -check -recursive` failed. Because it was
the first step in the job, `terraform init` and `terraform validate` never ran
at all — so a purely cosmetic problem was hiding whether the configuration was
even valid. This is exactly the Phase 3 failure, unchanged.

Representative example, `modules/rds/main.tf`:

```hcl
# before — the run aligns to column 25, but backup_retention_period is longer
publicly_accessible    = false
skip_final_snapshot    = true
backup_retention_period = 0
multi_az               = false

# after — fmt re-aligns the whole consecutive run to the longest name
publicly_accessible     = false
skip_final_snapshot     = true
backup_retention_period = 0
multi_az                = false
```

**How it was fixed.** `cd terraform && terraform fmt -recursive`.

**Verification.** The diff is whitespace-only — `diff -r -w -B` between the
before and after trees reports zero differences, so no configuration semantics
changed. Re-running `fmt -check` afterwards reports no drift, confirming the
result is stable.

Files reformatted:

```
terraform/outputs.tf
terraform/modules/ecr/variables.tf
terraform/modules/eks/main.tf
terraform/modules/eks/outputs.tf
terraform/modules/eks/variables.tf
terraform/modules/irsa/outputs.tf
terraform/modules/irsa/variables.tf
terraform/modules/rds/main.tf
terraform/modules/rds/outputs.tf
terraform/modules/rds/variables.tf
terraform/modules/vpc/main.tf
terraform/modules/vpc/outputs.tf
terraform/modules/vpc/variables.tf
```

### 1.2 ✅ fmt no longer masks validate

**File:** `.github/workflows/ci.yml`

**What was wrong.** Beyond the drift itself, the job's *structure* was the
problem: one cosmetic failure suppressed the check that actually matters.
The review calls this out directly in §6.3 — *"make Terraform validation
independent of formatting so both results are visible."*

**How it was fixed.** `fmt -check` now runs with `continue-on-error: true` and
an `id`, `init` and `validate` always run, and a final step re-asserts the fmt
result so the job still fails if formatting drifted. Both signals are now
visible in one run. `-diff` was added so the log shows exactly what to fix.

### 1.3 ✅ YAML validity job used the wrong loader

**File:** `.github/workflows/ci.yml`

**What was wrong.** The job called `yaml.safe_load()`, which accepts exactly
**one** YAML document per file. Three files are multi-document manifests
(`---` separated), which is entirely normal Kubernetes YAML:

| File | Documents |
|---|---|
| `jenkins/rbac.yaml` | 7 |
| `jenkins/networkpolicy.yaml` | 3 |
| `jenkins/secret.example.yaml` | 2 |

Each raised `ComposerError: expected a single document in the stream`.

**This was a bug in the test, not in the manifests.** The YAML was always
valid. A test that fails on correct input is worse than no test — it trains
you to ignore a red build.

**How it was fixed.** `safe_load_all()` wrapped in `list()` to force the
generator to evaluate. The step now also prints per-file results with the
document count, collects all failures instead of aborting on the first, and
additionally covers `helm/*/Chart.yaml`.

### 1.4 ✅ hadolint DL4006 on the Jenkins agent image

**File:** `jenkins/agent-tools/Dockerfile`

**What was wrong.** Two `RUN` steps pipe `curl` into `tar` (the Helm and
ShellCheck installs). Under the default `/bin/sh`, a pipeline's exit status is
that of the **last** command only — so a 404 or a truncated download still
produced a layer that `docker build` considered successful. The broken binary
would then surface hours later, mid-pipeline, as `helm: not found`.

**How it was fixed.** One directive after `FROM`:

```dockerfile
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
```

This is a genuine correctness fix, not a lint suppression — the build now
fails at the download, where the problem actually is.

### 1.5 ✅ Repository test suite wired into CI

**File:** `.github/workflows/ci.yml` (new `repo-tests` job)

**What was wrong.** Review §3.14 and §6.3: *"`tests/run_all.sh` is not invoked
by the GitHub Actions workflow, so repository regression tests do not protect
pull requests."* The suite's 115 checks — the repository's single strongest
quality asset — could only be run by hand, so anything they were written to
catch could still be merged.

**How it was fixed.** A new `repo-tests` job installs `shellcheck` and the
suite's Python dependencies (`pyyaml`, `python-hcl2`, `crossplane`,
`dockerfile`, `kubernetes-validate`, `requests`) and runs
`bash tests/run_all.sh`.

Every check is offline — AWS calls route through `tests/mocks/`, so the job
needs no credentials and adds no attack surface.

**Verification.** 115 passed, 0 failed against the fixed tree.

---

## 2. P1 — Security findings carried over from Phase 3 🔄 OPEN

### 2.1 🔄 EKS control-plane endpoint open to `0.0.0.0/0`

> Review §5 (MEDIUM) and §8.3

`modules/eks/main.tf` sets `endpoint_public_access = true` with no
`public_access_cidrs`, so the Kubernetes API is internet-reachable with only
IAM/RBAC in front of it.

**Plan.** Add an `api_public_access_cidrs` variable (no default — force an
explicit decision) and wire it into the `vpc_config` block. The pattern already
exists in this repo: `jenkins/values.yaml` restricts the Jenkins ALB with
`alb.ingress.kubernetes.io/inbound-cidrs`.

**Caveat to document:** Jenkins agents run inside the VPC and reach the API
privately, so they are unaffected. A human operator on a rotating home IP will
lose `kubectl` access until they re-apply. The README must record that recovery
path — the review explicitly asks to *"document the operator access path."*

### 2.2 🔄 One shared `app-secrets` object for backend and worker

> Review §3.7

`scripts/install-jenkins.sh` creates a single Secret holding `DB_HOST`,
`DB_PASSWORD`, `SNS_TOPIC_ARN` and `SES_SENDER`. Both Deployments consume all
of it via `envFrom: secretRef`, so each workload sees values beyond its need.

**Plan.** Split into `backend-secrets` and `worker-secrets`, selected per chart
through the existing `existingSecret` value. Note the win is partial: the
worker legitimately needs DB access to update `notification_sent`. The real
gain is SES/SNS configuration no longer sitting in the backend.

### 2.3 🔄 `grep`/`cut` parsing of `terraform.tfvars`

> Review §3.7 and §6.3

```bash
DB_PASSWORD=$(grep -E '^\s*db_password' terraform.tfvars | cut -d'"' -f2)
```

Breaks on a password containing `"`, on single-quoted values, on a heredoc, and
on a commented-out duplicate line.

**Plan.** Add a `sensitive` output and read it structurally:

```bash
DB_PASSWORD=$(terraform output -raw db_password)
```

One source of truth, no text parsing. Longer term this is superseded by 2.6.

### 2.4 🔄 No rate limiting, authentication or body-size cap

> Review §5 (MEDIUM) and §6.2

`docker/frontend/nginx.conf` contains no `limit_req`, no `client_max_body_size`
and no auth. `/submit-order` is fully open and each call performs RDS + S3 +
worker → SNS + SES work — an amplification path directly to the AWS bill.

**Plan.** `limit_req_zone` in the `http` block, `limit_req` on the
`/submit-order` location, and a global `client_max_body_size` well below the
1 MB default.

### 2.5 🔄 CORS enabled for all origins

> Review §6.2

`app/backend/app.py` still calls `CORS(app)` with the comment *"Allow Frontend
EC2 to call this API"* — a leftover from the Phase 2 EC2 architecture. Under
Kubernetes the browser talks to nginx and nginx proxies to the backend, so the
request is **same-origin and CORS is not needed at all**.

**Plan.** Remove `CORS(app)` and the `flask-cors` dependency; confirm
`/check-name` and `/submit-order` still work through the ALB.

### 2.6 🔄 Secrets Manager / External Secrets Operator

> Review §4 (bonus, "not implemented") and §8.7

Currently documented as a future option only. Implementing it closes 2.2 and
2.3 together and picks up two bonus items.

---

## 3. P2 — Correctness bugs 🔄 OPEN

### 3.1 🔄 False-success deployment — **the Phase 3 bug, in a new place**

> Review §5 (MEDIUM) and §8.4

Phase 3's finding was *"`deploy.sh` exits 0 after a failed live health
verification."* `deploy.sh` was fixed. The same bug now lives in
`Jenkinsfile-cd`, Smoke test stage:

```bash
if [ -n "$ALB" ]; then
    for i in $(seq 1 12); do
        if curl -sf "http://${ALB}/healthz"; then break; fi
        sleep 10
    done                    # 12 failures? the loop just ends. No error.
else
    echo "no ALB address yet (skipping external check)"   # also passes
fi
```

Both branches let a completely unreachable application report a green deploy.
`set -e` does not help: a `curl` failure inside an `if` condition is not an
error.

**Why this is the highest-value fix in section 3:** it means the pipeline's
automatic rollback stage never triggers on the exact failure mode it exists
for.

**Plan.** Fail hard when `$ALB` is empty; track success with an explicit flag;
on failure dump `kubectl describe ingress` and recent events, then `exit 1`.

### 3.2 🔄 Order submission reports success on partial failure

> Review §5 (MEDIUM), §6.2 and §8.6

`app/backend/app.py` swallows both the S3 and the worker-notification
exceptions — with comments saying so — then unconditionally returns
`{"success": True}`. An order can land in RDS with no S3 record and no email
while the customer sees a confirmation. There is no idempotency key either, so
a double-click creates two orders.

**Plan (lab-scoped; a full outbox is out of scope and will be documented as
the production answer):**

1. `order_state` column: `received` → `stored` → `notified`
2. Return HTTP 202 with the state instead of a blanket `success: true`
3. Accept an `Idempotency-Key` header, `UNIQUE` in the DB, returning the
   existing ticket on repeat
4. Split `notification_sent` into `sns_sent` and `ses_sent` — `worker.py`
   currently sets one flag if *either* channel succeeds, which the review
   flags as losing channel-specific state

### 3.3 🔄 `innerHTML` with server-supplied values

> Review §5 (LOW)

`app/index.html` uses `textContent` almost everywhere — but the name-suggestion
chips interpolate a server-supplied value into **two** injection contexts at
once, an HTML body and a JS string inside an `onclick` attribute:

```javascript
suggestions.map(s => `<span class="suggestion-chip" onclick="useSuggestion('${s}')">${s}</span>`)
```

**Plan.** Build the chips with `createElement` / `textContent` /
`addEventListener` so the value is never parsed as markup or code.

### 3.4 🔄 Flask development server in production

> Review §3.12 and §6.2

`app.py` and `worker.py` both call `app.run()`. Werkzeug's server is
single-threaded by default and prints a production warning into the pod logs.

**Plan.** Add `gunicorn` and switch the Dockerfile `CMD`.

**Caveat:** the backend runs a background health-check thread. With
`--workers 2` it would run twice — drop it (there is already `/health/full`) or
guard it.

---

## 4. P3 — Lower priority 🔄 OPEN

| # | Finding | Review ref | Plan |
|---|---|---|---|
| 4.1 | Namespace created imperatively via `kubectl create namespace` | §3.2 (PARTIAL) | Add `k8s/namespace.yaml` and `kubectl apply -f` it |
| 4.2 | Base images tagged but not digest-pinned | §3.12, §5 (LOW) | `FROM python:3.12-slim@sha256:...` across all four Dockerfiles |
| 4.3 | Python dependencies have no hashes | §5 (LOW) | `pip-compile --generate-hashes` |
| 4.4 | App ingress is HTTP-only while Jenkins has HTTPS | §3.5, §4 bonus | Reuse `scripts/create-cert.sh` + ACM for the frontend ingress |
| 4.5 | No Trivy report or SBOM committed | §3.12, §3.13, §7 | CI produces them as build artifacts; commit one run's `trivy-*.txt` and `sbom-*.cdx.json` under `evidence/` |
| 4.6 | Backend NetworkPolicy egress to RDS uses the whole `/16` | §3.8 | Narrow to the DB subnet CIDRs |
| 4.7 | `destroy.sh` verification is account-wide | §6.3 | Filter by project tags rather than `aws eks list-clusters` |

---

## 5. Evidence gap — the largest single deduction ⬜ IN PROGRESS

> Review §1: *"Largest compliance gap: none of the mandatory kubectl outputs or
> functional screenshots/transcripts are committed."*
> Review §7: *"runtime claims … remain unverified until evidence is supplied."*

`evidence/README.md` documents exactly what to capture, but only
`evidence/08-verify.txt` is committed. This must be collected during a live
cycle, **before** `destroy.sh` runs.

**Highest-value single artifact:** after fix 3.1 lands, deliberately break the
application and capture the CD pipeline detecting it and rolling back. That
demonstrates the capability Phase 3 lost points for claiming without proof.

---

## 6. Suggested order of work

| When | Items | Rationale |
|---|---|---|
| **Done** | 1.1 – 1.5 | Turns CI green. The review's §9 conclusion names the red CI as a direct cause of the capped score |
| **Next** | 2.1, 3.1 | Statically verifiable by a reviewer, and 3.1 restores the rollback safety net |
| **Then** | 2.4, 2.5, 3.3 | Public-facing hardening — §8.5 |
| **Before submission** | Section 5 evidence, 4.5 | §7 states every runtime claim is currently unverified |

---

## 7. Verification commands

Reproduce the P0 result locally before pushing:

```bash
# 1.1 — formatting
cd terraform && terraform fmt -check -recursive && cd ..

# 1.4 — Dockerfile lint (expect no output)
for f in docker/*/Dockerfile jenkins/agent-tools/Dockerfile; do hadolint "$f"; done

# 1.3 — YAML, multi-document aware
python3 -c "
import glob, yaml
for f in glob.glob('jenkins/*.yaml') + glob.glob('helm/*/values.yaml'):
    print(f, len(list(yaml.safe_load_all(open(f)))), 'document(s)')"

# 1.5 — the full suite (expect 115 passed, 0 failed)
bash tests/run_all.sh
```
