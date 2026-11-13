# ScriptWidget Android 版：深度调研、开发规划与落地规划

状态：调研与规划稿，2026-11-12。尚未写任何 Android 代码，本文所有 Android 侧结论均未经真机验证。

目标：做一个 Android 版 ScriptWidget，让**同一个 Package 2.0 widget（同一份 `main.jsx` + `widget.json`）在 iOS 和 Android 上都能运行**，尽量覆盖现有全部标签和功能；Android 上没有对应物的能力明确降级，而不是悄悄变样。

标注约定：**[已核实]** 本次调研直接读到官方页面；**[二手]** 来自媒体或社区；**[待验证]** 没有可靠来源或需要真机/原型确认，不能当作事实。

---

## 1. 结论摘要

1. **可行，而且仓库里已经有两块可直接复用的资产。** `Web/preview-engine/src/kernel.js` 是一份与宿主解耦的执行内核（通过 `host` 接口注入求值、文件、日志、超时），`Web/preview-engine/src/render/layout.js` 是按 iPhone 快照校准过的 SwiftUI 式 propose/size/place 布局算法（文本度量走 `measurer` 抽象）。Android 运行时应当复用内核、移植布局，而不是从 Swift 源码重写。
2. **JS 引擎选 QuickJS-NG**（自编译 + 薄 JNI），备选 Javet（V8）。最大的兼容性风险是 QuickJS 没有 `Intl`，需要宿主侧补齐。
3. **渲染选"自写布局引擎 + Canvas 画成位图 + RemoteViews 点击遮罩"**作为全版本基线。Glance / 手写 RemoteViews 无法表达旋转、渐变、阴影、任意裁剪、图表、Gauge、自定义字体，不适合作主后端。Remote Compose 与 JSX 树模型最贴合，但仍是 alpha 且仅 Android 16+，作为第二后端并行试验。
4. **同一脚本跨端运行靠"契约 + 一致性测试"保证，不靠共享 Swift 代码。** 现有 100 棵 parity 树（`test/parity/native-trees.json`）直接作为 Android 运行时的验收门槛。
5. **不能 1:1 的能力**：Live Activity / Dynamic Island 的自由布局、锁屏 accessory 家族、`backgroundMaterial` 毛玻璃、`$icloud`、`$reminders`、`$home`、WeatherKit、时钟/摆动动画。逐项给出降级方案（见第 5 节）。
6. **节奏**：先做 2–3 周技术验证（4 个 go/no-go 问题），通过后约 3–4 个月出可用内测版，6–8 个月到功能基本对齐的 1.0（单人全职 + AI 辅助的粗估，未含 OEM 适配的意外成本）。

---

## 2. 现状盘点：需要搬到 Android 的东西

| 领域 | 现有规模（iOS/macOS） | 来源 |
| --- | --- | --- |
| JSX 标签 | 29 个：`vstack hstack zstack vgrid hgrid text date image gif spacer rect roundedrect capsule ellipse circle gauge chart link divider line icon label progress ring badge chip stat button toggle` | `docs/scriptwidget-runtime-api.md` |
| 通用属性 | 约 21 个：`background backgroundMaterial color font fontWeight fontDesign frame padding corner opacity alignment clip rotation rotation3d shadow animation widgetAccentable linkurl` 等 | 同上 |
| 运行时函数 | 约 110 个，分布在 `$storage $file fetch $http $xml $dataSource $device $system $location $health $calendar $reminders $photos $music $services $notifications $alarms $documents $contacts $maps $home $weather $icloud` | 同上 |
| 权限 | 20 类：`network location health calendar calendarWrite reminders remindersWrite photos services music storage icloud notifications maps weather alarms documents contacts home files` | `widget.schema.json` |
| Widget 家族 | `systemSmall/Medium/Large/ExtraLarge/ExtraLargePortrait`、`accessoryCircular/Rectangular/Inline` | 同上 |
| 其他 surface | Live Activity + Dynamic Island、Control Widget、Siri/Shortcuts 动作、WidgetKit push | `docs/widgetkit-modern-features.md` |
| 资源限制 | 源码 512 KiB、转译后 2 MiB、执行 5 秒；网络 8 并发 / 32 总量 | `docs/runtime-api.md` |
| 包与生态 | Package 2.0（`.swt` ZIP）、Skills 1.0、Gallery 1.0（24 个精选 widget）、Data Source Plugin 1.0、146 个内置模板/示例包 | `docs/package-format.md` 等 |
| App 功能 | 脚本库、CodeMirror 6 编辑器（`Editor/editorfe`）、AI 生成（Agent loop + Skills）、Gallery、导入导出、诊断 | `Shared/ScriptWidgetRuntime/*` |
| Swift 运行时代码量 | `Widget/` 约 1.5 万行，`Common/ Gallery/ Plugin/ AI/` 约 1.8 万行 | `wc -l` |

对 Android 最关键的三个既有事实：

- **执行内核已经有 JS 版本。** `kernel.js`（1373 行）镜像了 `internalExecuteJavaScriptForWidget`、组件展开、树校验和 JavaScriptCore 桥接转换（例如 `undefined` 属性丢弃、函数变 `{}`、`<text>{true}</text>` 渲染为 `1`）。它在 Node（V8）和 Chromium 里对 100 棵树做到了与 JavaScriptCore 逐字节一致。
- **"规范树 JSON"已经存在**，目前只是测试产物。它正好是 Android 需要的跨端中间表示：JS 执行产出树，渲染后端只吃树。
- **SF Symbols 的替代已经做过。** 预览引擎把 283 个 SF Symbol 名映射到 252 个 Lucide 图标（ISC），未映射的显示占位并告警。Android 不能分发 Apple 符号，直接沿用这套映射。

