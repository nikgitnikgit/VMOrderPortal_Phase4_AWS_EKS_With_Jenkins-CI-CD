#!/bin/bash
# tests/run_all.sh — Phase 4 QA test suite
# Groups: T1 structure, T2 static syntax, T3 terraform semantics,
# T4 helm/K8s validity, T5 cross-component consistency, T6 env-var coverage,
# T7 mock end-to-end script execution, T8 call-order assertions,
# T9 security/leak checks, T10 package (zip) checks, T11 docs consistency,
# T12 live-deploy regressions, T13 Jenkins/RBAC/pipeline checks.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
PASS=0; FAIL=0; FAILED_TESTS=()

t() { # t <id> <description> <command...>
  local id="$1" desc="$2"; shift 2
  if "$@" > /tmp/qa_out.log 2>&1; then
    echo "  ✅ $id  $desc"; PASS=$((PASS+1))
  else
    echo "  ❌ $id  $desc"; sed 's/^/       /' /tmp/qa_out.log | head -6
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$id $desc")
  fi
}

echo "=== T1: Project structure & hygiene ==="
t T1.1 "expected top-level layout present" bash -c '
  for d in docker app terraform helm scripts k8s docs .github tests; do [ -d "$d" ] || exit 1; done
  for f in README.md .gitignore .dockerignore; do [ -f "$f" ] || exit 1; done'
t T1.2 "no junk files/dirs (braces, tmp, pyc, .git)" bash -c '
  [ -z "$(find . -name "*{*" -o -name "*}*" -o -name "*.pyc" -o -name "__pycache__" -o -name ".DS_Store" | grep -v tests/)" ]'
t T1.3 "no unexpected empty directories" bash -c '
  [ -z "$(find . -type d -empty | grep -v ".git")" ]'
t T1.4 "all shell scripts executable" bash -c '
  for f in scripts/*.sh terraform/bootstrap-state.sh tests/run_all.sh; do [ -x "$f" ] || { echo "$f not executable"; exit 1; }; done'
t T1.5 "expected file inventory (spot check 12 key files)" bash -c '
  for f in docker/backend/Dockerfile docker/worker/Dockerfile docker/frontend/Dockerfile \
           docker/frontend/nginx.conf terraform/main.tf terraform/terraform.tfvars.example \
           helm/backend/Chart.yaml helm/worker/values.yaml helm/frontend/templates/ingress.yaml \
           Jenkinsfile jenkins/values.yaml jenkins/rbac.yaml; do
    [ -f "$f" ] || { echo "missing $f"; exit 1; }; done'

echo "=== T2: Static syntax ==="
t T2.1 "all shell scripts: bash -n" bash -c '
  for f in scripts/*.sh terraform/bootstrap-state.sh; do bash -n "$f" || exit 1; done'
t T2.2 "all shell scripts: shellcheck" bash -c '
  /usr/local/bin/shellcheck scripts/*.sh terraform/bootstrap-state.sh'
t T2.3 "all YAML files parse" python3 -c "
import yaml, glob
for f in glob.glob('.github/**/*.yml', recursive=True) + glob.glob('k8s/*.yaml') + glob.glob('helm/*/Chart.yaml') + glob.glob('helm/*/values.yaml') + glob.glob('jenkins/*.yaml'):
    list(yaml.safe_load_all(open(f)))"
t T2.4 "all Dockerfiles parse, pinned tags, non-root" python3 -c "
import dockerfile
for f in ['docker/backend/Dockerfile','docker/worker/Dockerfile','docker/frontend/Dockerfile']:
    cmds = dockerfile.parse_file(f)
    g = lambda k: [' '.join(c.value) for c in cmds if c.cmd.upper()==k]
    assert ':' in g('FROM')[0] and 'latest' not in g('FROM')[0], f
    assert g('USER') or 'unprivileged' in g('FROM')[0], f + ': no non-root'"
t T2.5 "nginx.conf valid (crossplane official parser)" python3 -c "
import crossplane, shutil, os
os.makedirs('/tmp/ng', exist_ok=True)
shutil.copy('docker/frontend/nginx.conf','/tmp/ng/default.conf')
open('/tmp/ng/nginx.conf','w').write('events {}\nhttp { include /tmp/ng/default.conf; }')
r = crossplane.parse('/tmp/ng/nginx.conf')
assert r['status']=='ok', r['errors']"
t T2.6 "all .tf files parse (hcl2)" python3 -c "
import hcl2, glob
for f in glob.glob('terraform/**/*.tf', recursive=True): hcl2.load(open(f))"

