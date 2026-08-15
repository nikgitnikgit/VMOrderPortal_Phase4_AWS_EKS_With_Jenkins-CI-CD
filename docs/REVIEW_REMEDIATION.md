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

## 2. P1 — Security findings (2.1–2.5 ✅ done; 2.6 🔄 open)

### 2.1 ✅ EKS control-plane endpoint open to `0.0.0.0/0`

> Review §5 (MEDIUM) and §8.3

**Files:** `terraform/modules/eks/main.tf`, `terraform/modules/eks/variables.tf`,
`terraform/variables.tf`, `terraform/main.tf`,
`terraform/terraform.tfvars.example`, `README.md`

**What was wrong.** `modules/eks/main.tf` set `endpoint_public_access = true`
with no `public_access_cidrs`, so the Kubernetes API was reachable from the
whole internet with only IAM/RBAC in front of it.

**How it was fixed.** A new `api_public_access_cidrs` variable, wired through
the root module into `vpc_config`:

```hcl
endpoint_public_access  = true
endpoint_private_access = true
public_access_cidrs     = var.api_public_access_cidrs
```

**Deliberately no default.** A default would be either insecure (`0.0.0.0/0`,
the thing being fixed) or wrong for everyone but its author. Terraform now
prompts if it is missing, and test T3.2 already asserts that every variable
without a default appears in `terraform.tfvars.example` — so the documentation
cannot drift from the code.

Two `validation` blocks reject `0.0.0.0/0` explicitly and reject an empty list
(which would lock everyone out).

**Where the operator sets it.** `terraform/terraform.tfvars`, alongside
`db_password` and the other per-contributor secrets. That file is gitignored,
so no real address is ever committed.

**Why two CIDRs, not one.** Public access stays enabled because a human needs
`kubectl` from outside the VPC — `install-jenkins.sh`, `verify-jenkins.sh` and
all debugging depend on it. But a static list plus a rotating ISP address means
eventual lockout, and the only way back is `terraform apply` run blind. A
second entry (phone hotspot) is the break-glass path. `tfvars.example` ships
with two placeholder entries so the shape is obvious.

**Blast radius is small by design.** Nodes and Jenkins agent Pods reach the API
privately via `endpoint_private_access`. Losing your own `kubectl` stops
neither a running deployment nor a pipeline mid-build.

**Operator access path documented** in `README.md` §10.1, as the review
explicitly requires — including the recovery procedure and the diagnostic that
a *timeout* means the CIDR list while *Forbidden* means RBAC.

**Verification.** `terraform fmt -check` clean; T3.0, T3.1 (module wiring) and
T3.2 (tfvars coverage) pass; full suite 115/115.

⚠️ **On first apply after this change** the cluster's endpoint access config is
updated in place — roughly a minute, no downtime, no node restart. If your
address is wrong in `tfvars`, the apply succeeds and *then* you cannot reach
the API. Run `curl -s https://checkip.amazonaws.com` and check the value before
applying.

### 2.2 ✅ One shared `app-secrets` object for backend and worker

> Review §3.7

**Files:** `scripts/install-jenkins.sh`, `helm/backend/values.yaml`,
`helm/worker/values.yaml`, `helm/*/templates/configmap.yaml`,
`jenkins/secret.example.yaml`, `docs/WALKTHROUGH.md`, `docs/PHASE4_PLAN.md`
(plus tests T12.4, T14.42, T14.43, T14.44)

**What was wrong.** A single `app-secrets` object held `DB_HOST`,
`DB_PASSWORD`, `SNS_TOPIC_ARN` and `SES_SENDER`, and both Deployments pulled
all of it in with `envFrom: secretRef`.

**What the split actually buys — stated honestly.** Checking which environment
variables each service reads:

| Key | Backend | Worker |
|---|---|---|
| `DB_HOST` | ✅ | ✅ |
| `DB_PASSWORD` | ✅ | ✅ |
| `SNS_TOPIC_ARN` | ❌ | ✅ |
| `SES_SENDER` | ❌ | ✅ |

