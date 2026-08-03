# Phase 4 Cookbook — Jenkins CI/CD inside the EKS cluster

This is the full work plan: what changes, what gets added, in what order, and
**why** for every decision. Read it top to bottom — it follows the order the
work will actually be done.

Same format as the phase 3 cookbook, but with more explanation, because the
goal here is that you can defend every choice, not just run the scripts.

---

## 0. The one-sentence summary

> Terraform stops at "a running cluster with Jenkins in it". Jenkins does
> everything after that: build the three images, scan them, push them, deploy
> them into pods.

---

## 1. What actually changes from phase 3

In phase 3, the split was clean and you documented it proudly:

> *Terraform creates everything outside the cluster plus the cluster itself.
> Helm/kubectl create everything inside. Nothing overlaps.*

That sentence has to be rewritten, because Jenkins lives **inside** the cluster
but is **not** part of the application. If you leave the old sentence in the
README, a teacher will immediately ask "so who creates Jenkins?"

**The new division of labor — memorise this, it's the core idea of phase 4:**

| Layer | Owner | Contains | Lifecycle |
|---|---|---|---|
| **Infrastructure** | Terraform | VPC, EKS, RDS, S3, SNS, ECR, IAM/IRSA | Created once per cycle, destroyed at the end |
| **Platform** | Terraform + bootstrap script | ALB controller, metrics-server, **Jenkins**, app Secret | Comes up with the infrastructure, before any app exists |
| **Application** | **Jenkins pipeline** | frontend, backend, worker Deployments/Services/Ingress | Built and deployed many times per cycle |

This is the real-world split too. In a company, a platform team owns the
cluster and the CI system; product teams own what runs on it. You are now
modelling both roles. That's a much stronger story than phase 3's version.

**Concretely, `deploy.sh` gets cut in half:**

| Old `deploy.sh` step | Phase 4 owner |
|---|---|
| 1. terraform apply | Terraform (unchanged) |
| 2. kubectl config | Terraform / bootstrap |
| 3. build & push images | **Jenkins pipeline** |
| 4. cluster add-ons | bootstrap script (+ Jenkins now) |
| 5. namespace + Secret | Terraform / bootstrap |
| 6. helm install ×3 | **Jenkins pipeline** |
| 7. wait + print URL | **Jenkins pipeline** |

---

## 2. Target architecture

### Namespaces

| Namespace | What's in it | Created by |
|---|---|---|
| `kube-system` | ALB controller, metrics-server, EBS CSI driver | bootstrap |
| `jenkins` | Jenkins controller pod + ephemeral agent pods | bootstrap |
| `devops-app` | frontend ×2, backend ×2, worker ×2 | **Jenkins** |

Why separate namespaces at all: a namespace is the unit that RBAC,
NetworkPolicy, and resource quotas apply to. Putting Jenkins in `devops-app`
would mean any rule you write for the app also applies to Jenkins, and Jenkins
needs *very* different permissions from an nginx pod. Separation is what makes
"Jenkins may deploy to `devops-app` but may not read its database secret"
expressible at all.

### The flow, end to end

```
you: terraform apply
        │
        ├─ VPC, EKS (3 app nodes + 1 jenkins node), RDS, S3, SNS, ECR, IRSA
        │
        └─ then: bootstrap script
                  ├─ ALB controller + metrics-server + EBS CSI
                  ├─ namespace devops-app + app-secrets Secret
                  └─ helm install jenkins  ──► Jenkins UI reachable
                                                     │
you: open Jenkins, click Build ─────────────────────┘
        │
        ├─ Stage: checkout           (git)
        ├─ Stage: validate           (tf fmt, helm lint, hadolint, shellcheck)
        ├─ Stage: build ×3           (BuildKit pod → ECR)
        ├─ Stage: scan ×3            (Trivy, fail on CRITICAL)
        ├─ Stage: deploy             (helm upgrade --install ×3)
        ├─ Stage: smoke test         (curl /healthz, /api/health)
        └─ Stage: rollback on failure
```