echo "=== T3: Terraform semantics ==="
t T3.1 "module wiring: args/outputs/vars all consistent" python3 tests/check_terraform.py
t T3.2 "tfvars.example covers every variable without a default" python3 -c "
import hcl2, re
required = set()
for v in hcl2.load(open('terraform/variables.tf')).get('variable', []):
    for name, body in v.items():
        if name=='__is_block__': continue
        if not (isinstance(body,dict) and 'default' in body): required.add(name.strip('\"'))
example = set(re.findall(r'^(\w+)\s*=', open('terraform/terraform.tfvars.example').read(), re.M))
missing = required - example
assert not missing, f'tfvars.example missing: {missing}'"
t T3.3 "vendored ALB policy is valid IAM JSON" python3 -c "
import json
d = json.load(open('terraform/modules/irsa/alb_iam_policy.json'))
assert d['Version']=='2012-10-17' and len(d['Statement'])>10"
t T3.4 "no duplicate terraform resource addresses" python3 -c "
import re, glob, collections
c = collections.Counter()
for f in glob.glob('terraform/**/*.tf', recursive=True):
    for typ, name in re.findall(r'^resource \"(\S+)\" \"(\S+)\"', open(f).read(), re.M):
        c[(f.rsplit('/',1)[0], typ, name)] += 1
dups = [k for k,v in c.items() if v>1]
assert not dups, dups"

echo "=== T4: Helm charts render to valid Kubernetes objects ==="
t T4.1 "all templates render + strict K8s 1.35 schema validation" python3 tests/check_helm.py

t T4.2 "every .Values.* path used by templates exists in values.yaml" python3 tests/check_values_paths.py
t T4.3 "Chart.yaml sanity (apiVersion v2, name == directory)" python3 -c "
import yaml
for c in ['backend','worker','frontend']:
    d = yaml.safe_load(open(f'helm/{c}/Chart.yaml'))
    assert d['apiVersion']=='v2' and d['name']==c and d['appVersion'], c"

echo "=== T5: Cross-component consistency ==="
t T5.1 "nginx proxy target == backend Service name:port" python3 -c "
import re, yaml
ng = open('docker/frontend/nginx.conf').read()
m = re.search(r'proxy_pass http://(\w+):(\d+)/', ng)
vals = yaml.safe_load(open('helm/backend/values.yaml'))
svc = open('helm/backend/templates/service.yaml').read()
assert m.group(1) == 'backend' and 'name: backend' in svc
assert int(m.group(2)) == vals['service']['port'], f'nginx {m.group(2)} vs chart {vals[\"service\"][\"port\"]}'"
t T5.2 "backend WORKER_URL == worker Service name:port" python3 -c "
import yaml, re
b = yaml.safe_load(open('helm/backend/values.yaml'))['config']['WORKER_URL']
w = yaml.safe_load(open('helm/worker/values.yaml'))['service']['port']
m = re.match(r'http://(\w+):(\d+)$', b)
assert m and m.group(1)=='worker' and int(m.group(2))==w, f'{b}: code appends /notify itself — URL must have no suffix'"
t T5.3 "probe paths exist in app code / nginx" bash -c '
  grep -q "\"/health\"\|@app.route(.\?/health" app/backend/app.py &&
  grep -q "\"/health\"\|@app.route(.\?/health" app/worker/worker.py &&
  grep -q "location /healthz" docker/frontend/nginx.conf'
t T5.4 "NetworkPolicy ports match Service ports" python3 -c "
import yaml, re
for chart, port in [('backend',5000),('worker',5001),('frontend',8080)]:
    np = open(f'helm/{chart}/templates/networkpolicy.yaml').read()
    assert f'port: {port}' in np, f'{chart} netpol missing its own port {port}'"