---

## 3. 平台调研结论

### 3.1 JS 引擎

| 引擎 | 版本 | 结论 |
| --- | --- | --- |
| **QuickJS-NG** | v0.18.0（2026-11-01）[已核实] | **主选。** 每 ABI 约 1 MB 量级 [待验证]；同步宿主函数；中断回调 + `JS_SetMemoryLimit`；字节码缓存；0.18 起 OOM/InternalError 不能被脚本 catch；MIT。缺点：**没有 `Intl`，官方表示不会支持** [已核实]；纯解释器，低端机上 5 秒预算更紧。 |
| Javet（V8 15.7） | 6.0.3（2026-11-02）[已核实] | **备选。** 语义最接近 JSC，i18n 变体带 Intl，支持 16 KB 页。缺点：十几到数十 MB、单人维护。 |
| androidx.javascriptengine | 1.1.1 [已核实] | 不作主路径：隔离最好，但**没有同步宿主桥**（只能传字符串/消息端口），而 `$import`、`$file.read`、`$getenv` 都是同步的；且依赖设备 WebView，国产 ROM 可用性 [待验证]。 |
| Hermes | V1 | 只围绕 React Native 发布，没有独立嵌入制品 [待验证]；不支持 `with`、局部 `eval`，与现有"保留 legacy eval/with"的契约冲突。 |
| jsc-android | 2024-11 后低活跃 [二手] | 与 iOS 同源但版本不同、无内存上限 API，不选。 |
| Swift on Android / Skip | Swift 6.3 首个官方 Android SDK [已核实]；Skip Fuse 增加约 60 MB [已核实] | 不选：现有运行时深度依赖 JavaScriptCore.framework、SwiftUI、WidgetKit、App Intents，可共享的只有很小一部分，体积代价不合理。 |

JSX 转译：三种引擎都不解析 JSX。现有流程在保存/安装时用 Babel 转译并写入 `__Build/` 缓存（指纹 `scriptwidget-babel-v5`，带取消检查插桩）。Android 上 QuickJS 有真正的中断回调，**不需要插桩**，只需要 JSX → `$element.createElement` 转换。候选：在 QuickJS 里跑现有 Babel bundle（最保真，耗时 [待验证]），或 sucrase（classic runtime + 自定义 pragma，[已核实] 支持）。无论哪种，**widget 后台路径只执行缓存产物**，绝不在后台转译。

Google Play 政策允许解释执行 JS [已核实，Device and Network Abuse 政策原文]，前提是解释器不成为绕过政策的通道。现有的权限模型、"Skills 不授予权限"、"插件是声明式 HTTPS 映射"正好满足。

### 3.2 Widget 渲染

| 策略 | 保真度 | 覆盖 | 判断 |
| --- | --- | --- | --- |
| A. Glance 动态树（稳定版 1.2.0 [已核实]） | 低 | API 23+ | Box/Row/Column 映射到 RelativeLayout/LinearLayout [已核实]；Row/Column 最多 10 个子节点 [二手]；不支持自定义字体 [已核实]；没有旋转、渐变、阴影、任意 clip、Canvas [待验证]。大部分标签仍要转位图，不值得。 |
| B. 手写 RemoteViews | 低–中 | 全版本 | 能力上限同 A，还要预置大量 XML layout 组合。 |
| **C. 整张位图 + 点击遮罩** | 高（静态） | 全版本、全 launcher | **基线后端。** 自写布局 + `android.graphics.Canvas`/`StaticLayout`，不依赖 window，可在 Worker 里确定性运行。 |
| D. Remote Compose（1.0.0-alpha23，2026-11-04 [已核实]） | 高（含动画、host 本地交互） | **仅 Android 16+**，官方称 17+ 最佳 [已核实] | 模型最贴合（Box/Row/Column、Canvas、渐变、clip、旋转、时间表达式、可运行时生成文档 [已核实]）。但 alpha、两周一版有破坏性改动、手机入口 `RemoteComposeWidget` 是 RestrictedApi [已核实]；OEM launcher 是否带 player [待验证]。 |
| **E. 混合（C 为基线，D 试验）** | 高 | 全版本 | **推荐。** JSX 树 → 后端无关的布局结果 → 位图渲染器 / Remote Compose 发射器。 |

"离屏渲染 Compose 再截图"不可靠：未 attach 到 window 的 composition 不组合、测量为 0，没有官方支持的 headless 方案 [二手，待验证]。所以基线后端不用 Compose，用纯 Canvas。

位图方案必须遵守的硬约束：

- **位图预算** [已核实，Android 17 behavior changes]：单次 widget 更新中所有图像合计不得超过 `6 × 屏宽px × 屏高px` 字节；target API 37 起超限直接抛 `IllegalArgumentException`，之前只告警。1080×2400 屏预算约 15.5 MB，一张 4×4 widget（约 1000×1100 px，ARGB_8888）约 4.4 MB。结论：每次更新只带当前尺寸（最多横竖两张），用完整 `updateAppWidget` 而不是 partial update，不透明内容可用 RGB_565。
- **点击区域**：位图上叠透明 View，各自 `setOnClickPendingIntent`。精确定位依赖 API 31 的 `setViewLayoutMargin/Width/Height` [已核实]。
- **深色模式**：位图不会随系统主题自动变，需要在配置变化时重渲染，或用 `setIcon(notNight, night)` 带两张图（预算翻倍）。
- **自更新文本**：只有 `TextClock`、`Chronometer` 能不唤醒应用自己走 [已核实]；"3 分钟前"这类相对时间没有对应 View。