---

## 3. Decisions, and the reasoning behind each

| Decision | Choice | Why |
|---|---|---|
| Where Jenkins runs | Inside EKS, `jenkins` namespace | Your requirement. Also demonstrates dynamic agents, RBAC, and PVCs — three things phase 3 didn't have. |
| Node isolation | **Separate node group** with taint, app nodes stay t3.small | Jenkins is memory-hungry (controller + BuildKit agents). Tainting the Jenkins node keeps app pods off it, keeps app nodes cheap, and demonstrates taints/tolerations. |
| Registry | **Keep ECR** | The node-trust problem (see §10). ECR is already Terraform-managed, kubelet already authenticates to it via the node role, and it's IMMUTABLE which we rely on. A self-hosted registry adds a week of yak-shaving for no new marks. |
| Image builder | **BuildKit rootless** | Pods have no Docker daemon. Docker-in-Docker needs `privileged: true`, which directly contradicts your own container-security section. Kaniko was the classic answer but Google archived it in June 2025. BuildKit is maintained and takes the same Dockerfiles. |
| Jenkins config | **JCasC (Configuration as Code)** | `destroy.sh` deletes the cluster and Jenkins with it. If Jenkins was configured by clicking, every cycle starts from zero. With JCasC, `helm install` reproduces plugins, jobs, and credentials identically. |
| Agent type | **Ephemeral pod per build** | No idle build server burning money; each build gets a clean environment, so "works on the agent" can't rot. This is the whole point of Jenkins-on-Kubernetes. |
| App Secret | **Terraform creates it** | The values (DB host, SNS ARN) *are* Terraform outputs. Jenkins never sees the DB password — it can deploy the app without being able to read its credentials. Least privilege in action. |
| CI trigger | **Manual / polling** | A webhook needs a public Jenkins URL and a stable one. Your cluster is destroyed nightly, so the URL changes every cycle. Poll SCM, or click Build. Document the reason — it's a legitimate constraint, not laziness. |

---

## 4. Terraform changes

### 4.1 Two node groups — keep app nodes cheap, give Jenkins its own space

Your current default is `t3.small` × 3 in a single node group. A `t3.small`
is **2 vCPU / 2 GiB**, of which roughly **1.7 GiB is allocatable** after the
kubelet and system pods take their share. That's fine for your application
pods, but the Jenkins controller alone wants ~1–2 GiB, and a BuildKit agent
pod needs memory too (image builds are mostly decompression). If Jenkins
lands on the same small nodes as the app, you'll get `Pending` pods with
`Insufficient memory`.

**Important concept:** namespaces and nodes are **not** the same thing.
A namespace is a logical label — it controls RBAC and policies. A node is a
physical EC2 machine. By default, **all namespaces share all nodes.** Putting
Jenkins in its own namespace does NOT put it on its own machine. The scheduler
places pods on whichever node has room, regardless of namespace.

To physically separate the workloads, Kubernetes uses two mechanisms:

- **Taint** — a "keep out" sign on a node. Regular pods won't be scheduled
  there. You set this on the node group in Terraform.
- **Toleration** — a pass that says "I know about the taint, let me in."
  You set this on the Jenkins pods in `values.yaml`.
- **nodeSelector** — "only schedule me on nodes with this label." Ensures
  Jenkins doesn't just tolerate the taint but actually *prefers* those nodes.

**The Terraform change — two node groups instead of one:**

