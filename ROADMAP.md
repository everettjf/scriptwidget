# ScriptWidget 优化与发展路线图

> 评估日期：2026-05-20 · 分支：`claude/review-optimization-roadmap`
> 基于对 `Shared/ScriptWidgetRuntime`、iOS/macOS 工程、`Editor/editorfe` 以及 GitHub 仓库现状的审查。

---

## 1. 项目现状

| 维度 | 现状 |
|------|------|
| Stars / Forks | 261 / 41（2021 创建，持续维护中） |
| 技术栈 | JavaScriptCore + Babel(JSX) → SwiftUI 元素树；iOS/macOS 共享 `ScriptWidgetRuntime` |
| 平台能力 | Widget、Live Activity / 灵动岛、Control Widget、App Intents 交互式组件 |
| 编辑器 | React 17 + CodeMirror 6（CRA / react-scripts 5） |
| 存储 | iCloud Documents 优先 + App Group 回退，`.swt` 导入导出 |
| 测试 | **无任何单元测试**（Swift 与前端均无） |
| Issue | 仅 1 个未决（iCloud 蜂窝网下缓存问题，见 #6） |
| 最近 Release | `v2024`（2025-04） |

**核心竞争力**：相比命令式绘制的同类产品，ScriptWidget 用 **JSX 声明式语法直接映射 SwiftUI**，且已支持 Apple 最新的交互式 Widget / 灵动岛 / Control Widget —— 这是当前最大差异化优势。

---

## 2. 优化点（按价值/成本排序）

### 2.1 性能（高价值）
- **JSX 无编译缓存**：每次 Widget 刷新都重新跑一遍 Babel transform（`ScriptWidgetRuntime.swift:103–160`）。Widget 进程内存与时间预算紧张，应缓存转译结果（按脚本 hash）。
- **同步阻塞渲染**：渲染管线大量使用 `DispatchSemaphore` 做异步转同步桥接（`ScriptWidgetRuntime.swift:270/376`），在 Widget 扩展受限的执行时间内有超时风险。
- **元素树/视图无 memoization**：每次构建全量遍历（`ScriptWidgetElementView.swift:54`）。

### 2.2 用户痛点（高价值）
- **离线/弱网不可用**（Issue #6）：iCloud Drive 在蜂窝网关闭时脚本被系统清理，Widget 报错。应**始终本地缓存最近可用版本**并在 iCloud 不可达时回退。这是唯一未决 issue，且用户呼声明确。
- 错误信息缺乏行号/堆栈（`ScriptWidgetRuntime.swift:379` 仅泛化字符串），调试体验差。

### 2.3 代码健康（中价值）
- **Timeline Provider 重复代码**：8 个几乎相同的频率分支（`ScriptWidgetTimelineProvider.swift:27–91`），iOS/macOS 各一份，应抽成表驱动。
- **iOS/macOS 桥接代码重复**：`WKWebViewJavascriptBridgeBase.swift` 两端各 177 行雷同。
- **大文件**：`ScriptWidgetRuntime.swift`(831)、`ScriptManager.swift`(519)、Chart 元素(652)。
- **57 处 `print()`**，无日志分级，应替换为 `os.Logger`。

### 2.4 工程化（中价值）
- **零测试**：runtime 是纯逻辑（JSX→元素树→prop 解析），非常适合 XCTest 单元测试，应优先建立 runtime 测试目标。
- 编辑器停留在 React 17 + CRA（已停止维护），后续可迁移 Vite。
- README 与真实结构不符（描述了不存在的 `Examples/`、`Templates/`、`useWeather()` 等），易误导贡献者，应对齐 `AGENTS.md`。

---

## 3. 竞品对比

| | **ScriptWidget** | **Scriptable**（主竞品） | **Widgy / 无代码类** |
|---|---|---|---|
| 编程模型 | JSX 声明式 → SwiftUI | 命令式 `drawContext`/UITable | 可视化拖拽，无代码 |
| 交互式 Widget | ✅ App Intents | ❌（基本停更） | 部分 |
| Live Activity / 灵动岛 | ✅ | ❌ | ❌ |
| Control Widget | ✅ | ❌ | ❌ |
| macOS | ✅ | ✅ | ❌ |
| 生态 / 社区脚本量 | 较小 | 很大（先发优势） | 模板市场 |
| 开源 | ✅ MIT | 闭源 | 闭源 |
| 文档/示例 | 偏弱 | 完善 | N/A |