### 3.3 尺寸、刷新、交互

- **尺寸**：Android 格子不是正方形。Pixel 竖屏 n×m 格约 `(73n−16) × (118m−16)` dp [已核实]，即 2×2 ≈ 130×220 dp，4×2 ≈ 276×220 dp；iOS small 是 158×158 pt。**不能假设 small 是方的**，渲染器必须按 launcher 实际给的尺寸布局。`OPTION_APPWIDGET_SIZES` 可能为空 [已核实]；各 OEM 的格子尺寸、圆角、内边距 [待验证]。
- **刷新**：`updatePeriodMillis` 最小 30 分钟，WorkManager 周期任务最小 15 分钟 [已核实]。`AppWidgetProvider.onUpdate` 约 10 秒内必须返回，JS 执行要放进 WorkManager。App Standby 的 Rare/Restricted 桶会禁网并把后台配额压到每天 10 分钟 [已核实]。国产 ROM 需要用户手动开"自启动 + 电池无限制"，否则进程被杀后不更新 [二手]。
- **Timeline**：iOS 的"预排多个 entry 准点切换"在 Android 没有等价机制。可行做法是预渲染 N 张存盘，到点用 AlarmManager 推送；精度受 Doze 和 OEM 影响。精确闹钟在 Android 14+ 对新装应用默认拒绝 [已核实]。
- **交互**：`PendingIntent` 广播 → 唤醒进程 → 执行动作函数 → 重渲染。与 iOS 17 的 AppIntent 往返等价，但进程被 OEM 冻结时会延迟或失败 [待验证]。

### 3.4 其他 surface

| iOS | Android 对应 | 差距 |
| --- | --- | --- |
| Live Activity / Dynamic Island | Live Updates：`Notification.ProgressStyle` + promoted ongoing（Android 16，API 36）[已核实] | **模板化通知，不能放自定义布局。** |
| Control Widget | Quick Settings tile（`TileService`） | tile 必须在 manifest 里静态声明，数量固定。 |
| Siri / Shortcuts 动作 | 动态 App Shortcuts；可选 Tasker 插件 | 没有系统级语音入口。 |
| 锁屏 accessory 家族 | Pixel 自 Android 16 QPR2 起有锁屏 widget 页 [二手]，用的是普通 widget | 没有 circular/rectangular/inline 这种专用小尺寸。 |
| WidgetKit push | FCM 数据消息触发刷新 | 依赖 GMS，国内不可用。 |
| Apple Watch | Wear OS 7 "Wear Widgets"（Glance Wear + Remote Compose）[已核实] | 不在本规划范围。 |

### 3.5 发布政策

- 16 KB 页大小：自 2027-02-01 起，不支持的更新无法发布 [已核实]。NDK r28+ 默认对齐，自编译 QuickJS 即可满足。
- Target API：新应用与更新须面向 API 36（2026-08-31 起）[已核实]。
- 开发者验证：2026-09-30 起在巴西、印尼、新加坡、泰国生效，2027 年起全球 [已核实]。
- 个人开发者账号的封闭测试门槛（测试人数与天数）[待验证]，开账号时确认。
- 中国分发：无 Google Play，各商店通常要求软著和 APP 备案；无 GMS。已决定暂不考虑国内渠道（D9）。
- 竞品：KWGT 用公式语言，不是 JS [已核实]；Tasker Widget v2 用 JSON + Glance [二手]；**没有找到已确认的"用 JS/JSX 写 Android 桌面 widget"的应用**。需要注意 Google 自己在推用自然语言生成 widget（"Create My Widget"）[二手]，这与 AI 生成卖点直接重叠；ScriptWidget 的差异是可编程、可分享、跨 iOS/Android。

---

## 4. 目标架构

```text
.swt / Scripts/<Package>/            （与 iOS 完全相同的 Package 2.0）
        │  安装/保存时：校验 manifest → JSX 转译 → 写 __Build 缓存（前台或 Worker）
        ▼
┌─ runtime（Kotlin + JNI）──────────────────────────────────────────┐
│ QuickJS-NG ── kernel.js（与 Web 预览同一份）── Kotlin host 实现     │
│   中断回调 5s / 内存上限 / 每次执行一个新 context                    │
│   bridges: $storage $file fetch/$http $xml $dataSource $device ...  │
│   policy: 权限、networkDomains、私网拒绝、预算（与 Swift 同语义）    │
└───────────────┬────────────────────────────────────────────────────┘
                ▼  规范树 JSON（跨端一致性测试的比对对象）
┌─ render（Kotlin）─────────────────────────────────────────────────┐
│ layout：layout.js 的 Kotlin 移植（propose/size/place）              │
│ 输出：绘制列表 + 命中区域（link/button/toggle）+ 动态文本槽          │
│   ├─ BitmapBackend：Canvas → Bitmap（全版本基线）                   │
│   └─ RemoteComposeBackend：Android 16/17+（试验，开关控制）          │
└───────────────┬────────────────────────────────────────────────────┘
                ▼
widget host：AppWidgetProvider + WorkManager + 配置 Activity
  RemoteViews = ImageView(位图) + 透明点击层 + TextClock/Chronometer
app：Jetpack Compose UI（库、编辑器 WebView、Gallery、AI、设置）
```

关键设计决定：

