# ScriptWidget Linux 版（Omarchy）：开发计划

状态：计划稿，2026-11-16。尚未写任何 Linux 代码，也没有在 Omarchy 机器上运行过任何东西。

标注约定：**[已核实]** 本次直接读到官方页面或本仓库源码；**[二手]** 来自第三方文章；**[待验证]** 没有可靠来源，或需要在 Omarchy 真机上确认，不能当作事实。

## 1. 目标与定位

**目标**：同一个 Package 2.0 小组件（同一份 `main.jsx` 和 `widget.json`）在 iPhone、iPad、Mac、Android 和 Linux 上都能运行。

**目标用户**：使用 Omarchy 的人。他们在桌面上写小组件、看到效果，再把同一个小组件装到自己的手机上。Linux 版是入口，手机版是落点。

由此得出三条产品原则：

1. **Linux 上不做图形界面的应用。** Omarchy 用户用终端和 Neovim，用自己的 Coding Agent。Linux 版是一个命令行工具、一个后台进程和一个 Omarchy 插件。编辑器、AI 生成、Gallery 界面都不搬过来。
2. **"发到手机"是一等功能，不是附属功能。** 如果桌面上写好的小组件不能在一分钟内出现在手机上，这个版本就没有达到目的。
3. **不和 Omarchy 自己的插件比"谁更能定制桌面"。** QML 插件能做的事比我们多，而且没有沙箱。我们提供的是它们没有的两点：跨到手机，以及可以安全安装别人写的小组件。

## 2. Omarchy 4 的现状

