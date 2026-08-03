"""Every resource the pipeline asks kubectl for must be granted in RBAC.

Catches the `kubectl get all` class of bug: a command that silently requests
resource types the ServiceAccount is deliberately not permitted to list, so
the step fails even though the deployment succeeded.
"""
import os, re, sys, yaml

os.chdir(os.path.join(os.path.dirname(__file__), ".."))

ALIAS = {"deployment": "deployments", "deploy": "deployments",
         "replicaset": "replicasets", "rs": "replicasets",
         "pod": "pods", "po": "pods",
         "service": "services", "svc": "services",
         "ingress": "ingresses", "ing": "ingresses",
         "hpa": "horizontalpodautoscalers",
         "configmap": "configmaps", "cm": "configmaps",
         "pdb": "poddisruptionbudgets",
         "secret": "secrets"}

docs = [d for d in yaml.safe_load_all(open("jenkins/rbac.yaml")) if d]
role = [d for d in docs
        if d["kind"] == "Role" and d["metadata"]["namespace"] == "devops-app"][0]
granted = set()
for rule in role["rules"]:
    if "list" in rule["verbs"]:
        granted |= set(rule["resources"])

# strip comment lines so documentation about `get all` is not treated as usage
lines = [l for l in open("Jenkinsfile") if not l.strip().startswith(("//", "#"))]
body = "".join(lines)

fails = []
for group in re.findall(r"kubectl get ([\w,]+)", body):
    for item in group.split(","):
        full = ALIAS.get(item, item)
        if full == "all":
            fails.append("`kubectl get all` requests types RBAC does not grant "
                         "(replicationcontrollers, daemonsets, statefulsets, "
                         "jobs, cronjobs) — list resources explicitly")
        elif full not in granted:
            fails.append(f"kubectl get {item} -> '{full}' not granted list in RBAC")

if fails:
    print("\n".join(sorted(set(fails)))); sys.exit(1)
print(f"all kubectl resource requests are covered by RBAC ({len(granted)} listable types)")
