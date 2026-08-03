#!/bin/bash
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$(dirname "$REPO")"
NAME="$(basename "$REPO")"
rm -f /tmp/qa_package.zip
zip -rq /tmp/qa_package.zip "$NAME" -x "*.DS_Store"
LIST=$(unzip -l /tmp/qa_package.zip)
echo "$LIST" | grep -q "{" && { echo "junk brace entries in zip"; exit 1; }
echo "$LIST" | grep -qE "terraform\.tfvars$|tfstate" && { echo "secrets/state leaked into zip"; exit 1; }
FS_COUNT=$(find "$NAME" -type f ! -name ".DS_Store" | wc -l)
ZIP_COUNT=$(zipinfo -1 /tmp/qa_package.zip | grep -cv "/$")
[ "$FS_COUNT" = "$ZIP_COUNT" ] || { echo "inventory mismatch: fs=$FS_COUNT zip=$ZIP_COUNT"; exit 1; }
echo "zip clean: $ZIP_COUNT files match filesystem"
