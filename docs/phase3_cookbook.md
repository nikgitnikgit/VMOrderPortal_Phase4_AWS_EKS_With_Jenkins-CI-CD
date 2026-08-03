# Phase 3 Cookbook — VM Order Portal on Kubernetes (EKS)

This is the exact work plan: every file that will be created, the important
parameters inside it, the values we chose, and why. Read it top to bottom —
it follows the same order the work will be done.

**Final decisions already agreed:**
- Cluster: AWS EKS, 3 nodes
- Packaging: a SEPARATE Helm chart per service (teacher requirement) — three charts sharing one namespace
- Replicas: frontend ×2, backend ×2, worker ×2, spread across different nodes
- Autoscaling: HPA on frontend (2–4) and backend (2–5), CPU target 70%
- Bonuses: IRSA, NetworkPolicies, HPA, Trivy scan, CI/CD, per-service ServiceAccounts

**Project folder structure (the target):**

```
phase3/
├── docker/
│   ├── backend/Dockerfile
│   ├── worker/Dockerfile
│   └── frontend/Dockerfile + nginx.conf
├── app/                      # unchanged code from phase 2
├── terraform/
│   ├── main.tf, variables.tf, outputs.tf
│   └── modules/  vpc | rds | s3 | sns | eks | ecr | irsa
├── helm/
│   ├── backend/   Chart.yaml + values.yaml + templates/
│   ├── worker/    Chart.yaml + values.yaml + templates/
│   └── frontend/  Chart.yaml + values.yaml + templates/ (+ ingress)
├── scripts/
│   ├── build-images.sh
│   ├── create-secret.sh
│   ├── deploy.sh
│   └── destroy.sh
├── k8s/secret.example.yaml
├── docs/architecture (diagram)
├── .github/workflows/ci.yml
└── README.md
```

---

## STEP 1 — Dockerfiles (packaging the services)

### 1.1 `docker/backend/Dockerfile`

| Line | Value | Why |
|---|---|---|
| `FROM` | `python:3.12-slim` | official slim base, pinned version — never `latest` (teacher requirement) |
| `WORKDIR` | `/app` | working directory inside the container |
| `COPY requirements.txt` first, `RUN pip install` after | — | Docker caches layers: dependencies re-install only when requirements change, not on every code edit |
| `COPY app.py` | — | the unchanged phase 2 code |
| `RUN adduser --system appuser` + `USER appuser` | — | run as NON-root (teacher requirement + container security) |
| `EXPOSE` | `5000` | documents the listening port |
| `CMD` | `["python3", "app.py"]` | starts Flask, binds 0.0.0.0:5000 (already in code) |

### 1.2 `docker/worker/Dockerfile`
Identical pattern, port **5001**, copies `worker.py`.

### 1.3 `docker/frontend/Dockerfile`

| Line | Value | Why |
|---|---|---|
| `FROM` | `nginxinc/nginx-unprivileged:1.27-alpine` | official *non-root* nginx variant; listens on **8080** because non-root processes cannot bind ports below 1024 |
| `COPY index.html` | to `/usr/share/nginx/html/` | the phase 2 page, unchanged |
| `COPY nginx.conf` | to `/etc/nginx/conf.d/default.conf` | **the one real change of the project**, see below |

### 1.4 `docker/frontend/nginx.conf` — THE key difference from phase 2
In phase 2, Ansible templated the backend's private IP into
`proxy_pass http://10.23.4.x:5000;`. In Kubernetes, pods get random IPs —
so we proxy to the **Service name** instead. Kubernetes internal DNS
resolves it automatically:

```nginx
location /api/ {
    proxy_pass http://backend:5000/;   # "backend" = the K8s Service name
}
```

No IPs anywhere, ever. This is why no Ansible is needed.

### 1.5 `.dockerignore` (one per service)
Excludes `venv/`, `__pycache__/`, `.env`, `*.md` — keeps images small and
guarantees no secrets are baked into an image (teacher requirement).

---

## STEP 2 — `scripts/build-images.sh` (build + push to ECR)

Parameters at the top of the script:
```bash
VERSION="1.0.0"          # image tag; bump on every change — never latest
AWS_REGION="us-east-1"
SERVICES="frontend backend worker"
```

What it does, in order:
1. `aws ecr get-login-password | docker login ...` — authenticates Docker to your private ECR
2. for each service: `docker build -t vm-order-<svc>:1.0.0 docker/<svc>/`
3. tags it with the full ECR address `<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/vm-order-<svc>:1.0.0`
4. `docker push`
5. bonus: `trivy image --severity HIGH,CRITICAL vm-order-<svc>:1.0.0` — scan report saved to `docs/trivy-report.txt`