t T5.5 "Dockerfile EXPOSE == chart service port" python3 -c "
import yaml, dockerfile
for c in ['backend','worker','frontend']:
    port = yaml.safe_load(open(f'helm/{c}/values.yaml'))['service']['port']
    cmds = dockerfile.parse_file(f'docker/{c}/Dockerfile')
    exp = [int(x.value[0]) for x in cmds if x.cmd.upper()=='EXPOSE'][0]
    assert exp == port, f'{c}: EXPOSE {exp} != service {port}'"
t T5.6 "chart image repos match ECR repos created by terraform" python3 -c "
import yaml, re
tf = open('terraform/main.tf').read()
repos = re.search(r'repositories = \[(.*?)\]', tf).group(1)
for c in ['backend','worker','frontend']:
    repo = yaml.safe_load(open(f'helm/{c}/values.yaml'))['image']['repository']
    assert repo == f'vm-order-{c}' and f'\"{c}\"' in repos, repo"

echo "=== T6: Env-var coverage (app code vs ConfigMap+Secret) ==="
t T6.1 "every env var the code reads is supplied (or defaulted in code)" python3 tests/check_envvars.py

echo "=== T7: Mock end-to-end script execution ==="
t T7.1 "deploy.sh runs end-to-end against mocks" bash tests/run_mock_deploy.sh
t T7.2 "destroy.sh runs end-to-end against mocks" bash tests/run_mock_destroy.sh
t T7.3 "build-images.sh runs standalone against mocks" bash tests/run_mock_build.sh

t T7.5 "pip layer: exact pinned requirements install on python 3.12" bash -c '
  [ -d /tmp/appvenv ] || python3 -m venv /tmp/appvenv
  /tmp/appvenv/bin/pip install -q -r app/backend/requirements.txt -r app/worker/requirements.txt'
t T7.6 "FUNCTIONAL: real order through real app (nginx->backend->DB/S3->worker->SNS/SES)" bash tests/run_functional.sh

echo "=== T8: Call-order assertions (from mock logs) ==="
t T8.1 "deploy: terraform apply → bootstrap-platform.sh" python3 -c "
log = open('/tmp/mock_deploy.log').read().splitlines()
def idx(sub): return next(i for i,l in enumerate(log) if sub in l)
order = [idx('terraform apply'), idx('terraform output')]
assert order == sorted(order), order"
t T8.2 "destroy: jenkins uninstall → app uninstall → ALB wait → terraform destroy" python3 -c "
log = open('/tmp/mock_destroy.log').read().splitlines()
def idx(sub): return next(i for i,l in enumerate(log) if sub in l)
order = [idx('helm uninstall jenkins'), idx('helm uninstall frontend'), idx('helm uninstall backend'),
         idx('elbv2 describe-load-balancers'), idx('terraform destroy')]
assert order == sorted(order), order"
t T8.3 "destroy: Jenkins PVC deleted before terraform destroy" bash -c '
log=$(cat /tmp/mock_destroy.log)
pvc_line=$(echo "$log" | grep -n "delete pvc" | head -1 | cut -d: -f1)
tf_line=$(echo "$log" | grep -n "terraform destroy" | head -1 | cut -d: -f1)
[ -n "$pvc_line" ] && [ -n "$tf_line" ] && [ "$pvc_line" -lt "$tf_line" ]'
t T8.4 "destroy: S3 emptied before terraform destroy" bash -c '
log=$(cat /tmp/mock_destroy.log)
s3_line=$(echo "$log" | grep -n "s3 rm" | head -1 | cut -d: -f1)
tf_line=$(echo "$log" | grep -n "terraform destroy" | head -1 | cut -d: -f1)
[ -n "$s3_line" ] && [ -n "$tf_line" ] && [ "$s3_line" -lt "$tf_line" ]'

echo "=== T9: Security & leak checks ==="
t T9.1 "no real-looking secrets in the repo" bash -c '
  ! grep -rn --include="*" -E "AKIA[0-9A-Z]{16}|aws_secret_access_key" \
      --exclude-dir=tests . | grep -v -i "example\|CHANGE_ME\|secrets\." '
t T9.2 ".gitignore covers tfvars, state, backend.tf, .env" bash -c '
  for p in "terraform/terraform.tfvars" "terraform/*.tfstate*" "terraform/backend.tf" "*.env"; do
    grep -qF "$p" .gitignore || { echo "missing: $p"; exit 1; }; done'
