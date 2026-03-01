# GitHubCollector (macOS)

GitHubCollector 是一个 macOS 桌面工具，用于批量收集 GitHub 项目、自动下载最新 Release 安装包，并在本地形成可搜索的软件库。

## 主要功能

- 识别并抓取 GitHub 仓库链接：`https://github.com/<owner>/<repo>`
- 支持 stars 页面批量导入：`https://github.com/<username>?tab=stars`
- 自动抓取仓库简介、README、最新 Release 信息
- 支持中文翻译（可配置 OpenAI，失败自动回退原文）
- 生成简要摘要，首页卡片快速浏览
- 自动下载并优选安装包（支持更多格式）
- 同步库：对比远程版本，发现新版本自动下载并归档旧版本
- 本地分类管理、搜索过滤、分页展示（每页 12 项）
- 失败项目汇总（含项目名、GitHub 链接、失败原因）
- 详情窗口支持 Markdown 渲染 / 原文切换
- 抓取实时日志（含下载链接、速度、进度），并支持展开单独查看

## 安装包格式支持

下载优选与本地扫描支持以下格式：

- `.dmg`, `.pkg`, `.mpkg`, `.app.zip`
- `.zip`, `.tar.gz`, `.tgz`, `.tar.xz`, `.txz`
- `.tar.bz2`, `.tbz2`, `.tar`, `.7z`, `.gz`, `.xz`, `.bz2`
- `.appimage`, `.deb`, `.rpm`

## 项目结构

- `Package.swift`: Swift Package 定义
- `Sources/GitHubCollector/GitHubCollectorApp.swift`: App 入口
- `Sources/GitHubCollector/ContentView.swift`: 主界面与详情页
- `Sources/GitHubCollector/AppViewModel.swift`: 抓取流程、同步、状态管理
- `Sources/GitHubCollector/GitHubService.swift`: GitHub API 抓取与资产选择
- `Sources/GitHubCollector/DownloadService.swift`: 下载安装与进度回调
- `Sources/GitHubCollector/StorageService.swift`: 本地持久化与目录扫描
- `Sources/GitHubCollector/TextServices.swift`: 翻译、总结、分类
- `Sources/GitHubCollector/SettingsStore.swift`: 配置持久化
- `Sources/GitHubCollector/URLParser.swift`: 链接解析
- `Sources/GitHubCollector/NativeInputField.swift`: 原生输入控件

## 本地运行

```bash
cd "/Users/sexyfeifan/Documents/New project"
mkdir -p .clang-cache
CLANG_MODULE_CACHE_PATH="$PWD/.clang-cache" swift build
swift run
```

## 打包

### 打包 `.app`

```bash
cd "/Users/sexyfeifan/Documents/New project"
CLANG_MODULE_CACHE_PATH="$PWD/.clang-cache" swift build -c release
```

之后将 `./build/release/GitHubCollector` 组装为 `dist/GitHubCollector.app`（项目内已使用该流程）。

### 打包 `.dmg`

项目发布产物：

- `dist/GitHubCollector.app`
- `dist/GitHubCollector.dmg`

## 数据存储

默认存储到：

- `~/Downloads/GitHubCollector/<分类>/<项目>/...`
- `~/Downloads/GitHubCollector/records.json`

支持在设置中自定义下载路径，切换后会自动扫描已有文件。

每个项目目录会额外写入：

- `README_COLLECTOR.md`
- `project_info.json`

## 说明

- 首页输入区在部分系统环境可能存在键盘焦点异常，提供了“输入链接”弹窗作为稳定输入兜底入口。
- 如需降低 GitHub API 限速影响，建议后续加入 GitHub Token 配置。
