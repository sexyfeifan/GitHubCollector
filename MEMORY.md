# GitHubCollector 快速记忆卡（Memory）

位置与目标
- 主路径：/Users/sexyfeifan/Documents/New project
- 仓库：origin = https://github.com/sexyfeifan/GitHubCollector.git（分支：master）
- 目标：批量收集 GitHub 项目，下载最新 Release 安装包，形成本地可搜索的软件库（macOS 13+，SwiftUI）

一键构建/运行
- 构建：CLANG_MODULE_CACHE_PATH="$PWD/.clang-cache" swift build
- 运行：swift run

打包（.app + .dmg）
- 脚本：scripts/package_macos.sh <version> [build]
  - 例：./scripts/package_macos.sh 1.0.10（build 默认为时间戳）
  - 产物：dist/GitHubCollector.app, dist/GitHubCollector.dmg（.gitignore 仅放行 DMG）
- 图标：Resources/AppIcon.icns（已固定）

发布流程（手工）
1) 本地备份（不入库）：./scripts/create_local_backup.sh <version>
2) 打包：./scripts/package_macos.sh <version>
3) 提交与 tag：
   - git add dist/GitHubCollector.dmg
   - git commit -m "chore(release): <version>"
   - git tag -a v<version> -m "GitHubCollector <version>"
   - git push origin master && git push origin v<version>
4) GitHub Release：创建 v<version> 的 Release 并上传 dist/GitHubCollector.dmg 作为资产

关键特性（代码已对齐）
- GitHub Token：设置页可填；请求自动带 Authorization；命中限流显示重置时间提示
- 目录级配置：<下载目录>/collector_settings.json（切换目录自动加载）；全局 UserDefaults 兜底
- 流量计量：本次/累计（累计持久化）
- 预检跳过：已存在（记录或目录）/ 3 年未更新 / archived / disabled / 404/410
- 资产识别扩展：.mpkg/.app(.zip)/.ipa/.apk/.xapk/.apks/.aab；.zip 需含 app/mac/darwin/osx/ios/android 等关键词
- 停止任务：丢弃当前项目临时数据，避免半成品入库
- 分类模式：按安装包/按类型；分类计数；列表分页每页 12
- 详情：Markdown 渲染/原文切换；可显示 README 首图
- 文本：翻译为中文（OpenAI，可选）；离线排版统计 tokens；提取 Docker/Compose 安装片段

数据位置
- 默认：~/Downloads/GitHubCollector/<分类>/<项目>/...
- 索引：~/Downloads/GitHubCollector/records.json；每项目含 README_COLLECTOR.md 与 project_info.json

入口与模块（只看这些文件即可上手）
- App 入口：Sources/GitHubCollector/GitHubCollectorApp.swift
- UI：Sources/GitHubCollector/ContentView.swift
- 业务编排：Sources/GitHubCollector/AppViewModel.swift
- GitHub API：Sources/GitHubCollector/GitHubService.swift
- 下载：Sources/GitHubCollector/DownloadService.swift
- 存储/扫描：Sources/GitHubCollector/StorageService.swift
- 翻译/排版/分类：Sources/GitHubCollector/TextServices.swift
- 配置：Sources/GitHubCollector/SettingsStore.swift
- 解析：Sources/GitHubCollector/URLParser.swift

常见问题
- 限流：配置 GitHub Token 或等待重置；日志会提示重置时间
- 输入异常：使用“输入链接”弹窗
- 版本同步：右上“同步库”会下载新版本并将旧版本移动到“过期版本/<旧版本>/”

新增（v1.0.12）
- 更安全：GitHub/OpenAI 凭据迁移并保存在系统钥匙串；
- 更聚焦：新增仅 macOS 安装包的过滤（影响扫描与下载）；
- 更高效：列表支持排序（时间/Star/名称）与筛选（最小 Star、语言、排除 Fork）；
- 更明确：命中 GitHub 限流时提示重置时间；
- 配置持久化：onlyMacOSAssets 随设置保存到目录  与全局设置。

新增（v1.0.13）
- 整理分类：新增一键“整理分类”，把“有/无安装包项目”中的项目搬运到类型分类文件夹；
- 分类来源：按项目类型模式枚举下载目录的一级文件夹作为分类（自动排除“有安装包项目/无安装包项目”）。

新增（v1.0.14）
- UI：项目卡片块状显示（边框+阴影），项目名更醒目；
- 交互：点击卡片即可进入详情。


新增（v1.0.16）
- 分类固定：仅按项目类型展示分类（枚举下载目录一级文件夹）；设置中移除分类模式与“无/有安装包”显示方式；
- 首页卡片：移除预览图；双击整卡进入详情；卡片仅保留“GitHub/打开目录”；
- 详情操作：项目名下方排列 GitHub/打开目录/重新翻译/离线排版；右上角不再显示“离线排版”；
- 整理分类：在首页日志输出 (i/N) 进度与总计；
- 导入：新项目总是按类型归档，不再写入“有/无安装包项目”。