1. **内核共享方式。** `kernel.js`、`contract.js`、`timeline.js`、`package/manifest.js`、图标映射由构建脚本从 `Web/preview-engine` 拷入 Android assets（做法类比 `Editor/editorfe` 的 `npm run release` 拷 bundle）。Kotlin 只实现 `host` 接口：`evaluateScript / compiledImport / readFile / fileExists / supportScript / log / parseXML / defer / timeout / finish`。这样"执行流程、组件展开、树校验、桥接转换"三端同源。
2. **内核里 JSC 特有的行为保持不变。** 现有内核刻意隐藏了 `setTimeout`、`structuredClone`、`URL` 等，并保留 then-only 的原生 Promise 形态。Android 沿用，目的是"在 iOS 上不能跑的写法在 Android 上也不能跑"，避免脚本只在一端可用。
3. **布局用 Kotlin 移植，而不是在 JS 里跑 `layout.js`。** 布局要频繁调文本度量，跨 JNI 往返代价高，且渲染阶段不应再持有 JS 上下文。`layout.js` 仅 638 行，移植成本低；它的常数（如单行文本高度 `ceil(size × 1.1934 × 2) / 2`）是按 SF 字体校准的，Android 需要按所选字体重新校准（见决策 D3）。
4. **安全不变量逐条移植到 Kotlin**，并移植对应回归测试：规范化包路径（拒绝穿越、绝对路径、符号链接、反斜杠、大小写冲突）、ZIP 预检与条目/体积上限、事务安装、`networkDomains` 匹配、私网/本地主机拒绝、请求/响应预算、`$storage` 命名空间与 256 KiB 上限、malformed manifest fail closed。Android 17 新增的 `ACCESS_LOCAL_NETWORK` 权限**不申请**。AI 凭据放 Android Keystore（Jetpack Security Crypto 已弃用 [已核实]，用 Keystore + Tink/DataStore）。
5. **存储模型比 iOS 简单。** Android widget 与 App 同进程族，没有 app group / widget extension 的跨进程共享容器问题；`compareAndSet` 仍要保留进程内 + 文件锁语义，因为 Worker 与前台可能并发。
6. **minSdk 暂定 35（Android 15），基线只依赖 API 31。** 点击遮罩定位、响应式尺寸、系统圆角、原生 Switch 都是 API 31 引入，基线代码不使用 32–35 才有的接口，保留降回 31 的余地（决策 D2）。

仓库布局建议：

```text
Android/
  app/        Compose UI、编辑器 WebView、设置、Gallery、AI
  runtime/    QuickJS-NG JNI、host、bridges、policy、package/archive
  render/     layout、BitmapBackend、RemoteComposeBackend（试验）
  widget/     AppWidgetProvider、Worker、配置 Activity、Tile、Live Update
  shared-js/  构建时从 Web/preview-engine 生成，不手改
```

---

## 5. 功能映射与降级

级别：**P0** 内测版必须有；**P1** 1.0 必须有；**P2** 1.0 之后；**N/A** Android 无对应，明确降级。

### 5.1 标签与属性

| 项 | Android 实现 | 级别 |
| --- | --- | --- |
| `vstack hstack zstack spacer` + `frame padding alignment spacing` | Kotlin 布局移植 | P0 |
| `text` + `font fontWeight fontDesign color` | `StaticLayout` + 字体映射；内置 4 个自带字体（Monofonto 等）随包分发需确认授权 | P0 |
| `rect roundedrect capsule ellipse circle line divider` + `trim stroke` | Canvas Path | P0 |
| `background`（颜色/渐变）`corner clip opacity rotation shadow` | Canvas（`saveLayer`、`setShadowLayer`、Shader） | P0 |
| `image`（包内、URL、`systemName`）`icon label` | 包内与 URL 解码并按目标尺寸降采样；SF Symbol → Lucide 映射 | P0 |
| `progress ring badge chip stat` | 组合绘制，照搬 Web 渲染器 | P0 |
| `gauge` | 移植 `MineGaugeView` 的绘制（Web 已有同款实现） | P1 |
| `chart`（10 种类型） | 移植 Web 渲染器的图表几何，改用 Canvas | P1 |
| `vgrid hgrid` | 布局移植（Web 侧也是近似） | P1 |
| `date`（`time date relative offset timer`） | `timer` → `Chronometer` 叠加层；`time` → `TextClock`；`relative/offset` 渲染时刻的静态文本 + 分钟级重渲染（近似） | P1 |
| `link` / `linkurl` | 透明点击层 + `PendingIntent`（URL 或深链） | P0 |
| `button`（`action=reload`、`onClick`、`actionID`） | 广播 → Worker 执行动作函数 → 重渲染 | P1 |
| `toggle`（`on stateKey actionID`） | 画出开关外观 + 点击层；状态写包内 `$storage` | P1 |
| `gif` | 首帧静态（与 Mac / Reduce Motion 行为一致） | P1 |
| `rotation3d` | `Camera`/矩阵静态变换 | P2 |
| `animation`（clock / swing） | 位图后端保持静止姿态（与 Mac 一致）；Remote Compose 后端可做 | P2 / 试验 |
| `backgroundMaterial` | **N/A。** 无 widget 内毛玻璃；使用 `background` 作为不透明回退（契约里已定义的 Reduce Transparency 回退） | N/A |
| `widgetAccentable` / `accentedRenderingMode` | **N/A。** `widget-rendering-mode` 恒为 `fullColor` | N/A |

### 5.2 运行时 API

