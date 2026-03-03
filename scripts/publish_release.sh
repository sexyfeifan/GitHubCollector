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
BUILD_OUTPUT="$("$ROOT_DIR/scripts/build_dmg.sh")"
OUT_DIR="$(echo "$BUILD_OUTPUT" | awk -F= '/^OUT_DIR=/{print $2}')"
DMG_PATH="$(echo "$BUILD_OUTPUT" | awk -F= '/^DMG_PATH=/{print $2}')"
SOURCE_TAR_PATH="$(echo "$BUILD_OUTPUT" | awk -F= '/^SOURCE_TAR_PATH=/{print $2}')"

if [ -z "$OUT_DIR" ] || [ -z "$DMG_PATH" ] || [ -z "$SOURCE_TAR_PATH" ]; then
  echo "Failed to parse build output"
  exit 1
fi

API="https://api.github.com/repos/${OWNER}/${REPO}"
AUTH_HEADERS=(
  -H "Authorization: Bearer ${GITHUB_TOKEN}"
  -H "Accept: application/vnd.github+json"
  -H "X-GitHub-Api-Version: 2022-11-28"
)

NOTES="## 更新亮点
- 发布流程升级：自动构建 macOS 可安装的 GitHubCollector.dmg 并上传到 Release。
- 新增设置页检测能力：支持 AI 连通性测试与 GitHub Token 有效性测试。
- 抓取稳健性修复：Token 异常时自动回退无 Token 请求，降低抓取失败概率。
- 抓取准确性提升：latest release 无资产时自动回退到有资产版本。
- 抓取流程升级：先完整拉取源码，再下载该 release 全部安装包。
- README 语义修复：原文完整保留，中文区显示翻译与精简归纳。
- 搭建教程提取增强：安装/构建/运行/部署/测试步骤统一提取并标注说明。
- 设置增强：支持 GitHub Token，设置写入下载目录并可自动回填。"

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

upload_asset "$DMG_PATH" "GitHubCollector.dmg"
upload_asset "$SOURCE_TAR_PATH" "GitHubCollector-source.tar.gz"

curl -sS "${AUTH_HEADERS[@]}" "${API}/releases/${RELEASE_ID}" | jq -r \
  '.html_url, .name, .tag_name, (.assets[]?.name)'

echo "BUILD_OUTPUT_DIR=${OUT_DIR}"