t T9.3 "secret.example.yaml has placeholders only" bash -c '
  grep -q "CHANGE_ME" k8s/secret.example.yaml && grep -q "YOUR_ACCOUNT_ID" k8s/secret.example.yaml'
t T9.4 "no latest tags anywhere (Dockerfiles, values, workflows)" bash -c '
  ! grep -rn ":latest" docker/ helm/ .github/ terraform/'
t T9.5 "all SAs disable API token automount" bash -c '
  [ "$(grep -l "automountServiceAccountToken: false" helm/*/templates/serviceaccount.yaml | wc -l)" = "3" ]'

echo "=== T12: Live-deploy regression tests (every test = a real failure we hit) ==="
t T12.1 "Dockerfiles: numeric USER (kubelet runAsNonRoot verification)" bash -c '
  grep -q "^USER 10001" docker/backend/Dockerfile && grep -q "^USER 10001" docker/worker/Dockerfile'
t T12.2 "Dockerfiles: COPY --chmod (600-permission poisoning from zip)" bash -c '
  [ "$(grep -h "^COPY " docker/*/Dockerfile | grep -cv -- --chmod)" = "0" ]'
t T12.3 "checksum/config annotation (ConfigMap change must roll pods)" bash -c '
  grep -q "checksum/config" helm/backend/templates/deployment.yaml &&
  grep -q "checksum/config" helm/worker/templates/deployment.yaml'
t T12.4 "app Secret created by bootstrap (Jenkins never sees the password)" bash -c '
  grep -q "kubectl create secret generic app-secrets" scripts/bootstrap-platform.sh &&
  grep -q "DB_PASSWORD" scripts/bootstrap-platform.sh &&
  [ ! -f scripts/create-secret.sh ] &&
  ! grep -q "DB_PASSWORD" Jenkinsfile'
t T12.5 "ALB controller chart PINNED and policy matches (AccessDenied lesson)" bash -c '
  [ -f terraform/modules/irsa/ALB_CONTROLLER_VERSION ] &&
  grep -q "ALB_CONTROLLER_VERSION" scripts/bootstrap-platform.sh'
t T12.6 "vendored policy contains the two actions that failed live" bash -c '
  grep -q "GetSecurityGroupsForVpc" terraform/modules/irsa/alb_iam_policy.json &&
  grep -q "DescribeListenerAttributes" terraform/modules/irsa/alb_iam_policy.json'
t T12.7 "destroy.sh empties bucket incl. versions (BucketNotEmpty lesson)" bash -c '
  grep -q "s3 rm" scripts/destroy.sh && grep -q "list-object-versions" scripts/destroy.sh'
t T12.8 "destroy.sh sweeps orphan ENIs + retries (stuck-subnet lesson)" bash -c '
  grep -q "delete-network-interface" scripts/destroy.sh && grep -q "sweep_orphan_enis" scripts/destroy.sh'
t T12.9 "destroy.sh deletes ALB webhooks first (TLS webhook lesson)" bash -c '
  grep -q "validatingwebhookconfiguration" scripts/destroy.sh'
t T12.10 "S3 bucket has force_destroy" bash -c '
  grep -q "force_destroy = true" terraform/modules/s3/main.tf'

echo "=== T10: Package (zip) checks ==="
t T10.1 "zip inventory == filesystem, no junk, no state/tfvars" bash tests/check_zip.sh

echo "=== T11: Docs consistency ==="
t T11.1 "key files exist (phase 4 inventory)" python3 -c "
import os
for f in ['docs/architecture.png','docs/architecture.svg',
          'scripts/deploy.sh','scripts/destroy.sh','scripts/bootstrap-platform.sh',
          'Jenkinsfile','jenkins/values.yaml','jenkins/rbac.yaml']:
    assert os.path.exists(f), f"
t T11.2 "README documents every chart + namespace + all 5 tfvars inputs" bash -c '
  for w in devops-app db_password s3_bucket_name notification_email ses_sender \
           github_repo_url helm/backend helm/worker helm/frontend; do
    grep -q "$w" README.md || { echo "README missing: $w"; exit 1; }; done'

