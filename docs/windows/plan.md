# ScriptWidget Windows 版：开发计划

状态：2026-11-17 已按本计划做出预览版（阶段 0 到 3 的代码都在 `Windows/`），现状见 [README.md](README.md)，测试记录见 [testing.md](testing.md)，剩余事项见 [TODO.md](TODO.md)。阶段 0 的三项验证里，QuickJS 和 Win2D 两项已通过；置底窗口一项因为开发机整晚处于锁屏状态，还没有在可见的桌面上验证过。和计划不同的地方：数据目录在打包安装时用包自己的本地目录；AddressSanitizer 只覆盖引擎封装层的测试。下面的正文是 2026-11-16 写的计划原文。依据是 [Windows 可行性调研](feasibility.md)。Linux 版已搁置，本计划不以和 Linux 共用代码为目标。

标注约定：**[已实测]** 2026-11-16 在开发机（Windows 11 26200，x64）上跑过；**[已核实]** 读过官方页面、项目源码或本仓库文件；**[二手]** 第三方文章或搜索摘要；**[待验证]** 没有可靠来源，或还没有在 Windows 上试过。

## 1. 目标和已定事项

同一个 Package 2.0 小组件（同一份 `main.jsx` 和 `widget.json`）在 Windows 11 的桌面上原生运行，并且能装到同一个人的 iPhone 或 Android 手机上。

2026-11-16 定下的事项：

| 事项 | 决定 |
| --- | --- |
| 形态 | 我们自己画的桌面小组件。官方小组件面板只接受 Adaptive Card，不能自绘 [已核实]，最多是后期的附加出口 |
| 绘制 | 原生绘制，不用 WebView 画小组件 |
| 语言 | C#（.NET 10）。QuickJS 留在一个小的 C 动态库里 |
| 绘制库 | Win2D（微软官方，底下是 Direct2D 和 DirectWrite）。退路是 Vortice.Windows |
| 分发 | 只走微软商店，MSIX。不提供商店外安装包 |
| 价格 | 免费 |
| 开发和真机验证 | 在这台 Windows 11 x64 机器上 |
| 管理窗口 | 原生界面（WinUI 3），只有代码编辑器是网页；预览用我们自己的渲染器。不加载整个 Web Studio |
| 发到手机 | 做，需要改 iOS 和 Android 应用（阶段 4） |
| 推进方式 | `windows` 分支，草稿 PR，不等 Android 的封闭测试 |

## 2. 已经验证的

| 事项 | 结果 |
| --- | --- |
| 开发环境 | Visual Studio 2026（MSVC 14.51、clang-cl、ARM64 库、AddressSanitizer、CMake、Ninja）、Windows SDK 26100、`makeappx`、WebView2 运行时、.NET SDK 10.0.401、Node 26 都已装好 [已实测] |
| QuickJS 用 MSVC 编译 | `Android/core/src/main/cpp/quickjs` 不改一行，用 `/std:c11 /experimental:c11atomics` 编过 [已实测] |
| 运行时限制 | 内存上限、超时中断、栈上限分别抛出 `out of memory`、`interrupted`、`Maximum call stack size exceeded` [已实测] |
| C# 调 QuickJS | 编成 1.3 MB 的 DLL，C# 用函数指针提供回调，20 万次回调约 105 毫秒 [已实测] |
| 原生 AOT | 调 QuickJS 的空程序：exe 1.0 MB，工作集 16.6 MB；不做 AOT 时工作集 31.1 MB [已实测] |
| 共用 JS 的构建 | **在 Windows 上是坏的。** `build-browser.mjs` 和 `build-shared-js.mjs` 用 `\n` 匹配 `import` 行，而仓库在 Windows 上检出成 CRLF（`core.autocrlf=true`，没有 `.gitattributes`）。用 LF 副本可以正常跑 [已实测] |

## 3. 技术选型

