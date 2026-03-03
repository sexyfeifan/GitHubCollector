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
- 🚀 发布流程升级：自动构建并上传 `GitHubCollector.dmg` / `GitHubCollector.app.zip` / 源码包。
- 🧪 设置页新增检测：支持 AI 连通性测试与 GitHub Token 有效性测试。
- 🛡️ 抓取稳健性修复：Token 异常自动回退无 Token 请求，降低抓取失败概率。
- 🎯 抓取准确性提升：latest release 无资产时自动回退到有资产版本。
- 🧰 抓取流程升级：抓取阶段优先仓库信息与安装包下载，源码改为按需手动拉取。
- 📚 README 语义修复：原文完整保留，中文区显示翻译与精简归纳。
- 🧭 搭建教程提取优化：仅提取安装/构建/运行/部署相关内容，不再生成步骤编号与冗余代码块。
- ⏱️ 抓取队列容错：单项目 10 秒无数据先暂时跳过并延后重试，重试阶段 30 秒无数据再次跳过。
- ⏭️ 手动控制增强：拉取过程中支持一键跳过当前项目。
- 📦 抓取策略调整：抓取阶段不再自动拉取源码，详情页支持手动拉取源码。
- 📈 进度展示增强：主界面显示拉取百分比与完成计数（完成/总数）。
- 🧾 详情阅读优化：搭建教程改为代码宽显示，日志详情窗口显著加宽。
- 🗂️ 分类规则统一：按项目类型分类，不再按有/无安装包做分类。
- 🧼 文本优化增强：详情页支持“文本优化”，自动清洗 HTML/Markdown 噪声并输出更干净的中文简介。
- 🗃️ 交互结构优化：卡片移除“查看简介/重新翻译”，统一迁移到详情页内操作。
- 📜 日志可读性提升：展开日志内容宽度自适应弹窗，尽可能铺满显示区域。

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
