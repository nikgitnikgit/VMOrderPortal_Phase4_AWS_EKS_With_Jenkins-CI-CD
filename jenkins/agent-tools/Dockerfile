# jenkins/agent-tools/Dockerfile
# Pre-baked tools image for Jenkins agent pods.
# Building tools into the image avoids apt-get on every build (saves ~2 min)
# and eliminates mirror-down failures.
#
# This image runs as a sidecar container alongside BuildKit and Trivy.

FROM debian:12.9-slim

# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        unzip \
        xz-utils \
        git \
        jq \
    && rm -rf /var/lib/apt/lists/*

# --- AWS CLI v2 ---
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip \
    && unzip -q /tmp/awscli.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscli.zip

# --- kubectl (minor version matched to the EKS cluster) ---
# We pin the MINOR version and resolve the latest patch at build time.
# kubectl supports only +/- 1 minor version of skew from the API server,
# so this must track terraform/modules/eks/variables.tf.
ARG KUBECTL_MINOR=1.35
RUN KUBECTL_VERSION=$(curl -fsSL "https://dl.k8s.io/release/stable-${KUBECTL_MINOR}.txt") \
    && curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client

# --- Helm ---
ARG HELM_VERSION=3.15.0
RUN curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
    | tar xz -C /tmp \
    && mv /tmp/linux-amd64/helm /usr/local/bin/helm \
    && rm -rf /tmp/linux-amd64

# --- ShellCheck (for validate stage) ---
ARG SHELLCHECK_VERSION=0.10.0
RUN curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
    | tar xJ -C /tmp \
    && mv /tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck /usr/local/bin/shellcheck \
    && rm -rf /tmp/shellcheck-*

# --- Hadolint (Dockerfile linter) ---
ARG HADOLINT_VERSION=2.12.0
RUN curl -fsSLo /usr/local/bin/hadolint \
      "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-x86_64" \
    && chmod +x /usr/local/bin/hadolint

# Non-root (UID matches Jenkins agent convention)
RUN groupadd -g 1000 jenkins && useradd -u 1000 -g 1000 -m jenkins
USER 1000

CMD ["sleep", "infinity"]
