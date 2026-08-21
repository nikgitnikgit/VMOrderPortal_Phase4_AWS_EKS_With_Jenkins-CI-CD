# Evidence

Outputs and screenshots proving each required step. Collect these during a
live cycle, **before** running `destroy.sh` (it empties the S3 bucket).

## How to collect

```bash
# Jenkins on Kubernetes
kubectl get namespaces                                   > evidence/01-namespaces.txt
kubectl get pods -n jenkins -o wide                      > evidence/02-jenkins-pods.txt
kubectl get service,ingress,pvc -n jenkins               > evidence/03-jenkins-exposure.txt
kubectl get serviceaccount,role,rolebinding -n jenkins   > evidence/04-jenkins-rbac.txt
kubectl get role,rolebinding -n devops-app               > evidence/05-app-rbac.txt
helm list -n jenkins                                     > evidence/06-helm-jenkins.txt
kubectl get networkpolicy -n jenkins                     > evidence/07-networkpolicies.txt

# The permission split — the core security claim
./scripts/verify-jenkins.sh                              > evidence/08-verify.txt

# CD results
kubectl get deployments,pods,services,ingress -n devops-app > evidence/20-app-resources.txt
kubectl get pods -n devops-app -o jsonpath='{..image}'      > evidence/21-running-images.txt
kubectl get events -n devops-app --sort-by=.metadata.creationTimestamp > evidence/22-events.txt
HELM_DRIVER=configmap helm list -n devops-app               > evidence/23-helm-app.txt
```

## What is here

Every file is prefixed with a number. The ranges are blocks, so a gap at the end
of a block is deliberate rather than a missing file.

| Range | Block |
|---|---|
| `00` | the deploy run itself |
| `01`–`08` | Jenkins on Kubernetes |
| `09`–`19` | CI pipeline |
| `20`–`29` | CD pipeline |
| `30`–`32` | rollback |
| unnumbered | build artifacts pulled by `scripts/collect-ci-evidence.sh`, kept under their own names |

## Index

| File | What it proves |
|---|---|
| `00-deploy-run.log` | The whole stack builds from nothing: terraform, Jenkins, jobs, webhook, verify. One line is redacted — the printed admin password. |
| `01-namespaces.txt` | Three namespaces; nothing running in `default`. |
| `02-jenkins-pods.txt` | Three states in one file: CI agent up (4 containers), CD agent up (2 containers — no builder), then only the controller. Agents are ephemeral and CD cannot build. |
| `03-jenkins-exposure.txt` | Service, Ingress (HTTPS, IP-restricted) and a Bound PVC. |
| `04-jenkins-rbac.txt` | Three ServiceAccounts, namespaced Roles only, no ClusterRole. |
| `05-app-rbac.txt` | The application namespace's own Roles. |
| `06-helm-jenkins.txt` | Jenkins installed by Helm, not by hand. |
| `07-networkpolicies.txt` | Default-deny plus the specific allows. |
| `08-verify.txt` | `verify-jenkins.sh`, including the **negative** RBAC checks: CI cannot deploy, CD cannot read Secrets. |
| `09-jenkins-both-jobs.png` | Both jobs exist, with the folder description stating they came from JCasC — no manual UI setup. |
| `10-ci-stage-view-green-and-earlier-failures.png` | CI stage view: lint and tests green across builds. |
| `11-ci-trivy-gate-blocks-vulnerable-image.png` | The gate **blocking** a fixable CRITICAL (CVE-2026-31789), with the push stages skipped. |
| `12-ci-trivy-gate-passes-after-fix.png` | The same gate passing once the base image was patched. Together with `11`, the gate has teeth in both directions. |
| `13-ci-image-manifest-tag-and-digests.png` | `image-manifest.json`: immutable tag plus a digest per service. |
| `14-ci-triggered-by-push.png` | A run following a push, with the commit, author and revision. |
| `15-github-webhook-recent-deliveries.png` | GitHub's delivery history for the webhook. |
| `16-github-webhook-delivery-200.png` | One delivery in detail, showing the 200 Jenkins returned. |
| `17-ci-failing-test-does-not-trigger-cd.png` | A deliberately failed test: `Unit tests` red, and `ECR login`, `Push` and `Trigger CD` never run. Nothing is promoted. |
| `18-ecr-images-exist.txt` | The registry's own view: the tag exists, and the digests match `image-manifest.json` and the CD parameters. |
| `19-ci-junit-trend.png` | JUnit results tracked build over build, with the deliberate failure visible as a real data point. |
| `20-app-resources.txt` | Deployments, Pods, Services and Ingress after deployment. |
| `21-running-images.txt` | The image actually running equals the tag CI produced. |
| `22-events.txt` | Namespace events across the rollout. |
| `23-helm-app.txt` | Helm releases for the three services. |
| `24-cd-stage-view-green-and-earlier-failures.png` | CD stage view, including earlier failures and the green run. |
| `25-cd-approval-gate.png` | The manual approval gate — a human authorises promotion. |
| `26-cd-smoke-test-passing.png` | Smoke test reaching the public URL: 200 after the HTTP→HTTPS redirect. It waited out a cold ALB, which is why the retry budget exists. |
| `27-cd-sns-notification.png` | The deployment notification published to SNS, carrying the full traceability block. |
| `28-sns-email-received.png` | The same notification delivered to a subscriber — published *and* received. |
| `29-cd-build-parameters.png` | CD's parameters: started by the upstream CI build, with tag, three digests, originating build and commit. CD deployed; it did not rebuild. |
| `30-history-before.txt` | Helm history before the rollback. |
| `31-rollback.txt` | The rollback itself, and the image afterwards — an older tag, proving it moved rather than restarted. |
| `32-history-after.txt` | Helm history after, showing the new revision. |
| `ci-console.txt` | Full CI console log for the collected build. |
| `image-manifest.json` | The CI→CD contract as a file, not a screenshot. |
| `trivy-*.txt` | Scan reports per service. |
| `sbom-*.cdx.json` | CycloneDX SBOM per service. |
| `s3-deployment-records/` | What CD wrote to S3, pulled down before teardown. |