```hcl
# ── Group 1: application nodes (unchanged) ──────────────────
resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "app-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  instance_types  = ["t3.small"]          # stays small, stays cheap

  scaling_config {
    desired_size = 3
    min_size     = 1
    max_size     = 4
  }
  # No taint — app pods, system pods, anything without
  # special needs can land here.
}

# ── Group 2: Jenkins node (bigger, tainted) ──────────────────
resource "aws_eks_node_group" "jenkins" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "jenkins-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  instance_types  = ["t3.medium"]         # 4 GiB — room for controller + agent

  scaling_config {
    desired_size = 1                      # one node is enough
    min_size     = 1
    max_size     = 2                      # room to scale if builds queue up
  }

  taint {
    key    = "role"
    value  = "jenkins"
    effect = "NO_SCHEDULE"                # keep out everyone without a pass
  }
}
```

**What the cluster looks like at runtime:**

```
App Node 1 (t3.small)       App Node 2 (t3.small)       App Node 3 (t3.small)
├─ frontend pod             ├─ frontend pod             ├─ backend pod
├─ backend pod              ├─ worker pod               ├─ worker pod
├─ kube-proxy               ├─ kube-proxy               ├─ kube-proxy
└─ coredns                  └─ ALB controller           └─ coredns

Jenkins Node (t3.medium) — tainted: role=jenkins
├─ jenkins controller pod
├─ build agent pod (appears during builds, disappears after)
└─ kube-proxy
```

App pods **physically cannot** land on the Jenkins node. Jenkins **physically
cannot** land on app nodes. Each group is sized for its actual workload.

> **VPC CNI pod limit note:** with the AWS VPC CNI, each node can host a
> limited number of pods because every pod gets a real VPC IP from the node's
> ENIs. `t3.small` caps out around 11 pods, `t3.medium` around 17. With the
> separation, the 3 × 11 limit on app nodes is comfortable for six app pods
> plus system pods, and the Jenkins node has room for the controller plus
> several concurrent agents.

**Cost comparison:**

| Approach | Nodes | Hourly cost |
|---|---|---|
| Old (phase 3): 3 × t3.small | 3 | $0.063 |
| All upgraded: 3 × t3.medium | 3 | $0.125 |
| **Two groups: 3 × t3.small + 1 × t3.medium** | **4** | **$0.104** |

The two-group approach is cheaper than upgrading all nodes, isolates workloads,
and gives you taints/tolerations to demonstrate — a concept phase 3 didn't
touch.

### 4.2 EBS CSI driver — required for Jenkins to have a disk

Jenkins needs persistent storage (`/var/jenkins_home`) so a controller restart
doesn't lose job history mid-cycle. That means a **PersistentVolumeClaim**,
which means a real EBS volume.

**Here's the part people trip on:** since Kubernetes 1.23, EKS does *not*
include the EBS CSI driver by default. Without it, your PVC sits in `Pending`
forever with no obvious error, and Jenkins never starts.

Add to `terraform/modules/eks/main.tf`:

```hcl
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = var.ebs_csi_role_arn   # IRSA — see 4.3
}
```

The driver needs its **own IRSA role** with the AWS-managed policy
`AmazonEBSCSIDriverPolicy`, bound to `kube-system/ebs-csi-controller-sa`.
Same pattern as your ALB controller role — copy that block and change three
strings.

### 4.3 New IRSA roles

Two additions to `terraform/modules/irsa/`:

**a) EBS CSI driver role** — as above.

**b) Jenkins agent role** — this is the one that lets builds push images:

```hcl
# Trust: system:serviceaccount:jenkins:jenkins-agent
# Permissions: ecr:GetAuthorizationToken (account-wide — the API requires it),
#              ecr:BatchCheckLayerAvailability, PutImage, InitiateLayerUpload,
#              UploadLayerPart, CompleteLayerUpload  — on YOUR 3 repos only
#              ecr:BatchGetImage, GetDownloadUrlForLayer  — for Trivy to scan
```

Note the shape: **push permissions scoped to your three repositories**, not
`ecr:*` on `*`. `GetAuthorizationToken` is the one exception that AWS requires
to be account-wide — say so in the README before the teacher asks.

Notice what this role does **not** have: no S3 write, no SNS publish, no RDS
access. Jenkins can ship the application but cannot do anything the application
does. That's the containment argument.