| 部分 | 选择 | 说明 |
| --- | --- | --- |
| 宿主 | C#，.NET 10，目标是原生 AOT | 常驻托盘。AOT 和 Win2D 是否兼容 [待验证]；不行就发布为自带运行时的普通 .NET 程序 |
| 脚本引擎 | QuickJS-NG，仓库里已有的源码 | 和 Android 同一份。封装成 `swcore.dll`，接口照 `scriptwidget_jni.c` 去掉 JNI |
| 绘制和文字 | Win2D（`Microsoft.Graphics.Win2D`），离屏画到位图 | 依赖 Windows App SDK，商店安装时自动带上 [待验证：不用 WinUI 界面的进程里实际加载多少] |
| 字体 | 随包带 Inter 和六个展示字体，和 Android 相同；中文和表情交给 DirectWrite 的系统回退 | 不带 Android 那份 17 MB 的 Noto Sans SC |
| 图片解码 | Win2D 的 `CanvasBitmap`（底下是 WIC） | PNG、JPEG、GIF、WebP |
| `Intl` | 直接调系统的 `icu.dll` | Windows 10 1903 起自带 [已核实]。不用 .NET 自己的格式化，避免和 Android 的输出不一致 |
| 网络 | `HttpClient`，在连接回调里检查解析后的地址 | 私有、本地、回环地址在连接前拒绝 |
| 压缩包、JSON、哈希 | .NET 自带的 `System.IO.Compression`、`System.Text.Json`、`SHA256` | 不引第三方库 |
| 窗口和托盘 | Win32 分层窗口，用 CsWin32 生成的接口 | 每个小组件一个窗口 |
| 管理窗口 | 单独的按需进程：WinUI 3 界面，代码编辑器用 WebView2 加载现有的 `Editor/editorfe` | 和 Mac 应用同样的分工。预览用我们自己的渲染器，和桌面上完全一致 |
| 打包 | MSIX，`StartupTask` 负责开机启动 | |

不采用的：

- **用 WebView2 画小组件。** 实测可行（启动 0.2 秒，每次渲染约 0.15 秒），但每次刷新要拉起约 330 MB 的浏览器进程，动画做不了，也不符合"原生小组件"的定位。
- **C++。** 选它的主要理由是可移植，Linux 搁置后不成立。要移植的参考实现是 Kotlin，译成 C# 更近；宿主处理不可信输入，放在内存安全的语言里更稳。
- **SharpDX。** 2019 年已停止维护。

## 4. 参考实现：照 Android 移植

`Android/core` 是一套完整的、有测试的 Kotlin 实现，Windows 版逐文件对应移植，不重新设计。

| Android（Kotlin） | 行数 | Windows（C#，`Windows/src/ScriptWidget.Core/`） |
| --- | --- | --- |
| `cpp/scriptwidget_jni.c` | 336 | `Windows/native/swcore.c`：同样的引擎生命周期、内存和栈上限、中断、宿主回调，导出普通 C 函数 |
| `js/QuickJs.kt` | 63 | `Js/QuickJs.cs` |
| `runtime/` 的 `PackageCompiler`、`ScriptExecutor`、`TimelinePlanner`、`XmlBridge`、`SharedScripts` | 约 560 | `Runtime/` |
| `runtime/IntlBridge.kt` | 276 | `Runtime/IntlBridge.cs`，改为调 `icu.dll` |
| `pkg/`（校验、压缩包预检、事务式安装、安全文件操作） | 约 1,350 | `Packages/`，另加 Windows 的路径规则 |
| `api/` 的 `FetchModule`、`StorageModule`、`DeviceInfo`、`RuntimePolicy` | 约 400 | `Api/` |
| `plugin/`（Data Source Plugin 1.0） | 约 1,090 | `Plugins/` |
| `render/` 的 `Css`、`DomPainter`、`SvgPainter`、`TextEngine`、`FontRegistry`、`WidgetRenderer` | 约 1,270 | `Render/`，`Canvas` 换成 Win2D 的绘图会话 |
| `system/WeatherModule.kt` | 192 | `Api/WeatherModule.cs`，同一个数据来源 |
| `WidgetRuntime.kt` | 203 | `WidgetRuntime.cs` |

共用的 JavaScript 原样使用：