**The worker needs all four**, because it publishes to SNS, sends the SES
confirmation, *and* updates `sns_sent`/`ses_sent` on the order row. So the
entire benefit is one-directional: the **backend** stops holding notification
credentials it never uses. That is still worth doing — a compromised backend
pod no longer leaks the topic ARN, which embeds the AWS account ID, or the
verified sender address — but it is less than the finding's phrasing implies,
and the doc says so rather than overclaiming.

**How it was fixed.** `install-jenkins.sh` creates `backend-secrets` (two keys)
and `worker-secrets` (four), and each chart points at its own via
`existingSecret`.

**The step that is easy to miss.** The script also runs:

```bash
kubectl delete secret app-secrets --namespace "$NAMESPACE" --ignore-not-found
```

On an upgrade of an existing cluster the old object would otherwise remain,
still holding the full credential set and still readable by anything with
`get secrets` in that namespace — making the whole fix cosmetic. T14.44 exists
specifically to stop that line being dropped.

**Note on an alternative considered.** Only `DB_PASSWORD` is truly secret;
`SNS_TOPIC_ARN` and `SES_SENDER` are identifiers that could live in the
worker's ConfigMap. That would mean fewer objects and stop mislabeling
non-secrets as secrets. Splitting by workload was chosen instead because
Secrets carry stricter default RBAC than ConfigMaps and the ARN does expose the
account ID — keeping it in a Secret is the more conservative reading of the
review.

**Superseded by 2.6 if implemented.** With External Secrets Operator each
workload gets an `ExternalSecret` naming exactly the keys it needs, so the
sharing problem disappears rather than being divided.

**Verification.** `shellcheck` clean; the example manifest parses as three
valid documents; suite 134/134; T14.42-44 mutation-verified.

### 2.3 ✅ `grep`/`cut` parsing of `terraform.tfvars`

> Review §3.7 and §6.3

**Files:** `scripts/install-jenkins.sh`, `terraform/outputs.tf`,
`tests/mocks/terraform` (plus test T14.34)

**What was wrong.**

```bash
DB_PASSWORD=$(grep -E '^\s*db_password' terraform.tfvars | cut -d'"' -f2)
```

`cut -d'"' -f2` takes everything between the first and second double quote. Any
password containing a `"` is silently truncated; single-quoted values, heredocs
and a commented-out earlier line all break it too. Demonstrated concretely:

| | Value |
|---|---|
| Actual password | `p@ss"w/ord 123` |
| Old `grep`/`cut` | `p@ss` — **wrong, truncated, no error** |
| `terraform output -raw` | `p@ss"w/ord 123` — correct |

The silence is the dangerous part: the wrong password is written into the
Kubernetes Secret and only surfaces much later, at pod start, as an opaque
database authentication failure with no hint at the real cause.

**How it was fixed.** A `sensitive` output, read the same way as the other
fourteen values this script already pulls from Terraform:

```bash
DB_PASSWORD=$(terraform output -raw db_password)
```

One source of truth, no text parsing.

**Does this leak anything?** No. `db_password` was already stored in plain text
in the state file — that is why the state backend is encrypted and private.
`sensitive = true` keeps it out of bare `terraform output` and out of apply
logs, while `-raw` still returns it to the one script that needs it.

**Test-quality note.** `tests/mocks/terraform` now returns a password
containing both a quote and a slash. A mock that only ever returned simple
values could not tell the old implementation from the new one — the test would
have passed against the bug.

**Verification.** `shellcheck` clean; `terraform fmt` clean;
`tests/run_mock_deploy.sh` exercises the new path end to end; suite 124/124.

### 2.4 ✅ No rate limiting, authentication or body-size cap

> Review §5 (MEDIUM), §6.2 and §8.5

**File:** `docker/frontend/nginx.conf` (plus tests T14.28 / T14.29)

**What was wrong.** No `limit_req`, no `client_max_body_size`, no auth.
`/submit-order` was fully open and every call performed RDS + S3 + worker →
SNS + SES work — an amplification path straight to the AWS bill.

