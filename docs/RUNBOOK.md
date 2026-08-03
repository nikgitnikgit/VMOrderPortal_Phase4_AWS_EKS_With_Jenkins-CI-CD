# Phase 4 runbook — from zip to running application

Follow top to bottom. Each part ends with a check you can verify before
moving on. Do not skip the checks; every one of them catches a failure that
is cheap now and expensive later.

---

## Part 0 — Before you touch anything

### 0.1 Tools that must be on your Linux machine

The scripts call these five binaries. Confirm all of them:

```bash
aws --version          # AWS CLI v2
terraform version      # >= 1.5
kubectl version --client
helm version
docker --version       # needed once, to build the Jenkins agent image
```

`kubectl` must be within one minor version of the cluster. The cluster is
pinned to **1.35** in `terraform/modules/eks/variables.tf`, so install a
matching client:

```bash
KV=$(curl -fsSL https://dl.k8s.io/release/stable-1.35.txt)
curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KV}/bin/linux/amd64/kubectl"
sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
```

Helm 4 is fine — this project uses no `helm registry login`, no `--atomic`,
no `--force`, and no plugins, and its charts are `apiVersion: v2`.

**Before each new cycle, check the EKS version calendar.** A version that has
left standard support is billed at $0.60/cluster/hour instead of $0.10, and
EKS enrols you automatically.

If any are missing, install them before continuing.

### 0.2 AWS credentials

```bash
aws sts get-caller-identity
```

This must print your account ID. If it errors, run `aws configure` first.

### 0.3 SES sender verification

`ses_sender` must be a **verified** address or the worker cannot send mail:

```bash
aws ses list-identities --identity-type EmailAddress --region us-east-1
```

If your address is not listed:

```bash
aws ses verify-email-identity --email-address you@example.com --region us-east-1
```

Then click the link in the confirmation email AWS sends you.

**Check:** all five tools respond, `get-caller-identity` works, sender verified.

---

## Part 1 — Create the repo and unpack the project

### 1.1 Create an empty repo on GitHub

Name it something like `vm-order-portal-phase4`. Do **not** add a README,
.gitignore, or licence — the zip already contains those, and an initialised
repo just creates a merge conflict on your first push.

Your phase 3 repo is untouched by everything below.

### 1.2 Unpack into a new folder

```bash
mkdir -p ~/projects/vm-order-portal-phase4
cd ~/projects/vm-order-portal-phase4
unzip ~/Downloads/phase4.zip
ls -la
```

You should see `app/ docker/ helm/ jenkins/ terraform/ scripts/ tests/ docs/`
plus `Jenkinsfile` and `README.md`.

### 1.3 Fix file permissions

Zip does not reliably preserve the executable bit, so set it explicitly:

```bash
chmod +x scripts/*.sh
chmod +x terraform/bootstrap-state.sh
chmod +x tests/*.sh
chmod +x tests/mocks/*
```

**Check:**

```bash
ls -l scripts/
```

Every `.sh` must show `-rwxr-xr-x`. If they show `-rw-r--r--`, the chmod did
not apply and `./scripts/deploy.sh` will fail with "Permission denied".

---

## Part 2 — Configure

### 2.1 Create terraform.tfvars

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
```

Fill in all five values:

| Variable | Notes |
|---|---|
| `db_password` | Strong password. RDS rejects `/`, `@`, `"`, and spaces. |
| `s3_bucket_name` | Must be **globally unique** across all of AWS and lowercase. Add a random suffix. |
| `notification_email` | Where SNS alerts go. |
| `ses_sender` | The address you verified in step 0.3. |
| `github_repo_url` | Your new repo's HTTPS clone URL. Jenkins clones from here. |

This file is gitignored on purpose — it holds your database password and must
never be committed. Verify:

```bash
cd .. && git status --short 2>/dev/null | grep tfvars
```

Nothing should print (before `git init` this command simply returns nothing,
which is also fine).

### 2.2 Push to GitHub

