> **STATUS: implemented.** This document is the gap analysis written before
> the work began. Every item marked as a gap below has since been built;
> see README.md for the delivered system and `bash tests/run_all.sh` (107
> checks) for verification. Kept in the repository as a record of the
> analysis that drove the design.

# Phase 4 — assignment spec vs. what we built

This document compares the official task sheet against the current repository,
lists every gap, and sets out the plan to close them.

**Headline:** what we built is a working single-pipeline CI/CD system. The
assignment requires a **two-pipeline system with a strict CI/CD separation**.
That is the central architectural requirement and it is the main thing we have
to change. Most other gaps are additive.

---

## 1. The requirement we currently violate

The spec is explicit:

> **"אין שלב deploy ב-Pipeline זה"** — there is no deploy stage in the CI pipeline.

> **"כלל קידום גרסה: ה-image שנבדק ב-CI הוא ה-image שנפרס ב-CD. אין לבנות אותו שוב"**
> — the image tested in CI is the image deployed in CD. Do not rebuild it.

| Pipeline | Responsibility | Explicitly forbidden |
|---|---|---|
| **CI** | test, build images, scan, tag, push to registry | deploying to the cluster |
| **CD** | take an existing tag/digest, deploy, verify, rollback | rebuilding the image |

Our current `Jenkinsfile` does **both** in one job. It must be split into
`Jenkinsfile-ci` and `Jenkinsfile-cd`, driven by two separate Jenkins jobs.

This is not cosmetic. It also changes the permission model: the spec says
**"Pipeline ה-CI אינו צריך הרשאות deploy ל-Kubernetes"** — the CI pipeline needs
no deploy permissions at all. Today our single `jenkins-agent` ServiceAccount
has both ECR push *and* Helm deploy rights. That must become two ServiceAccounts.

---

## 2. What we already satisfy

These are done and need no rework:

| Requirement | Where it lives |
|---|---|
| Jenkins runs inside Kubernetes | `jenkins` namespace on EKS |
| Single controller as a persistent Pod | StatefulSet `jenkins-0` |
| Dynamic agents as Pods, deleted after build | Kubernetes plugin podTemplate |
| Controller runs no builds | `controller.numExecutors: 0` |
| PersistentVolumeClaim for Jenkins home | 8Gi gp2 via EBS CSI |
| Dedicated namespaces, nothing in `default` | `jenkins` + `devops-app` |
| Service + Ingress access path | ALB Ingress, IP-restricted |
| JCasC for system config, cloud, agent templates | `jenkins/values.yaml` |
| Plugin list defined in code | `controller.installPlugins` |
| Jobs created from code, not the UI | JCasC + job-dsl |
| No Docker socket mounted | rootless BuildKit |
| Unique image tag, never `latest` | `1.0.${BUILD_NUMBER}` |
| Image scanning | Trivy, fails on CRITICAL |
| No cluster-admin anywhere | two namespaced Roles |
| IRSA instead of static AWS keys | ECR push + scoped S3 write |
| Secrets not in Git or Jenkinsfile | `.gitignore` + bootstrap-created Secret |
| Jenkins UI not open to the internet | ALB `inbound-cidrs` = your IP /32 |
| NetworkPolicies on the application | three charts, phase 3 |
| helm lint / helm template validation | CI validate stage |
| `helm upgrade --install` + `rollout status` | deploy/verify stages |
| Smoke test proving the app works | via frontend, respecting NetworkPolicy |
| Concurrency control | `disableConcurrentBuilds()` |
| Full teardown script | `destroy.sh` |

---

## 3. Gaps, by severity

### 3.1 Blocking — the task is not met without these

| # | Gap | What the spec demands |
|---|---|---|
| B1 | One pipeline doing everything | Separate `Jenkinsfile-ci` and `Jenkinsfile-cd` |
| B2 | One job `vm-order-cicd` | Two jobs: `application-ci`, `application-cd` |
| B3 | CD does not exist as an input-driven job | CD takes `IMAGE_TAG`/`IMAGE_DIGEST` as a parameter, rejects `latest`, never builds |
| B4 | CI agent can deploy | Separate ServiceAccounts: CI agent gets **no** Kubernetes deploy rights |
| B5 | No unit tests, no test results in Jenkins | Run tests and publish results (JUnit); if the project has none, add basic ones |
| B6 | No language-level lint | Static analysis appropriate to the app language (Python) |
| B7 | No webhook | CI triggered by a Git webhook, with evidence of a run caused by a push |
| B8 | Four named scripts missing | `install-jenkins.sh`, `configure-jenkins.sh`, `create-jobs.sh`, `verify-jenkins.sh` (+ uninstall) |
| B9 | No metadata handoff | CI publishes tag **and digest** as an artifact/output that CD consumes |
| B10 | No traceability chain | From a CD build you must identify the CI build, the Git commit, and the image digest |