**The non-obvious part: keying the limit correctly.** The naive fix is
`limit_req_zone $binary_remote_addr`. Behind an ALB with `target-type=ip`,
**that is worse than no limit at all.** Every request arrives from one of a
handful of load balancer ENIs, so the entire internet shares one bucket: a
single ordinary visitor throttles everyone, while an attacker spreading across
addresses is unaffected.

The ALB *appends* the true client address to `X-Forwarded-For`, so:

```nginx
set_real_ip_from  10.0.0.0/8;
real_ip_header    X-Forwarded-For;
real_ip_recursive off;
```

A client can forge the header, but forged values land **earlier** in the list
and `real_ip_recursive off` makes nginx take the **last** address — the one the
ALB wrote. The key is therefore both correct and unspoofable. Trusting
`10.0.0.0/8` is safe because the frontend NetworkPolicy only admits ALB
traffic, so nothing else can present the header at all.

**Two zones, because the endpoints differ:**

| Zone | Applies to | Rate | Why |
|---|---|---|---|
| `submit` | `= /api/submit-order` | 10/min, burst 5 | Writes RDS, S3, SNS, SES. A human orders a VM a few times a day |
| `api` | `/api/` (health, check-name) | 60/min, burst 20 | `check-name` fires as the user types; too strict breaks the form |

`/healthz` is deliberately **not** limited — the kubelet probes it every few
seconds and throttling it would restart healthy pods.

Also added: `client_max_body_size 16k` (an order is a few hundred bytes; the
nginx default of 1m lets an anonymous caller push a megabyte into Flask's
parser), `limit_req_status 429` (the default 503 reads as "backend down"), and
`server_tokens off`.

**Verified against real nginx 1.24**, not just a parser — a stub backend plus
`curl`:

| Behaviour | Result |
|---|---|
| `/healthz` × 30 rapid | 30 × 200 — never limited |
| `/api/submit-order` × 12 from one client | 6 × 200 (1 + burst 5), then 429 |
| Second client IP, same moment | 200 — per-client, not global |
| Forged `X-Forwarded-For`, new value each request | still 429 after 6 — spoofing does not buy a fresh bucket |
| 1 KB body / 64 KB body | 200 / 413 |
| `check-name` × 20 rapid (simulated typing) | 20 × 200 — form unaffected |

⚠️ **Still no authentication.** Rate limiting caps the damage; it does not stop
a determined distributed abuser. The review asks for "an identity layer or
signed internal access", which is a larger change and remains open.

### 2.5 ✅ CORS enabled for all origins

> Review §6.2

**Files:** `app/backend/app.py`, `app/backend/requirements.txt`,
`jenkins/agent-tools/Dockerfile`, `.github/workflows/ci.yml` (plus test T14.30)

**What was wrong.** `CORS(app)` allowed every origin. The comment beside it —
*"Allow Frontend EC2 to call this API"* — dated it exactly: in phase 2 the
browser called the API on a different host, so cross-origin headers were
genuinely needed.

Under Kubernetes the browser only ever talks to nginx, which proxies `/api/` to
this Service. **Same origin, so CORS is not needed at all** — this was dead
configuration that only widened exposure.

**How it was fixed.** Removed the import and the call, and dropped
`flask-cors` from all three places that installed it. One less dependency to
scan, patch and carry.

**Verification.** `python3 -m pytest app/` passes; full suite 120/120.

### 2.6 🔄 Secrets Manager / External Secrets Operator

> Review §4 (bonus, "not implemented") and §8.7

Currently documented as a future option only. Implementing it closes 2.2 and
2.3 together and picks up two bonus items.

---

## 3. P2 — Correctness bugs ✅ ALL DONE

### 3.1 ✅ False-success deployment — **the Phase 3 bug, in a new place**

> Review §5 (MEDIUM) and §8.4

**File:** `Jenkinsfile-cd` (plus regression tests T14.26 / T14.27)

Two defects were found here, and the second is far more serious than the one
the review pointed at.

