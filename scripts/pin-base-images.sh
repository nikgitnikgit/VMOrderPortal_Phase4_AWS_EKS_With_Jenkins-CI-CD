#!/usr/bin/env bash
#
# scripts/pin-base-images.sh — REVIEW FIX 4.2
#
# THE PROBLEM
#   Every Dockerfile pins a base image by TAG:
#       FROM python:3.12-slim
#   A tag is a mutable pointer. The maintainer can move it, and a rebuild six
#   months from now can produce a different image than the one that was
#   scanned, tested and approved — with no change in Git to show for it.
#   That breaks reproducibility and it means a Trivy result has a shelf life.
#
# THE FIX
#   Pin by DIGEST as well:
#       FROM python:3.12-slim@sha256:<64 hex chars>
#   The tag stays for readability; the digest is what Docker actually resolves.
#   Bytes are now fixed: the same Dockerfile builds the same base forever.
#
# WHY THIS IS A SCRIPT RATHER THAN A COMMITTED DIFF
#   A digest can only be obtained from the registry, and it must be the REAL
#   one — an invented or stale digest does not degrade gracefully, it fails
#   the build with "manifest unknown". So this resolves them on your machine,
#   where the registry is reachable, and rewrites the Dockerfiles in place.
#
# USAGE
#   ./scripts/pin-base-images.sh            # rewrite in place
#   ./scripts/pin-base-images.sh --check    # verify all bases are pinned (CI)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DOCKERFILES=(
    docker/backend/Dockerfile
    docker/worker/Dockerfile
    docker/frontend/Dockerfile
    jenkins/agent-tools/Dockerfile
)

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

if [ "$CHECK_ONLY" -eq 1 ]; then
    unpinned=0
    for f in "${DOCKERFILES[@]}"; do
        while read -r line; do
            case "$line" in
                *"@sha256:"*) ;;
                *) echo "  UNPINNED  $f: $line"; unpinned=$((unpinned + 1)) ;;
            esac
        done < <(grep -E '^FROM ' "$f")
    done
    if [ "$unpinned" -gt 0 ]; then
        echo ""
        echo "$unpinned base image(s) pinned by tag only."
        echo "Run ./scripts/pin-base-images.sh to pin them by digest."
        exit 1
    fi
    echo "All base images are digest-pinned."
    exit 0
fi

command -v docker >/dev/null || {
    echo "ERROR: docker is required to resolve digests." >&2; exit 1; }

echo "Resolving base image digests (this pulls each base once)..."
for f in "${DOCKERFILES[@]}"; do
    echo ""
    echo "  $f"
    # Only the image reference, ignoring any existing digest and any AS alias.
    while read -r ref; do
        base="${ref%%@*}"
        docker pull --quiet "$base" >/dev/null
        digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$base" | cut -d'@' -f2)
        [ -n "$digest" ] || { echo "    could not resolve $base" >&2; exit 1; }
        echo "    $base -> $digest"
        # Rewrite: keep the tag for readability, append/replace the digest.
        escaped_base=$(printf '%s' "$base" | sed 's/[][\.*^$/]/\\&/g')
        sed -i -E "s|^(FROM )${escaped_base}(@sha256:[a-f0-9]+)?( .*)?$|\1${base}@${digest}\3|" "$f"
    done < <(grep -E '^FROM ' "$f" | awk '{print $2}')
done

echo ""
echo "Done. Review the diff, then rebuild and re-scan:"
echo "  git diff -- docker jenkins/agent-tools"
echo ""
echo "To update a base image later, edit the tag and re-run this script."