### 3.2 Required — explicitly listed, currently missing

| # | Gap | Note |
|---|---|---|
| R1 | Jenkins exposed over HTTP | Spec: if exposed via Ingress/LoadBalancer, use HTTPS |
| R2 | Agent containers have no `resources` requests/limits | Required for agent Pods |
| R3 | Agent securityContext incomplete | Need `runAsNonRoot`, `allowPrivilegeEscalation: false`, dropped capabilities, read-only rootfs where possible |
| R4 | No NetworkPolicy in the `jenkins` namespace | Required where the cluster supports it, or a written justification |
| R5 | Controller image tag not pinned explicitly | Spec: fixed version, never `latest` |
| R6 | Agent and controller images not scanned | Both must be scanned |
| R7 | No workspace/credential cleanup on failure | CI must clean up even when it fails |
| R8 | Rollback never demonstrated | Must be documented **and** exercised at least once |
| R9 | No `evidence/` directory | Required deliverable |
| R10 | No credentials example files | `secret.example.yaml` / `values.example.yaml` with no real values |
| R11 | README missing several required chapters | Security chapter, credential rotation/revocation, install/configure/verify/uninstall, trade-offs |
| R12 | Architecture diagram is phase 3 | Needs two views: Deployment View and Pipeline Flow, plus source file |
| R13 | No deliberate-failure evidence | Must show a failing CI run that does **not** trigger CD |

### 3.3 Bonus — optional, listed in the spec

Manual approval before promotion · separate PR pipeline with a quality gate ·
`dev`→`staging` promotion using the same digest · Jenkins Shared Library ·
parallel/matrix builds · SBOM + Cosign signing · External Secrets Operator ·
automated rollback on smoke-test failure (we already have this) ·
backup/restore of Jenkins home · Slack/email notifications.

---

## 4. Target architecture

```
Developer pushes to GitHub
        │
        │  webhook
        ▼
┌──────────────────────────────────────────────────────────┐
│ jenkins namespace                                        │
│                                                          │
│  jenkins-0 (controller, 0 executors)                     │
│      │                                                   │
│      ├── job: application-ci                             │
│      │     agent SA: jenkins-agent-ci                    │
│      │     ├─ checkout (commit SHA)                      │
│      │     ├─ validate (helm lint, hadolint, shellcheck) │
│      │     ├─ lint (flake8) + unit tests (pytest→JUnit)  │
│      │     ├─ build ×3 (BuildKit rootless)               │
│      │     ├─ scan ×3 (Trivy, fail on CRITICAL)          │
│      │     ├─ push ×3 to ECR, tag = git short SHA        │
│      │     ├─ record DIGEST → image-manifest.json        │
│      │     └─ trigger application-cd with the digest     │
│      │        NO DEPLOY. NO KUBERNETES CREDENTIALS.      │
│      │                                                   │
│      └── job: application-cd                             │
│            agent SA: jenkins-agent-cd                    │
│            ├─ validate input (reject latest/empty)       │
│            ├─ helm lint / template / dry-run             │
│            ├─ helm upgrade --install (existing digest)   │
│            ├─ rollout status ×3                          │
│            ├─ verify image running == image requested    │
│            ├─ smoke test through the ALB                 │
│            └─ on failure: helm rollback + events/logs    │
│               NO BUILD. NO ECR PUSH RIGHTS.              │
└──────────────────────────────────────────────────────────┘
        │ deploys into
        ▼
   devops-app namespace: frontend ×2, backend ×2, worker ×2
```

### Permission split (this is the heart of the security answer)

| Identity | Can | Cannot |
|---|---|---|
| `jenkins` (controller) | create/delete agent Pods in `jenkins` | anything in `devops-app` |
| `jenkins-agent-ci` | push/scan images in ECR (IRSA) | **any** Kubernetes deploy; read Secrets |
| `jenkins-agent-cd` | deploy the app in `devops-app` | push images; read Secrets |

No identity can read `backend-secrets` or `worker-secrets`. Helm keeps release history in ConfigMaps
(`HELM_DRIVER=configmap`) precisely so that CD never needs Secret access.

---

## 5. Work plan

Each phase ends at a checkpoint you can verify.

| Phase | Work | Checkpoint |
|---|---|---|
| **A** | Split `Jenkinsfile` into `Jenkinsfile-ci` + `Jenkinsfile-cd`; switch tags to git short SHA; capture image digests into `image-manifest.json` | CI produces images + manifest; CD deploys from a digest alone |
| **B** | Two agent ServiceAccounts + two IRSA roles + revised RBAC (CI has no deploy rights) | `kubectl auth can-i` proves CI cannot create deployments |
| **C** | Two jobs in JCasC/job-dsl; CI triggers CD with the digest; traceability fields printed by both | CD build page shows CI build number, commit, digest |
| **D** | Add `flake8` + `pytest` with JUnit publishing; workspace/credential cleanup on failure | Jenkins shows a test results trend; a failing test fails the build and does not trigger CD |
| **E** | The four named scripts + uninstall; agent resources/securityContext; jenkins NetworkPolicy; pinned & scanned controller/agent images; HTTPS | `verify-jenkins.sh` passes on a clean deploy |
| **F** | Webhook registration; new architecture diagram (2 views); README rewrite; `evidence/` collection; rollback demonstration | A push to `main` triggers CI with no manual action |