#### 3.1a ✅ Duplicate `post` condition — the CD pipeline could never run

Found while fixing 3.1b. `Jenkinsfile-cd` had **two `failure { }` blocks** in
its `post` section: one running diagnostics and the Helm rollback, another
sending the notification email.

Declarative Pipeline forbids this. It rejects the file at **parse time**:

```
WorkflowScript: Duplicate build condition name: failure
```

That is not a runtime warning — the job never starts, no stage executes, and
no rollback is possible because the pipeline as a whole is invalid. The
`application-cd` job **could not have run a single successful build**.

This was invisible because nothing exercised it: no test in the suite read the
`post` section, and the pipeline had not yet been run against a live cluster.
`Jenkinsfile-ci` was checked too and is fine (`always`, `success`, `failure`,
`fixed` — all distinct).

**How it was fixed.** The two blocks were merged into one, with `emailext`
placed *after* the diagnostics and rollback so the notification is sent once,
and only once the cleanup has run.

#### 3.1b ✅ The smoke test was incapable of failing

Phase 3's finding was *"`deploy.sh` exits 0 after a failed live health
verification."* `deploy.sh` was fixed; the same bug had reappeared in the CD
smoke test:

```bash
if [ -n "$ALB" ]; then
    for i in $(seq 1 12); do
        if curl -sf "http://${ALB}/healthz"; then break; fi
        sleep 10
    done                    # 12 failures? the loop just ends. No error.
else
    echo "no ALB address yet ..."                     # also passes
fi
```

Both branches let a completely unreachable application report a green deploy.
`set -e` does not help: a `curl` that fails inside an `if` condition is not an
error, it is the false branch.

**Why this mattered more here than in `deploy.sh`.** A false green in the smoke
test means `post { failure { ... } }` never fires — so the automatic rollback
could not trigger on the exact failure mode it exists to catch. A broken
release would stay live and the pipeline would report success.

**How it was fixed.** An empty `$ALB` is now a hard failure with the two
diagnostic commands worth running. The retry loop sets an explicit `ALB_OK`
flag, and never setting it exits 1 with a clear message. Retrying is still
correct — a new ALB genuinely takes 2-3 minutes to become healthy — but
*never succeeding* is now distinguishable from *succeeding late*.

#### Regression tests

Both bugs could have returned silently, so the suite now covers them:

| Test | Asserts |
|---|---|
| T14.26 | No duplicate `post` conditions in either Jenkinsfile |
| T14.27 | The smoke test contains both failure exit paths |

Both were **mutation-tested**: reintroducing each original bug makes the
corresponding test fail. A regression test that cannot fail would be the same
class of mistake as the bug it guards.

**Verification.** `bash tests/run_all.sh` — 117 passed, 0 failed.

⚠️ **Expect the first real CD run to be noisier than before.** These fixes turn
silent passes into loud failures. If the ALB is genuinely slow or misconfigured
the pipeline will now fail and roll back where it previously reported success —
that is the point, but it is a behaviour change worth knowing about before the
first live run.

### 3.2 ✅ Order submission reports success on partial failure

> Review §5 (MEDIUM), §6.2 and §8.6

**Files:** `app/backend/app.py`, `app/worker/worker.py`, `app/index.html`,
`app/worker/test_worker.py` (plus tests T14.38 / T14.39 / T14.40 / T14.41)

**What was wrong.** Both the S3 upload and the worker notification were wrapped
in bare `except` blocks — with comments saying so — and the handler then
returned `{"success": True}` unconditionally. An order could land in RDS with
no S3 archive and no email while the customer saw a confirmation screen. There
was no idempotency key either, so a double-click created two VMs.

#### Order state

Three states, recorded as the order progresses:

| State | Meaning |
|---|---|
| `received` | In RDS. Nothing downstream has run |
| `stored` | Also archived to S3 |
| `notified` | The worker accepted it and both channels delivered |

The response is now **202 Accepted**, not 200 OK — notification is genuinely
asynchronous, so saying the work is complete would be a lie:

