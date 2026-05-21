# AI Generate — 设计文档

在 ScriptWidget 中引入 "AI 生成 Widget" 能力：用户在设置里配置 OpenAI (或兼容端点) 的 API key，然后在新建 Widget 流程里输入一段自然语言 prompt，由 LLM 生成 JSX 代码，并在本机 runtime 中自动"跑—看错—修"直至通过，最后进入审阅+预览态，由用户确认落盘。

本设计为 `feature/ai-generate` 分支的实施依据。实现阶段按第 9 节里程碑推进。

---

## 1. 目标

- 让不会写 JSX/JS 的用户，用一段描述就能得到一个可运行的 Widget。
- 生成出的 Widget 必须**真的能跑**，不是"看起来像代码"。通过 runtime 侧自动执行 + 错误回灌的 agent loop 保证。
- 用户体验接近 Claude Code / Codex：能看到迭代进度，能中断，跑完能审阅修改再保存。

### 非目标（本期不做）

- 多轮自由聊天 / 聊天历史。用户在已生成的 widget 基础上再下一句"优化 prompt"即可，不是多轮。
- Widget extension 二进制里调 LLM。AI 调用仅发生在主 app 进程。
- 生成图片素材 / DALL·E。只生成 JSX 代码。
- Streaming UI 打字效果。见 §8，列为第二期。

---

## 2. 决策摘要