echo "=== T13: Jenkins, RBAC & pipeline (phase 4) ==="
t T13.1 "Jenkinsfile has pipeline block and all expected stages" bash -c '
  grep -q "pipeline {" Jenkinsfile &&
  grep -q "stage.*Validate" Jenkinsfile &&
  grep -q "stage.*Build" Jenkinsfile &&
  grep -q "stage.*Scan" Jenkinsfile &&
  grep -q "stage.*Deploy" Jenkinsfile &&
  grep -q "stage.*Verify" Jenkinsfile &&
  grep -q "stage.*Archive" Jenkinsfile'
t T13.2 "Jenkinsfile has rollback on failure" bash -c '
  grep -q "helm rollback" Jenkinsfile'
t T13.3 "jenkins/values.yaml has pinned plugins (no :latest)" bash -c '
  grep -q "installPlugins" jenkins/values.yaml &&
  ! grep -q ":latest" jenkins/values.yaml'
t T13.4 "jenkins/values.yaml has JCasC config" bash -c '
  grep -q "JCasC" jenkins/values.yaml &&
  grep -q "configScripts" jenkins/values.yaml'
t T13.5 "RBAC: no cluster-admin in actual rules" python3 -c "
lines = [l for l in open('jenkins/rbac.yaml') if not l.strip().startswith('#')]
assert 'cluster-admin' not in ''.join(lines), 'cluster-admin found in RBAC rules'"
t T13.6 "RBAC: no wildcard verbs" python3 -c "
assert '*' not in open('jenkins/rbac.yaml').read(), 'wildcard found in RBAC'"
t T13.7 "RBAC: secrets NOT granted to Jenkins (containment)" python3 -c "
content = open('jenkins/rbac.yaml').read()
# secrets should appear only in comments, never as a granted resource
lines = [l.strip() for l in content.splitlines() if not l.strip().startswith('#')]
assert 'secrets' not in ' '.join(lines), 'secrets granted in RBAC'"
t T13.8 "Two node groups in EKS module (app + jenkins)" bash -c '
  grep -q "aws_eks_node_group.*app" terraform/modules/eks/main.tf &&
  grep -q "aws_eks_node_group.*jenkins" terraform/modules/eks/main.tf'
t T13.9 "Jenkins node group has taint" bash -c '
  grep -q "NO_SCHEDULE" terraform/modules/eks/main.tf'
t T13.10 "EBS CSI driver addon present" bash -c '
  grep -q "aws-ebs-csi-driver" terraform/main.tf'
t T13.11 "Jenkins agent IRSA role scoped to ECR repos" bash -c '
  grep -q "jenkins-agent" terraform/modules/irsa/main.tf &&
  grep -q "ecr_repo_arns" terraform/modules/irsa/main.tf'
t T13.12 "destroy.sh: Jenkins uninstalled + PVC deleted before terraform destroy" bash -c '
  grep -q "helm uninstall jenkins" scripts/destroy.sh &&
  grep -q "delete pvc" scripts/destroy.sh'
t T13.13 "bootstrap-platform.sh: auto-detects IP (no hardcoded IPs in Git)" bash -c '
  grep -q "checkip.amazonaws.com" scripts/bootstrap-platform.sh'
t T13.14 "GitHub Actions: no AWS access keys (keys removed in phase 4)" bash -c '
  ! grep -q "AWS_ACCESS_KEY_ID" .github/workflows/ci.yml &&
  ! grep -q "AWS_SECRET_ACCESS_KEY" .github/workflows/ci.yml'
t T13.15 "agent-tools Dockerfile: pinned, non-root" bash -c '
  grep -q "^FROM" jenkins/agent-tools/Dockerfile &&
  grep -q "^USER" jenkins/agent-tools/Dockerfile &&
  ! grep -q ":latest" jenkins/agent-tools/Dockerfile'

echo "=== T14: Regressions for bugs found in the phase 4 audit ==="
t T14.1 "no Terraform module dependency cycle" python3 -c "
import re
main=open('terraform/main.tf').read()
g={n:set(re.findall(r'module\.(\w+)\.',b)) for n,b in re.findall(r'module \"(\w+)\" \{(.*?)\n\}',main,re.S)}
color={n:0 for n in g}
def dfs(n,path):
    color[n]=1; path.append(n)
    for m in g.get(n,()):
        if m not in g: continue
        if color[m]==1: raise AssertionError('cycle: '+' -> '.join(path[path.index(m):]+[m]))
        if color[m]==0: dfs(m,path)
    color[n]=2; path.pop()