```json
{"success": true, "ticket_id": "VM-NW755KP1", "state": "received", "notified": false}
```

S3 failure remains non-fatal, and that is a deliberate product decision: the
order is safe in RDS and an archive should not be able to lose a customer's
order. What changed is that the failure is **recorded** rather than swallowed,
so an operator can find every affected row with one query.

#### Idempotency

An optional `Idempotency-Key` header. The subtlety is that a
SELECT-then-INSERT check **cannot** be correct: two pods handling a genuine
double-click both find no row and both proceed. So the database is the arbiter
— a partial `UNIQUE` index, with the loser catching `UniqueViolation` and
returning the winner's ticket. The lookup before it is only a fast path.

#### Per-channel notification state

`notification_sent` was set to 1 if **either** channel succeeded, so an order
where SES failed and SNS worked looked identical to one where both worked —
the customer never got their email and nothing recorded it. Now `sns_sent` and
`ses_sent` are separate, the update always runs (previously a total failure
wrote nothing at all, indistinguishable from an order never received), and the
worker returns **207** on a partial send so the backend does not advance the
order to `notified`.

```sql
SELECT ticket_id FROM vm_orders WHERE ses_sent = 0;   -- now answerable
```

`notification_sent` is kept with its original meaning so an older pod
mid-rolling-update keeps working.

#### Migration

`CREATE TABLE IF NOT EXISTS` is a no-op on an existing table, so the new
columns need explicit `ADD COLUMN IF NOT EXISTS`. Being idempotent is what
makes it safe to run from gunicorn's `on_starting` hook on every pod start
without a migration tool.

#### Verified against real PostgreSQL

Tested on a **pre-migration table containing a legacy row**, not a fresh one:

| Test | Result |
|---|---|
| Legacy row after migration | Survived, defaults applied |
| `init_db()` run twice | No error — idempotent |
| S3 + worker both down | `202 state=received notified=false` (was `200 success=true`) |
| Same key twice | Same ticket, `replay:true`, HTTP 200 |
| **10 simultaneous requests, same key** | **1 ticket, 1 row in RDS** |
| No key at all | Works — backwards compatible |
| Malformed key | 400 |
| Worker returns 200 / 207 / 500 | state `notified` / `received` / `received` |

#### Unit tests updated, not accommodated

Two tests in `test_worker.py` asserted the **old** behaviour and had to be
inverted:

- *"one channel failed but return `success: true`"* — the §5 defect
- *"write nothing when both channels fail"* — the §6.2 silent data loss

They were rewritten to assert the corrected behaviour and **confirmed to fail
against the old worker code**, so they pin the fix rather than accommodate it.

#### Still open

A true transactional outbox is the production answer and remains out of scope;
this is the lab-scoped version, documented as such. Backend escaping also still
happens at input rather than output (see 3.3), which is the natural companion
change if this area is revisited.

### 3.3 ✅ `innerHTML` with server-supplied values

> Review §5 (LOW) and §6.2

**Files:** `app/index.html` (plus tests T14.31 / T14.32 / T14.33)

Three related problems, all in the page's rendering path.

#### 3.3a The suggestion chips — two injection contexts in one line

```javascript
suggestions.map(s => `<span class="suggestion-chip" onclick="useSuggestion('${s}')">${s}</span>`)
```

`s` comes from the backend and was interpolated into **an HTML body and a JS
string inside an `onclick` attribute simultaneously**. Escaping correctly for
both at once is notoriously hard; escaping for neither is what happened.

Rebuilt with `createElement` + `textContent` + `addEventListener`. The value is
never serialised into markup or into an attribute, so neither context exists.

#### 3.3b The live summary — rebuilt from user input on every keystroke

`updateSummary()` used `innerHTML` on values the user is actively typing. Now
built as DOM nodes with `textContent`, which is also more *correct*: a machine
name containing `<` now displays a `<` instead of vanishing into the parser.

#### 3.3c Client-side entity encoding — double-encoded every order

