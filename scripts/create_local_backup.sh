#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_ROOT="$ROOT_DIR/_local_version_backups"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || echo no-tag)"
fi

TS="$(date +%Y%m%d-%H%M%S)"
DEST="$BACKUP_ROOT/${VERSION}_${TS}"

mkdir -p "$DEST"

rsync -a \
  --exclude ".git" \
  --exclude ".build" \
  --exclude ".clang-cache" \
  --exclude ".build-cache" \
  --exclude "dist" \
  --exclude "_local_version_backups" \
  --exclude ".DS_Store" \
  "$ROOT_DIR/" "$DEST/"

echo "Backup created: $DEST"