## Checklist

### Jenkins on Kubernetes
- [x] `01` three namespaces; nothing in `default`
- [x] `02` controller Ready; **an agent Pod present during a build and gone after**
- [x] `03` Service, Ingress (HTTPS + IP-restricted), PVC Bound
- [x] `04` three ServiceAccounts, namespaced Roles only
- [x] `08` verify-jenkins.sh passes, including the negative RBAC checks
- [x] Screenshot: Jenkins UI showing both jobs, neither created by hand — `09`

### CI pipeline
- [x] Screenshot: build triggered **by a push** — `14`
- [x] Screenshot: GitHub → Settings → Webhooks → Recent Deliveries, 200 — `15`, `16`
- [x] Screenshot: stage view with lint and tests green — `10`
- [x] Screenshot: JUnit test trend graph — `19`
- [x] `trivy-*.txt` and `sbom-*.cdx.json` build artifacts
- [x] `image-manifest.json` showing tag **and** digests — file, and `13`
- [x] `aws ecr describe-images` proving the tag exists — `18`
- [x] **A deliberately failing build that does NOT trigger CD** — `17`

### CD pipeline
- [x] Screenshot: CD build showing parameters — tag, digests, CI build, commit — `29`
- [x] Screenshot: the manual approval gate — `25`
- [x] `20`–`23` rollout complete, all Pods Ready
- [x] `21` running image tag == the tag CI produced
- [x] Screenshot: smoke test passing in the console — `26`
- [x] Screenshot / log of a rollback — `30`–`32`

### Beyond the checklist
- [x] `11` + `12` the vulnerability gate blocking and then passing
- [x] `27` + `28` build notification published to SNS and delivered

## Producing the deliberate CI failure

Required by the spec: a failing build must not promote anything.

```bash
git checkout -b break-a-test
# make one unit test fail, e.g. in app/backend/test_app.py:
#   def test_health_returns_ok(client):
#       assert client.get('/health').status_code == 500   # wrong on purpose
git commit -am "deliberate test failure for evidence" && git push -u origin break-a-test
```

Capture: the red build, the Unit tests stage failing, and `application-cd`
with **no** new build queued. Then delete the branch.

## Demonstrating rollback

```bash
# deploy a known-good tag, then an older one, then roll back
HELM_DRIVER=configmap helm history backend -n devops-app  > evidence/30-history-before.txt
HELM_DRIVER=configmap helm rollback backend -n devops-app
kubectl rollout status deployment/backend -n devops-app   > evidence/31-rollback.txt
HELM_DRIVER=configmap helm history backend -n devops-app  > evidence/32-history-after.txt
```