### 4.4 The app Secret moves into Terraform

Today `create-secret.sh` shells out to `terraform output` and `kubectl`. In
phase 4, Terraform creates the Secret directly with the `kubernetes` provider:

```hcl
resource "kubernetes_secret" "app_secrets" {
  metadata {
    name      = "app-secrets"
    namespace = var.k8s_namespace
  }
  data = {
    DB_HOST       = module.rds.address
    DB_PASSWORD   = var.db_password
    SNS_TOPIC_ARN = module.sns.topic_arn
    SES_SENDER    = var.ses_sender
  }
}
```

**Why this is better, not just different:** every value here is already known
to Terraform. Passing them out to a shell script and back in via `kubectl` is a
detour. And critically — **Jenkins is now never given the database password**.
The Secret already exists in the namespace when Jenkins deploys; the pods mount
it; Jenkins itself has no RBAC permission to read Secrets. If Jenkins is
compromised, the attacker cannot read your DB credentials from it.

*Caveat to be honest about in the README:* the password now lives in
Terraform state, which is why remote state on S3 with encryption enabled
(`bootstrap-state.sh`) stops being optional. Note this trade-off explicitly —
acknowledging a weakness scores better than pretending it doesn't exist.

### 4.5 What stays exactly as-is

VPC, RDS, S3, SNS, ECR, the ALB controller role, the backend/worker IRSA roles,
all NetworkPolicies, all three Helm charts. Phase 4 is additive. That's a good
sign about how phase 3 was built.

---

## 5. Installing Jenkins

### 5.1 Why a bootstrap script and not the Terraform `helm` provider

The obvious idea is to add a `helm_release` resource for Jenkins to Terraform,
so one `terraform apply` does everything. It's a well-known trap, and worth
understanding because it comes up constantly in real work.

Terraform configures a provider **before** it builds the dependency graph. The
`helm` provider needs the cluster's endpoint and CA certificate — which don't
exist until the `aws_eks_cluster` resource has been created in that very same
apply. It usually *works* on the first run and then fails on `destroy`, because
the provider tries to configure itself against a cluster that's already gone,
leaving state you have to unpick by hand.

**So:** `terraform apply` for infrastructure, then `scripts/bootstrap-platform.sh`
for the platform layer. One extra line in `deploy.sh`, zero fragility.

*(The textbook production answer is two separate root modules with separate
state files — `infra/` then `platform/`. Worth one sentence in your README to
show you know it; not worth building for a course project.)*

### 5.2 What the bootstrap script does

```bash
aws eks update-kubeconfig ...                    # connect
helm install metrics-server ...                  # (as today)
helm install aws-load-balancer-controller ...    # (as today)
kubectl create namespace jenkins
helm repo add jenkins https://charts.jenkins.io
helm install jenkins jenkins/jenkins \
     -n jenkins --version <PINNED> \
     -f jenkins/values.yaml
kubectl rollout status statefulset/jenkins -n jenkins
```

