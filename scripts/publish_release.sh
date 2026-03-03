#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <tag> [owner] [repo]"
  exit 1
fi

TAG="$1"
OWNER="${2:-sexyfeifan}"
REPO="${3:-GitHubCollector}"

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "GITHUB_TOKEN is required"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_OUTPUT="$("$ROOT_DIR/scripts/build_dmg.sh" "" "$TAG")"
OUT_DIR="$(echo "$BUILD_OUTPUT" | awk -F= '/^OUT_DIR=/{print $2}')"
DMG_PATH="$(echo "$BUILD_OUTPUT" | awk -F= '/^DMG_PATH=/{print $2}')"
APP_ZIP_PATH="$(echo "$BUILD_OUTPUT" | awk -F= '/^APP_ZIP_PATH=/{print $2}')"
SOURCE_TAR_PATH="$(echo "$BUILD_OUTPUT" | awk -F= '/^SOURCE_TAR_PATH=/{print $2}')"
ARCHIVE_LATEST_DIR="$(echo "$BUILD_OUTPUT" | awk -F= '/^ARCHIVE_LATEST_DIR=/{print $2}')"

if [ -z "$OUT_DIR" ] || [ -z "$DMG_PATH" ] || [ -z "$APP_ZIP_PATH" ] || [ -z "$SOURCE_TAR_PATH" ] || [ -z "$ARCHIVE_LATEST_DIR" ]; then
  echo "Failed to parse build output"
  exit 1
fi

API="https://api.github.com/repos/${OWNER}/${REPO}"
AUTH_HEADERS=(
  -H "Authorization: Bearer ${GITHUB_TOKEN}"
  -H "Accept: application/vnd.github+json"
  -H "X-GitHub-Api-Version: 2022-11-28"
)

NOTES="$(cat <<'EOF'
## ✨ 更新亮点
- 🚀 发布流程保持标准化：自动构建并上传 `GitHubCollector.dmg` / `GitHubCollector.app.zip` / 源码包。
- 🧠 抓取与下载解耦：仓库信息先入库，安装包改为独立下载队列，减少“日志有下载但入库缺失”的情况。
- 📥 下载队列增强：下载完成后再更新项目记录与本地路径，状态展示更准确。
- 🧰 自动下载策略升级：当可下载资产较多时，优先筛选 x86/arm 与 Windows/macOS/iOS/Android 相关安装包。
- 🚫 资产过滤优化：自动排除源码压缩包（source/src/sources 等）避免误下载。
- 🔄 详情页新增“实时再抓取安装包”：可即时刷新最新 release 资产列表。
- ✅ 手动勾选下载：支持弹窗勾选待下载文件并加入队列排队，便于控制本地空间。
- 📊 主界面新增下载队列面板：展示待下载/下载中/完成/失败统计与明细。

## 📦 资产说明
- `GitHubCollector.dmg`：macOS 安装包（推荐）
- `GitHubCollector.app.zip`：应用包压缩版
- `GitHubCollector-source.tar.gz`：对应版本源码
EOF
)"

release_http_code="$(curl -sS -o /tmp/gh_release_existing.json -w '%{http_code}' \
  "${AUTH_HEADERS[@]}" \
  "${API}/releases/tags/${TAG}")"

if [ "$release_http_code" = "200" ]; then
  RELEASE_ID="$(jq -r '.id' /tmp/gh_release_existing.json)"
  PATCH_PAYLOAD="$(jq -nc \
    --arg name "GitHubCollector ${TAG}" \
    --arg body "$NOTES" \
    '{name:$name,body:$body,draft:false,prerelease:false}')"
  curl -sS -o /tmp/gh_release_current.json \
    -X PATCH \
    "${AUTH_HEADERS[@]}" \
    -H "Content-Type: application/json" \
    -d "$PATCH_PAYLOAD" \
    "${API}/releases/${RELEASE_ID}" >/dev/null
else
  CREATE_PAYLOAD="$(jq -nc \
    --arg tag "$TAG" \
    --arg name "GitHubCollector ${TAG}" \
    --arg body "$NOTES" \
    '{tag_name:$tag,target_commitish:"main",name:$name,body:$body,draft:false,prerelease:false}')"
  create_http_code="$(curl -sS -o /tmp/gh_release_current.json -w '%{http_code}' \
    "${AUTH_HEADERS[@]}" \
    -H "Content-Type: application/json" \
    -d "$CREATE_PAYLOAD" \
    "${API}/releases")"
  if [ "$create_http_code" != "200" ] && [ "$create_http_code" != "201" ]; then
    echo "Failed to create release: HTTP ${create_http_code}"
    cat /tmp/gh_release_current.json
    exit 1
  fi
fi

RELEASE_ID="$(jq -r '.id' /tmp/gh_release_current.json)"
UPLOAD_URL="$(jq -r '.upload_url' /tmp/gh_release_current.json | sed 's/{?name,label}//')"

# Ensure Release assets are deterministic: clear old files and only keep current package set.
jq -r '.assets[]?.id' /tmp/gh_release_current.json | while read -r asset_id; do
  if [ -n "$asset_id" ]; then
    curl -sS -X DELETE "${AUTH_HEADERS[@]}" "${API}/releases/assets/${asset_id}" >/dev/null
  fi
done

upload_asset() {
  local file_path="$1"
  local asset_name="$2"
  local code
  code="$(curl -sS -o /tmp/gh_upload_asset.json -w '%{http_code}' \
    "${AUTH_HEADERS[@]}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$file_path" \
    "${UPLOAD_URL}?name=${asset_name}")"
  if [ "$code" != "201" ]; then
    echo "Failed to upload ${asset_name}: HTTP ${code}"
    cat /tmp/gh_upload_asset.json
    exit 1
  fi
}

upload_asset "$ARCHIVE_LATEST_DIR/GitHubCollector.dmg" "GitHubCollector.dmg"
upload_asset "$ARCHIVE_LATEST_DIR/GitHubCollector.app.zip" "GitHubCollector.app.zip"
upload_asset "$ARCHIVE_LATEST_DIR/GitHubCollector-source.tar.gz" "GitHubCollector-source.tar.gz"

curl -sS "${AUTH_HEADERS[@]}" "${API}/releases/${RELEASE_ID}" | jq -r \
  '.html_url, .name, .tag_name, (.assets[]?.name)'

echo "BUILD_OUTPUT_DIR=${OUT_DIR}"
echo "ARCHIVE_LATEST_DIR=${ARCHIVE_LATEST_DIR}"
