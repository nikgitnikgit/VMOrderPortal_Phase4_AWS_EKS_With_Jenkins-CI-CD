# jenkins/agent-tools/Dockerfile
# Pre-baked tools image for Jenkins agent Pods (both CI and CD).
#
# Building tools into the image avoids apt-get on every build (~2 min saved)
# and removes the failure mode where a package mirror is down mid-pipeline.
#
# Runs as a non-root user. Pinned base image, never :latest. This image is
# itself scanned by Trivy in install-jenkins.sh before it is pushed.

FROM debian:12.9-slim@sha256:12c396bd585df7ec21d5679bb6a83d4878bc4415ce926c9e5ea6426d23c60bdc

# REVIEW FIX 1.3 (hadolint DL4006) — several RUN steps below pipe `curl` into
# `tar`. The default /bin/sh reports only the exit status of the LAST command
# in a pipeline, so a truncated or 404 download still produces a "successful"
# layer and a broken binary gets baked into the image. That failure surfaces
# mid-pipeline, hours later, as "helm: not found".
# With pipefail the pipeline fails on the curl, and the build fails here.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# xz-utils is required: shellcheck ships as .tar.xz and `tar xJ` cannot
# unpack it without xz, which debian-slim does not include.
# `apt-get upgrade` matters here: the base image tag is pinned for
# reproducibility, but pinning also freezes whatever CVEs shipped with it.
# Upgrading pulls the patched versions Debian has released since (this cleared
# 2 CRITICAL findings in libgnutls30). Unfixable CVEs remain — see the note on
# --ignore-unfixed in scripts/install-jenkins.sh.
# hadolint ignore=DL3008
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        unzip \
        xz-utils \
        git \
        jq \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

# --- Python tooling for the CI lint and test stages ---
# hadolint ignore=DL3013
RUN pip3 install --no-cache-dir --break-system-packages \
        pytest==8.3.4 \
        pytest-cov==6.0.0 \
        flake8==7.1.1 \
        flask==3.1.0 \
        psycopg2-binary==2.9.9 \
        boto3==1.37.0 \
        requests==2.32.3

# --- AWS CLI v2 ---
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip \
    && unzip -q /tmp/awscli.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscli.zip

# --- kubectl: minor version matched to the EKS cluster ---
# kubectl supports only +/- 1 minor of skew from the API server, so this must
# track terraform/modules/eks/variables.tf. Patch resolved at build time.
ARG KUBECTL_MINOR=1.35
RUN KUBECTL_VERSION=$(curl -fsSL "https://dl.k8s.io/release/stable-${KUBECTL_MINOR}.txt") \
    && curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client

# --- Helm ---
# Resolved at build time rather than pinned. Helm is a Go binary, so it
# embeds its dependencies: a pinned old Helm carries whatever CVEs its Go
# toolchain and vendored libraries had at release. Helm 3.15.0 alone
# accounted for 4 CRITICAL findings (docker/docker, grpc, Go stdlib).
# The build is still reproducible in the sense that matters: the resulting
# image is tagged and immutable in ECR.
RUN HELM_VERSION=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest \
      | jq -r .tag_name) \
    && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    | tar xz -C /tmp \
    && mv /tmp/linux-amd64/helm /usr/local/bin/helm \
    && rm -rf /tmp/linux-amd64 \
    && helm version

# --- ShellCheck ---
ARG SHELLCHECK_VERSION=0.10.0
RUN curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
    | tar xJ -C /tmp \
    && mv "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck \
    && rm -rf /tmp/shellcheck-*

# --- Hadolint ---
ARG HADOLINT_VERSION=2.12.0
RUN curl -fsSLo /usr/local/bin/hadolint \
      "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-x86_64" \
    && chmod +x /usr/local/bin/hadolint

# Non-root. UID 1000 matches the Jenkins agent convention and the fsGroup
# set on the agent Pod, so the shared workspace volume is writable.
RUN groupadd -g 1000 jenkins && useradd -u 1000 -g 1000 -m jenkins
USER 1000
WORKDIR /home/jenkins

CMD ["sleep", "infinity"]