| 事实 | 来源 |
| --- | --- |
| Omarchy 是 Arch Linux 加 Hyprland 加 Quickshell。4.0 于 2026-08-14 发布，文章写作时最新为 4.0.6（2026-10-19） | [二手] [starryhope.com](https://www.starryhope.com/linux/what-is-omarchy/) |
| 4.0 用一个 Quickshell 进程替换了 Waybar、Walker、Mako、SwayOSD、hyprlock、hypridle、swaybg、polkit-gnome | [已核实] [PR 6231](https://github.com/basecamp/omarchy/pull/6231) |
| 外壳的每个部分都是插件。第三方插件是一个 Git 仓库，根目录有 `manifest.json`，入口是 QML 文件 | [已核实] [Develop a Plugin](https://plugins.omarchy.org/develop.html) |
| 插件种类：`bar-widget`、`bar`、`panel`（浮动窗口）、`overlay`（全屏）、`menu`、`service`（无界面的常驻单例） | [已核实] 同上，及 [omarchy-shell.md](https://github.com/omacom/omarchy/blob/quattro/docs/omarchy-shell.md) |
| 安装：`omarchy plugin add <git-url>`，装到 `~/.config/omarchy/plugins/<id>/`；另有 `enable`、`disable`、`update`、`remove`、`validate` | [已核实] 同上 |
| 插件"以用户权限运行，没有沙箱"，和外壳共用一个进程；文档要求不要为插件再启动第二个 Quickshell 进程 | [已核实] 同上 |
| 调色板在主题的 `colors.toml`，QML 里通过 `Commons.Color` 读取（`foreground`、`background`、`accent`、`urgent` 及各表面的角色） | [已核实] omarchy-shell.md |
| IPC：`omarchy-shell shell summon <id> <json>`、`hide`、`toggle`、`call <id> <method> <arg>` | [已核实] 同上 |
| 上架插件目录：公开的 GitHub 仓库，根目录有合法的 `manifest.json`、README 和许可证，通过 GitHub issue 表单提交，自动校验后由维护者批准 | [已核实] [Publish](https://plugins.omarchy.org/publish.html) |
| 插件目录对外部二进制依赖、商业产品、AI 生成代码有没有限制 | **[待验证]** 发布页没有写。提交前要问维护者 |
| 插件能否自己创建壁纸层（background layer）的窗口，也就是真正的"桌面小组件" | **[待验证]** 文档只列了上面六种，没有提 |
| 装软件包：`omarchy pkg add`，AUR 包用 `omarchy pkg aur add` | [已核实] Omarchy 自带的 Skill 文档；该文档部分内容还是 4.0 之前的，命令要在真机上确认 |
| 4.0 第一个月下载超过 30 万次，第一周出现一千多个插件 | [二手] 项目自己公布的数字 |
| 硬件：x86 PC 和 Intel Mac；Apple 芯片的 Omarchy M 还没完成 | [二手] starryhope.com |

三点影响方案的结论：

- **展示端应当是一个 Omarchy 插件，而不是自己开窗口。** 这是 Omarchy 用户安装东西的标准方式，也能自动跟随主题。
- **平铺式桌面上，壁纸层的小组件大部分时间被窗口盖住。** 更合适的形态是一个按快捷键呼出的"小组件面板"（`panel`），加上状态栏上的一个入口（`bar-widget`）。壁纸层小组件作为可选项，等验证了可行性再做。
- **这里已有的同类不是 AGS，而是上千个 QML 插件。** 之前的对比对象要换。

## 3. 仓库里可以直接复用的东西

| 资产 | 位置 | 在 Linux 上的用法 |
| --- | --- | --- |
| 执行内核，通过 `host` 接口注入求值、文件、日志、超时 | `Web/preview-engine/src/kernel.js` | 原样复用，和 Android 一样在 QuickJS 里运行 |
| 布局和渲染（propose/size/place，文本度量走 `measurer` 抽象） | `Web/preview-engine/src/render/` | 原样复用 |
| 在 QuickJS 里跑渲染器、把结果记录成元素树的入口 | `Android/core/src/main/js/render/entry.mjs` | 不含 Android 专有代码，可以共用 |
| QuickJS 宿主（去掉原生入口、补 `Intl` 子集、启动函数） | `Android/core/src/main/js/android-host.js` | 大部分与平台无关，抽成共用文件 |
| QuickJS-NG 源码 | `Android/core/src/main/cpp/quickjs` | 用同一份源码编译，保证两端引擎行为一致 |
| 包校验、清单、压缩包处理 | `Web/preview-engine/src/package/` | JS 版可直接在 QuickJS 里用；路径和压缩包的安全检查在原生侧再做一遍 |
| 164 棵一致性树 | `Web/preview-engine/test/parity/native-trees.json` | 作为 Linux 运行时的验收门槛 |
| 把元素树画成位图的画笔 | `Android/core/.../render/`（`DomPainter.kt`、`SvgPainter.kt`、`Css.kt`、`TextEngine.kt`，约 1,300 行） | 依赖 `android.graphics`，不能复用，需要移植。**这是最大的一块新工作** |
| 给 Coding Agent 用的创作 Skill 和 MCP 服务 | `Web/preview-engine/bin/scriptwidget-mcp.mjs`、`docs/mac-cli.md` 里的 `scriptwidget-creator` | Omarchy 用户自己有 Agent，直接提供这两样，不做内置 AI |
| Mac CLI 的命令设计（`check`、`render`、`pack`、`doctor`，JSON 报告，退出码） | `docs/mac-cli.md` | Linux CLI 用同样的命令和报告格式 |

## 4. 架构

```
~/Widgets/MyWidget/           scriptwidget（一个二进制）              Omarchy 外壳
  widget.json   ──读取──▶   ┌──────────────────────────┐          ┌─────────────────────┐
  main.jsx                   │ 包存储与校验              │          │ 插件                 │
                             │ QuickJS：内核 + 宿主      │  PNG +   │  service：连接后台   │
                             │ QuickJS：共用渲染器       │  点击区  │  panel：小组件面板   │
                             │ 画笔：元素树 → PNG        │ ───────▶ │  bar-widget：入口    │
                             │ 时间线与刷新调度          │ ◀─────── │                     │
                             │ 网络、存储、文件（受限）  │  动作号  └─────────────────────┘
                             └──────────────────────────┘
                                  Unix socket，仅本用户可访问
```

### 4.1 后台进程和命令行

一个二进制 `scriptwidget`，既是命令行也是后台进程（`scriptwidget daemon`，由 systemd 用户服务启动）。

- **语言：Rust。** 理由：它要解析不可信的压缩包、清单和网络响应，内存安全有实际价值；能产出单个静态链接的二进制，便于分发。
- **JS 引擎：QuickJS-NG，用仓库里已有的那份源码编译。** 和 Android 相同的中断回调和内存上限。不在 Quickshell 自带的 QML JS 引擎里运行包代码：那里没有内存上限和中断，语义也和 JavaScriptCore 不一致，而且等于把不可信脚本放进外壳进程。
- **`Intl`：** QuickJS 没有 `Intl`。Android 用设备上的 ICU 补了一个子集。Linux 上用系统的 ICU 或 ICU4X，哪个能通过 Android 那套 `Intl` 测试就用哪个。**[待验证]**
- **画笔：** 把共用渲染器记录下来的元素树画成 PNG，同时输出可点击区域。两个候选：纯 Rust 的 `tiny-skia` 加 `cosmic-text`，或者 Skia。前者体积小、不依赖系统库，后者的文字和绘制更成熟但构建更重。**由阶段 0 的对比结果决定**，判断标准是和浏览器预览截图的差异。原先考虑过系统的 Cairo 加 Pango，因为这套核心也要用于 Windows（见 [Windows 可行性调研](../windows/feasibility.md)），而它们在 Windows 上不是合适的依赖，所以不再作为候选；对比时要同时在 Linux 和 Windows 的字体上测中日韩文字和表情。
- **文本度量和绘制必须是同一套代码。** 布局在画之前就要知道每段文字的宽度，度量和绘制不一致会导致错误的换行和截断。这也是不让 QML 来画的原因。

命令（和 Mac CLI 对齐）：

| 命令 | 作用 |
| --- | --- |
| `scriptwidget new <name>` | 从模板创建一个包 |
| `scriptwidget check <dir>` | 校验清单并编译，不执行脚本 |
| `scriptwidget render <dir> --family medium --output <dir>` | 执行并输出 PNG 和报告。不需要图形会话，可以在 CI 里跑 |
| `scriptwidget dev <dir>` | 监视文件，保存后刷新面板里的小组件 |
| `scriptwidget add <dir 或 .swt>` / `remove` / `list` | 管理已安装的小组件 |
| `scriptwidget pack <dir>` | 导出 `.swt` |
| `scriptwidget send <dir>` | 发到手机，见第 5 节 |
| `scriptwidget doctor` | 环境自检 |

### 4.2 Omarchy 插件

一个很小的 QML 插件，只做显示和转发，不执行任何包代码。

- `service`：连接后台进程的 socket，接收"某个小组件有新图了"的通知。
- `panel`：小组件面板，按快捷键呼出，按网格排列已安装的小组件。每个小组件是一张图，上面盖着后台给出的点击区域。
- `bar-widget`：状态栏上的入口，点击打开面板。后续可以让一个小尺寸的小组件直接显示在状态栏上。
- 点击时只把一个数字发回后台，由后台从自己保存的动作表里查出对应的动作。插件和 socket 上都不传动作内容。这和 Android 列表行点击的规则相同。
- 主题：插件把 `Commons.Color` 的当前配色发给后台，后台据此给脚本提供深色或浅色外观。

插件要能连接 Unix socket 或启动进程，Quickshell 提供这类类型（`Process`、`Socket`）。**[待验证]** 这是凭记忆，本次没有读到 Quickshell 的类型文档；Omarchy 的能力外观（facade）是否对第三方插件开放它们，也要在真机上确认。

### 4.3 平台契约

- `$system.platform()` 返回 `"linux"`。内核现在的默认值是 `"ios"`（`kernel.js` 第 538 行），由宿主传入。
- 支持 small、medium、large、extraLarge 四种尺寸；没有锁屏尺寸。
- 没有对应物的能力返回 `[unsupported_platform]`，和 Android 的做法一致。所有差异写进 `docs/platform-support.md` 的新增一列。

| API | Linux 第一版 | 说明 |
| --- | --- | --- |
| `$device`、`$system`、`$storage`、`$file`、`fetch`、`$http`、`$xml` | 支持 | 权限、域名声明、私有地址拒绝、请求预算和其他平台相同 |
| `$dataSource`（数据源插件） | 支持 | 纯声明式的 HTTPS 映射，逻辑可复用 |
| 时间线、按钮和开关 | 支持 | 后台进程自己调度，没有系统的刷新配额 |
| `$music` | 之后 | 通过 MPRIS（D-Bus）读取正在播放的媒体 |
| `$notifications` | 之后 | 通过桌面通知接口 |
| `$weather`、`$location` | 之后 | 需要先确定数据来源 |
| `$calendar`、`$reminders`、`$health`、`$photos`、`$contacts`、`$home`、`$icloud`、`$alarms`、`$maps`、`$services` | 不支持 | 返回 `[unsupported_platform]` |
| Live Activity、Control Widget、Siri 动作、推送刷新 | 不支持 | |

这意味着依赖健康、日历这类数据的小组件在桌面上只能显示"此平台不支持"。对目标用户来说可以接受：他们在桌面上写和预览，数据在手机上才有。但 `render` 要支持模拟数据（Mac CLI 已有 `--fixtures`），否则这类小组件在桌面上没法调试。

## 5. 发到手机

这是整个计划里决定成败的部分，也是目前最不确定的部分。

现状：

- Android 应用能打开 `.swt` 文件，并注册了 `scriptwidget://` 协议（`AndroidManifest.xml`）。**[已核实]**
- iOS 应用注册了 `scriptwidget://` 协议（`Info.plist`）。它现在能处理哪些地址，本次没有核实；一份旧调研文档说只支持 `reload-all`。**[待验证]**
- iOS 应用有 Web Studio 配对：手机上开启后，同一局域网的电脑用六位配对码连接，推送包里的文本文件（`docs/web-studio.md`，客户端在 `Web/preview-engine/src/cli/deviceSync.js`）。**[已核实]** Android 有没有同样的接口，本次没有核实。**[待验证]**

方案：`scriptwidget send <dir>`

1. 打包成 `.swt`，在局域网上临时提供一次下载，地址里带一次性令牌。
2. 在终端里显示一个二维码，内容是 `scriptwidget://import?...`，带下载地址、文件大小和 SHA-256。
3. 手机相机扫码，打开应用。应用下载文件，核对大小和 SHA-256，然后走**现有的不可信压缩包导入流程**：预检、限额、权限预览、用户确认后才安装。
4. 下载完成或超时后，电脑端关闭这次下载。

需要的应用侧改动：iOS 和 Android 各加一个 `import` 地址处理。这会改动两个已上架应用，属于新增契约，要有安全评审和回归测试：

- 只接受用户主动扫码触发的导入，不能由小组件脚本触发。
- 导入的包和其他来源的包一样不可信，不因为来自"自己的电脑"而放宽任何检查。
- 脚本的网络规则（拒绝私有和本地地址）不变；这里访问局域网的是应用自己的导入功能，不是脚本。iOS 上会触发"本地网络"权限提示。
- 二维码内容不进日志。

备选方案（不需要改应用，但体验差）：`scriptwidget pack` 后用户自己把 `.swt` 传到手机，例如通过 LocalSend 或聊天软件。阶段 0 用它来验证流程是否有人愿意用。

以后可以考虑的：从 Git 仓库地址安装。Omarchy 用户习惯把配置放在 Git 里，但这是一个新的安装来源，要单独做信任设计，不在这份计划里。

## 6. 安全

脚本、导入的压缩包、网络响应仍然全部视为不可信。Linux 上要重新落实的不变量：

- 包路径规范化，拒绝穿越、绝对路径、符号链接、反斜杠、大小写冲突。
- 压缩包的条目数、单文件大小、展开后总大小限制；先预检再解压；用唯一的临时目录；事务式安装。
- 网络需要 `network` 权限和匹配的 `networkDomains`；拒绝私有和本地地址；请求和响应预算。
- `$file` 限制在包内，`$storage` 按包隔离并有上限。
- 清单存在但格式错误时直接失败，不当作旧格式处理。
- 以上每一条都要有对应的测试，从 Android 和 Swift 的测试用例移植。

Linux 特有的：

- socket 放在 `$XDG_RUNTIME_DIR` 下，权限仅限本用户。
- 包代码只在后台进程里运行，不进入外壳进程。Omarchy 插件本身没有沙箱，所以它越小越好，并且不解释任何来自包的内容。
- 执行脚本的子进程用 Landlock 和 seccomp 再加一层系统级限制。**[待验证]** 放在阶段 4，不阻塞第一版；第一版依靠 QuickJS 不暴露任何系统接口这一点。
- 不做 AI 客户端，所以 Linux 版不保存任何 API 密钥。

## 7. 分发

| 内容 | 渠道 |
| --- | --- |
| `scriptwidget` 二进制 | GitHub Releases（x86_64，之后加 aarch64）；AUR 包 `scriptwidget-bin` |
| Omarchy 插件 | 一个单独的公开仓库（根目录要有 `manifest.json`），源码在本仓库 `Linux/omarchy-plugin/`，发布时同步过去 |
| 插件目录上架 | 通过 plugins.omarchy.org 的 issue 表单提交 |

未决的问题：

- 插件依赖一个外部二进制。Omarchy 的清单没有声明系统依赖的字段，文档只要求在 README 里写清楚。所以安装是两步：先装二进制，再 `omarchy plugin add`。插件在后台没运行时要显示清楚的安装提示，而不是空白。
- **提交上架前先问插件目录的维护者**：是否接受依赖外部二进制的插件，是否接受关联商业应用的插件。发布页没有写这两点，不能假设可以。

## 8. 阶段

估算是单人加 AI 辅助的粗估，没有依据可以校准，只用来排顺序。

### 阶段 0：技术验证（1 到 2 周）

回答五个问题，任何一个是"否"就停下来重新评估。

| 问题 | 通过标准 |
| --- | --- |
| 共用内核在 Linux 的 QuickJS 里结果是否一致 | 164 棵一致性树全部逐字节相同 |
| 画笔的保真度够不够 | 选 10 个有代表性的模板，和浏览器预览的截图对比，差异在 Android 当时接受的范围内；中文、表情、图表各至少一个 |
| Omarchy 插件能不能做展示端 | 在 Omarchy 4 真机上：面板能显示后台给的图，保存文件后 1 秒内更新，点击能传回后台 |
| 发到手机的流程走不走得通 | 先用备选方案（`pack` 后手动传），iPhone 和 Android 各成功导入并显示一次 |
| 有没有人要 | 把原型的短视频发到 Omarchy 社区，看反馈。由你判断，我给不出阈值 |

顺带确认：壁纸层窗口是否可行；第三方插件能否使用 socket 或进程；`omarchy pkg aur add` 在 4.0 上是否还是这个命令。

### 阶段 1：命令行（2 到 3 周）

`Linux/` 目录和 Rust 工程；QuickJS 宿主抽成 Android 和 Linux 共用；包存储和校验；`new`、`check`、`render`、`pack`、`doctor`；网络、存储、文件模块和它们的权限检查；安全测试移植；GitHub Actions 上的 Linux 任务。

完成标准：`scriptwidget render` 能在没有图形会话的机器上渲染全部内置模板中不依赖系统数据的那部分，一致性树和安全测试在 CI 里通过。这一阶段结束时，CLI 本身已经可以单独发布。

### 阶段 2：后台进程和插件（2 到 3 周）

`daemon`、socket 协议、时间线调度、按钮和开关；Omarchy 插件的 `service`、`panel`、`bar-widget`；`dev` 的实时刷新；`add`、`remove`、`list`；深浅色跟随主题。

完成标准：在 Omarchy 4 真机上，装好插件后面板里能放多个小组件，按时间线刷新，点击按钮生效，外壳重启和后台重启后都能恢复。

### 阶段 3：发到手机（2 到 3 周）

`send` 和二维码；iOS 和 Android 的 `import` 地址处理，及各自的安全测试；发布包含它的 iOS 和 Android 版本。

完成标准：在 iPhone 和 Android 真机上，从终端里的二维码到主屏幕上出现小组件，全程不离开手机相机和应用。

这一阶段依赖应用商店审核。Android 还要先拿到正式发布权限。

### 阶段 4：发布（1 到 2 周）

AUR 包；插件仓库和上架申请；`docs/linux/README.md`、`testing.md`、`TODO.md`；`docs/platform-support.md` 加 Linux 列；官网和 README 加 Linux；`$music`（MPRIS）；系统级沙箱的评估。

## 9. 测试

- **CI 里能跑的**：一致性树、包和压缩包的安全测试、网络策略测试、`render` 的截图回归。这些不需要图形会话。
- **只能在真机上做的**：插件的显示、刷新、点击、主题切换、外壳重启后的恢复；HiDPI 和分数缩放；多显示器。每次记录到 `docs/linux/testing.md`，写明 Omarchy 版本和机器。
- **改动共用代码时**：`Web/preview-engine` 和 QuickJS 宿主被三端共用，改动后要跑预览引擎自己的测试、Android 的 JVM 和设备测试、Linux 的测试。

## 10. 需要你提供或决定的

1. **一台装了 Omarchy 4 的 x86 机器。** 当前这台 Mac 上验证不了插件，Apple 芯片上的 Omarchy 还没完成。没有它，阶段 0 的第三个问题和阶段 2 都做不了，我也不能声称任何插件行为是验证过的。
2. **是否接受改动两个手机应用来支持扫码导入。** 这是阶段 3 的前提。
3. **优先级。** 仓库当前的优先事项是稳定已有契约和把 Android 送上 Google Play。Android 封闭测试要等 14 天，阶段 0 可以放在这段等待期里；阶段 1 之后的投入建议等阶段 0 的第五个问题有了答案再决定。
4. **插件目录的政策。** 上架前要问维护者，见第 7 节。

## 11. 不做的事

- Linux 上的图形界面应用、编辑器、Gallery 界面、内置 AI。
- Omarchy 3 及更早版本（Waybar）。
- 承诺支持其他发行版和窗口管理器。命令行在任何 Linux 上都能用；展示端第一版只有 Omarchy 插件。因为它是 Quickshell 的 QML，之后做一个独立的 Quickshell 配置给非 Omarchy 用户是可能的，但不在这份计划里。
- 新的 JSX 标签或只有 Linux 才有的能力（例如读取 Hyprland 工作区、使用主题调色板里的具体颜色）。这些是新的契约范围，等第一版有用户之后再提。

## 资料来源

- [Omarchy 4 "Quattro" 的合并请求](https://github.com/basecamp/omarchy/pull/6231)
- [omarchy-shell.md（外壳参考）](https://github.com/omacom/omarchy/blob/quattro/docs/omarchy-shell.md)
- [Develop a Plugin](https://plugins.omarchy.org/develop.html)
- [Publish a Plugin](https://plugins.omarchy.org/publish.html)
- [Omarchy 自带的 Skill 文档](https://raw.githubusercontent.com/basecamp/omarchy/master/default/omarchy-skill/SKILL.md)
- [What is Omarchy（第三方文章）](https://www.starryhope.com/linux/what-is-omarchy/)
- [Quickshell](https://quickshell.org/)
- [Android 版的调研与规划](../android/android-port-research-and-plan.md)