`sanitizeAllInputs()` rewrote the user's own input fields to HTML entities
before submit, and `app.py` then ran `html.escape()` on the result.
`O'Brien & Sons` was stored and emailed as `O&amp;#x27;Brien &amp;amp; Sons` —
double-encoded, and irreversibly so.

It was also not a security control: anything client-side is optional from an
attacker's point of view, since `curl` skips the page. Replaced with
`trimAllInputs()`, which only trims whitespace. Server-side validation in
`app.py` is unchanged and remains the actual defence.

#### Verified by executing the real page, not by reading it

The page was loaded under **jsdom** with a stubbed backend returning hostile
suggestions, exercising both render paths:

| Check | Before | After |
|---|---|---|
| `<img src=x onerror=...>` from server → element created? | **yes** | no |
| Same payload typed into the form → element created? | **yes** | no |
| Chip text equals the literal hostile string | no | yes |
| Clicking a chip whose value contains quotes | **broken** | works |
| `"  O'Brien & Sons  "` after submit-time processing | `O&#x27;Brien...` | `O'Brien & Sons` |

The "before" column is the original file run through the identical test — the
vulnerability was confirmed to be real, not theoretical, and the quote-laden
suggestion also proved the old `onclick` was functionally broken.

#### Remaining, deliberately out of scope

`app.py` still calls `html.escape()` at **input** time, so values are stored
HTML-escaped in RDS and appear escaped in the plain-text half of the SES email.
The review's full recommendation — *"validate canonical raw values; escape only
at the output boundary"* — means storing raw and escaping in the HTML email
body only. That touches storage semantics and `worker.py`, so it belongs with
**3.2**, which already changes the schema. Double-encoding, the user-visible
defect, is fixed here.

**Note on scope:** `innerHTML` remains on four lines that assign **static
literals** (the spinner, the "Checking availability" badge). Those carry no
data and are not injection points; T14.31 permits static assignment and fails
only on interpolation, so the distinction is enforced rather than assumed.

### 3.4 ✅ Flask development server in production

> Review §3.12 and §6.2

**Files:** `app/backend/app.py`, `app/worker/worker.py`,
`app/backend/gunicorn.conf.py` (new), `app/worker/gunicorn.conf.py` (new),
`docker/backend/Dockerfile`, `docker/worker/Dockerfile`, both
`requirements.txt`, `helm/backend/templates/deployment.yaml`
(plus tests T14.35 / T14.36 / T14.37)

**What was wrong.** Both services called `app.run()`. Werkzeug is
single-threaded by default, prints a production warning into the pod log on
every start, and is explicitly not built to face traffic.

#### The trap that makes this more than a one-line change

`init_db()` lived inside `if __name__ == "__main__"`. **Gunicorn imports the
module rather than executing it**, so that block never runs — swapping the CMD
alone would have left the table uncreated and every request failing, with
nothing in the diff to suggest why.

The fix is an `on_starting` hook in `gunicorn.conf.py`, which runs in the
master process before any worker forks: once per pod, not once per worker.
It retries a slow RDS five times and then exits 1, so a pod that cannot reach
its database is restarted by Kubernetes rather than serving 500s forever.

#### Two further container-specific hazards, both handled

**Liveness could kill a healthy pod.** `on_starting` runs *before* the port is
bound and can take ~40s against a cold RDS. The existing liveness probe would
have started checking at 15s and killed the pod after three failures — a
restart loop caused entirely by a slow database. A `startupProbe`
(30 x 2s) now suspends liveness and readiness until startup completes.

**`readOnlyRootFilesystem: true` versus gunicorn's heartbeat.** Gunicorn writes
a heartbeat file per worker and its arbiter kills any worker whose file goes
stale. On a read-only filesystem every worker looks hung and is killed in a
loop. The chart already mounts an `emptyDir` at `/tmp`, so
`worker_tmp_dir = "/tmp"` is pinned explicitly rather than left to `TMPDIR`.

#### Other changes