---

## STEP 3 — Terraform (the infrastructure)

### Kept from phase 2 (nearly unchanged)
- **modules/vpc** — subnets get 2 required EKS tags: public subnets `kubernetes.io/role/elb = 1` (tells AWS where to place the public load balancer), private subnets `kubernetes.io/role/internal-elb = 1`. NAT Gateway stays — nodes live in private subnets (same security logic you already built!)
- **modules/rds** — unchanged, except its security group now allows port 5432 from the **EKS node security group** instead of backend/worker EC2 SGs
- **modules/s3**, **modules/sns** — unchanged

### Removed from phase 2
- modules/ec2, app security groups, all Ansible — pods replace all of it

### New modules

**modules/eks**
| Resource | Key parameters | Why |
|---|---|---|
| `aws_eks_cluster` | `version = "1.31"`, private subnets | pinned K8s version |
| `aws_eks_node_group` | `instance_types = ["t3.small"]`, `desired_size = 3`, `min_size = 3`, `max_size = 4` | your 3-node decision; t3.small (2 GB) is the realistic minimum — system pods eat ~30% of a node |
| `aws_iam_openid_connect_provider` | cluster OIDC URL | the foundation of IRSA — lets IAM trust Kubernetes ServiceAccounts |

**modules/ecr** — 3 repositories (`vm-order-frontend/-backend/-worker`),
`image_tag_mutability = "IMMUTABLE"` (a pushed tag can never be silently
replaced), `scan_on_push = true` (free AWS scanning = extra bonus evidence).

**modules/irsa** — the phase 3 equivalent of your EC2 instance profiles:
| IAM role | Trusted ServiceAccount | Permissions |
|---|---|---|
| `vm-order-backend-irsa` | `devops-app/backend-sa` | S3 PutObject on our bucket only + SNS Publish on our topic only |
| `vm-order-worker-irsa` | `devops-app/worker-sa` | SNS Publish + SES SendEmail |
| (frontend gets NO role) | `frontend-sa` | nginx needs zero AWS access — least privilege |

The trust policy uses the OIDC provider + condition on the exact
namespace/name of the ServiceAccount — that's the whole IRSA trick.

---

## STEP 4 — The Helm charts (one per service — teacher requirement)

Three independent charts: `helm/backend/`, `helm/worker/`, `helm/frontend/`.
Each has its own `Chart.yaml` (`name: backend|worker|frontend`,
`version: 0.1.0`, `appVersion: "1.0.0"`), its own `values.yaml`, and its own
templates. They share one namespace (`devops-app`) and one Secret, both
created outside the charts by scripts. Trade-off (documented in README):
shared values like region and image registry are passed to each chart
separately — the price of per-service independence.

### `values.yaml` per chart — shown merged here for readability
```yaml
namespace: devops-app          # teacher: never "default"
imageRegistry: ""              # filled by deploy.sh from Terraform output

frontend:
  image: vm-order-frontend
  tag: "1.0.0"
  replicas: 2
  port: 8080
  resources:
    requests: {cpu: 50m,  memory: 64Mi}    # baseline for HPA math
    limits:   {cpu: 200m, memory: 128Mi}
  hpa: {enabled: true, min: 2, max: 4, targetCPU: 70}

backend:
  image: vm-order-backend
  tag: "1.0.0"
  replicas: 2
  port: 5000
  resources:
    requests: {cpu: 100m, memory: 128Mi}
    limits:   {cpu: 500m, memory: 256Mi}
  hpa: {enabled: true, min: 2, max: 5, targetCPU: 70}
  serviceAccountRoleArn: ""    # IRSA role ARN, filled by deploy.sh

worker:
  image: vm-order-worker
  tag: "1.0.0"
  replicas: 2                  # your decision: 2 for availability
  port: 5001
  resources:
    requests: {cpu: 50m,  memory: 96Mi}
    limits:   {cpu: 300m, memory: 192Mi}
  hpa: {enabled: false}        # documented decision: email volume is tiny
  serviceAccountRoleArn: ""

config:                        # goes into the ConfigMap (non-secret only)
  awsRegion: us-east-1
  s3Bucket: ""                 # from Terraform output
  dbName: vmorders
  dbUser: vmadmin
```

### `templates/` inside EACH chart

