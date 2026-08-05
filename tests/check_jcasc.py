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
src = open("scripts/configure-jenkins.sh").read()
block = re.search(r'cat > "\$OVERRIDES" <<EOF\n(.*?)\nEOF\n', src, re.S).group(1)
env = {k: "x" for k in ("JENKINS_NODE_GROUP", "MY_IP", "AWS_REGION", "ECR_REGISTRY",
                        "TOOLS_IMAGE", "BACKEND_ROLE_ARN", "WORKER_ROLE_ARN",
                        "S3_BUCKET", "GITHUB_REPO_URL", "CLUSTER_NAME",
                        "NOTIFICATION_EMAIL", "SES_SENDER", "CERT_ARN")}
# REPO_ROOT must be real: the overrides heredoc splices jenkins/jobs/seed.groovy
# in with sed, and a fake path would silently yield an empty script — making
# the round-trip check below pass for the wrong reason.
env["REPO_ROOT"] = os.getcwd()
# A realistic URL: the seed substitutes this in, and the checks below verify
# the result is a usable git remote. A placeholder like "x" would make the
# URL check pass for the wrong reason.
env["GITHUB_REPO_URL"] = "https://github.com/example/repo.git"
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

# The Job DSL script must survive the YAML round-trip with its line structure
# intact. A FOLDED block scalar (>) joins same-indentation lines with spaces,
# so the first // comment swallows the code that followed it on the next line
# and Jenkins dies with MultipleCompilationErrorsException.
# A LITERAL block scalar (|) preserves every line.
#
# Comparing against the source file is the reliable test: folding preserves
# MORE-indented lines, so merely counting newlines is not enough to detect it.
seed_lines = open("jenkins/jobs/seed.groovy").read().splitlines()
seed_count = len(seed_lines)

for label, scripts in (("values.yaml", base["controller"]["JCasC"]["configScripts"]),
                       ("bootstrap overrides", ov["controller"]["JCasC"]["configScripts"])):
    if "jobs" not in scripts:
        continue
    inner = yaml.safe_load(scripts["jobs"]) or {}
    for entry in inner.get("jobs", []):
        rendered = entry.get("script", "")
        rendered_count = len(rendered.splitlines())

        if rendered_count < seed_count * 0.9:
            fails.append(
                f"{label}/jobs: script rendered as {rendered_count} lines but "
                f"seed.groovy has {seed_count} — lines were folded together. "
                "Use a literal block scalar (|), not a folded one (>)."
            )
        # Every comment line must still start a line of its own; if a comment
        # was folded onto the end of a code line, the code is now commented out.
        for raw_line in seed_lines:
            # apply the same substitution the renderer does, or every line
            # containing a placeholder looks like it was mangled
            src_line = raw_line.replace("__GITHUB_REPO_URL__",
                                        env["GITHUB_REPO_URL"])
            stripped = src_line.strip()
            if stripped.startswith("//") and len(stripped) > 6:
                if stripped not in [r.strip() for r in rendered.splitlines()]:
                    fails.append(
                        f"{label}/jobs: comment line was folded into another "
                        f"line: {stripped[:50]}"
                    )
                    break

# The Job DSL seed must not read configuration with System.getenv(). JCasC
# globalNodeProperties sets Jenkins BUILD environment variables, injected into
# agent processes — they are NOT in the controller JVM's environment, so
# System.getenv() returns null when the seed runs at startup. The job is then
# created with an empty remote and branch indexing fails with
# "Cannot parse Git URI-ish: The uri was empty or null".
# Values must be substituted into the file at render time instead.
seed_code = "\n".join(
    line for line in open("jenkins/jobs/seed.groovy").read().splitlines()
    if not line.strip().startswith("//")
)
if "System.getenv" in seed_code:
    fails.append(
        "jenkins/jobs/seed.groovy uses System.getenv() — returns null in the "
        "Job DSL sandbox; substitute the value at render time instead"
    )

# Every placeholder in the seed must actually be substituted, and the result
# must be a usable git URL rather than an empty string.
for label, scripts in (("values.yaml", base["controller"]["JCasC"]["configScripts"]),
                       ("bootstrap overrides", ov["controller"]["JCasC"]["configScripts"])):
    if "jobs" not in scripts:
        continue
    inner = yaml.safe_load(scripts["jobs"]) or {}
    for entry in inner.get("jobs", []):
        rendered = entry.get("script", "")
        if "__" in re.sub(r"^\s*//.*$", "", rendered, flags=re.M):
            leftover = re.findall(r"__[A-Z_]+__", rendered)
            if leftover:
                fails.append(f"{label}/jobs: unsubstituted placeholder(s): {set(leftover)}")
        for m in re.finditer(r"(?:remote|url)\(\s*'([^']*)'\s*\)", rendered):
            if not m.group(1).startswith("http"):
                fails.append(
                    f"{label}/jobs: git remote is '{m.group(1)}' — "
                    "branch indexing will fail with an empty URI"
                )

# Deprecated JCasC keys that make Jenkins refuse to start.
# Each was hit for real; the error names the key but not the correct location.
DEPRECATED = {
    "mailer.adminAddress": (
        "adminAddress is deprecated under unclassified.mailer — "
        "move it to unclassified.location.adminAddress"
    ),
}
for label, scripts in (("values.yaml", base["controller"]["JCasC"]["configScripts"]),
                       ("bootstrap overrides", ov["controller"]["JCasC"]["configScripts"])):
    for name, body in scripts.items():
        doc = yaml.safe_load(body) or {}
        uncl = doc.get("unclassified", {}) or {}
        if "adminAddress" in (uncl.get("mailer") or {}):
            fails.append(f"{label}/{name}: {DEPRECATED['mailer.adminAddress']}")

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
