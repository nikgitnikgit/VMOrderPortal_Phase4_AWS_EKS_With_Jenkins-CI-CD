"""Agent pod containers must have a NUMERIC runAsUser.

The pod sets runAsNonRoot: true. The kubelet then refuses to start any
container whose image declares its user as a NAME rather than a UID, because
it cannot verify the name is non-root before starting:

    container has runAsNonRoot and image has non-numeric user (jenkins),
    cannot verify user is non-root

The jnlp container is injected automatically by the Kubernetes plugin and its
image (jenkins/inbound-agent) declares USER jenkins. It must therefore be
declared explicitly in the pod template purely so a numeric runAsUser can be
attached — otherwise three containers start, jnlp does not, and the build
hangs forever with no error in the Jenkins console.
"""
import os
import re
import sys

import yaml

os.chdir(os.path.join(os.path.dirname(__file__), ".."))

fails = []
for jf in ("Jenkinsfile-ci", "Jenkinsfile-cd"):
    raw = re.search(r'yaml """\n(.*?)\n"""', open(jf).read(), re.S).group(1)
    raw = re.sub(r"\$\{env\.\w+\}", "PLACEHOLDER", raw)
    pod = yaml.safe_load(raw)

    if not pod["spec"].get("securityContext", {}).get("runAsNonRoot"):
        continue

    names = {c["name"] for c in pod["spec"]["containers"]}
    if "jnlp" not in names:
        fails.append(
            f"{jf}: pod sets runAsNonRoot but jnlp is not declared. The plugin "
            "injects it with a NAME-based user and the kubelet will refuse it."
        )

    for c in pod["spec"]["containers"]:
        uid = c.get("securityContext", {}).get("runAsUser")
        if not isinstance(uid, int):
            fails.append(
                f"{jf}: container '{c['name']}' has runAsUser={uid!r} — "
                "must be a number when runAsNonRoot is set"
            )

if fails:
    print("\n".join(fails))
    sys.exit(1)
print("all agent containers declare a numeric runAsUser")
