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

## Checklist

### Jenkins on Kubernetes
- [ ] `01` three namespaces; nothing in `default`
- [ ] `02` controller Ready; **an agent Pod present during a build and gone after**
- [ ] `03` Service, Ingress (HTTPS + IP-restricted), PVC Bound
- [ ] `04` three ServiceAccounts, namespaced Roles only
- [ ] `08` verify-jenkins.sh passes, including the negative RBAC checks
- [ ] Screenshot: Jenkins UI showing both jobs, neither created by hand

### CI pipeline
- [ ] Screenshot: build triggered **by a push** (cause: "Started by GitHub push")
- [ ] Screenshot: GitHub → Settings → Webhooks → Recent Deliveries, 200
- [ ] Screenshot: stage view with lint and tests green
- [ ] Screenshot: JUnit test trend graph
- [ ] `trivy-*.txt` and `sbom-*.cdx.json` build artifacts
- [ ] `image-manifest.json` showing tag **and** digests
- [ ] `aws ecr describe-images` proving the tag exists
- [ ] **A deliberately failing build that does NOT trigger CD** (see below)

### CD pipeline
- [ ] Screenshot: CD build showing parameters — tag, digests, CI build, commit
- [ ] Screenshot: the manual approval gate
- [ ] `20`–`23` rollout complete, all Pods Ready
- [ ] `21` running image tag == the tag CI produced
- [ ] Screenshot: smoke test passing in the console
- [ ] Screenshot / log of a rollback

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
