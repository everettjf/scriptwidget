# ScriptWidget Studio 与 CodeMirror 6 统一规划

> 实施状态（2026-08-05）：Studio 1.0–1.2 的核心范围已落地。iOS 与 macOS 共用 CodeMirror 6 bundle 和 StudioBridge v1；macOS Monaco 已移除；API Schema、组件/属性/枚举补全、Hover、编辑前诊断、保存状态与文档位置恢复均已实现。

## 1. 项目目标

ScriptWidget Studio 不是一个新的独立 App，而是现有 iOS 与 macOS App 内统一的脚本创作工作区。

规划目标如下：

- iOS 与 macOS 使用同一套 CodeMirror 6 编辑器内核和构建产物。
- 移除 macOS 现有 Monaco 编辑器，解决重复加载、输入卡顿和双端行为不一致的问题。
- 保留 SwiftUI 原生应用外壳，让各平台采用适合自身的导航、窗口、菜单和键盘交互。
- 统一编辑、保存、格式化、补全、诊断和预览协议。
- 将 ScriptWidget 的 JavaScript/JSX 公共 API 结构化并版本化，为补全、文档、校验和迁移提供单一数据源。
- 建立可重复的编辑和预览性能基准，避免后续功能增加带来性能回退。

## 2. 产品边界

Studio 由三层组成：

1. **原生应用外壳**
   - iOS：导航、屏幕键盘工具栏、外接键盘、编辑与预览切换。
   - iPadOS：根据可用宽度支持编辑器与预览并排。
   - macOS：多栏布局、菜单命令、窗口状态和桌面快捷键。
2. **共享编辑器内核**
   - CodeMirror 6、JSX 语言支持、主题、补全、诊断、搜索和格式化。
   - 产出一个由 iOS 与 macOS 共同嵌入的 `StudioEditor.bundle`。
3. **共享运行时与预览**
   - 沿用 `Shared/ScriptWidgetRuntime`。
   - 负责 JSX 转换、JavaScript 执行、元素树生成、控制台和 WidgetKit 预览。

平台 UI 可以不同，但编辑语义、语言能力和运行结果必须一致。

### 2.1 平台版本基线

- ScriptWidget Studio 主 App 与 Share Extension 的最低支持版本调整为 **iOS 16.0**。
- iPadOS 与 iOS 采用相同的代码和能力基线，最低支持版本为 **iPadOS 16.0**。
- Widget Extension 维持 **iOS 18.0**：可配置 AppIntent Widget 需要 iOS 17，现有 Control Widget 需要 iOS 18；App 内编辑与预览在 iOS 16 提供非交互的 Button/Toggle 降级渲染。
- macOS 最低支持版本为 **macOS 26.0**。
- 编辑器和 Bridge 不得依赖高于最低系统版本的 API；使用较新系统能力时必须通过 availability 检查提供降级路径。

## 3. 当前状态

### 3.1 iOS

- 使用 WKWebView、React 和 CodeMirror。
- `Editor/editorfe` 当前锁定的是 CodeMirror 0.19.x 预发布时期的 API，并非当前稳定的 CodeMirror 6 包结构。
- 已经支持 JSX 高亮、内容读写、只读模式和 Prettier 格式化。
- 自定义补全代码仍是示例状态，尚未形成可维护的 ScriptWidget API 补全系统。

### 3.2 macOS

- 使用 WKWebView 和 Monaco Editor 0.31.1。
- 编辑器资源较大，且 iOS 与 macOS 维护两套不同的编辑器实现。
- SwiftUI 更新时可能再次调用 `load`，导致 WebView 和 Monaco 重载。
- 输入、保存和预览之间存在较重的桥接及主线程工作。
- JSX 转换和 JavaScriptCore 执行可能阻塞编辑体验。

### 3.3 主要问题

- 双端编辑器能力和行为不一致。
- 两套资源、桥接协议和问题修复需要重复维护。
- 当前 CodeMirror 依赖过旧，需要先完成正式的 6.x 迁移。
- 编辑器状态、文档状态和预览状态边界不清晰。
- ScriptWidget JSX API 尚无统一、版本化的机器可读描述。

## 4. 目标架构

```text
ScriptWidget Studio
├── Native Studio Shell
│   ├── iOS / iPadOS SwiftUI
│   └── macOS SwiftUI
├── StudioEditor.bundle
│   ├── CodeMirror 6
│   ├── JavaScript + JSX language support
│   ├── ScriptWidget completion and diagnostics
│   ├── Themes, search, formatting and commands
│   └── StudioBridge v1
├── Studio Document Session
│   ├── document identity
│   ├── dirty and save state
│   ├── selection and scroll state
│   └── preview scheduling
└── ScriptWidget Runtime
    ├── JSX transform
    ├── JavaScriptCore execution
    ├── console and diagnostics
    └── WidgetKit preview
```

## 5. 实施阶段

