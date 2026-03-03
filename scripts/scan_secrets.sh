#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Match common leaked credential forms while avoiding placeholder variables.
PATTERN='ghp_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{20,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}'

EXCLUDES=(
  --glob '!.git/*'
  --glob '!dist/*'
  --glob '!GitHubCollectorArchive/*'
)

if rg -n --hidden "${EXCLUDES[@]}" "$PATTERN" .; then
  echo
  echo "Secret scan failed: potential plaintext token(s) detected."
  echo "Please remove/redact them before push."
  exit 1
fi

echo "Secret scan passed: no plaintext token patterns found."