---

## 6. Final deliverables

```
├── Jenkinsfile-ci                  # CI only — never deploys
├── Jenkinsfile-cd                  # CD only — never builds
├── jenkins/
│   ├── values.yaml                 # Helm values + JCasC
│   ├── values.example.yaml         # sanitised example
│   ├── CHART_VERSION
│   ├── rbac.yaml                   # 3 SAs, namespaced Roles, no cluster-admin
│   ├── networkpolicy.yaml          # jenkins namespace
│   ├── jobs/                       # Job DSL seed for both jobs
│   └── agent-tools/Dockerfile
├── scripts/
│   ├── install-jenkins.sh          # required name
│   ├── configure-jenkins.sh        # required name
│   ├── create-jobs.sh              # required name
│   ├── verify-jenkins.sh           # required name
│   ├── uninstall-jenkins.sh
│   ├── register-webhook.sh
│   ├── deploy.sh / destroy.sh      # infrastructure
├── app/ docker/ helm/ terraform/   # unchanged from phase 3/4
├── tests/                          # QA suite (92 tests) + app unit tests
├── docs/
│   ├── architecture-deployment.svg # view 1
│   ├── architecture-pipeline.svg   # view 2
│   ├── RUNBOOK.md
│   └── phase4_cookbook.md
├── evidence/                       # required outputs and screenshots
└── README.md                       # incl. Security chapter
```

---

## 7. Open decisions

Four things the spec leaves to us, where the choice materially changes the work.

### 7.1 HTTPS for the Jenkins UI

The spec requires HTTPS if Jenkins is exposed via Ingress/LoadBalancer. An AWS
ALB can only serve HTTPS with a certificate from ACM.

| Option | Effort | Notes |
|---|---|---|
| Real domain + ACM DNS validation | needs a domain you control | cleanest, no browser warning |
| Self-signed cert **imported** into ACM | ~20 lines in the install script | valid HTTPS listener; browser warning on first visit; fully scriptable |
| Keep HTTP, document the compensating control | none | relies on `inbound-cidrs` = your IP; spec allows "explain the protection mechanism" but HTTPS is named explicitly |

**Recommendation:** the self-signed-into-ACM option. It satisfies the literal
requirement, needs nothing you don't already have, and the browser warning is
explainable in one sentence.

### 7.2 Webhook, given an ephemeral cluster

A GitHub webhook needs a stable public URL. Your ALB hostname changes on every
`deploy.sh`. Options:

| Option | Notes |
|---|---|
| Auto-register the hook via the GitHub API during bootstrap | Needs a GitHub PAT held locally (never committed). Deletes and recreates the hook each cycle, so the URL is always right. Fully automated. |
| Update the webhook URL by hand each cycle | Zero setup, one manual step per deploy, easy to forget before a demo |
| SCM polling instead | Simplest, but the spec asks specifically for a webhook |

**Recommendation:** auto-registration, with polling configured as a fallback so
a build still triggers if the hook fails.

### 7.3 How CI hands off to CD

The spec lists four acceptable mechanisms and asks us to pick one and explain it.

**Recommendation:** CI archives `image-manifest.json` (tag, digest, commit,
branch, CI build number) **and** triggers `application-cd` with the digest as a
parameter. This satisfies traceability from both directions and still allows a
purely manual CD run with a hand-entered digest.

### 7.4 Tag scheme

Spec prefers an immutable tag such as the commit SHA, and prefers recording the
digest as well. We currently use `1.0.${BUILD_NUMBER}`, which restarts at 1
whenever Jenkins is rebuilt — and ECR is IMMUTABLE, so a re-run then collides
with an existing tag.

**Recommendation:** switch to the git short SHA, and deploy by **digest** so the
deployed artifact is provably the scanned one.

---

## 8. Effort estimate

| Phase | Estimate |
|---|---|
| A — split the pipelines | 2–3 h |
| B — permission split | 1–2 h |
| C — jobs, trigger, traceability | 1–2 h |
| D — tests, lint, cleanup | 1–2 h |
| E — scripts, hardening, HTTPS, NetworkPolicy | 2–3 h |
| F — webhook, diagrams, README, evidence | 2–3 h |

Roughly 10–15 hours against the sheet's suggested 8, mostly because our
existing phase 3/4 base already covers a large part of the infrastructure work.