Pin the chart version. You already learned this lesson the hard way with the
ALB controller (README lesson #4) — the same failure mode applies here.

### 5.3 `jenkins/values.yaml` — the interesting parts

```yaml
controller:
  installPlugins:            # pinned versions, never latest
    - kubernetes:<ver>       # dynamic pod agents
    - workflow-aggregator:<ver>
    - git:<ver>
    - configuration-as-code:<ver>
  serviceType: ClusterIP     # exposed via Ingress, not a second LoadBalancer
  ingress:
    enabled: true
    ingressClassName: alb
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/inbound-cidrs: "<YOUR.IP>/32"   # ← important
  # ── Schedule on the Jenkins node only ──────────────────────
  tolerations:                          # the "pass" for the tainted node
    - key: "role"
      operator: "Equal"
      value: "jenkins"
      effect: "NoSchedule"
  nodeSelector:                         # land on jenkins-nodes, not app-nodes
    eks.amazonaws.com/nodegroup: jenkins-nodes
  JCasC:
    configScripts:
      jobs: |
        jobs:
          - script: >
              pipelineJob('vm-order-cicd') { ... points at Jenkinsfile in Git ... }
persistence:
  enabled: true
  size: 8Gi
serviceAccount:
  create: true               # controller SA — RBAC attaches here
```

**`inbound-cidrs` restricted to your IP** is the single most important line.
An internet-facing Jenkins with no restriction is a genuine security incident
waiting to happen — Jenkins runs arbitrary code by design, and unauthenticated
Jenkins instances get found by scanners within hours. Locking it to your public
IP is one annotation and turns a liability into a defensible design.

---

## 6. RBAC — what to grant and why

The rule to apply: **grant verbs on resources in a namespace, never
`cluster-admin`.** Two Roles, both namespaced.

### Role 1 — in `jenkins`: run builds

| Resource | Verbs | Why |
|---|---|---|
| `pods` | create, delete, get, list, watch | every build creates an agent pod and deletes it after |
| `pods/exec` | create | Jenkins runs the build steps *inside* the agent container |
| `pods/log` | get | streaming build output into the Jenkins console |
| `events` | get, list, watch | so a failing agent shows a real reason, not a silent hang |

### Role 2 — in `devops-app`: deploy the application

| Resource | Verbs | Why |
|---|---|---|
| `deployments`, `services`, `configmaps` | full CRUD | Helm creates and updates them |
| `ingresses`, `horizontalpodautoscalers`, `poddisruptionbudgets`, `networkpolicies`, `serviceaccounts` | full CRUD | the rest of your chart templates |
| `pods`, `pods/log` | get, list, watch | `rollout status` and log-tailing in the smoke test |
| **`secrets`** | **not granted** | ← deliberate. Jenkins deploys an app whose Secret it cannot read. |

That last row is the sentence to put in your README. It's a small thing that
demonstrates you understand what RBAC is *for*.

### The bit that surprises everyone

Inside the pipeline you will run `helm upgrade` and `kubectl` — with **no
kubeconfig and no credentials anywhere**. It just works, because the agent pod
mounts its ServiceAccount token at a well-known path and both tools look there
automatically. Authentication is the pod's identity.

Note the contrast with your application pods, which set
`automountServiceAccountToken: false` precisely so they *can't* do this. Same
mechanism, opposite decision, both correct for their job. If you understand
why, you understand Kubernetes identity.

---

## 7. The pipeline

### 7.1 The agent pod

Each build launches one pod with several containers sharing a workspace:

| Container | Image | Job |
|---|---|---|
| `jnlp` | jenkins/inbound-agent | talks to the controller (added automatically) |
| `tools` | your own small image | aws-cli, kubectl, helm, git, terraform, shellcheck |
| `buildkit` | moby/buildkit:rootless | builds the images |
| `trivy` | aquasec/trivy | scans them |

Build a `jenkins/agent-tools/Dockerfile` for the `tools` container rather than
`apt-get install`-ing on every build — installing four tools per build wastes
about two minutes each time and breaks the day a mirror is down.

The agent pod template also needs the same toleration and nodeSelector as the
controller, so build agents land on the Jenkins node too:

```yaml
agent:
  podTemplates:
    tools: |
      - name: tools
        tolerations:
          - key: "role"
            operator: "Equal"
            value: "jenkins"
            effect: "NoSchedule"
        nodeSelector:
          eks.amazonaws.com/nodegroup: jenkins-nodes
```

Without these, the scheduler would try to place agents on the app nodes
(where they fit poorly) and ignore the Jenkins node (which is tainted).

> **Honest note on BuildKit rootless:** it needs a `securityContext` exception
> (`seccompProfile: Unconfined`) to work in a pod. That's *far* less than
> `privileged: true`, but it isn't nothing. Document it as a scoped exception
> confined to the build container in the `jenkins` namespace, and note that
> your application pods keep `RuntimeDefault`. Naming your own exceptions is
> exactly what a security review looks for.

### 7.2 ECR authentication inside the build

BuildKit doesn't know about AWS. The `tools` container runs
`aws ecr get-login-password` (authenticating via **IRSA**, no keys), writes a
`config.json` into the shared workspace volume, and BuildKit reads it. The
token lives ~12 hours and only inside that pod, which dies at the end of the
build.

### 7.3 The stages

| # | Stage | What it does | Why it's there |
|---|---|---|---|
| 1 | **Checkout** | clone the repo at the triggering commit | — |
| 2 | **Validate** | `terraform fmt -check`, `terraform validate`, `helm lint`, `helm template`, `hadolint` ×3, `shellcheck` | fails in ~30s, before anything expensive |
| 3 | **Unit tests** | pytest on `app/backend`, `app/worker` | you don't have tests yet — even two or three is worth marks |
| 4 | **Build** | BuildKit builds all 3 images, tagged `1.0.${BUILD_NUMBER}`, pushed to ECR | ECR is IMMUTABLE, so BUILD_NUMBER guarantees a never-reused tag |
| 5 | **Scan** | Trivy on all 3 images, **fail on CRITICAL** | phase 3 CI only scanned backend — fixed here |
| 6 | **Deploy** | `helm upgrade --install` ×3 with `--set image.tag=1.0.${BUILD_NUMBER}` | same charts as today, unchanged |
| 7 | **Verify** | `kubectl rollout status` ×3, then `curl` the frontend Service internally **and** the ALB externally | internal proves the pods work; external proves the whole ALB→nginx→backend chain |
| 8 | **Rollback** | on failure: `helm rollback` each release | this is the payoff for having three separate charts |
| 9 | **Post** | archive Trivy reports + `kubectl get all` output as build artifacts | free submission evidence, automatically, every build |

Stage 9 is worth appreciating: your evidence checklist stops being a manual
screenshot exercise and becomes a build artifact with a timestamp.

---

## 8. Build order — the actual work plan

Each phase ends at a checkpoint you can verify. Don't move on until it's green.

| Phase | Work | Checkpoint |
|---|---|---|
| **A** | Two node groups (app: t3.small ×3, jenkins: t3.medium ×1 with taint); EBS CSI addon + IRSA; Jenkins agent IRSA role; app Secret in Terraform | `terraform validate` passes; `terraform plan` shows the second node group and expected additions |
| **B** | `scripts/bootstrap-platform.sh` + `jenkins/values.yaml` (no JCasC yet) | `terraform apply` then bootstrap → Jenkins UI opens in your browser |
| **C** | RBAC Role + RoleBinding; agent pod template | a "hello world" Jenkins job launches an agent pod and prints `kubectl get nodes` |
| **D** | `jenkins/agent-tools/Dockerfile`; build + scan + push stages | three images appear in ECR, tagged with the build number |
| **E** | deploy + verify + rollback stages | app reachable through the ALB, deployed by Jenkins only |
| **F** | JCasC (job defined in code); update `destroy.sh`; README + diagram; tests T13 | destroy → apply → the pipeline runs again with zero clicking |

Phase C is the one to be patient with. If the agent pod won't start, it's RBAC
or scheduling every single time — `kubectl describe pod` in the `jenkins`
namespace tells you which within seconds.

---

## 9. Teardown changes

`destroy.sh` needs three additions, each corresponding to a resource that
didn't exist in phase 3:

1. **Two ALBs now**, not one — the app's and Jenkins's. Both are created by the
   controller, neither is known to Terraform. Uninstall both Helm releases and
   wait for both ALBs to disappear before `terraform destroy`, or the VPC
   deletion hangs. (Same failure you already documented as lesson #5, now
   doubled.)
2. **Delete the Jenkins PVC.** A PVC creates a real EBS volume. Terraform
   doesn't know about it, so it survives `terraform destroy` and quietly costs
   money forever.
3. **`helm uninstall jenkins`** before the rest, so agent pods aren't
   mid-build when the nodes go away.

---

## 10. Gotchas, ranked by how much time they'll cost you

| # | Gotcha | Symptom | Fix |
|---|---|---|---|
| 1 | EBS CSI driver missing | Jenkins pod `Pending` forever, PVC unbound, no useful error | the addon in §4.2 |
| 2 | Nodes too small | pods `Pending`, `Insufficient memory` | separate Jenkins node group at t3.medium (app nodes stay t3.small) |
| 3 | RBAC too narrow | build hangs "waiting for agent", or Helm fails with `forbidden` | read the exact verb in the error — it names what's missing |
| 4 | Chart version drift | worked last week, broken today | pin the Jenkins chart version |
| 5 | Jenkins ALB open to the world | nothing — until it's very much something | `inbound-cidrs` restricted to your IP |
| 6 | Immutable tag collision | push fails on a re-run | always `${BUILD_NUMBER}`, never a fixed version |
| 7 | Self-hosted registry | `ImagePullBackOff` after a green build | avoided entirely by keeping ECR |

Number 7 is worth remembering as a concept even though we're designing around
it: **the node pulls the image, not the pod.** The build pod can push to an
in-cluster Service name; the node's containerd cannot resolve it. Push
succeeds, deploy fails — which is why the failure lands hours after the
mistake.

---

## 11. Documentation and tests to update

- **README** — rewrite the division-of-labor paragraph (§1); replace the "we
  define no Roles or RoleBindings — deliberately" section with the real RBAC
  design (§6); add a CI/CD section; add the BuildKit and Jenkins-exposure
  trade-offs to the trade-off list.
- **Architecture diagram** — add the `jenkins` namespace and the build→push→
  deploy arrows. The current SVG is easy to extend.
- **`tests/run_all.sh`** — add group **T13**: Jenkinsfile parses, `values.yaml`
  is valid YAML with plugins pinned, RBAC manifests contain no `cluster-admin`
  and no `"*"` verbs, destroy script deletes the PVC. Regression tests for
  §9 and §10, in the style you already use.
- **GitHub Actions** — decide: delete it, or keep it as pre-merge validation
  only (lint/validate, no AWS). Keeping it is defensible — "GitHub Actions
  guards the pull request, Jenkins owns build and deploy" — but *only* if you
  strip the AWS access keys out of it, since they contradict your no-keys
  claim.

---

## 12. Cost

| Item | Change |
|---|---|
| App nodes: 3 × t3.small (unchanged) | $0.063/hr (same as phase 3) |
| Jenkins node: 1 × t3.medium (new) | +$0.042/hr |
| Jenkins EBS volume, 8 GiB gp3 | ~$0.64/month if left; deleted with the cluster |
| Second ALB (Jenkins) | ~$0.023/hr while running |
| ECR storage | pennies |
| **Total** | **~$0.104/hr for all 4 nodes** |

A one-hour deploy–demo–destroy cycle stays well under **$1**. The discipline
that matters is unchanged: run `destroy.sh` when you're done.

---

## 13. What you'll be able to say in the defence

- Why Jenkins runs in the cluster, and why it's a platform component rather
  than part of the application.
- What RBAC is, why phase 3 legitimately needed none, and why phase 4 does.
- Why building images in Kubernetes needs BuildKit rather than Docker, and what
  privilege that avoids.
- Why Jenkins can deploy the application but cannot read its database password.
- Which registry you chose and the specific technical reason
  (*the node pulls the image, not the pod*).
- How taints and tolerations physically isolate Jenkins from the application
  nodes, and why namespaces alone don't do that.
- Where every credential comes from, and that none of them are long-lived keys.