```bash
git init
git add .
git commit -m "Phase 4: Jenkins CI/CD inside EKS"
git branch -M main
git remote add origin https://github.com/YOUR_USER/vm-order-portal-phase4.git
git push -u origin main
```

**Check:** open the repo in a browser. You must see `Jenkinsfile` at the root
and you must **not** see `terraform/terraform.tfvars`.

This push matters: Jenkins clones `main` from this repo. If the code is not
pushed, the pipeline has nothing to build.

---

## Part 3 — Validate locally before spending money

Everything here is free and takes about a minute. It catches the mistakes that
would otherwise surface twenty minutes into an apply.

```bash
cd terraform
terraform init
terraform fmt -check -recursive
terraform validate
cd ..

helm lint helm/backend helm/worker helm/frontend

bash tests/run_all.sh
```

**Check:** `terraform validate` prints "Success", helm lint passes all three
charts, and the test suite ends with `0 failed`.

If `terraform validate` complains, fix it now. An invalid config fails at
apply time anyway — but only after EKS has been creating for 15 minutes.

---

## Part 4 — Remote state (recommended, once)

State holds resource IDs and is the single thing you cannot recreate. Local
state on your laptop is a single point of failure.

```bash
cd terraform
./bootstrap-state.sh
```

This creates an encrypted, versioned S3 bucket plus a DynamoDB lock table,
writes `backend.tf`, and migrates your state. Answer `yes` when Terraform asks
to copy existing state.

**Check:** `cat backend.tf` shows your bucket, and `terraform init` reports the
S3 backend.

Skip this only if you accept losing state if the laptop dies.

---

## Part 5 — Deploy infrastructure and Jenkins

```bash
cd ~/projects/vm-order-portal-phase4
./scripts/deploy.sh
```

What happens, in order:

1. `terraform apply` — VPC, EKS (3 app nodes + 1 Jenkins node), RDS, S3, SNS,
   ECR, IRSA roles, EBS CSI addon. **15–20 minutes.** The EKS control plane is
   slow; this is normal, do not interrupt it.
2. `bootstrap-platform.sh` — kubeconfig, `devops-app` namespace and Secret,
   metrics-server, ALB controller, Jenkins namespace and RBAC, agent
   ServiceAccount, agent-tools image build and push, Jenkins install, ALB wait.

Total: roughly 25–30 minutes. The script prints the Jenkins URL, username, and
password at the end. **Copy them.**

**Checks:**

```bash
kubectl get nodes                    # 4 nodes, all Ready
kubectl get pods -n jenkins          # jenkins-0 Running 2/2
kubectl get secret app-secrets -n devops-app
kubectl get ingress -n jenkins       # ADDRESS column populated
```

If `jenkins-0` is stuck in `Pending`, run
`kubectl describe pod jenkins-0 -n jenkins` and read the Events at the bottom.
It is almost always the PVC (EBS CSI) or scheduling (taint/nodeSelector).

---

## Part 6 — Run the pipeline

1. Open the Jenkins URL from step 5 in your browser. Access is restricted to
   the public IP you had at deploy time.
2. Log in as `admin` with the printed password.
3. Open the job `vm-order-cicd`.
4. Click **Build with Parameters**, leave `IMAGE_TAG` empty, click **Build**.

Leaving `IMAGE_TAG` empty is the normal case — the pipeline then uses
`1.0.<build number>`, which is required because your ECR repositories are
IMMUTABLE and refuse a repeated tag.

Stages: Setup, Validate, ECR login, Build & Push, Scan, Deploy, Verify,
Archive. First run takes 8–12 minutes; later runs are faster.

**Checks:**

```bash
kubectl get pods -n devops-app       # 6 pods Running
kubectl get ingress -n devops-app    # app ALB address
aws ecr list-images --repository-name vm-order-backend --region us-east-1
```

Then open the app ALB address in a browser.

---

## Part 7 — Collect evidence before destroying

`destroy.sh` empties the S3 bucket, so anything stored there disappears with
it. Download what you need first.

- Jenkins: open the build, download the archived `trivy-*.txt` and
  `cluster-state.txt`.