| 资产 | 位置 | 用法 |
| --- | --- | --- |
| 执行内核、清单校验、包准备、时间线、JSX 编译 | `Web/preview-engine/src/` | 打包后在 QuickJS 里运行 |
| 布局和渲染器 | `Web/preview-engine/src/render/` | 在 QuickJS 里对着一个记录用的文档运行，输出元素树交给 C# 画 |
| 渲染入口 | `Android/core/src/main/js/render/entry.mjs` | 移到两个平台共用的位置，Android 专有的选项由调用方传入 |
| 宿主脚本和各 API 的 JS 一侧 | `Android/core/src/main/js/android-host.js`、`android-apis*.js` | 宿主脚本和 `datasource` 共用；其余按 Windows 支持的范围挑选 |
| 打包脚本 | `Android/scripts/build-shared-js.mjs` | 抽出共用部分，新增 `Windows/scripts/build-shared-js.mjs`。Windows 的产物在构建时生成，不提交 |
| 164 棵一致性树 | `Web/preview-engine/test/parity/native-trees.json` | 运行时的验收门槛 |
| Android 的测试 | `Android/core/src/test`、`androidTest` | 同名测试逐个移植成 xUnit |

改动共用的 JS 和构建脚本会影响 Android，改完要跑 Android 的 JVM 和设备测试。

## 5. 目录和工程

```
Windows/
  ScriptWidget.sln
  native/                  swcore：CMake，QuickJS + swcore.c，出 x64 和 ARM64 的 DLL
  scripts/                 build-shared-js.mjs、build.ps1、package.ps1
  src/
    ScriptWidget.Core/     类库：引擎、运行时、包、API、插件、渲染。不依赖窗口
    ScriptWidget.Cli/      swcli.exe：validate、run、render、timeline。CI 出图和调试用
    ScriptWidget.App/      ScriptWidget.exe：托盘、桌面窗口、调度。常驻
    ScriptWidget.Studio/   ScriptWidgetStudio.exe：管理窗口。按需启动
  tests/
    ScriptWidget.Core.Tests/   xUnit
  package/                 MSIX 清单、图标、商店素材
docs/windows/
  plan.md、testing.md、TODO.md
.github/workflows/windows.yml
```

`ScriptWidget.Core` 不引用任何窗口或界面的东西，这样命令行、常驻程序和管理窗口用同一套运行时，CI 里不需要桌面也能跑全部测试和出图。

## 6. 架构

```
ScriptWidget.exe（常驻，托盘）
┌──────────────────────────────────────────────────────────┐
│ 调度：时间线、定时刷新、网络恢复、唤醒                     │
│ 执行：QuickJS（内核 + 包代码），每次执行一个新的运行时     │
│        内存上限、栈上限、超时中断                          │
│        网络、存储、文件只能经宿主的 API，按清单权限放行    │
│ 布局：另一个长期存活的 QuickJS，只跑我们自己的渲染器       │
│ 绘制：Win2D 离屏位图                                      │
│ 小组件窗口：贴位图、收点击                                │
│ 包存储、设置、托盘菜单                                    │
└───────────────────┬──────────────────────────────────────┘
                    │ 按需启动，命名管道通信
        ScriptWidgetStudio.exe（管理窗口）
```

### 6.1 执行和隔离

- 包代码和渲染器分在两个 QuickJS 运行时里，和 Android 相同：渲染器那一侧的输入是元素树（数据），不是包代码。
- **第一版包代码在常驻进程内执行。** 这和 iOS、Android 的做法一致：QuickJS 不暴露任何系统接口，限制靠内存上限、栈上限和中断。原计划的独立执行进程推到阶段 5，届时连同 AppContainer 和作业对象一起做；`ScriptExecutor` 的接口按"将来可以搬到另一个进程"来设计，不让调用方依赖同进程。
- 代价是 QuickJS 自身如果有内存破坏漏洞，会落在常驻进程里。用 AddressSanitizer 构建的 `swcore` 在 CI 里跑全部测试，作为第一版的补偿。

### 6.2 渲染

