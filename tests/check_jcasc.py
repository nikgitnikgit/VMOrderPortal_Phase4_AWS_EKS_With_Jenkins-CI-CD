"""Guard against ConfiguratorConflictException.

The Jenkins chart generates its own JCasC config from controller.* values.
Any custom configScript that sets the same jenkins.* key makes JCasC merge
two sources, find a conflict, and refuse to boot. This checks that:
  1. every configScript is valid YAML
  2. no jenkins.* key is defined by two different scripts
  3. no chart-owned key appears in a custom script at all
"""
import os, re, subprocess, sys, yaml

os.chdir(os.path.join(os.path.dirname(__file__), ".."))
CHART_OWNED = {"numExecutors", "securityRealm", "authorizationStrategy", "clouds"}

base = yaml.safe_load(open("jenkins/values.yaml"))
src = open("scripts/bootstrap-platform.sh").read()
block = re.search(r'cat > "\$OVERRIDES" <<EOF\n(.*?)\nEOF\n', src, re.S).group(1)
env = {k: "x" for k in ("JENKINS_NODE_GROUP", "MY_IP", "AWS_REGION", "ECR_REGISTRY",
                        "TOOLS_IMAGE", "BACKEND_ROLE_ARN", "WORKER_ROLE_ARN",
                        "S3_BUCKET", "GITHUB_REPO_URL")}
rendered = subprocess.run(["bash", "-c", "cat <<EOF\n" + block + "\nEOF"],
                          capture_output=True, text=True,
                          env={**os.environ, **env}).stdout
ov = yaml.safe_load(rendered)

seen, fails = {}, []
for label, scripts in (("values.yaml", base["controller"]["JCasC"]["configScripts"]),
                       ("bootstrap overrides", ov["controller"]["JCasC"]["configScripts"])):
    for name, body in scripts.items():
        try:
            doc = yaml.safe_load(body) or {}
        except yaml.YAMLError as e:
            fails.append(f"{label}/{name}: invalid YAML: {e}")
            continue
        for key in doc.get("jenkins", {}):
            seen.setdefault(key, []).append(f"{label}/{name}")

for key, where in seen.items():
    if key in CHART_OWNED:
        fails.append(f"jenkins.{key} is chart-owned but set in {where}")
    if len(where) > 1 and key not in CHART_OWNED:
        fails.append(f"jenkins.{key} defined twice: {where}")

# controller.numExecutors must come from the chart value, not a script
if "numExecutors" not in base["controller"]:
    fails.append("controller.numExecutors should be set as a chart value")

# job-dsl is required for the `jobs:` root element
all_bodies = "".join(base["controller"]["JCasC"]["configScripts"].values()) + rendered
if "jobs:" in all_bodies and "job-dsl" not in base["controller"]["installPlugins"]:
    fails.append("configScripts use `jobs:` but job-dsl plugin is not installed")

if fails:
    print("\n".join(fails)); sys.exit(1)
print(f"JCasC config clean: {len(seen)} jenkins.* keys, no conflicts")