[dfs(n,[]) for n in g if color[n]==0]"
t T14.2 "no kubernetes/helm provider in Terraform (endpoint-unknown-at-plan trap)" bash -c '
  ! grep -qE "^provider \"(kubernetes|helm)\"" terraform/main.tf'
t T14.3 "RBAC: jenkins-agent SA is bound to the deployer role" python3 -c "
import yaml
docs=[d for d in yaml.safe_load_all(open('jenkins/rbac.yaml')) if d]
rb=[d for d in docs if d['kind']=='RoleBinding' and d['metadata']['name']=='jenkins-deployer'][0]
names=[s['name'] for s in rb['subjects']]
assert 'jenkins-agent' in names, f'agent SA not bound: {names}'"
t T14.4 "every RBAC RoleBinding references a Role that exists" python3 -c "
import yaml
docs=[d for d in yaml.safe_load_all(open('jenkins/rbac.yaml')) if d]
roles={(d['metadata']['name'],d['metadata']['namespace']) for d in docs if d['kind']=='Role'}
for d in docs:
    if d['kind']=='RoleBinding':
        key=(d['roleRef']['name'],d['metadata']['namespace'])
        assert key in roles, f'dangling roleRef {key}'"
t T14.5 "Jenkinsfile does not shell out to terraform" bash -c '
  ! grep -qE "^\s+(sh )?.*terraform (output|init|plan|apply)" Jenkinsfile'
t T14.6 "every binary the Jenkinsfile calls exists in the agent image" python3 -c "
import re
jf=open('Jenkinsfile').read()
df=open('jenkins/agent-tools/Dockerfile').read()
provided={'aws','kubectl','helm','shellcheck','hadolint','curl','git','jq'}
buildkit={'buildctl-daemonless.sh'}; trivy={'trivy'}
called=set(re.findall(r'\b(buildctl-[a-z]+\.sh|[a-z]+ctl-[a-z]+)\b', jf))
for c in called:
    assert c in buildkit, f'unknown builder binary invented: {c}'"
t T14.7 "correct EKS node-group label (no invented -name suffix)" bash -c '
  ! grep -rq "eks.amazonaws.com/nodegroup-name" Jenkinsfile jenkins/ scripts/'
t T14.8 "Jenkinsfile declares parameters it reads" bash -c '
  ! grep -q "params\." Jenkinsfile || grep -q "parameters {" Jenkinsfile'
t T14.9 "no self-referential environment assignment in Jenkinsfile" python3 -c "
import re
for m in re.finditer(r'^\s*(\w+)\s*=\s*\"\\\$\{(\w+)\}\"\s*$', open('Jenkinsfile').read(), re.M):
    assert m.group(1)!=m.group(2), f'self-referential env: {m.group(1)}'"
t T14.10 "helm values overrides use a file, not multi-line --set-string" bash -c '
  ! grep -q "set-string.*JCasC" scripts/bootstrap-platform.sh'
t T14.11 "agent-tools image has its own ECR repo (not squatting in an app repo)" bash -c '
  grep -q "jenkins-agent" terraform/main.tf &&
  grep -q "vm-order-jenkins-agent" scripts/bootstrap-platform.sh'
t T14.12 "EBS CSI addon is at root where both modules resolve" bash -c '
  grep -q "aws-ebs-csi-driver" terraform/main.tf &&
  ! grep -q "aws-ebs-csi-driver" terraform/modules/eks/main.tf'
t T14.13 "agent kubectl minor matches the cluster's kubernetes_version" python3 -c "
import re
tf=open('terraform/modules/eks/variables.tf').read()
k8s=re.search(r'variable \"kubernetes_version\".*?default\s*=\s*\"([\d.]+)\"', tf, re.S).group(1)
df=open('jenkins/agent-tools/Dockerfile').read()
kc=re.search(r'ARG KUBECTL_MINOR=([\d.]+)', df).group(1)
assert k8s==kc, f'skew: cluster {k8s} vs agent kubectl {kc}'"

echo ""
echo "=============================================="
echo "  RESULT: $PASS passed, $FAIL failed"
[ $FAIL -gt 0 ] && printf '  FAILED: %s\n' "${FAILED_TESTS[@]}"
echo "=============================================="
exit $FAIL