### 阶段 0：建立基线和兼容清单

在替换实现前记录当前行为和性能：

- 整理现有 iOS/macOS 编辑命令、桥接消息和快捷键。
- 建立代表性 JSX 样例，包括中文、Emoji、长行和较大文件。
- 记录编辑器首次可输入时间、内存、输入卡顿和预览耗时。
- 将 iOS 16.0、iPadOS 16.0 和 macOS 26.0 纳入构建、实机测试与回归矩阵。
- 为旧脚本格式化结果、保存行为和只读脚本建立回归样例。

**完成标准**：形成迁移前基线，后续阶段可以判断功能或性能是否回退。

### 阶段 1：现代化共享 CodeMirror 6 内核

重构 `Editor/editorfe`，产出唯一的 Studio 编辑器：

- 将 CodeMirror 0.19.x 升级到稳定的 6.x 包。
- 使用 JavaScript 语言扩展并开启 JSX。
- 迁移主题到当前 `HighlightStyle` 和扩展 API。
- 启用行号、括号匹配、自动闭合、代码折叠、当前行、选择高亮、撤销与重做。
- 支持查找替换、格式化、只读和运行时主题切换。
- 清理演示 UI、无效日志和示例补全。
- 评估移除 React 与 `@uiw/react-codemirror`，优先直接使用 CodeMirror API，降低包体和生命周期复杂度。
- 输出平台无关的 `StudioEditor.bundle`。

**完成标准**：共享编辑器可以在浏览器测试页独立打开并完整编辑、格式化 JSX。

### 阶段 2：定义 StudioBridge v1

用版本化协议取代平台各自的零散桥接接口。

建议的首版消息：

```text
studio.ready
document.open
document.replace
document.changed
document.save
document.setReadOnly
selection.changed
editor.insert
editor.format
editor.setTheme
diagnostics.publish
completion.request
preview.request
```

协议要求：

- 每条消息包含协议版本和 document ID。
- 编辑输入优先传递增量 change，不在每次按键时传完整文档。
- 高频事件合并或节流。
- Swift 发起的更新带来源标记，防止消息回环。
- 编辑器只发送结构化事件，调试日志不经过业务 Bridge。
- 页面销毁时释放 message handler 和 pending callback。
- Bridge 和存储失败必须可观测，不能静默丢失用户内容。

**完成标准**：同一套 Bridge 测试同时覆盖 UIKit/AppKit WKWebView 宿主。

### 阶段 3：优先迁移 macOS

macOS 是当前收益最高且问题最明显的平台：

- 使用 `StudioEditor.bundle` 替换 Monaco 和现有 `Editor.bundle`。
- macOS 26.0 作为最低版本完成编译、启动、编辑、保存和预览验证。
- WKWebView 只在创建时加载一次。
- `updateNSView` 只同步发生变化的文档、主题、只读和编辑器设置。
- 切换脚本通过 `document.open` 完成，不重载页面。
- 保留原生菜单、保存命令和桌面键盘快捷键。
- 保存并恢复每个文档的选区和滚动位置。
- 删除 Monaco 资源及其专用桥接代码。

同步优化预览管线：

- 让拥有数据对象的 SwiftUI 视图使用正确的对象生命周期。
- JSX 转换和 JavaScript 执行移出主线程。
- 编辑触发预览使用可配置 debounce，初始建议为 300ms。
- 新任务开始时取消或废弃过期预览任务。
- 只有最新文档版本的结果可以更新预览。
- 控制台输出批量更新，避免逐条刷新界面。

**完成标准**：连续输入不会重载 WebView，光标不被预览阻塞，快速切换脚本不会串写内容。

### 阶段 4：迁移 iOS 和 iPadOS

在 macOS 验证共享内核后替换现有 iOS 编辑器：

- iOS 使用相同的 `StudioEditor.bundle` 和 Bridge。
- iOS 16.0 与 iPadOS 16.0 作为最低版本完成编译、启动、编辑、保存和预览验证。
- 保留并升级原生屏幕键盘工具栏。
- 支持常用外接键盘命令。
- 统一字号、Tab 宽度、换行、主题和自动保存设置。
- iPhone 使用编辑与预览切换；iPad 在空间允许时使用并排布局。
- 验证中文输入法、组合字符、触控选择、复制粘贴和 VoiceOver。

**完成标准**：iOS 与 macOS 对同一份脚本提供一致的高亮、格式化、补全基础和保存语义。

### 阶段 5：形成 Studio 1.0 产品体验

第一版 Studio 应包括：

- 编辑器与实时预览。
- Small、Medium、Large 等 Widget 尺寸切换。
- Widget 参数编辑。
- 错误列表及点击跳转行列。
- 控制台查看、清空和复制。
- 自动保存、保存状态和未保存提醒。
- 新建模板和示例入口。
- 编辑器设置同步。

这一阶段不引入复杂多文件工程、语言服务器或云端协作，先保证单脚本创作链路稳定。