一次渲染分两步：布局在 QuickJS 里跑共用的渲染器，得到一棵带样式的元素树；`DomPainter` 用 Win2D 把它画到位图上。文字的度量和绘制都走同一个 `TextEngine`（`CanvasTextLayout`），量到多宽就画多宽。

渲染输出除了位图，还有点击区域和"活的部分"的位置（日期、GIF、时钟动画），和 Android 的 `RenderOutput` 相同。第一版用到点击区域和日期；GIF 和动画的位置先保留在输出里，阶段 5 再播放。

### 6.3 桌面窗口

采用 Rainmeter 的做法：顶层窗口保持在所有普通窗口之下，而不是挂到桌面的内部窗口上。后者（Lively 的做法）在 Windows 11 24H2 上被系统改动弄坏过一次 [已核实，读过两者的源码]。两种做法都依赖系统未公开的行为。

- 窗口样式：分层（逐像素透明）、不进任务栏和 Alt-Tab、点击不抢焦点。位图整幅更新到窗口。
- 每个显示器按自己的缩放比例出图；窗口移到另一个显示器或缩放变化时重画。
- 位置按显示器保存；显示器拔掉后小组件回到主显示器，插回去后恢复。
- 编辑模式下可以拖动、对齐网格、换尺寸；平时锁定，点击只触发小组件自己的动作。
- 点击时按坐标查点击区域，得到一个编号，由宿主从自己保存的动作表里查出动作。窗口消息里不带动作内容。
- 全屏应用或游戏在前台时暂停刷新。

要在真机上确认的 [待验证]：按 Win+D 后小组件是否还在；资源管理器重启后是否恢复；睡眠唤醒后定时是否正常；多个虚拟桌面上是否都出现。

### 6.4 管理窗口

单独的进程，关掉就退出，常驻进程不加载界面框架。

- 四个页面：我的小组件、模板库、编辑器、设置。
- 编辑器左边是代码（WebView2 加载 `Editor/editorfe` 的构建产物，和 iOS、Mac 应用用的是同一个），右边是预览。预览由 `ScriptWidget.Core` 渲染，和桌面上是同一段代码。
- 保存后通知常驻进程刷新对应的小组件。
- WebView2 只加载应用自带的页面，桥接接口只对这个来源开放。
- 第一版不做内置的 AI 生成，不保存任何 API 密钥。

### 6.5 平台契约

- `$system.platform()` 返回 `"windows"`。
- 尺寸沿用预览引擎里的 `macos` 配置：small 170×170、medium 329×170、large 329×345、extraLarge 639×345（点），再乘以显示器缩放。没有锁屏尺寸。
- 没有对应物的能力返回 `[unsupported_platform]`。所有差异写进 `docs/platform-support.md` 新增的 Windows 一列。

| API | 第一版 | 说明 |
| --- | --- | --- |
| `$device`、`$system`、`$storage`、`$file`、`fetch`、`$http`、`$xml` | 支持 | 权限、域名声明、私有地址拒绝、预算和其他平台相同 |
| `$dataSource` | 支持 | 逻辑在共用的 JS 里 |
| 时间线、按钮、开关、`<date>` 的自动更新 | 支持 | |
| `$weather` | 支持 | 照搬 Android 的实现和数据来源 |
| `<gif>`、`animation` | 第一帧 | 阶段 5 播放 |
| `$music`、`$notifications`、`$location` | 之后 | 有系统接口，需要包身份和用户授权 [待验证] |
| `$calendar`、`$reminders`、`$health`、`$photos`、`$contacts`、`$home`、`$icloud`、`$alarms`、`$maps`、`$services` | 不支持 | |
| Live Activity、Control Widget、Siri 动作、推送刷新 | 不支持 | |

依赖健康、日历数据的模板在 Windows 的模板库里不显示。

## 7. 安全

脚本、导入的压缩包、网络响应仍然全部视为不可信。每一条都要有测试，其中安全相关的测试从 Android 的同名测试移植，并补上 Windows 特有的用例。