| File | In which charts | Key parameters |
|---|---|---|
| `configmap.yaml` | each chart, its own values only | backend: region, bucket, db name/user; worker: region, ses sender; frontend: none needed |
| `serviceaccount.yaml` | all three | annotation `eks.amazonaws.com/role-arn: <IRSA ARN>` — this line IS the keyless AWS access; frontend SA has no annotation (needs zero AWS access) |
| `deployment.yaml` | all three | labels `app: <name>`; env from ConfigMap + shared Secret; `readinessProbe`/`livenessProbe: httpGet /health` (your existing endpoints!); `topologySpreadConstraints` — replicas on different nodes; `securityContext: runAsNonRoot: true, allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: drop [ALL]` |
| `service.yaml` | all three, `type: ClusterIP` | internal round-robin balancer — the thing you invented in our discussion. Service names `frontend`/`backend`/`worker` = the DNS names in nginx.conf |
| `ingress.yaml` | **frontend chart only** | `ingressClassName: alb`, `alb.ingress.kubernetes.io/scheme: internet-facing`, routes `/` → frontend Service. Backend/worker have NO ingress (teacher requirement) |
| `hpa.yaml` | frontend + backend (worker: `hpa.enabled: false`) | min/max/targetCPU from that chart's values.yaml |
| `networkpolicy.yaml` | each chart defines rules for ITS pods | frontend: allow ALB→8080; backend: allow only from frontend→5000; worker: allow only from backend→5001; plus DNS/AWS/RDS egress |
| `pdb.yaml` | all three | `minAvailable: 1` — extra bonus, protects during node upgrades |

### Secrets — deliberately NOT a chart template
`scripts/create-secret.sh` reads Terraform outputs and runs
`kubectl create secret generic app-secrets` with `DB_HOST`, `DB_PASSWORD`,
`SNS_TOPIC_ARN`, `SES_SENDER`. Git gets only `k8s/secret.example.yaml`
with placeholder values (teacher requirement). Same philosophy as the
phase 2 vault generation — one source of truth, nothing sensitive in Git.

---

## STEP 5 — Orchestration scripts

**`scripts/deploy.sh`** (the phase 3 twin of your phase 2 deploy.sh):
1. `terraform apply` (~15–20 min — EKS is slow, this is normal)
2. `aws eks update-kubeconfig` — connects your `kubectl` to the new cluster
3. `./build-images.sh` — build, scan, push
4. `helm install aws-load-balancer-controller + metrics-server` — two infrastructure add-ons (ALB controller creates the load balancer for Ingress; metrics-server feeds the HPA)
5. `./create-secret.sh`
6. three installs in logical order, values injected from Terraform outputs:
   `helm upgrade --install backend ./helm/backend -n devops-app --create-namespace --set image.registry=...,serviceAccount.roleArn=...`
   then the same for `worker`, then `frontend`
7. waits for pods Ready, prints the Ingress URL

**`scripts/destroy.sh`**: `helm uninstall frontend worker backend` → wait for the ALB to delete
(otherwise `terraform destroy` fails on the VPC) → `terraform destroy`.
Back to $0.

---

## STEP 6 — CI/CD, diagram, README

- **`.github/workflows/ci.yml`**: on every push — `helm lint`, `terraform validate`, hadolint (Dockerfile linter); on manual trigger — build images, Trivy scan, push to ECR
- **`docs/architecture`** — final diagram: VPC → EKS → namespace → pods/Services/Ingress/SA + RDS/S3/SNS outside, security boundaries marked
- **README** — run instructions + the required Security chapter: permission separation (who has which IRSA role and why frontend has none), secrets management, network flows (who may talk to whom), container security (securityContext), image security (pinned tags, Trivy, ECR scan), Ingress security (only entry point, HTTP-only documented as a trade-off), and every decision we debated: 3 nodes, worker ×2, HPA targets, chart-per-service structure

---

## STEP 7 — Your part: evidence collection

In one session (~1 hour, ~$0.20–0.50):
1. `./scripts/deploy.sh` → screenshot of pods starting
2. `kubectl get nodes / namespaces / pods -n devops-app / deployments / services / ingress` — screenshot each (exact list from the assignment)
3. `kubectl describe pod <backend-pod>` + `kubectl logs <backend-pod>`
4. Open the Ingress URL → place an order → email arrives + JSON in S3 → screenshots
5. `kubectl delete pod <a-backend-pod>` then `kubectl get pods -w` — watch the replacement appear while the site still works
6. HPA bonus demo: small load loop → `kubectl get hpa -w` shows replicas climbing
7. `./scripts/destroy.sh` → screenshot of clean AWS console
