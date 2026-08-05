"""Every plugin-provided step or option used in a pipeline must be installed.

Jenkins only discovers this at build time: the Jenkinsfile parses fine locally,
the job is created fine, and the build dies with
"Invalid option type" or "No such DSL method" on first run.

Real instance: `timestamps()` requires the timestamper plugin, which was not in
installPlugins. Branch indexing succeeded, the build was scheduled, and it
failed in under a second with no agent pod ever created.
"""
import os
import re
import sys

import yaml

os.chdir(os.path.join(os.path.dirname(__file__), ".."))

# pipeline construct -> plugin that provides it
PROVIDED_BY = {
    "timestamps": "timestamper",
    "junit": "junit",
    "emailext": "email-ext",
    "readJSON": "pipeline-utility-steps",
    "readYaml": "pipeline-utility-steps",
    "writeJSON": "pipeline-utility-steps",
    "cleanWs": "ws-cleanup",
    "archiveArtifacts": None,        # core
    "buildDiscarder": None,          # core
    "disableConcurrentBuilds": None,  # core
    "timeout": None,                 # core
    "input": None,                   # core
}

installed = set(
    yaml.safe_load(open("jenkins/values.yaml"))["controller"]["installPlugins"]
)

fails = []
for jf in ("Jenkinsfile-ci", "Jenkinsfile-cd"):
    code = "\n".join(
        line for line in open(jf).read().splitlines()
        if not line.strip().startswith("//")
    )
    for construct, plugin in PROVIDED_BY.items():
        if plugin is None:
            continue
        if re.search(rf"(?<![\w.]){re.escape(construct)}\s*[(:]", code):
            if plugin not in installed:
                fails.append(
                    f"{jf} uses {construct}() but plugin '{plugin}' "
                    "is not in controller.installPlugins"
                )

if fails:
    print("\n".join(sorted(set(fails))))
    sys.exit(1)
print(f"all pipeline steps are covered by installed plugins "
      f"({len(installed)} plugins declared)")