| API | Android 实现 | 级别 |
| --- | --- | --- |
| `$render $element $component $import $getenv $json $runtime console` | 内核自带 | P0 |
| `$storage`（含 compareAndSet）、`$file` | 应用私有目录，同语义同上限 | P0 |
| `fetch`、`$http.getResponse` | OkHttp + 同一套域名/私网/预算策略 | P0 |
| `$xml.parse` | 移植有界解析器（禁 DTD/外部实体） | P0 |
| `$dataSource.request` + Data Source Plugin 1.0 | 纯声明式 HTTPS，直接移植 | P1 |
| `$device`、`$system` | `Build`、`BatteryManager`、`Configuration` 等；`$system.platform` 返回 `android` | P0 |
| `$location` | 前台授权 + 缓存；用 Fused Location（只上 Google Play，可依赖 Play 服务）。**首版不申请后台定位**（Play 审核成本高 [二手]） | P1 |
| `$calendar`（读/写） | Calendar Provider + 用户选择日历范围 | P1 |
| `$health` | Health Connect；需 Play Health apps 声明表 [已核实]；国内无 | P2 |
| `$photos` | Photo Picker，把所选缩略图复制到私有目录 | P1 |
| `$notifications` | `NotificationManager` + 本地定时 | P1 |
| `$alarms` | 系统闹钟 intent；精确闹钟权限受限 | P2 |
| `$documents` | SAF 授权目录内的 JSON/CSV | P2 |
| `$contacts.selected` | 系统联系人选择器（无需通讯录权限） | P2 |
| `$services`（GitHub） | Custom Tabs OAuth + Keystore | P1 |
| `$music` | 需通知监听特殊授权才能读 MediaSession，成本高 | P2 |
| `$maps` | `geocode/reverseGeocode` 用 `Geocoder`；`search/snapshot` 需要第三方地图 SDK | P2 |
| `$weather.forecast` | **无系统 API。** Open-Meteo 免费层限非商用 [二手]，Google Weather 收费 [已核实]。需要产品决策（D5） | P2 |
| `$reminders` | **N/A。** 无系统提醒事项；`isAvailable()` 返回 false | N/A |
| `$home` | **N/A。** 无 HomeKit | N/A |
| `$icloud` | **N/A。** `status()` 报告不可用。跨端同步是独立课题（D6） | N/A |
| `$dynamic_island` | 接受调用但不产生输出 | N/A |
| AI 生成、Skills 1.0、Gallery 1.0 | HTTP + 提示构建 + 事务安装，逻辑移植 | P1 |

不可用能力的统一规则（已定）：**在 Android 上明确提示不支持，不做替代实现。**

- 包**仍可安装**。安装和打开包详情时，列出该包声明或用到的、Android 不支持的权限、API 和 surface。
- 运行时：对应 `isAvailable()` 返回 false，调用以既有错误类别拒绝，错误文本说明"Android 不支持"。现有契约已要求脚本对可选设备能力做特性检测，所以这不是破坏性变更。
- 脚本未处理该错误时，widget 显示可见的"此功能在 Android 上不支持"卡片，而不是空白。
- 不支持的标签属性（`backgroundMaterial`、`animation` 等）按 5.1 的回退渲染，并在编辑器诊断里给出提示，不打断渲染。
- Gallery 条目需要增加平台可用性标注（见 5.4）。

### 5.3 Surface 与 widget 家族

| iOS | Android 方案 | 级别 |
| --- | --- | --- |
| `systemSmall / Medium / Large` | 三个 provider，默认 2×2 / 4×2 / 4×4，可缩放；`$getenv("widget-size")` 返回同样的 `small/medium/large` | P0 |
| `systemExtraLarge(Portrait)` | 平板/折叠屏上的大尺寸 provider | P2 |
| `accessory*` | **N/A**（Wear OS 另议） | N/A |
| widget 参数（`widget-param`）与脚本选择 | 配置 Activity（`reconfigurable`），长按可重新配置 | P0 |
| Timeline `dailyTimes` | 复用 `timeline.js` 规划；预渲染各 slot，到点用 AlarmManager 推送 | P1 |
| 动作（`actions`）+ Siri/Shortcuts | 动态 App Shortcuts | P2 |
| Control Widget（`controls`） | 预声明固定数量的 `TileService` 槽位，用户把槽位绑定到某个 control | P2 |
| Live Activity | Live Update：把 `title / detail / progress / total / endsAt` 这套 demo 状态映射到 `ProgressStyle`；自定义 JSX 布局不支持 | P2 |
| WidgetKit push（`pushUpdates`） | FCM（仅有 GMS 的设备） | P2 |

### 5.4 需要的契约变更（全部为增量）

- `$system.platform` 增加取值 `android`；文档写明各 API 的平台可用性。
- `scriptWidgetAPI.js` 元数据增加 `platforms` 字段，生成的 API 文档和 Studio 补全据此标注；改完需 `npm run docs` 和 `npm run release`。
- Gallery `index.json` 条目增加可选的平台声明（Gallery 1.0 对未知键 fail closed，需要走 schema 版本评估）。
- 可选的新环境值，用于让脚本适配非方形尺寸，例如 `widget-width` / `widget-height`（单位 dp/pt）。iOS 同步提供，保持两端一致。
- "规范树 JSON"从测试产物升级为内部跨端接口，仍不对脚本公开。
- Web Studio 的渲染 profile（`render/profiles.js`）增加 Android profile，让用户在浏览器里预览 Android 尺寸与字体。

`widget.json` 的 `formatVersion`、`runtimeVersion`、权限枚举**不变**；`.swt` 在两端互通。

---

## 6. 开发规划

### 阶段 0：技术验证（2–3 周）

四个 go/no-go 问题，每个都产出可运行的最小原型和实测数字：

