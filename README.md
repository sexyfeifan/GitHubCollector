# 🚀 GitHubCollector (macOS)

GitHubCollector 是一个 macOS 桌面工具，用于批量收集 GitHub 项目、自动下载最新 Release 安装包，并在本地形成可搜索的软件库。

## ✨ 核心能力

- 🔗 识别并抓取仓库链接：`https://github.com/<owner>/<repo>`
- ⭐ 支持 stars 页面批量导入：`https://github.com/<username>?tab=stars`
- 📦 自动抓取仓库简介、README、最新 Release，并优选安装包下载
- 🌍 支持中文翻译（可配置 OpenAI，失败自动回退原文）
- 🧠 自动生成摘要，首页卡片快速浏览
- 🔄 同步库：对比远程版本，发现新版本自动下载并归档旧版本
- 🗂️ 本地分类管理、搜索过滤、分页展示（每页 12 项）
- 🧹 一键整理分类：按项目类型重组目录，支持预览勾选
- 📜 抓取实时日志（含下载链接、速度、进度）与日志详情展开
- 📊 流量计量（本次流量 + 累计流量）
- 🛡️ 支持 GitHub Token，提升 API 配额并减少限流失败

## 🆕 最新版本（v1.0.19）

本版本重点做了“本地检测项目补抓”与分拣清理能力升级：

- ✅ 解释并区分“本地目录检测项目”：这类项目不是抓取成功记录，默认无 GitHub 地址
- ✅ 详情页新增“重新抓取”按钮，可直接补抓；无地址时会弹窗要求输入仓库链接
- ✅ 失败分拣页新增“本地待补抓项目”分类，支持单条清除与一键清除
- ✅ 首页失败汇总加入“本地待补抓”数量，便于快速进入处理
- ✅ 无 GitHub 地址的项目卡片与详情页中，GitHub 按钮自动禁用，避免空跳转

## 🧭 分类与整理规则（当前）

- 默认仅按“项目类型”分类展示（与下载目录一级文件夹对齐）
- 新项目默认按类型归档
- 整理分类支持预览、全选/全不选、执行日志进度
- 若无法可靠判断类型，会进入“未分类”

## 📦 安装包识别策略

当前下载优选与本地扫描聚焦以下格式：

- Apple 安装包：`.dmg`, `.pkg`, `.mpkg`, `.app`, `.app.zip`
- iOS 安装包：`.ipa`
- Android 安装包：`.apk`, `.xapk`, `.apks`, `.aab`
- `.zip`：仅当文件名包含 `app/mac/darwin/osx/ios/android` 等安装相关关键词时，视为可下载安装包

## 🖥️ 运行方式

```bash
cd "/Users/sexyfeifan/Documents/Codex/GitHubCollector"
mkdir -p .clang-cache
CLANG_MODULE_CACHE_PATH="$PWD/.clang-cache" swift build
swift run
```

## 📀 打包（.app + .dmg）

```bash
cd "/Users/sexyfeifan/Documents/Codex/GitHubCollector"
./scripts/package_macos.sh 1.0.19
```

脚本会：

- 执行 release 构建
- 组装 `dist/GitHubCollector.app`
- 使用固定图标 `Resources/AppIcon.icns`
- 生成 `dist/GitHubCollector.dmg`

## 🚚 发布流程（手工）

1. 本地备份（不入库）：`./scripts/create_local_backup.sh <version>`
2. 打包：`./scripts/package_macos.sh <version>`
3. 提交与 tag：
   - `git add dist/GitHubCollector.dmg`
   - `git commit -m "chore(release): <version> dmg"`
   - `git tag -a v<version> -m "GitHubCollector <version>"`
   - `git push origin master && git push origin v<version>`
4. 创建 GitHub Release 并上传 `dist/GitHubCollector.dmg`

## 🗄️ 数据存储

默认位置：

- `~/Downloads/GitHubCollector/<分类>/<项目>/...`
- `~/Downloads/GitHubCollector/records.json`
- `~/Downloads/GitHubCollector/known_urls.json`（已记录仓库与 stars 地址）

每个项目目录附带：

- `README_COLLECTOR.md`
- `project_info.json`

支持在设置中自定义下载路径；切换目录会自动扫描已有文件并加载目录级配置（`collector_settings.json`）。

## 🧱 项目结构

- `Package.swift`：Swift Package 定义
- `Sources/GitHubCollector/GitHubCollectorApp.swift`：App 入口
- `Sources/GitHubCollector/ContentView.swift`：主界面与详情页
- `Sources/GitHubCollector/AppViewModel.swift`：抓取流程、同步、状态管理
- `Sources/GitHubCollector/AppViewModel+Reorg.swift`：分类整理预览与执行
- `Sources/GitHubCollector/GitHubService.swift`：GitHub API 抓取与资产选择
- `Sources/GitHubCollector/DownloadService.swift`：下载安装与进度回调
- `Sources/GitHubCollector/StorageService.swift`：本地持久化与目录扫描
- `Sources/GitHubCollector/TextServices.swift`：翻译、总结、分类
- `Sources/GitHubCollector/SettingsStore.swift`：配置持久化与流量统计

## 📝 历史版本（简要）

- `v1.0.19`：本地检测项目支持详情页重新抓取、失败分拣新增本地待补抓分组与清除能力
- `v1.0.18`：同步全量已记录仓库（含 stars）、失败项目双分组批量重试/批量打开、日志详情加宽
- `v1.0.17`：固定按类型分类、首页卡片精简、详情操作重排、整理进度日志
- `v1.0.16`：目录对齐刷新、未分类排序优化、项目目录识别增强
- `v1.0.15`：整理分类预览清单、卡片 hover/高亮、分类规则文件支持
- `v1.0.14`：卡片块状化与交互优化
- `v1.0.13`：一键整理分类（有/无安装包目录迁移）
- `v1.0.12`：Token 入钥匙串、仅 macOS 资产过滤、排序筛选增强

## ❗ 常见问题

- 出现限流：在设置中配置 GitHub Token，或等待重置时间后重试
- 输入框焦点异常：使用“输入链接”弹窗导入
- 停止抓取：当前项目会丢弃半成品，避免脏数据入库