`gthread` workers rather than the default sync worker, because `/submit-order`
blocks on RDS, then S3, then an HTTP call to the worker — sync workers would
serialise concurrent orders behind each other. Timeouts are set relative to
their neighbours: the backend's 60s is not shorter than nginx's
`proxy_read_timeout`, and the worker's 30s reflects the backend giving up on it
after 5s. `keepalive` sits above the ALB idle timeout so the ALB closes idle
connections, not gunicorn — the other way round produces sporadic 502s.

`check_worker_health()` was removed: a `while True` thread started per gunicorn
worker would duplicate every log line, and it only printed. `/health/full`
probes on demand and Kubernetes probes on a schedule.

#### Verified

| Check | Result |
|---|---|
| `Database initialized` in the log | **exactly once**, master pid, before 2 workers boot |
| Werkzeug production warning | gone |
| 6 parallel requests | 127 ms — not serialised |
| Database unreachable at start | 5 retries logged, then `EXIT=1` |
| Unwritable `TMPDIR` | healthy at start and after 12s, zero worker timeouts |
| Pinned requirements in a clean venv | install OK |
| Memory, master with boto3 resident | ~52 MiB against a 256Mi limit |

⚠️ `gunicorn` is pinned to **26.0.0**, the version actually tested here. An
earlier draft pinned 23.0.0; the configuration API is identical across both,
but 26.0.0 is what these results came from.

## 4. P3 — Lower priority (4.8 ✅ done, rest 🔄 open)

| # | Finding | Review ref | Plan |
|---|---|---|---|
| 4.1 | Namespace created imperatively via `kubectl create namespace` | §3.2 (PARTIAL) | Add `k8s/namespace.yaml` and `kubectl apply -f` it |
| 4.2 | Base images tagged but not digest-pinned | §3.12, §5 (LOW) | `FROM python:3.12-slim@sha256:...` across all four Dockerfiles |
| 4.3 | Python dependencies have no hashes | §5 (LOW) | `pip-compile --generate-hashes` |
| 4.4 | App ingress is HTTP-only while Jenkins has HTTPS | §3.5, §4 bonus | Reuse `scripts/create-cert.sh` + ACM for the frontend ingress |
| 4.5 | No Trivy report or SBOM committed | §3.12, §3.13, §7 | CI produces them as build artifacts; commit one run's `trivy-*.txt` and `sbom-*.cdx.json` under `evidence/` |
| 4.6 | Backend NetworkPolicy egress to RDS uses the whole `/16` | §3.8 | Narrow to the DB subnet CIDRs |
| 4.7 | `destroy.sh` verification is account-wide | §6.3 | Filter by project tags rather than `aws eks list-clusters` |
| 4.8 | ✅ Functional test skip guard checked binaries but not privileges | (found in remediation) | Done — see below |
| 4.9 | ✅ T7.1 failed intermittently: `tar` exits 1 if a file changes mid-copy, and CPython writes `.pyc` lazily after the pytest step | (found in remediation) | `run_mock_deploy.sh` now excludes `__pycache__`, `*.pyc` and `.pytest_cache` from the sandbox copy. Verified 5/5 with bytecode present, where it previously failed roughly 1 run in 10. Bytecode has no business in a copy meant to exercise the source |

### 4.8 ✅ Functional test failed on non-root developer machines

**File:** `tests/run_functional.sh`

**Found during remediation, not in the review** — surfaced the first time
`tests/run_all.sh` was run on a developer workstation rather than a root shell.

**What was wrong.** T7.6 is the suite's heaviest check: it boots real
PostgreSQL, real nginx, the real backend and worker, mocks AWS with moto, and
pushes an actual order through every hop. It needs root in three places —
starting the postgresql cluster, `su postgres` to create the test database,
and writing `/usr/share/nginx/html`.

Its skip guard only checked whether `psql` and `nginx` were **installed**:

```bash
if ! command -v psql >/dev/null || ! command -v nginx >/dev/null; then
    echo "SKIPPED (needs postgresql + nginx installed)"
```

So on an Ubuntu workstation that has both packages but is running as a normal
user, the guard passed, the test started, and it died partway through with:

