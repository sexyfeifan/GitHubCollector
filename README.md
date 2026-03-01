# GitHubCollector (macOS)

GitHubCollector 是一个 macOS 桌面工具，用于批量收集 GitHub 项目、自动下载最新 Release 安装包，并在本地形成可搜索的软件库。

## 主要功能

- 识别并抓取 GitHub 仓库链接：`https://github.com/<owner>/<repo>`
- 支持 stars 页面批量导入：`https://github.com/<username>?tab=stars`
- 自动抓取仓库简介、README、最新 Release 信息
- 支持中文翻译（可配置 OpenAI，失败自动回退原文）
- 生成简要摘要，首页卡片快速浏览
- 自动下载并优选安装包（按移动端/苹果安装格式优选）
- 同步库：对比远程版本，发现新版本自动下载并归档旧版本
- 本地分类管理、搜索过滤、分页展示（每页 12 项）
- 失败项目汇总（含项目名、GitHub 链接、失败原因）
- 详情窗口支持 Markdown 渲染 / 原文切换
- 抓取实时日志（含下载链接、速度、进度），并支持展开单独查看
- 抓取流量计量（本次流量 + 累计流量）
- 设置中支持 GitHub Token，提升 API 配额并减少限流失败

## 安装包格式策略（当前）

当前下载优选与本地扫描聚焦以下格式：

- Apple 安装包：`.dmg`, `.pkg`, `.mpkg`, `.app`, `.app.zip`
- iOS 安装包：`.ipa`
- Android 安装包：`.apk`, `.xapk`, `.apks`, `.aab`
- `.zip`：仅当文件名明显包含 `app/mac/darwin/osx/ios/android` 等安装相关关键词时，才视为可下载安装包

## 项目结构

- `Package.swift`: Swift Package 定义
- `Sources/GitHubCollector/GitHubCollectorApp.swift`: App 入口
- `Sources/GitHubCollector/ContentView.swift`: 主界面与详情页
- `Sources/GitHubCollector/AppViewModel.swift`: 抓取流程、同步、状态管理
- `Sources/GitHubCollector/GitHubService.swift`: GitHub API 抓取与资产选择
- `Sources/GitHubCollector/DownloadService.swift`: 下载安装与进度回调
- `Sources/GitHubCollector/StorageService.swift`: 本地持久化与目录扫描
- `Sources/GitHubCollector/TextServices.swift`: 翻译、总结、分类
- `Sources/GitHubCollector/SettingsStore.swift`: 配置持久化与流量统计存储
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

随后将二进制组装为 `dist/GitHubCollector.app`。

### 打包 `.dmg`

发布产物：

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
- 若提示限流，请在设置中配置 GitHub Token，或等待错误提示中的重置时间后重试。