- 包路径规范化，拒绝穿越、绝对路径、符号链接、反斜杠、大小写冲突。Windows 另外拒绝：保留设备名（`CON`、`NUL`、`COM1` 等，含带扩展名的）、结尾的点和空格、文件名里的冒号（备用数据流）、盘符和 UNC 路径、重解析点。
- 压缩包的条目数、单文件大小、展开总大小限制；先预检再解压；唯一的临时目录；事务式安装。
- 网络需要 `network` 权限和匹配的 `networkDomains`；拒绝私有、本地和回环地址，检查的是解析之后实际连接的地址；重定向后重新检查；请求和响应预算。
- `$file` 限制在包内，`$storage` 按包隔离并有上限。
- 清单存在但格式错误时直接失败，不当作旧格式包。
- 清单和包的校验继续用共用的 JS 在 QuickJS 里跑，C# 一侧不另写一套规则。
- 不记录凭据、完整的敏感响应和用户文件内容。

## 8. 阶段

每个阶段对应一个或几个指向 `windows` 分支的 PR；`windows` 分支在阶段 3 结束、能从商店内测安装后合并到 `main`。估算是单人加 AI 辅助的粗估，只用来排顺序。

### 阶段 0：地基和三项验证（约 1 周）

| # | 事项 | 通过标准 |
| --- | --- | --- |
| 0.1 | 加 `.gitattributes`，把 JS、JSON、HTML、CSS 等文本固定为 LF | `node Web/preview-engine/bin/scriptwidget-preview.mjs` 在 Windows 上直接能跑；`npm test` 在 Windows 上通过；Mac 和 Linux 上没有文件内容变化 |
| 0.2 | `Windows/native`：`swcore.dll`，x64 和 ARM64 | 两个架构都编过；x64 用 AddressSanitizer 再编一份 |
| 0.3 | `ScriptWidget.Core` 的 `QuickJs`、共用 JS 的打包、`ScriptExecutor` | **164 棵一致性树逐字节相同**；内存上限、超时、栈上限各有一个测试 |
| 0.4 | Win2D 验证 | 在不带界面的进程里离屏画出圆角渐变、阴影、中文、彩色表情、SVG 路径；量出加载 Win2D 后的工作集；试原生 AOT 发布 |
| 0.5 | 置底窗口验证 | 一个贴静态位图的窗口，在这台机器上过 Win+D、资源管理器重启、睡眠唤醒、缩放变化 |
| 0.6 | `.github/workflows/windows.yml` | PR 上自动跑 0.2、0.3 |

0.3、0.4、0.5 任何一项不通过就停下来重新评估。0.4 不通过时先换 Vortice.Windows 重试一次。

你本人要做的：注册微软商店个人账号并保留应用名；向微软确认政策 10.2.2 对内嵌脚本引擎的适用（我起草问题）。

### 阶段 1：运行时（约 3 周）

按第 4 节的对应表移植 `Packages`、`Runtime`、`Api`、`Plugins`、`Render`，以及 `swcli` 的 `validate`、`run`、`render`、`timeline`。

完成标准：

- 移植过来的 Android 测试全部通过，另加 Windows 路径规则的测试。
- `swcli render` 能渲染全部不依赖系统数据的内置模板，输出和提交在仓库里的基准图做回归对比。
- 10 个有代表性的模板（中文、表情、图表、渐变、SVG 图标各至少一个）和浏览器预览并排对比，差异由你过目接受。

### 阶段 2：桌面（约 2 到 3 周）

小组件窗口、托盘、编辑模式、位置和尺寸保存、时间线调度、按钮和开关、`<date>` 自动更新、多显示器和缩放、单实例、开机启动。

完成标准：在这台机器上，从本地文件夹添加的多个小组件能放在桌面上、按时刷新、响应点击，注销重新登录后恢复原位。空闲时常驻进程的 CPU 为零，工作集记录在 `docs/windows/testing.md`。

### 阶段 3：管理窗口和商店（约 3 到 4 周）

管理窗口的四个页面、和常驻进程的通信、模板库、导入和导出 `.swt`、首次启动引导、中英文界面、MSIX 打包、商店的截图和说明，用商店的小范围发布做内测。