### 阶段 6：ScriptWidget API 元数据与智能能力

原生 JSX 组件 `switch` 是运行时实现的权威来源。Studio 在
`Editor/editorfe/src/scriptWidgetAPI.js` 中维护仅供补全和文档生成使用的静态元数据，
并通过测试确保组件名称与原生 `switch` 对齐：

```text
scriptWidgetAPI.js
├── schema version
├── runtime version
├── components
├── component properties
├── property value types
├── functions
├── environment values
├── availability
├── deprecations
└── documentation
```

基于 Schema 生成：

- JSX 组件补全。
- 属性名和枚举值补全。
- Hover 文档和示例。
- 不支持属性及平台可用性诊断。
- 模板兼容性测试。
- 公共 API 文档。

**完成标准**：新增或修改公共 Runtime API 时，只需更新受版本控制的 Schema，并由测试保证编辑器、运行时和文档一致。

## 6. 版本交付建议

### Studio 1.0

- 稳定版 CodeMirror 6。
- iOS/macOS 共享 bundle。
- macOS 移除 Monaco。
- StudioBridge v1。
- 保存、格式化、搜索替换和 JSX 高亮。
- 编辑器与预览基本联动。
- macOS 预览不阻塞编辑。

### Studio 1.1

- ScriptWidget 组件和属性补全。
- 错误定位与控制台。
- 可取消的预览调度。
- 编辑位置恢复。
- iPad 并排模式。

### Studio 1.2

- API Schema。
- Hover 文档。
- 属性值智能补全。
- 模板兼容性检查。
- 更完整的运行前诊断。
- 根据用户需求评估多文件支持。

## 7. 性能与质量验收

每个发布版本至少测试以下指标：

- 编辑器创建到首次可输入的时间。
- 打开 100KB、500KB 和 1MB JSX 文件的时间。
- 快速连续输入时的主线程卡顿和丢帧。
- 单次文档变化到预览完成的时间。
- 编辑过程中 WKWebView 重载次数，目标为零。
- Bridge 每秒消息数、平均大小和峰值大小。
- JSX 转换、JavaScript 执行和元素树生成耗时。
- 编辑与预览并存时的内存峰值。
- 中文输入法、Emoji 和组合字符正确性。
- 撤销重做、选区、搜索替换和只读模式正确性。
- iPhone、iPad、Apple Silicon Mac 的 Release 构建实机表现。

建议将代表性脚本加入自动化回归，并对 Runtime 元素树使用 golden fixture。

### 7.1 当前验收记录

- 前端 14 项自动化测试通过，覆盖 Bridge 协议、Schema/Runtime 对齐、补全、诊断以及光标和滚动恢复。
- Vite production/release 构建通过；iOS 与 macOS 内嵌 bundle 字节级一致。
- Xcode 27 Debug 构建通过：iOS App/Share 为 iOS 16，Widget Extension 为 iOS 18，macOS App/Widget 为 macOS 26。
- macOS 编辑器页面只加载一次；编辑只发送增量事件，预览采用 300ms 防抖、后台串行执行和过期结果丢弃。
- CodeMirror 初始状态基准：100KB 16.82ms、500KB 8.46ms、1MB 8.49ms（Apple Silicon，本地 Node 基准；大文档采用 CodeMirror 增量解析）。

## 8. 数据安全与迁移原则

- 编辑器替换不得改变现有脚本文件格式和存储位置。
- 保存过程继续采用原子写入或等价的防损坏策略。
- 页面重建、App 进入后台或窗口关闭前必须处理未保存内容。
- 自动保存失败必须向用户展示，并保留内存中的最新内容。
- 第一阶段保留旧编辑器的开发开关，便于回退和对照测试。
- macOS 完成稳定性验证后再删除旧 Monaco 资源。
- iOS 迁移完成并通过回归后再删除旧 CodeMirror bundle。

## 9. 暂不纳入首版的内容

- 新建独立的 ScriptWidget Studio App。
- 原生 TextKit 编辑器重写。
- 完整 JavaScript/TypeScript 语言服务器。
- 多人实时协作。
- 云端构建和云端运行脚本。
- 完整的多文件 IDE 和项目索引。

这些能力可以在统一编辑器和 API Schema 稳定后单独评估。

## 10. 推荐执行顺序

1. 建立行为与性能基线。
2. 将编辑器升级到稳定 CodeMirror 6。
3. 建立共享 bundle 与 StudioBridge v1。
4. macOS 替换 Monaco，并优化预览线程与生命周期。
5. 完成 macOS 性能、输入法和保存回归。
6. iOS/iPadOS 切换到共享 bundle。
7. 发布 Studio 1.0。
8. 引入 API Schema、补全、诊断和文档生成。

这一路线优先解决 macOS 卡顿和双端重复维护，同时把 Studio 控制在可逐步交付的范围内。