| 项 | 决定 |
|---|---|
| 存储 | `UserDefaults(suiteName: "group.everettjf.scriptwidget")`（第一期）。Keychain 迁移留作后续 |
| OpenAI 客户端 | [SwiftOpenAI](https://github.com/jamesrochabrun/SwiftOpenAI) |
| 默认模型 | `gpt-4o-mini`，用户可自填任意 SwiftOpenAI 支持的 model id |
| 默认 base URL | `https://api.openai.com/v1`，用户可自填（兼容 Azure / DeepSeek / 本地 vLLM 等） |
| 默认迭代上限 | 20，用户可设 30 / 40 / 50 |
| 交互形态 | 一次性 prompt → agent loop → 审阅+预览 → 用户点确认落盘 |
| 优化 | 已生成的 widget 上，用户可追加一段 prompt 触发新一轮 agent loop（单轮单次，不留聊天历史） |
| Agent UI | 进度条 + 当前阶段文本 + 错误日志折叠面板。不做流式打字 |
| Agent 循环位置 | 仅主 app，iOS/macOS 双端。不进 widget/share extension |

---

## 3. 总体架构

```
┌─────────────────────────────────────────────────────────────────┐
│  SwiftUI                                                         │
│  ┌──────────────┐   ┌───────────────────────┐   ┌─────────────┐ │
│  │ SettingAIView│   │ AIGenerateView        │   │ AIReviewView│ │
│  │  (config)    │──▶│  (prompt + progress)  │──▶│ (preview +  │ │
│  │              │   │                       │   │  confirm /  │ │
│  │              │   │                       │   │  refine)    │ │
│  └──────────────┘   └───────────┬───────────┘   └─────────────┘ │
│                                 │                                │
└─────────────────────────────────┼────────────────────────────────┘
                                  │
       ┌──────────────────────────▼─────────────────────────┐
       │ AIGenerateSession  (@MainActor ObservableObject)   │
       │  - phase / iteration / logs / currentJSX           │
       │  - start(prompt) / refine(prompt) / cancel()       │
       └───┬─────────────────────┬──────────────────────────┘
           │                     │
           ▼                     ▼
  ┌────────────────┐      ┌───────────────────────┐
  │ AIClient       │      │ AgentLoop             │
  │ (SwiftOpenAI)  │◀────▶│  plan→gen→run→fix     │
  │ baseURL/key/   │      │  terminates on:       │
  │ model/usage    │      │   pass / max iter /   │
  └────────────────┘      │   cancel              │
                          └──────────┬────────────┘
                                     │ runs JSX via
                                     ▼
                          ┌────────────────────────────┐
                          │ ScriptWidgetRuntime        │
                          │  (existing JavaScriptCore) │
                          │  → element? / error? /     │
                          │    console logs            │
                          └────────────────────────────┘
```

关键原则：
- **AI 业务逻辑放在 `Shared/ScriptWidgetRuntime/AI/`**，iOS/macOS 共享。
- **runtime 不动**，当作沙箱直接复用。AI 侧只消费它的输出。
- SwiftUI view 各端一份（iOS Form 风格；macOS GroupBox 风格，和现有 `SettingsView` 一致）。

---

## 4. 详细设计

### 4.1 配置存储

一组 key，挂在 app group `UserDefaults` 上，以便将来 extension 读写元数据（虽然当前 extension 不调 LLM）。

```swift
enum AISettingsKey {
    static let apiKey          = "ai.apiKey"            // String
    static let baseURL         = "ai.baseURL"           // String, default "https://api.openai.com/v1"
    static let model           = "ai.model"             // String, default "gpt-4o-mini"
    static let maxIterations   = "ai.maxIterations"     // Int,    default 20
    static let temperature     = "ai.temperature"       // Double, default 0.7
}
```

- 默认值集中在 `AISettings.default` 静态常量里。
- `AISettings.isConfigured: Bool { !apiKey.isEmpty }`。
- **注意**：第一期 UserDefaults 明文存储，**在 UI 上显式告知用户**"key 明文存在本机，请勿在共享设备上配置"。TODO: 下一期迁 Keychain。

### 4.2 AI 设置页 `SettingAIView`

挂在 `SettingsView` 新的 `GroupBox(label: SettingsLabelView(title: "AI", image: "sparkles"))` 下，用 `NavigationLink` 跳转。字段：

- API Key（`SecureField`，带"显示/隐藏"眼睛）
- Base URL（`TextField`，默认占位符展示官方地址）
- Model（`TextField` + 快捷按钮：`gpt-4o-mini` / `gpt-4o` / `gpt-4.1-mini` / 清空）
- Max Iterations（`Stepper`，范围 5...100，默认 20）
- Temperature（`Slider`，0.0...1.5，默认 0.7）
- "Test Connection" 按钮：发一条最小 chat（"ping"），成功绿勾、失败错误信息
- 一段风险说明文字（key 明文存储）

### 4.3 生成入口与审阅预览页

**入口**：在 `CreateGuideView` 的列表最上方插入一条独立行 "✨ Generate with AI"。

- 若 `AISettings.isConfigured == false`：点击弹窗"请先到设置 → AI 配置 API Key"，带一个按钮直接跳到 `SettingAIView`。
- 已配置：push `AIGenerateView`。

**`AIGenerateView`**（纯输入态）：

- 多行 `TextEditor`（prompt，至少 4 行可见），placeholder "描述一下你想要的 widget（例如：显示当前天气和三天预报，深色背景）"。
- Widget Size Picker（small / medium / large / extraLarge / accessoryCircular / accessoryRectangular / accessoryInline），默认 `medium`。
- 主按钮 "Generate"。
- 下方嵌一个 `AIGenerateProgressView`（见 §4.8），未开始时隐藏。

**`AIReviewView`**（agent loop 结束 + 成功时 push 过来）：

- 上半：复用现有 preview 机制，用生成出来的 JSX 建一个 **临时 package**（见下方"临时 package"设计），走 `ScriptWidgetElementView` 渲染，就是现在 `ScriptCodePreviewView` 那个 widget 预览块。
- 中间：折叠的 Code 查看器（复用现有 CodeMirror 或 `MirrorEditorScriptView`）—— 只读，避免用户在此编辑后状态混乱；要编辑请先点"Save"进入正式编辑态。
- 下半：
  - "Refine" 区：一个 TextField + "Refine" 按钮 → 回到 `AIGenerateView` 的进度流程，但这次初始 JSX 是上一轮的代码，用户 prompt 是"在原有基础上 …"（见 §4.5 refine prompt）。
  - "Save Widget" 主按钮 → 调用 `sharedScriptManager.createScript(content:, recommendPackageName: "AI Generated <timestamp 或首行注释>", imageCopyPath: nil)`，随后走和 `CreateGuideView` 相同的 dismiss + `ScriptWidgetHomeViewDataObject.scriptCreateNotification` 通知逻辑。
  - "Discard" 次级按钮 → 返回上一页。
- 顶部 navbar "Logs" 按钮 → 展示本次 agent loop 的完整迭代历史（每轮的错误 + 修改点概述），只读。

**临时 package**：AI 跑 JSX 需要一个 `ScriptWidgetPackage` 路径（runtime 强依赖 package 做 `$import / $file` 支持）。用 `NSTemporaryDirectory()/ScriptWidgetAI/<UUID>/` 建一次性目录，只放 `main.jsx`。审阅页完成或取消时清理。

### 4.4 AI 服务层 `AIClient`

薄封装 SwiftOpenAI。位置 `Shared/ScriptWidgetRuntime/AI/AIClient.swift`。

```swift
actor AIClient {
    struct Config {
        let apiKey: String
        let baseURL: URL
        let model: String
        let temperature: Double
    }

    struct Message { let role: Role; let content: String }
    enum Role: String { case system, user, assistant }

    struct Response {
        let content: String
        let promptTokens: Int
        let completionTokens: Int
    }

    func chat(messages: [Message], config: Config) async throws -> Response
}
```

- 内部根据 `config` 构造 SwiftOpenAI 的 `OpenAIService`（支持自定义 baseURL）。
- 不做流式（第一期）。失败直接抛错，由 `AgentLoop` 捕获。
- 超时（建议 60s / 次）单独在 config 里预留参数（先硬编码 60s）。

### 4.5 Prompt 构造

位置 `Shared/ScriptWidgetRuntime/AI/PromptBuilder.swift`。

**System Prompt** 组成（顺序）：

1. **角色与铁律**（硬编码、稳定）：
   ```
   You are a ScriptWidget code generator. Output ONLY a single JSX snippet
   that calls $render(...) exactly once. No markdown fences, no explanations.

   RULES:
   1. Must call $render(<...>) exactly once. Root must be a layout container
      (vstack / hstack / zstack).
   2. Do NOT use `import`, `require`, `module`, Node APIs, or DOM APIs.
   3. Networking is only via `fetch(url)` (returns string) or `$http.*`.
   4. Top-level `await` is allowed; the runtime wraps code in async $main.
   5. Time/date: use the globally injected `moment` or JS Date.
   6. Persistent data: use `$storage.set(key, value)` / `$storage.get(key)`.
   7. Only use tags and APIs listed in the REFERENCE section below.
   8. Keep the widget visually dense but readable for the given size.
   9. When using `fetch`, handle errors so the widget still renders.
   ```

2. **REFERENCE 段**（动态拼接）：
   - 启动时读 `Script.bundle/component/*/main.jsx` 和 `Script.bundle/api/*/main.jsx`，每个文件截取首 40 行，前面加 `// === <name> ===`。整份塞进 system。
   - 这样之后新增组件/新增 API 无需改 prompt，AI 自动知道。
   - 体积控制：若总长超过 ~60K chars，按优先级裁剪（component 全保留，api 保留常用 10 个：fetch / http / storage / location / health / device / file / getenv / system / console）。

3. **SIZE HINT**：告诉 AI 当前目标 size 的像素范围和设计建议（e.g., `accessoryCircular` 必须极简，`large` 可放多列等）。

**User Prompt（首轮）**：

```
Widget size: {size}
User description:
{user_prompt}
```

**User Prompt（第 N>1 轮，修错）**：

```
Your previous code:
```jsx
{last_code}
```
It failed to run. Runtime feedback:
- Error type: {errorCase}
- Error detail: {errorDetail}
- Last console lines:
{last_10_log_lines}

Fix the code. Return the FULL corrected JSX only.
```

**User Prompt（Refine）**：

```
Current working code:
```jsx
{current_code}
```
Apply this change request from the user:
{refine_prompt}

Return the FULL updated JSX only.
```

**后处理剥壳**：即便明确说了不要 markdown，仍写一个 `stripCodeFences(_ raw: String) -> String`，容错处理 `` ```jsx `` / `` ``` `` 围栏、以及前后解释文字（找到第一个 `<` 到最后一个 `);` 的片段作为兜底）。

### 4.6 Agent 自调试循环

位置 `Shared/ScriptWidgetRuntime/AI/AgentLoop.swift`。纯逻辑，返回流式结果给 `AIGenerateSession`。

**算法**：

```
fun run(userPrompt, size, initialCode?):
    lastCode = initialCode
    for i in 1...maxIterations:
        emit(.thinking(i))

        if lastCode == nil:
            messages = [system, user_first(userPrompt, size)]
        else if initialCode != nil and i == 1:
            messages = [system, user_refine(lastCode, userPrompt)]
        else:
            messages = [system, user_first(userPrompt, size),
                         assistant(lastCode),
                         user_fix(lastCode, lastError, lastLogs)]

        jsx = stripCodeFences(await aiClient.chat(messages))
        lastCode = jsx
        emit(.running(i, jsx))

        (element, err, logs) = runtime.execute(jsx)
        if success(element, err, logs):
            emit(.done(jsx, element))
            return .success(jsx)
        else:
            lastError = err
            lastLogs = logs
            emit(.fixing(i, err))
            if cancelled: return .cancelled
            continue

    return .exhausted(lastCode, lastError)
```

**成功判定** `success(element, err, logs)`：
- `err == nil`
- `element != nil`
- element 的 tag 不是 fallback (`"#UI Not Found#"` / `"#Loading#"` / `"#Failed#"`)
- logs 里不存在以 `[error]` 开头的条目（可调：`console.error` 调用会被记录）

**终止路径**：
- 成功：返回 JSX，UI 跳 `AIReviewView`。
- 达到 `maxIterations`：把最后一版代码和最后的错误信息一起交给用户，UI 上明示 "Did not converge, showing the last attempt"，仍允许用户点进 Review 手动修。
- 取消：回到输入态，保留 prompt。

**上下文成本控制**：每轮构造 messages 时只保留 `[system, firstUser, lastAssistant, lastUserFix]`，**不累积**所有历史。这既省 token 又让模型聚焦当前错误。

### 4.7 运行时沙箱

直接调 `ScriptWidgetRuntime.executeJSXSyncForWidget`。但有两个点要处理：

1. **阻塞 → 异步**：现有方法是 `DispatchSemaphore` 同步。agent loop 跑在非主线程没问题，但应该包一层：

   ```swift
   func runJSX(_ jsx: String, in package: ScriptWidgetPackage, size: String)
       async -> (ScriptWidgetRuntimeElement?, ScriptWidgetError?, [String])
   ```

   内部 `await withCheckedContinuation { DispatchQueue.global().async { ... } }`。

2. **日志采集**：执行前先 `sharedRunningState = ScriptWidgetRunningState(package: tempPackage)`，执行后读 `sharedRunningState.logger.logs`。这与 `ScriptCodePreviewDataObject` 做法一致。
   - 风险：`sharedRunningState` 是全局 var，和主 app 同时运行的 preview 会撞。实现时加一个 serial queue 保证 AI 执行与 preview 执行互斥；或在 runtime 内部改为每次新建 `ScriptWidgetRunningState` 传入 runtime 实例（更正经，但动了 runtime，放第二期）。**第一期用互斥 queue**。

### 4.8 状态机 / 进度展示

`AIGenerateSession` 是 `@MainActor ObservableObject`。

```swift
enum AIGeneratePhase: Equatable {
    case idle
    case thinking(iteration: Int)      // 在等 LLM
    case running(iteration: Int)       // 在跑 JSX
    case fixing(iteration: Int, error: String)
    case done(jsx: String)
    case exhausted(lastJSX: String?, lastError: String?)
    case failed(String)                // 网络 / API 错误等非 agent 循环错
    case cancelled
}

@Published var phase: AIGeneratePhase = .idle
@Published var iterationHistory: [IterationRecord] = []
@Published var usage: TokenUsage = .zero   // 累计 tokens，仅展示
```

UI（`AIGenerateProgressView`）：
- 顶部：小 `ProgressView` + 文本 `"Iteration 3 / 20 — running code…"`。
- 中部：最新错误 `Text` (一行，截断)；点开后展开整条。
- 底部：`Cancel` 按钮。
- 历史折叠：`DisclosureGroup("History")` 展示每轮的 role/status/error 一行摘要。

**进度条**：用 `ProgressView(value: Double(iteration), total: Double(maxIterations))`，虽然实际 iteration 不可预测，但能给用户"大概还能继续多少次"的感知。

### 4.9 优化（Refine）交互

在 `AIReviewView` 底部：

- 输入框："Ask AI to change it (e.g. 'make background darker, show icon on the left')"
- 按钮 "Refine" → 关闭 review，重新 push `AIGenerateView`（或直接原地覆盖），以 `initialCode = currentJSX` 和 `refinePrompt` 为输入启动 agent loop。
- 完成后再回到 review，循环。

注意：Refine 不保留多轮历史，每次 refine 都是"基于当前 code + 本次 prompt"的独立请求。这是为了成本可控，也符合你"不需要多轮聊天"的决策。

---

## 5. 文件改动清单（实施时的 checklist）

**新增**：

```
Shared/ScriptWidgetRuntime/AI/
├── AISettings.swift              // UserDefaults 封装 + default values
├── AIClient.swift                // SwiftOpenAI 封装 (actor)
├── PromptBuilder.swift           // system/user prompt 拼接 + stripCodeFences
├── AgentLoop.swift               // 核心循环
├── AgentRuntimeBridge.swift      // runJSX(...) async + 互斥 queue + 日志采集
├── AIGenerateSession.swift       // @MainActor ObservableObject
└── AIReferenceSnapshot.swift     // 启动时读 Script.bundle 构造 REFERENCE 段（带缓存）

iOS/ScriptWidget/App/Settings/
└── SettingAIView.swift           // 新设置页

iOS/ScriptWidget/View/AIGenerate/
├── AIGenerateView.swift          // prompt 输入 + progress
├── AIGenerateProgressView.swift  // 进度条 + 阶段文本 + 历史
└── AIReviewView.swift            // preview + refine + save

macOS/ScriptWidgetMac/...         // 三件与 iOS 对应的 macOS 版本
（若 view 可完全跨平台，优先跨端复用；不能则分开写，行为一致）
```

**修改**：

```
iOS/ScriptWidget/App/Settings/SettingsView.swift
  - 加一个 GroupBox "AI" → NavigationLink(SettingAIView)

iOS/ScriptWidget/App/Scripts/CreateGuideView.swift
  - 列表顶部插一行 "✨ Generate with AI"
  - 未配置时引导到 SettingAIView；已配置 push AIGenerateView

iOS/ScriptWidget.xcodeproj/project.pbxproj
  - 添加 XCRemoteSwiftPackageReference: SwiftOpenAI
  - 主 app target 链接 SwiftOpenAI；widget/share extension 不链接

macOS/ScriptWidgetMac.xcodeproj/project.pbxproj
  - 同上
```

**显式不改**：
- `Shared/ScriptWidgetRuntime/Widget/Runtime/ScriptWidgetRuntime.swift` 保持不变。
- `ScriptCodePreviewView` / `ScriptCodePreviewDataObject` 不动。

---

## 6. 安全 / 隐私 / 成本

- **Key 存储**：第一期 UserDefaults 明文。设置页必须有一段红色/橙色说明文字。TODO comment 写清楚"迁 Keychain"。
- **网络**：只向用户配置的 `baseURL` 发请求。禁止默认值之外的任何 hardcoded endpoint。
- **数据最小化**：prompt 只包含用户输入 + 我们的系统提示 + 当轮错误信息。不上传用户已有 widgets、设备标识、位置、健康数据等。
- **成本可感**：
  - 每轮请求后累加 `usage.prompt_tokens / completion_tokens`，在 progress view 展示 "used ~3.2K tokens so far"。
  - iteration 上限是硬性保险。UI 上明示 "cost scales with iterations"。
- **取消即止**：`AgentLoop` 内每轮入口检查 `Task.isCancelled`，一旦 cancel 立即返回，不再发下一次请求。
- **错误暴露**：SwiftOpenAI 抛的错（401 / 429 / 超时）直接以可读文本展示；不吞异常。

---

## 7. 跨平台

- 共享层（`Shared/ScriptWidgetRuntime/AI/`）纯 Swift + SwiftUI 无平台耦合。
- 三个 SwiftUI view 若能用 `#if os(iOS)` / `#if os(macOS)` 在单文件内分支处理，尽量单文件跨端。iOS 用 `Form`/`sheet`/`.navigationBarTitle`，macOS 用 `ScrollView`+`GroupBox`（和现有 `SettingsView` macOS 版本一致）。
- widget / share extension **不**链接 SwiftOpenAI。在 target membership 上严格限制。

---

## 8. 本期不做 / 延后

1. **流式 UI**（`LanguageModelChatUI` 风格打字效果）：实现成本中等，但需要改 `AIClient` 为流式 + UI 实时拼接 + 中断半完成响应。判断：不做流式 UX 已经够用（每轮 2–5 秒），延后到第二期。
2. **多轮聊天历史**：用户不需要。
3. **Keychain 存储**：第二期。
4. **Extension 内 LLM 调用**：不做（内存限制 + 隐私）。
5. **生成图片 / 素材**：不做。
6. **本地模型 / on-device**：先不做，用户想用的话自填本地 `baseURL`（例如 `http://127.0.0.1:11434/v1`）即可。

---

## 9. 里程碑拆分

建议按以下顺序合并小 PR，每步可独立验证：

- **M1 — 配置通路**：`AISettings` + `SettingAIView` + 设置入口 + "Test Connection"。无 AI 生成能力，只验证 key 配置与网络联通。
- **M2 — 单次生成**：`AIClient` + `PromptBuilder`（含 REFERENCE 构造）+ `AIGenerateView` 的 prompt 输入和"单次调用 LLM + 拿到 JSX + 直接渲染"路径，**不做 agent loop**，失败就失败。用来验证 prompt 质量。
- **M3 — Agent loop**：`AgentRuntimeBridge` + `AgentLoop` + `AIGenerateSession` + 进度 UI。
- **M4 — 审阅页**：`AIReviewView`（preview + logs + save）。
- **M5 — Refine**：在 M4 上加 refine 输入与再循环。
- **M6 — macOS 平齐**：确保 macOS 三个 view 功能等同。

本文档合入作为 M0。

---

## 10. 开放问题 / 待实施时确认

1. REFERENCE 段的裁剪策略：是否允许用户在设置里勾选"精简 / 完整"两档以控制 prompt token 成本？（当前设计：固定按优先级裁剪）
2. 临时 package 目录是否应该落在 app group 而非 `NSTemporaryDirectory()`？若 runtime 某些 API 依赖 `ScriptManager.scriptDirectory`，需要验证一下——实施时写个小 spike 跑通再定。
3. "审阅页"的 code 查看器要不要允许编辑？当前设计是只读；若允许编辑，则与进入正式编辑态后的行为边界需要再想清楚（覆盖还是分叉）。
4. 失败但 iteration 未耗尽时，是否给用户"再试一轮"按钮（单独追加一轮而非重头来）？第一期先不做，等实际用起来再加。

---

## 附录 A：相关源码锚点

- 运行时入口：`Shared/ScriptWidgetRuntime/Widget/Runtime/ScriptWidgetRuntime.swift` — `executeJSXSyncForWidget` (line 181)
- 错误类型：同文件 `ScriptWidgetError` (line 12)
- 日志聚合：`ScriptWidgetRunningState.logger.logs`（全局 `sharedRunningState`）
- 模板清单：`Shared/ScriptWidgetRuntime/Resource/Script.bundle/template/*/main.jsx`
- 组件用法：`Shared/ScriptWidgetRuntime/Resource/Script.bundle/component/*/main.jsx`
- API 用法：`Shared/ScriptWidgetRuntime/Resource/Script.bundle/api/*/main.jsx`
- 创建入口：`iOS/ScriptWidget/App/Scripts/CreateGuideView.swift`
- 编辑/预览：`iOS/ScriptWidget/View/CodeEditor/ScriptCodeEditorView.swift`、`.../Preview/ScriptCodePreviewView.swift`
- 设置页：`iOS/ScriptWidget/App/Settings/SettingsView.swift`
- 包落盘：`Shared/ScriptWidgetRuntime/Common/ScriptManager.swift` — `createScript(content:recommendPackageName:imageCopyPath:)`