| # | 问题 | 通过标准 |
| --- | --- | --- |
| S1 | QuickJS-NG 能否跑 `kernel.js` 并通过 parity 语料？ | 100 棵树中与 JSC 参考逐字节一致的比例 ≥ 95%，差异全部归因于 `Intl`/时区/错误文本并有处理方案；`while(true){}` 在 5 秒被中断；冷启动到出树的耗时和峰值内存有实测值 |
| S2 | JSX 转译放在哪、多快？ | 在中端机上，QuickJS 内跑 Babel 或 sucrase 转译一个典型包的耗时可接受（目标 < 2 秒）；否则改为 App 前台 WebView 转译 |
| S3 | 位图 + 遮罩方案在真机上是否成立？ | 在 Pixel、三星、小米、OPPO/vivo 各一台上：一个含 text/shape/渐变/图片/两个点击区的 widget 尺寸正确、文字清晰、点击命中、深浅色切换后 1 次刷新内更正；位图占用在预算的 50% 以内 |
| S4 | 后台刷新在厂商定制系统（三星 One UI、小米/OPPO 国际版）上的真实表现？ | 记录默认设置与"自启动 + 无限制"两种设置下，15 分钟周期刷新和点击广播 24 小时内的成功率，作为产品文案和引导设计的依据 |

**设备现状（2026-11-12）：手上只有一台 Pixel 6。** 因此阶段 0 调整为：

- S1、S2 和 S3 的 Pixel 部分在 Pixel 6 上实测；其他系统版本用官方模拟器补（模拟器只能验证 AOSP 行为）。
- S3 的三星/小米/OPPO/vivo 部分和整个 S4 **无法在阶段 0 完成**，结论保持 [待验证]，不阻塞进入阶段 1。
- 补齐途径：内测阶段招募持国产机型的测试用户并收集带机型的诊断日志；或租用云真机；或购入一台小米/OPPO 二手机。OEM 相关的引导页和文案在拿到数据前不定稿。
- Pixel 6 当前运行的系统版本需要先确认，它决定真机能覆盖 15/16/17 中的哪一个。

并行的非阻塞探测：Remote Compose 发射一个最小文档到 Android 16/17 设备，确认 OEM launcher 是否渲染。

S1 或 S3 不通过时的退路：S1 → 换 Javet；S3 → 点击遮罩在目标机型上不可靠时，把点击区降级为整卡单一点击。

### 阶段 1：运行时核心（4–6 周）

- `runtime` 模块：QuickJS-NG 构建（arm64-v8a、x86_64，16 KB 对齐）、JNI、host 实现、每次执行独立 context、时间/内存/栈限制。
- Package 2.0：manifest 校验（对照 `widget.schema.json`）、legacy `main.jsx`/`meta.json` 读取、`.swt` 导入导出、ZIP 加固、事务安装、`__Build` 缓存与编译指纹。
- P0 桥：`$storage $file fetch $http $xml $device $system $getenv`。
- `Intl` 补齐：用 `android.icu` 实现 `toLocaleString / toLocaleDateString / toLocaleTimeString / Intl.DateTimeFormat / Intl.NumberFormat` 中内置模板实际用到的子集；先统计 146 个内置包和 24 个 Gallery 包的用法再定范围。
- 测试：parity 语料、Swift 侧安全/校验用例的 Kotlin 对应版本、CI（Gradle 单测 + 模拟器）。

完成标准：命令行/测试里给定包和环境，输出与 iOS 一致的规范树；所有安全回归用例通过。

### 阶段 2：渲染器与 widget 宿主（6–8 周）

- `render`：布局移植、P0 标签与属性、图标映射、图片降采样、位图预算管理器。
- 校准：复用 `test/render/cases.json` 与 iOS 快照，建立 Android 快照比对（容差按字体差异单独设定）。
- `widget`：三个 provider、配置 Activity、WorkManager 刷新、尺寸变化与深浅色重渲染、点击遮罩、错误卡片（资源超限、权限缺失要可见，不能空白）。
- 然后补 P1 标签：gauge、chart、grid、date、button、toggle、gif。

完成标准：内置模板与 Gallery 中不依赖 N/A 能力的包，在 Pixel 上逐个目检通过并留存截图；位图预算在所有尺寸下不超限。

### 阶段 3：App（4–6 周，可与阶段 2 后半并行）

- Compose UI：脚本库、包详情、权限与系统访问设置、诊断日志导出。
- 编辑器：WebView 加载现有 `StudioEditor.bundle`（CodeMirror 6）。CM6 在 Android 上的 IME 组合输入仍在持续修 bug [已核实]，需锁定较新版本并用 GBoard、三星键盘、中文输入法回归。
- App 内预览：直接用 `render` 模块画到 View 上，所见即所得。
- 导入：`.swt` 文件关联、分享 intent、SAF；Gallery 安装（校验路径、字节数、SHA-256）。

### 阶段 4：数据与交互（4–6 周）

- P1 API：`$location $calendar $photos $notifications $services $dataSource`。
- Timeline `dailyTimes`、动作执行管线、button/toggle 回写。
- AI 生成、Skills、Data Source Plugin 导入导出。

### 阶段 5：加固与发布（约 4 周）

- OEM 矩阵回归、后台存活引导页、性能基线（JS 执行、渲染耗时、Worker 内存）。
- 可访问性：位图 widget 对 TalkBack 不友好，至少为整卡和每个点击区设置 `contentDescription`。
- 商店素材、隐私政策、数据安全表单、封闭测试 → 公开测试 → 正式发布。

### 版本路线图（1.0 → 1.2）

iOS 版功能面很宽，一次做完会把首版拖得很久，所以按三个版本交付。划分原则：1.0 保证"同一个包能跑、能看、能点"；1.1 补系统集成；1.2 补动效和跨端。

