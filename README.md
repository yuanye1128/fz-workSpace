# fz-workSpace

fz-workSpace 是一款面向开发者的 macOS 工单处理工作台。它把知识库工单、AI 修改代码、人工审核、Git 交付和工单流转串成一个可追踪、可恢复的流程。

## 功能概览

- 以项目分组的响应式工单卡片工作台，支持搜索、类型/优先级/状态/版本筛选和排序；卡片宽度随可用空间伸缩，每行最多四列。
- 工单详情使用居中的实色弹窗和半透明遮罩，不直接套用知识库网页界面；详情包含创建人和工单自身的最新更新时间。
- 支持浅色、暗黑和跟随系统主题。
- 支持每个项目配置多个本地 Git 仓库，并选择默认仓库、基础分支和远程名称。
- 支持 Codex 和 Cursor 两种 AI 工具，允许补充模块、文件和技术约束等辅助定位信息；可通过系统目录选择器写入本地文件夹路径。
- AI 完成后生成修改报告、修改原因、文件列表、测试结果、风险、代码差异和原始输出。
- 只有人工批准后才执行：本地 commit → 拉取最新代码 → 无冲突时 push → 更新知识库工单。
- 拉取冲突时停止并列出冲突文件；代码已 push 但工单更新失败时只允许重试工单更新。
- 启动时立即展示最近一次成功同步的缓存工单，同时在后台静默拉取最新数据。
- 知识库同步会遍历用户名下查询的全部分页，按工单编号去重后更新工作台，不限制在第一页。
- 默认每 2 小时自动同步一次，可在设置中选择 1–8 小时并保存；手动刷新期间刷新图标持续旋转。
- 后台同步发现新工单时，通知图标显示红点，并可查看新工单的标题、类型和优先级。
- “待测试”工单只展示详情，不显示“去解决”和 AI 操作区。
- 人工批准交付后，需求工单仅改为“待测试”；Bug 和支持工单改为“待测试”并转交工单创建人。

## 技术栈

- SwiftUI + AppKit
- macOS 13+
- WebKit 知识库会话与页面自动化
- Swift Package Manager
- XcodeGen 项目配置
- 无第三方运行时依赖

## 项目结构

```text
fz-workSpace/
├── Sources/DevFlow/
│   ├── Models/       数据模型、主题和本地状态
│   ├── Services/     知识库、AI、Git、持久化和任务编排
│   └── Views/        工作台、卡片、弹窗、报告、设置
├── Tests/DevFlowTests/
├── fz-workSpace.xcodeproj/
├── project.yml
└── Package.swift
```

> 应用和产品名称为 `fz-workSpace`。为保持既有构建配置稳定，当前 Swift 模块、源码目录和 Xcode scheme 仍使用内部技术名 `DevFlow`。

## 环境要求

- Apple Silicon Mac（首版优先支持）
- macOS 13 或更高版本
- Xcode
- Git
- Codex CLI（使用 Codex 时）
- Cursor Agent CLI（使用 Cursor 时）

知识库目前通过已登录网页会话访问，不保存账号密码。首次同步需要在知识库会话窗口中完成登录；如果后续改为浏览器扩展桥接，可继续复用默认浏览器的登录状态。

## 构建与测试

### Swift Package

```bash
mkdir -p .build/module-cache
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \\
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \\
swift test --disable-sandbox --scratch-path .build
```

### Xcode 应用

```bash
xcodebuild \\
  -project fz-workSpace.xcodeproj \\
  -scheme DevFlow \\
  -configuration Debug \\
  -derivedDataPath Build/DerivedDataNormal \\
  build
```

构建产物位于：

```text
Build/DerivedDataNormal/Build/Products/Debug/fz-workSpace.app
```

## 使用流程

1. 启动 fz-workSpace。
2. 在“设置”中打开知识库会话并完成登录。
3. 应用先展示上次缓存工单并自动后台同步；也可以点击“立即同步”或顶部“刷新”手动更新。
4. 在“项目与仓库配置”中为项目添加本地 Git 仓库。
5. 打开工单，选择仓库、分支和 AI 工具，可填写辅助定位信息。
6. 点击“开始解决”，查看 AI 实时日志和最终报告。
7. 审核报告后选择“批准并提交”，确认 commit 信息和当前工单对应的交付规则。
8. 应用按固定顺序完成 Git 交付，并在 push 成功后更新工单：需求保持负责人不变，Bug/支持转交创建人，其他类型可人工指定负责人。

## 安全边界

- AI 提示词明确禁止执行 commit、pull、push 和知识库更新。
- 未经人工批准不会执行外部副作用操作。
- 脏工作区会阻止任务启动，不自动覆盖、stash 或删除用户已有修改。
- Git rebase 冲突不会自动解决，也不会继续 push。
- 登录凭据、Cookie、Token 和仓库凭据不写入普通日志或 AI 报告。
- 工单更新失败时保留“部分完成”状态，只重试工单更新步骤。

## 当前限制

- 知识库没有可用 API 时，依赖已登录的 WebKit 页面会话完成同步和更新。
- Cursor 是否可用取决于本机是否安装 `cursor-agent`。
- 首版不包含 Windows、Linux、iOS、Android、云同步、自动解决冲突或自动创建合并请求。

## 需求与验收

- [产品需求规格](docs/产品需求规格-v1.0.md)
- [设计 QA](docs/design-qa.md)
- [验收报告](docs/验收报告-v1.0.md)

## License

当前项目用于内部工作流验证，暂未指定开源许可证。