完成标准：一个没有用过 ScriptWidget 的人，从商店安装后三分钟内能把一个模板小组件放到桌面上并改掉它的一处文字。

### 阶段 4：发到手机（约 2 到 3 周）

1. 管理窗口里点"发到手机"，把包打成 `.swt`。
2. 优先由电脑连手机：iOS 应用已有 Web Studio 配对（手机开服务，电脑用六位码连接）[已核实]，Android 有没有 [待验证]。这样 Windows 上不用开监听端口，不会弹防火墙提示。
3. 备选是电脑临时提供一次下载并显示二维码，内容是 `scriptwidget://import?...`，带下载地址、大小和 SHA-256；手机下载、核对后走现有的不可信压缩包导入流程，用户确认后安装。

两个手机应用新增的 `import` 处理是新增契约，要有安全评审和测试，并依赖两个应用商店的审核。在此之前，用户可以导出 `.swt` 自己传到手机。

### 阶段 5：之后

GIF 和动画的播放；独立的执行进程加 AppContainer 和作业对象；`$music`、`$notifications`、`$location`；Gallery；官方小组件面板的提供方；内置 AI。

## 9. 测试和 CI

- **`windows.yml`**（GitHub Actions 的 Windows 机器）：编 `swcore`、打包共用 JS、`dotnet test`、`swcli render` 的截图回归、AddressSanitizer 版的 `swcore` 跑同一套测试。ARM64 至少交叉编译；有没有可用的 ARM64 机器 [待验证]。
- **真机清单**：桌面窗口的各种行为、缩放和多显示器、睡眠唤醒、开机启动、从商店安装和升级。每次记录到 `docs/windows/testing.md`，写明 Windows 版本和机器。ARM64 真机上的表现在有机器之前不声称验证过。
- **共用代码**：改动 `Web/preview-engine`、共用的宿主脚本或打包脚本后，要跑预览引擎自己的测试、Android 的测试和 Windows 的测试。
- Windows 不在 `release-readiness.sh` 的范围内，和 Android 一样单独记录。

## 10. 风险和退路

| 风险 | 怎么发现 | 退路 |
| --- | --- | --- |
| Win2D 不能在不带界面的进程里离屏使用，或带进来的东西太重 | 阶段 0.4 | 换 Vortice.Windows，`Render/` 的接口不变 |
| Win2D 和原生 AOT 不兼容 | 阶段 0.4 | 发布为自带运行时的普通 .NET 程序，常驻内存高一些 |
| 一致性树不能逐字节相同 | 阶段 0.3 | 先查 `Intl` 和时区；确属引擎差异的逐项记录并和 Android 对齐 |
| 置底窗口在某个 Windows 更新后失效 | 阶段 0.5 和每次真机测试 | 两种挂载方式都实现，运行时选择 |
| 文字换行和 Android、浏览器不一致 | 阶段 1 的并排对比 | 在 `TextEngine` 里按共用渲染器的规则自己断行 |
| 商店审核不接受内嵌脚本引擎 | 阶段 0 提问，阶段 3 提交 | 描述里写明应用运行用户编写的小组件脚本；被拒再按意见调整 |
| 微软商店个人账号的身份验证卡住 [二手] | 阶段 0 | 没有不花钱的替代办法，需要你跟进 |

## 11. 需要你做或决定的

1. **注册微软商店个人账号并保留应用名。** 拿到包名和发布者 ID 后发我，MSIX 清单要用。阶段 3 之前需要。
2. **阶段 1 末尾过目并排对比图**，决定保真度是否可以接受。

## 12. 不做的事

- Linux 版。它是单独的 Rust 工程，2026-11-17 起在 `linux` 分支上进行，计划在 [docs/linux/plan.md](../linux/plan.md)。
- Windows 10。
- 商店之外的安装包。
- 第一版里的官方小组件面板、锁屏、内置 AI、Gallery、动画播放。
- 新的 JSX 标签或只有 Windows 才有的能力。
- 在 Windows 版里收费。