- Screenshots: pipeline stage view, `kubectl get pods -n devops-app`, the
  running application, `kubectl get nodes` showing both node groups.

```bash
kubectl get all -n devops-app > evidence-app.txt
kubectl get all -n jenkins    > evidence-jenkins.txt
kubectl get nodes -L eks.amazonaws.com/nodegroup > evidence-nodes.txt
```

---

## Part 8 — Destroy

```bash
./scripts/destroy.sh
```

Order matters and the script handles it: Jenkins uninstall, PVC delete,
webhook removal, app charts (frontend first), wait for both ALBs, add-ons,
Jenkins namespace, empty S3 including versions, then `terraform destroy` with
an orphaned-ENI sweep and one retry.

Takes 10–15 minutes.

**Checks:**

```bash
aws eks list-clusters --region us-east-1        # empty
aws ec2 describe-volumes --region us-east-1 \
  --filters Name=status,Values=available        # no stray Jenkins volume
aws elbv2 describe-load-balancers --region us-east-1   # no k8s-* ALBs
```

Confirm in the AWS console Billing page the next day that nothing is running.

---

## Part 9 — Later cycles

Once set up, a cycle is two commands:

```bash
./scripts/deploy.sh     # ~25 min, prints the Jenkins URL
# ... click Build, demo ...
./scripts/destroy.sh    # ~15 min
```

Jenkins rebuilds itself identically every time from `jenkins/values.yaml` and
the `Jenkinsfile` in Git — plugins, job, agent template, credentials. There is
nothing to restore because nothing is stored outside code.

Two things do change between cycles and are handled automatically:

- Your public IP is re-detected, so the Jenkins ALB stays locked to you.
- Build numbers restart at 1, so image tags restart at `1.0.1`. Because ECR is
  immutable, delete the old images first if you want to reuse a tag:
  `aws ecr batch-delete-image --repository-name vm-order-backend --image-ids imageTag=1.0.1`

---

## Troubleshooting quick reference

| Symptom | Cause | Fix |
|---|---|---|
| `Permission denied` on a script | executable bit lost in zip | redo step 1.3 |
| `terraform apply` cycle error | stale `.terraform` from a copied folder | `rm -rf terraform/.terraform && terraform init` |
| `jenkins-0` Pending | PVC unbound or taint mismatch | `kubectl describe pod jenkins-0 -n jenkins` |
| Jenkins URL times out | your IP changed since deploy | re-run `./scripts/bootstrap-platform.sh` |
| Pipeline stuck "waiting for agent" | RBAC or nodeSelector | `kubectl get pods -n jenkins` then describe the agent pod |
| Deploy stage `forbidden` | `jenkins-agent` not bound | `kubectl get rolebinding -n devops-app -o yaml` |
| Build push fails `tag immutable` | tag already used | let the pipeline use `1.0.<BUILD_NUMBER>` |
| Pods `ImagePullBackOff` | image tag not in ECR | `aws ecr list-images --repository-name vm-order-backend` |
| `terraform destroy` hangs on VPC | ALB still deleting | wait, re-run destroy; the script sweeps ENIs |
| Node group `CREATE_FAILED`, `not eligible for Free Tier` | account created on/after 2025-07-15 is hard-restricted to t3.micro, t3.small, t4g.micro, t4g.small, c7i-flex.large, m7i-flex.large | use one of those types; delete the failed node group, then re-run `deploy.sh` |
| Node group stuck `CREATING` 20+ min, `health.issues` empty, no ASG | launch is being rejected but not yet surfaced | `aws autoscaling describe-scaling-activities` names the real cause |
| `failed calling webhook "mservice.elbv2.k8s.aws"`, `x509: certificate signed by unknown authority` | ALB controller was re-upgraded; its webhook CA was regenerated but running pods still serve the old cert | `kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system` (the bootstrap now does this automatically) |
| Jenkins init container `CrashLoopBackOff`, `requires a greater version of Jenkins` | pinned plugin versions pull dependencies needing a newer core than the chart ships | update `jenkins/CHART_VERSION` from `helm search repo jenkins/jenkins --versions`; do not pin plugin versions |
