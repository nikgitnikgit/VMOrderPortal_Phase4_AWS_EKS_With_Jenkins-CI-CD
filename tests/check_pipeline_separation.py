"""Enforce the assignment's central rule: CI and CD must stay separate.

  "There is no deploy stage in the CI pipeline."
  "The image tested in CI is the image deployed in CD. Do not rebuild it."

These are structural properties of the two Jenkinsfiles, so they can be
checked offline. Comment lines are stripped first: both files legitimately
DISCUSS the other pipeline's forbidden commands in their headers.
"""
import os
import re
import sys

os.chdir(os.path.join(os.path.dirname(__file__), ".."))


def code(path):
    """File contents with // comment lines removed."""
    return "\n".join(
        line for line in open(path).read().splitlines()
        if not line.strip().startswith("//")
    )


ci = code("Jenkinsfile-ci")
cd = code("Jenkinsfile-cd")
fails = []

# --- CI must not deploy -----------------------------------------------------
for forbidden, why in [
    (r"helm upgrade", "CI must not deploy"),
    (r"helm install", "CI must not deploy"),
    (r"helm rollback", "CI must not touch releases"),
    (r"kubectl apply", "CI must not create cluster objects"),
    (r"kubectl create", "CI must not create cluster objects"),
    (r"kubectl rollout", "CI must not manage rollouts"),
]:
    if re.search(forbidden, ci):
        fails.append(f"Jenkinsfile-ci contains '{forbidden}': {why}")

if "jenkins-agent-ci" not in ci:
    fails.append("Jenkinsfile-ci must run as serviceAccountName jenkins-agent-ci")
if "jenkins-agent-cd" in ci:
    fails.append("Jenkinsfile-ci must not use the CD ServiceAccount")

# --- CD must not build ------------------------------------------------------
for forbidden, why in [
    (r"buildctl", "CD must not build images"),
    (r"docker build", "CD must not build images"),
    (r"name: buildkit", "CD agent must have no builder container"),
    (r"ecr get-login-password", "CD must not authenticate for push"),
]:
    if re.search(forbidden, cd):
        fails.append(f"Jenkinsfile-cd contains '{forbidden}': {why}")

if "jenkins-agent-cd" not in cd:
    fails.append("Jenkinsfile-cd must run as serviceAccountName jenkins-agent-cd")

# --- CD must validate its input --------------------------------------------
if "IMAGE_TAG" not in cd:
    fails.append("Jenkinsfile-cd must accept IMAGE_TAG as a parameter")
if "is not immutable" not in cd:
    fails.append("Jenkinsfile-cd must reject the tag 'latest'")
if "describe-images" not in cd:
    fails.append("Jenkinsfile-cd must verify the image exists before deploying")
if "rollout status" not in cd:
    fails.append("Jenkinsfile-cd must wait for rollout")
if "helm rollback" not in cd:
    fails.append("Jenkinsfile-cd must define a rollback path")

# --- the hand-off must be traceable ----------------------------------------
if "image-manifest.json" not in ci:
    fails.append("CI must publish image metadata for CD")
if "containerimage.digest" not in ci:
    fails.append("CI must record the pushed image digest, not just the tag")
if "application-cd" not in ci:
    fails.append("CI must trigger application-cd")
for param in ("CI_BUILD", "GIT_COMMIT_SHA"):
    if param not in ci or param not in cd:
        fails.append(f"traceability parameter {param} missing from CI or CD")

# --- tagging ---------------------------------------------------------------
if "GIT_SHA" not in ci:
    fails.append("CI must tag images with the git SHA")
if re.search(r"IMAGE_TAG\s*=\s*[\"']?latest", ci):
    fails.append("CI must never tag an image 'latest'")

# --- CI must test and lint --------------------------------------------------
for needed, why in [
    ("flake8", "static analysis stage required"),
    ("pytest", "unit test stage required"),
    ("junit", "test results must be published to Jenkins"),
    ("trivy", "image scan required"),
    ("cyclonedx", "SBOM required"),
]:
    if needed not in ci.lower():
        fails.append(f"Jenkinsfile-ci missing '{needed}': {why}")

if fails:
    print("\n".join(fails))
    sys.exit(1)
print("CI/CD separation verified: CI cannot deploy, CD cannot build, "
      "hand-off is traceable")