```
tests/run_functional.sh: line 45: /etc/hosts: Permission denied
```

Installed and usable are not the same thing. A test that fails on a correctly
configured machine is worse than no test — it trains you to ignore red results,
which is the same failure mode as the red CI in finding 1.

CI was never affected: GitHub's `ubuntu-latest` runners do not ship nginx, so
the first guard fired and the test skipped.

**How it was fixed — two changes.**

*1. The guard now checks privileges and says how to satisfy them:*

```bash
if [ "$(id -u)" != "0" ]; then
    echo "SKIPPED (needs root: starts the postgresql cluster, creates the test DB)"
    echo "  to run it:  sudo bash tests/run_functional.sh"
    exit 0
fi
```

*2. The `/etc/hosts` dependency was removed entirely.* The script used to
append `127.0.0.1 backend` to `/etc/hosts` so nginx could resolve the
Kubernetes Service name. That mutated a system file outside the repository,
needed root purely for name resolution, and left the line behind after the run.

The nginx config is already copied to `/tmp/qa_ngx/default.conf`, so the
upstream is rewritten *there* instead:

```bash
sed -i 's|proxy_pass http://backend:|proxy_pass http://127.0.0.1:|' /tmp/qa_ngx/default.conf
```

No coverage is lost: **T5.1 separately asserts that the real `nginx.conf`
targets the correct Service name and port**, so this rewrite cannot mask a
mismatch. A `grep -q` guard immediately after the `sed` fails loudly if the
upstream is ever renamed and the substitution silently stops matching —
otherwise the test would keep "passing" against an unmodified config.

**Verification.**

| Condition | Before | After |
|---|---|---|
| root, tools present | runs | runs |
| non-root, tools present | ❌ `Permission denied`, exit 1 | ✅ skips with instructions, exit 0 |
| tools absent (CI) | skips | skips |
| `shellcheck tests/run_functional.sh` | clean | clean |
| `bash tests/run_all.sh` | — | 115 passed, 0 failed |

---

## 5. Evidence — submitted separately in Phase 3 ⬜ NO ACTION

> Review §1: *"none of the mandatory kubectl outputs or functional
> screenshots/transcripts are committed."*

**Context correction.** The Phase 3 evidence was collected and submitted to the
assessor together with the repository link. It was not committed *inside* the
repository, and the review assessed the repository at revision `db163bf` only —
so the finding reflects where the reviewer looked, not missing work.

No remediation is required for Phase 3.

**Carried forward as a habit, not a fix.** `evidence/README.md` already
documents the collection procedure, and `Jenkinsfile-cd` writes a deployment
record to S3 on every run. Keeping future artifacts inside the repository
removes any dependence on the assessor opening a second attachment — cheap
insurance rather than a defect to close.

## 6. Suggested order of work

| When | Items | Rationale |
|---|---|---|
| **Done** | 1.1 – 1.5 | Turns CI green. The review's §9 conclusion names the red CI as a direct cause of the capped score |
| **Done** | 2.1, 4.8 | API endpoint restricted; functional test guard made honest |
| **Done** | 3.1 | Rollback safety net restored; CD pipeline made parseable at all |
| **Done** | 2.4, 2.5 | Public request path hardened; dead CORS config removed |
| **Done** | 3.3, 2.3 | XSS vectors closed; password read structurally |
| **Done** | 3.4, 3.2 | gunicorn with startup/heartbeat handling; order state and idempotency |
| **Done** | 2.2 | Per-workload Secrets; backend no longer holds SNS/SES credentials |
| **Next** | P3 list, or 2.6 | 2.6 adds a runtime dependency — a deliberate decision, not a defect |
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

# 2.1 — confirm your address before the first apply
curl -s https://checkip.amazonaws.com
grep -A4 api_public_access_cidrs terraform/terraform.tfvars

# 4.8 — T7.6 skips as non-root by design. To actually exercise the
# end-to-end path (needs postgresql + nginx installed locally):
sudo bash tests/run_functional.sh
```