| 版本 | 主题 | 内容 | 粗估 |
| --- | --- | --- | --- |
| **1.0** | 核心对齐 | 阶段 1–5 的全部内容：QuickJS 运行时与 Package 2.0；全部 29 个标签（位图后端，动画/GIF 为静态）；`$storage $file fetch $http $xml $dataSource $device $system $location $calendar $photos $notifications $services`；small/medium/large 三种尺寸；button/toggle 交互；`dailyTimes` 时间表；编辑器、Gallery、AI 生成、Skills、Data Source Plugin；`.swt` 与 iOS 互通。其余能力显示"Android 不支持" | 第 6–8 个月 |
| **1.1** | 系统集成 | `$health`（Health Connect，含 Play 健康类声明）；`$weather`（先定数据源）；`$alarms $documents $contacts $music`；Control Widget → 快捷设置磁贴；`actions` → App Shortcuts；Live Activity → Live Update（进度类模板）；`pushUpdates` → FCM；平板/折叠屏大尺寸；锁屏 widget 页适配 | 1.0 后 2–3 个月 |
| **1.2** | 动效与跨端 | Remote Compose 后端转正（前提：它进入 beta 且手机入口 API 公开）：时钟/摆动动画、GIF 播放、不唤醒应用的 toggle、自走的相对时间文本、准点切换的时间表；替代 `$icloud` 的跨端 JSON 同步（单独设计）；`$maps`；`rotation3d`；Wear OS 可行性评估 | 1.1 后约 3 个月 |

说明：

- 1.2 的 Remote Compose 部分取决于 Google 的发布进度，不受我们控制。若届时仍是 alpha，这部分顺延，1.2 只交付同步和 `$maps`。
- `$reminders`、`$home`、`backgroundMaterial`、accessory 家族、Dynamic Island 在三个版本内都不做，始终提示不支持。
- 每个版本发布前，把新增 API 从"不支持"清单移除，并更新平台可用性文档和 Gallery 标注。

### 粗略时间线

| 里程碑 | 累计时间 | 内容 |
| --- | --- | --- |
| M0 验证结论 | 第 3 周 | 四个 go/no-go 有数据 |
| M1 运行时可用 | 第 2 个月 | parity 通过 |
| M2 内测版 | 第 3.5–4 个月 | P0 全部 + 编辑器 + 导入，Play 内部测试 |
| M3 公测版 | 第 5–6 个月 | P1 全部 |
| M4 1.0 | 第 6–8 个月 | 加固完成、正式上架 |

这是单人全职 + AI 辅助的估计，误差主要来自 OEM 适配和渲染校准，可能上浮 30–50%。

---

## 7. 落地规划

**分发**
- **只上 Google Play**（D9）：内部测试 → 封闭测试 → 公开测试 → 正式。
- 国内应用商店和其他渠道暂不考虑。将来若要做，前置条件是软著、备案，以及把依赖 Google Play 服务的部分（Fused 定位、FCM）换成可替代实现。

**版本与品牌**
- Android 版本号独立于 iOS，但**运行时 API 版本共用**（当前 1.6）。Android 首版声明它实现的 API 版本和不可用 API 清单。
- 全部免费、无内购，与 iOS 一致；Android 代码后续开源（D7）。不需要接入 Play Billing。`applicationId` 为 `com.everettjf.scriptwidget`（D11）。

**跨端一致性的长期机制**
- parity 语料在 CI 里三端跑：JavaScriptCore（参考）、V8（Web）、QuickJS（Android）。任何运行时契约改动必须三端同时更新，否则 CI 失败。
- `release-readiness.sh` 增加可选的 Android 关卡（Gradle 单测 + parity），不阻塞没有 Android SDK 的贡献者。
- 文档：`docs/` 增加 Android 平台差异页；每个 API 文档标注平台可用性。

**用户侧落地**
- 首次添加 widget 时按机型给出后台存活引导（自启动、电池优化），并在 widget 上显示"上次更新时间"类的可诊断信息，避免"不更新"被当成 bug。
- 从 iOS 迁移：`.swt` 互通；Web Studio 导出的包可直接在 Android 安装。不做 `$storage` 数据迁移。

---

## 8. 风险

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| QuickJS 无 `Intl` | 日期/数字本地化两端输出不同 | 宿主侧补子集；parity 语料固定 locale；文档列出差异 |
| JSC 与 QuickJS 的其他差异（`Error.stack` 格式、`Date.parse` 宽松度、尾调用、微任务排空时机）[部分待验证] | 少数脚本行为不同 | 内核已隔离大部分；新增针对性用例；错误按类别比对而非文本 |
| 低端机上 5 秒预算更紧（解释器） | 重计算脚本超时 | 实测后决定是否按设备档位给出告警；字节码缓存减少启动耗时 |
| Android 17 位图硬限制 | 升级 target 后崩溃 | 从第一天起做预算管理和零位图降级布局 |
| 厂商定制系统杀后台（Play 渠道仍覆盖三星、小米/OPPO 国际版） | widget 不更新、点击无响应 | S4 实测；引导页；可见的更新时间；手动刷新入口 |
| 字体与图标不同（无 SF、无 SF Symbols） | 视觉与 iOS 不完全一致 | 目标定为"布局语义一致"而非像素一致；默认用随应用分发的字体（D3）；Web Studio 提供 Android 预览 |
| Remote Compose 长期停在 alpha 或 API 大改 | 动画、host 本地交互、准点 timeline 无法提升 | 位图后端独立可交付；Remote Compose 只在开关后试验 |
| CM6 在 Android IME 下的输入问题 | 编辑体验差，尤其中文 | 真机回归；必要时提供"外部编辑 + 导入"和 Web Studio 作为主编辑路径 |
| Google 平台级"AI 生成 widget" | AI 卖点被稀释 | 强调可编程、跨端、可分享的包生态 |
| 政策：Health Connect、后台定位审核 | 上架延期 | 这两项放 P2 或首版不做 |