**结论**：Scriptable 体量大但停滞，对新 WidgetKit 能力支持落后。ScriptWidget 的机会在于「**开源 + 紧跟 Apple 最新 Widget 能力 + 声明式语法**」。短板在于**社区/示例/文档**与**离线稳定性**。

---

## 4. 未来方向

1. **吃透 Apple 新能力**（护城河）：visionOS Widget、watchOS 复杂功能、Control Center 控件、可交互组件深化 —— 把"第一个支持 X"作为差异点持续输出。
2. **降低上手门槛**：内置模板库 + 一键示例 + 文档站；考虑 AI 辅助生成 widget 脚本（贴合 JSX 声明式特性）。
3. **稳定性优先**：离线缓存、清晰错误、性能预算内可靠刷新 —— 决定留存。
4. **生态**：脚本分享/导入机制（`.swt` 已有基础），可做社区画廊。

---

## 5. 下一步方案（分阶段）

### 阶段一 · 稳定性与基础（1–2 周，最高优先级）
- [x] **离线缓存（Issue #6）**：`ScriptWidgetPackage.readFile` 已有 build-cache 回退（iCloud 读失败时读 `__Build` 缓存），每次成功读取会 `syncBuildCache`。配合下方"错误可视化"，离线读真正失败时 Widget 会显示错误而非空白。后续可加：保存时主动写缓存、缓存淘汰。
- [x] **JSX 转译缓存**：按脚本内容 hash 缓存 Babel 输出，避免每次刷新重转译。（已实现：`ScriptWidgetTranspileCache`，内存 + App Group 落盘）
- [x] **错误信息增强**：`ScriptWidgetRuntime.describeException` 给异常补上行号/列号/JS 堆栈；`ScriptWidgetError.displayMessage` 统一取信息；iOS/macOS Widget、Live Activity、灵动岛、iOS/macOS 编辑器预览的执行错误现在**显示在界面上**（此前只进日志、界面停在占位符）。
- [x] **`os.Logger` 日志封装**：新增 `SWLog`（debug/info/error 分级，`.public` 不脱敏），已接入运行时异常路径与各 `systemLog`。剩余的 verbose 调试 `print` 为机械式后续迁移。

### 阶段二 · 代码健康与测试（1–2 周）
- [x] Timeline Provider 重复分支表驱动化：8 个雷同分支收敛为 `AppConfigFrequency.refreshOffset`（iOS + macOS 各一处）。
- [x] README 与真实结构对齐：项目结构、构建路径、示例脚本（`$render` + JSX）、API 表全部改为真实内容。
- [ ] 新建 `ScriptWidgetRuntimeTests` XCTest target，覆盖 JSX→元素树、prop 类型解析、fetch/storage。（需在 Xcode 内创建 target，无法离线完成）
- [ ] 合并 iOS/macOS 重复桥接代码到 `Shared`。（需改两个 .xcodeproj，建议在 Xcode 内做）
- [ ] 拆分 `ScriptWidgetRuntime.swift`（运行时初始化 / API 注入 / 渲染分离）。（需改 .xcodeproj 引入新文件）

### 阶段三 · 体验与生态（2–4 周）
- [ ] 文档站 + 内置模板/示例库。
- [ ] 编辑器迁移 Vite，补关键单测。
- [ ] 评估社区脚本画廊与一键导入。

### 阶段四 · 平台扩展（探索）
- [ ] visionOS / watchOS Widget 支持调研。
- [ ] AI 辅助脚本生成原型。

---

### 建议的立即起步项
**Issue #6 离线缓存** 与 **JSX 转译缓存** ——两者都是高价值、范围可控、直接改善现有用户体验，且互不依赖，可作为本路线图的第一个落地 PR。
