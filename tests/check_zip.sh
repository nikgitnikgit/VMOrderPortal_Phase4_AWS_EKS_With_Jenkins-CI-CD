#!/bin/bash
# Verifies the DISTRIBUTION package is clean: the exclusion rules must keep
# secrets and state out, and everything else must be present.
#
# Note we exclude the same paths the real packaging step does. A developer
# working in the repo will legitimately have terraform.tfvars, backend.tf,
# .terraform/ and tfstate on disk — the point of this test is that those
# never reach the zip, not that they never exist.
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$(dirname "$REPO")"
NAME="$(basename "$REPO")"

EXCLUDES=(
  -x "${NAME}/terraform/terraform.tfvars"
  -x "${NAME}/terraform/backend.tf"
  -x "${NAME}/terraform/.terraform/*"
  -x "${NAME}/terraform/*.tfstate*"
  -x "*.DS_Store"
  -x "*/__pycache__/*"
  -x "${NAME}/.git/*"
)

rm -f /tmp/qa_package.zip
zip -rq /tmp/qa_package.zip "$NAME" "${EXCLUDES[@]}"
LIST=$(zipinfo -1 /tmp/qa_package.zip)

echo "$LIST" | grep -q "{" && { echo "junk brace entries in zip"; exit 1; }
echo "$LIST" | grep -qE "terraform\.tfvars$|tfstate|backend\.tf$" \
  && { echo "secrets/state leaked into zip"; exit 1; }

# Count what SHOULD be there: filesystem minus the same exclusions
FS_COUNT=$(find "$NAME" -type f \
  ! -name ".DS_Store" \
  ! -path "*/.git/*" \
  ! -path "*/__pycache__/*" \
  ! -path "${NAME}/terraform/.terraform/*" \
  ! -name "terraform.tfvars" \
  ! -name "backend.tf" \
  ! -name "*.tfstate" \
  ! -name "*.tfstate.backup" \
  | wc -l)
ZIP_COUNT=$(echo "$LIST" | grep -cv "/$")

[ "$FS_COUNT" = "$ZIP_COUNT" ] || {
  echo "inventory mismatch: fs=$FS_COUNT zip=$ZIP_COUNT"
  echo "--- in fs but not zip ---"
  diff <(find "$NAME" -type f ! -path "*/.git/*" | sort) <(echo "$LIST" | grep -v "/$" | sort) | head -20
  exit 1
}
echo "zip clean: $ZIP_COUNT files, no secrets or state"