---

## 9. 决策记录

### 已定（2026-11-12，项目负责人确认）

| # | 决策 | 结论 |
| --- | --- | --- |
| D1 | JS 引擎 | **QuickJS-NG**（更轻量）。S1 不通过时再评估 Javet |
| D3 | 字体 | **随应用分发一款开源字体作为默认**，用户可在设置里改用系统字体或其他内置字体。候选 Inter（OFL）。Inter 不含中日韩字形，中文由内置的思源黑体承担（D10）；文本度量按默认字体校准，切换字体后允许有布局差异 |
| D4 | 尺寸与边缘 | **跟随 Android 系统**：按 launcher 给的实际尺寸布局，圆角用系统 widget 圆角（`system_app_widget_background_radius`），内边距遵循系统约定。不做"格内居中 iOS 比例内容区" |
| D7 | 商业模式 | **全部免费，无内购**（与 iOS 一致），Android 代码后续同样开源。不接入 Play Billing |
| — | Android 无对应的能力 | **明确提示不支持**，不做替代实现（规则见 5.2） |

| D2 | minSdk | **35**（Android 15/16/17，最新版本倒推两个）。基线代码不使用 API 32–35 才有的接口（基线只需要 API 31），公测前若覆盖面不够可降回 31，只需补测试。存量设备占比尚无核实数据 |
| D5 | `$weather` 数据源 | 放到 1.1；1.0 提示不支持。具体数据源在 1.1 开工前定 |
| D6 | 跨端同步（替代 `$icloud`） | 放到 1.2，单独设计 |
| D8 | Remote Compose 后端 | 1.0 前只做探测；1.2 视其发布状态转正 |
| D9 | 分发渠道 | **只上 Google Play**；国内应用商店和其他渠道暂不考虑。因此可以依赖 Google Play 服务（Fused 定位、FCM），国产 ROM 适配不作为 1.0 的发布门槛 |
| D10 | 中文字体 | **直接内置思源黑体（Noto Sans SC，OFL）**，优先用可变字体，一份覆盖全部字重。各机型中文排版一致，安装包增加十几兆量级（[待验证]，需实测）。日文、韩文和繁体专有字形仍回退系统字体。随应用分发时附带 OFL 许可文本 |
| D11 | `applicationId` | **`com.everettjf.scriptwidget`**，与 iOS/macOS 的 Bundle ID 相同。上架 Google Play 后不可更改 |

**中文字体调研。** 有开源且可商用的中文字体，问题只在体积（以下体积为印象值，[待验证]，需实测）：

| 字体 | 许可 | 说明 |
| --- | --- | --- |
| 思源黑体 / Noto Sans SC | OFL | 最稳妥。Pixel 等原生系统的中文字体本来就是它；简体子集单字重约十兆量级，有可变字体版本可一份覆盖全部字重 |
| 霞鹜文楷 | OFL | 楷体风格，适合做可选字体，不适合当默认 |
| 阿里巴巴普惠体、HarmonyOS Sans、MiSans | 各自的免费授权，非 OFL | 需逐条读授权条款后才能随应用分发，暂不建议 |

结论：采用"直接内置"（D10）。曾考虑过不内置（中文回退系统字体，各厂商排版不一致）和设置里可选下载（安装包不变大，但多一个下载与校验流程），均未采用。

---

## 10. 主要来源

- QuickJS-NG：<https://github.com/quickjs-ng/quickjs/releases>，<https://quickjs-ng.github.io/quickjs/diff>
- Javet：<https://github.com/caoccao/Javet/releases>
- JavaScriptSandbox：<https://developer.android.com/develop/ui/views/layout/webapps/jsengine>
- Glance：<https://developer.android.com/jetpack/androidx/releases/glance>，<https://developer.android.com/develop/ui/compose/glance/build-ui>
- RemoteViews：<https://developer.android.com/reference/android/widget/RemoteViews>
- Remote Compose：<https://developer.android.com/jetpack/androidx/releases/compose-remote>，<https://developer.android.com/develop/ui/compose/system/remote-compose>
- Android 17 行为变更（位图上限）：<https://developer.android.com/about/versions/17/behavior-changes-17>
- Widget 尺寸：<https://developer.android.com/develop/ui/views/appwidgets/layouts>
- 后台与配额：<https://developer.android.com/topic/performance/power/power-details>，<https://developer.android.com/develop/ui/views/appwidgets/advanced>
- Live Updates：<https://developer.android.com/develop/ui/views/notifications/live-update>
- 16 KB 页：<https://developer.android.com/guide/practices/page-sizes>
- Play 政策（解释执行代码）：<https://support.google.com/googleplay/android-developer/answer/16559646>
- Target API：<https://support.google.com/googleplay/android-developer/answer/11926878>
- 开发者验证：<https://developer.android.com/developer-verification>
- Health Connect 上架：<https://developer.android.com/health-and-fitness/health-connect/publish>
- Swift 6.3 / Skip：<https://www.swift.org/blog/swift-6.3-released/>，<https://skip.dev/docs/modes/>
- CodeMirror view changelog：<https://cdn.jsdelivr.net/npm/@codemirror/view@6.43.0/CHANGELOG.md>
- 仓库内：[运行时 API](../scriptwidget-runtime-api.md)、[浏览器预览引擎](../browser-preview-engine.md)、[Package 2.0](../package-format.md)、[Timeline](../timeline-api.md)、[现代 WidgetKit 能力](../widgetkit-modern-features.md)
