# ScriptWidget Linux 版：开发计划

状态：**选型已定，等待阶段 0**，分支 `linux`。本文写于 2026-11-17，取代 2026-11-16 的旧稿（旧稿设想命令行加 QML 面板，且当时已搁置）。目前还没有写任何 Linux 代码，也没有在 Omarchy 上运行过任何东西。

标注约定：**[已核实]** 本次读到官方文档、官方仓库源码或本仓库源码；**[待验证]** 来自记忆或推断，要在 Omarchy 虚拟机里确认后才能当作事实。

## 1. 已定的决定

| 决定 | 内容 | 谁定的 |
| --- | --- | --- |
| 语言 | 从零用 Rust 写，尽量用原生语言。不复用 Windows 的 C# 核心 | 你 |
| 小组件的显示 | 用 Omarchy 官方的方式：一个 QML 插件把 Rust 画好的图片显示在桌面层。在 Omarchy 上 QML 就是原生的界面语言，缩放、多显示器、点击、拖动都由外壳处理 | 你（2026-11-17 改，原先定的是 Rust 自己开窗口） |
| 位置 | 小组件贴在桌面层（壁纸之上、所有窗口之下），可拖动摆放；另有一个快捷键把它们临时提到最上层 | 你 |
| 管理窗口 | 完整的图形管理窗口，用 GPUI（Zed 编辑器的 Rust 界面框架）写 | 你 |
| 发到手机 | 第一版只导出 `.swt` 文件；扫码导入放到之后 | 你 |
| 测试机 | 这台 Mac 上的 RiftVM（Omarchy aarch64 虚拟机） | 你 |

下面两项是我定的，理由写在对应章节，你可以否决：

- 绘制库用 Skia（`skia-safe`），不用纯 Rust 的 `tiny-skia`（第 4.3 节）。
- 第一版执行脚本的引擎和后台服务在同一个进程里，和 iPhone、Android、Windows 现状相同；独立的受限进程放到之后（第 6 节）。

没有采用的方向：

- **把 JSX 直接变成 QML 或 GTK 的控件**（AGS 的做法）。排版和文字交给界面框架后，同一个小组件在 Linux 和手机上会不一样，一致性验收也做不了。
- **基于 AGS 做**。Omarchy 用户没有装它；它跑在 GNOME 的 JavaScript 引擎上，和手机端的 QuickJS 行为不一致；它的脚本能访问整个系统，和"可以安全安装别人写的小组件"冲突。AGS 只作为参照。
- **GTK 4 的管理窗口**。作为 GPUI 走不通时的退路保留（第 4.5 节）。

## 2. 调查得到的事实

### 2.1 Omarchy

| 事实 | 来源 |
| --- | --- |
| 最新版是 4.5.0 "Quattro RS"，2026-11-05 发布。仓库已迁到 `omacom/omarchy`，默认分支 `quattro` | [已核实] GitHub 发布页 |
| 4.5 起官方支持 ARM：有 aarch64 ISO，可原生装在 M1、M2、M3 的 Mac 上；M4 及以后还不支持 | [已核实] 4.5 发布说明、仓库里的 `install/omarchy-aarch64-*.packages` |
| 4.5 新增传统的浮动桌面模式（带 Dock） | [已核实] 4.5 发布说明 |
| 外壳是一个 Quickshell 进程（Omarchy 自己的构建，0.3.2），Qt 6.12 | [已核实] 软件源数据库 |
| 插件有六种：`bar-widget`、`bar`、`panel`、`overlay`、`menu`、`service`。没有专门的"桌面小组件"种类 | [已核实] `docs/omarchy-shell.md` |
| 桌面层小组件已经很常见：插件声明一个 `service`，在里面自己创建 `PanelWindow` 并放到 `WlrLayer.Bottom`。目录里有 49 个这样的插件 | [已核实] omaclock、omarchy-vitrine、OmaWidgets 的源码 |
| 插件没有沙箱，和外壳同进程；文档要求插件不要再启动第二个 Quickshell 进程 | [已核实] 同上 |
| 插件安装不执行任何安装脚本，不要 sudo；清单里没有声明系统依赖的字段 | [已核实] 插件开发手册 |
| 本地开发：把文件夹放进 `~/.config/omarchy/plugins/<id>/`，运行 `omarchy-shell shell rescanPlugins` 再 `omarchy plugin enable <id>`；保存文件即热重载 | [已核实] 同上 |
| 插件目录约 6,700 个条目，其中 5,645 个是状态栏小组件 | [已核实] 目录数据，2026-11-17 |
| 上架：公开的 GitHub 仓库，根目录是一个插件，有 README 和许可证；自动安全扫描后由维护者批准。捆绑可执行文件、安装器、systemd 单元不会被拒，但会转人工审核；"下载后直接执行"会被拦 | [已核实] 插件目录的 `SUBMISSION.md`、`SECURITY.md` |
| 插件配一个独立二进制的惯例：先 `omarchy pkg aur add <包>-bin`，再 `omarchy plugin add <仓库>`；二进制没装时插件显示"未安装" | [已核实] ai-usagebar（784 星）的做法 |
| 仓库 47,145 星；官网称第一年 ISO 下载 139 万次。活跃安装数没有公开数字 | [已核实] GitHub API、官网；下载数是项目自己公布的 |
| 对商业关联产品、AI 生成代码有没有限制 | **没查到规定**，提交前要问维护者 |

**已有的同类产品**：[Omalauncher](https://github.com/SimonSchubert/omalauncher-omarchy-plugin)（11 星）。它用自己的 `.owl` 语言写单文件小组件，保存即刷新，有审核过的小组件商店，能扫码发到它的 Android 启动器，有 AUR 包。也就是说"桌面上写、发到手机"这个卖点已经有人在做，但只到 Android，而且是它自己的语言。我们的不同点是：同一个包能跑在 iPhone、iPad、Mac、Android、Windows 上，用的是 JavaScript 和 JSX，包的权限和网络域名要声明。

### 2.2 仓库里现成的东西

| 资产 | 位置 | 在 Linux 上怎么用 |
| --- | --- | --- |
| 执行内核、布局渲染器、包校验器 | `Web/preview-engine/src/` | 原样复用，在 QuickJS 里运行 |
| 打包这些共用 JavaScript 的脚本 | `Scripts/lib/shared-js.mjs` | 已经支持非 Windows 平台，加一个 Linux 的输出目录 |
| QuickJS-NG 0.18.0 源码 | `Android/core/src/main/cpp/quickjs` | 用同一份源码编译，三端引擎行为一致 |
| QuickJS 的 C 绑定 | `Windows/native/swcore.c`（382 行） | 引擎部分是可移植的 C。接口设计（创建、求值、字节码、截止时间、内存上限、宿主回调）照搬到 Rust 的 FFI 层 |
| 画笔 | `Android/core/.../render/`（Kotlin）和 `Windows/src/ScriptWidget.Core/Render/`（C#，约 2,700 行） | 不能复用，要移植成 Rust。有两份实现可以对照 |
| 运行时其余部分（编译、执行、时间线、包存储、压缩包、`fetch`、存储、天气、数据源插件） | `Windows/src/ScriptWidget.Core/`（约 8,400 行） | 作为 Rust 移植的参照。Windows 版是照着 Android 逐文件移植的 |
| 测试 | `Windows/tests/`（约 239 个）、`Android/core` 的测试 | 逐个移植成 Rust 测试 |
| 164 棵一致性树 | `Web/preview-engine/test/parity/native-trees.json` | Linux 运行时的验收门槛：每棵树逐字节相同 |
| CodeMirror 编辑器 | `Editor/editorfe/` | 管理窗口的编辑器区域复用它 |
| API 和组件的参考数据 | `Editor/editorfe/src/scriptWidgetAPI.js` | 管理窗口的参考页由它生成，和 Windows 版一样 |

Windows 版已经踩过、Linux 上要留意的两个坑：

- `Intl` 靠 ICU 补。发行版的 ICU 版本不同，输出可能有细微差别，会影响"逐字节一致"。
- QuickJS 的本地时间在夏令时切换前后算错，Windows 版改为向 ICU 询问那个日期的偏移。Linux 上要先确认有没有同样的问题。**[待验证]**

### 2.3 RiftVM

| 事实 | 来源 |
| --- | --- |
| 已安装 0.6.10；这台 Mac 会分到 6 核、16 GB 内存、64 GB 稀疏磁盘；镜像下载约 4.4 GB | [已核实] RiftVM 源码 |
| 镜像是 Omarchy 4.0.6（aarch64），不是最新的 4.5.0 | [已核实] `sources.env` |
| 命令行只能查询（`list`、`inspect`、`validate`、`doctor`）。创建、启动、停止都只能在窗口里做，没有别的无界面方式 | [已核实] |
| 网络只有 NAT，客户机地址在 192.168.64.0/24，Mac 可以直接连过去 | [已核实] 网络模式；地址互通是 [待验证] |
| 装了 openssh 但默认不开；用 Omarchy 自带的 `omarchy-setup-security-sshd --key=…` 开启 | [已核实] |
| 共享文件夹用 virtiofs 挂在 `/mnt/mac/<名字>`，没有 `noexec` | [已核实] |
| 自带 gcc、clang、git、base-devel、grim、Qt 6、Quickshell、`omarchy plugin`。没有 Rust、cmake、Node | [已核实] 镜像的包清单 |
| 图形只有 OpenGL ES 3.0；Vulkan 是软件渲染。Omarchy 自己的外壳能正常运行 | [已核实] RiftVM 的验证记录 |
| 关掉 RiftVM 窗口，虚拟机就关机；每次开机要在锁屏输入密码 | [已核实] 前者；后者 [待验证] |
| 150 秒无操作出屏保，300 秒锁屏，会挡住截图；`omarchy-toggle-idle stay-awake` 可以关掉 | [已核实] |

## 3. 产品形态

| 部分 | 程序 | 语言 | 作用 |
| --- | --- | --- | --- |
| 后台服务 | `scriptwidget-host` | Rust | 一直在后台运行。按计划执行脚本，把每个小组件画成图片，保存位置和尺寸，处理点击对应的动作。自己不开窗口 |
| Omarchy 插件 | 一个 QML 插件 | QML | 把后台服务画好的图片显示在桌面层，转发点击和拖动；状态栏上有一个入口。不执行任何包代码，不解释任何来自包的内容 |
| 管理窗口 | `scriptwidget-studio` | Rust（GPUI） | 需要时才打开。我的小组件、模板、组件和 API 参考、编辑器加实时预览、设置。关掉后释放内存，小组件继续运行 |
| 命令行 | `scriptwidget` | Rust | 新建、检查、渲染、打包、添加到桌面、实时预览。不需要图形会话的命令可以在 CI 里跑 |

第一版只有 Omarchy 上能把小组件显示在桌面上。后台服务和显示是分开的，以后要支持其他桌面，只需要再加一个显示端（例如一个直接用 layer-shell 协议的 Rust 程序），不用改后台服务。命令行和管理窗口不依赖 Omarchy。

## 4. 架构

```
Linux/
  crates/
    sw-quickjs     QuickJS-NG 的 FFI 和安全封装
    sw-core        包、编译、执行、时间线、API、数据源插件
    sw-render      画笔：元素树 → 位图和点击区域
    sw-host        后台服务（调度、位置、动作、给显示端供图）
    sw-cli         命令行
    sw-studio      管理窗口（GPUI）
  omarchy-plugin/  QML 插件的源码：桌面层显示和状态栏入口（发布时同步到单独的公开仓库）
  packaging/       AUR 的 PKGBUILD、systemd 用户单元、桌面文件
```

### 4.1 引擎（`sw-quickjs`）

- 用 `cc` 在构建时编译仓库里那份 QuickJS-NG 源码，不用系统的 `quickjs-ng` 包，也不用第三方的 Rust 绑定，保证三端是同一份引擎。
- 每次执行一个新的上下文：64 MB 内存上限、栈上限、5 秒截止时间，和其他平台相同。
- 包代码只在"执行"上下文里跑；布局渲染器在另一个上下文里跑，只看得到元素树。
- 引擎绑定的测试在 CI 里用 AddressSanitizer 再跑一遍，和 Windows 版一样。

### 4.2 运行时（`sw-core`）

按 Windows 版的文件逐个移植：包路径规则、压缩包预检和事务式安装、清单校验（走共用的 JS 校验器）、Babel 编译、执行器、时间线、`$storage`、`$file`、`fetch`、`$http`、`$xml`、`$weather`、`$dataSource`。

- **`Intl`**：链接系统的 ICU（Arch 的 `icu` 在 `core` 里，一定存在），通过一小段 C 垫片调用，垫片用头文件解决符号带版本号后缀的问题。输出要和 164 棵一致性树逐字节相同；如果系统 ICU 的版本差异造成不一致，改为随程序携带固定版本的 ICU 数据。**由阶段 0 决定。**
- **网络**：自己解析主机名，拒绝私有、回环、链路本地地址后，只连接检查过的那个地址；重定向手动跟随，每一跳都重新检查；跨源重定向不带脚本设置的 `Authorization` 和 `Cookie`。和 Windows 版相同。
- **数据目录**：`$XDG_DATA_HOME/scriptwidget`（`Packages`、`Storage`、`Plugins`、`widgets.json`、`settings.json`），缓存在 `$XDG_CACHE_HOME/scriptwidget`。

### 4.3 画笔（`sw-render`）

把共用渲染器给出的元素树画成带透明度的位图，同时输出点击区域。文字的度量和绘制必须是同一套代码，否则换行和截断会错。

**选 Skia（`skia-safe`）。** 理由：

- Android 的画笔就是画在 Skia 上的，Windows 的画笔也是照着 Android 的 `Canvas` 形状写的。用 Skia 可以近乎逐行移植，保真度风险最小。
- 画笔用到的透视变换、模糊和阴影、锥形渐变、SVG 亮度蒙版，Skia 都直接支持。纯 Rust 的 `tiny-skia` 没有透视变换和滤镜，要自己补。
- 文字用 Skia 的段落排版（自带断行、中日韩和表情的字体回退），不用自己写断行。
- 代价：Skia 是 C++ 库，Rust 通过绑定调用；二进制会增大十几 MB；aarch64 上要确认有预编译包，否则要自己编译（很慢）。**[待验证]**

如果阶段 0 发现 Skia 在 aarch64 上构建或打包走不通，退回纯 Rust 方案（`tiny-skia` 加 `cosmic-text`，缺的效果自己实现）。

字体：随程序携带 Inter 和六种展示字体，和 Android、Windows 相同；中日韩文字和表情用系统字体（经 fontconfig 查找）。

### 4.4 后台服务（`sw-host`）和显示端

后台服务不开窗口。它把每个小组件画成 PNG，放在 `$XDG_RUNTIME_DIR/scriptwidget/` 下，并告诉显示端"哪个小组件有新图、放在哪、多大、哪些区域可以点"。

- **和显示端通信**：插件用 Quickshell 的 `Process` 运行 `scriptwidget watch`，这条命令连上后台服务，把事件一行一个 JSON 地打印出来；点击和拖动结束时插件运行 `scriptwidget tap <小组件> <编号>`、`scriptwidget move <小组件> <x> <y>`。`Process` 是外壳自己和很多插件都在用的方式。Quickshell 也有 `Socket` 类型，但外壳和我读过的插件都没用它，所以不依赖它。
- **显示**：插件声明 `service`（`keepLoaded: true`）和 `bar-widget`。`service` 里为每个小组件创建一个 `PanelWindow`，放在 `WlrLayer.Bottom`，里面是一个 `Image`。图片更新时在地址后面加版本号来绕过 Qt 的图片缓存，这是外壳自己的做法。
- **缩放**：插件把每个显示器的缩放比例告诉后台服务，后台服务按那个比例画图，QML 按逻辑尺寸显示。
- **提到最上层**：把这些窗口的层从 `Bottom` 改成 `Overlay`，再按一次改回去。由状态栏入口、`scriptwidget peek` 或用户绑定的快捷键触发。Quickshell 文档只写了"命名空间在窗口连接后不能改"，层能不能在运行中改要确认；不能的话，在 `Overlay` 层另建一组窗口。**[待验证]**
- **摆放模式**：平时小组件只响应按钮、开关、链接的点击，其余位置点击穿透到桌面。进入摆放模式后可以拖动，靠近屏幕边缘吸附；右键菜单可以改尺寸、编辑、移除。
- **点击**：插件只发回一个编号，后台服务从自己保存的动作表里查出动作。链接只允许 `http`、`https`、`mailto`，其他协议拒绝。
- **刷新**：默认每 15 分钟，时间线切换点，从睡眠恢复后，时钟或主题改变后，以及手动。会话锁定时暂停。睡眠和锁定通过 logind 的 D-Bus 信号得知。
- **深浅色**：插件从 `Commons.Color` 判断当前主题的明暗，告诉后台服务。
- **外壳重启或插件热重载**：窗口会消失再重建，小组件闪一下。位置、尺寸、内容都在后台服务里，不会丢。
- **用户换了第三方状态栏**：状态栏入口会失去和 `service` 的联系，但桌面上的小组件不受影响；这时用命令行或管理窗口操作。
- **开机启动**：一个 systemd 用户单元，随图形会话启动。插件发现后台服务没运行时，显示安装或启动的提示，不显示空白。
- **socket**：`$XDG_RUNTIME_DIR/scriptwidget/host.sock`，权限仅限本用户，并核对对端的用户 ID。请求只包含包名、小组件编号和命令，不传任何会被当作代码执行的内容。

### 4.5 管理窗口（`sw-studio`）

**用 GPUI 加 gpui-component。**

- GPUI 是 Zed 编辑器的界面框架，纯 Rust，Apache-2.0 许可。**[待验证]** 许可是凭记忆，开工前核对。
- gpui-component 是它上面的一套控件，Apache-2.0，带一个代码编辑器（Tree-sitter 语法高亮，诊断、补全、悬停提示）。项目自己说还在早期，接口会经常变。[已核实] 项目 README
- 这样管理窗口从界面到编辑器全部是 Rust，不需要 WebKit，也不需要 GTK。实时预览直接调用 `sw-render`，和桌面上的小组件是同一个画笔。

页面和 Windows 版对应：我的小组件、模板（打开后先看预览和代码，再"使用此模板"）、组件、API 参考、编辑器、设置。界面语言跟随系统，英文和简体中文。补全和参考页的数据来自 `Editor/editorfe/src/scriptWidgetAPI.js`，构建时转成 Rust 能读的数据。

要在阶段 0 确认的风险：

- **图形接口**。GPUI 在 Linux 上的渲染从 2026 年 2 月起改用 wgpu（[提交 46758](https://git.secluded.site/zed/commit/af8ea0d6c26192c45f44f473c0d4a7d6f72ed018)）。RiftVM 只有 OpenGL ES 3.0，Vulkan 是软件渲染。管理窗口在这台虚拟机里能不能跑、流不流畅，要实测。跑不动不代表真机不行，但意味着我没法在这里测它。
- **版本**。crates.io 上的 GPUI 停在 2025 年 10 月的版本，比 Zed 主线旧很多；新的渲染在 Git 主线上。要固定依赖 Zed 仓库的某个提交。Zed 团队表示 GPUI 只优先做编辑器自己需要的功能。[已核实] 第三方文章，未对照 Zed 仓库
- **中文输入**。Wayland 下的输入法支持要实测。**[待验证]**
- **编辑器的补全**。gpui-component 的补全是按语言服务器的方式设计的，我们要把 `scriptWidgetAPI.js` 的数据接进去，接口是否够用要试。**[待验证]**
- 编辑器的行为会和 Mac、Windows 上的 CodeMirror 不完全一样（快捷键、补全的细节）。

**退路**：如果 GPUI 在阶段 0 不通过，改用 GTK 4 加 libadwaita，编辑器区域用 WebKitGTK 放现有的 CodeMirror。

### 4.6 命令行（`sw-cli`）

和 Mac、Windows 的命令行对齐，输出 JSON 报告，退出码固定。

| 命令 | 作用 | 需要后台服务在运行 |
| --- | --- | --- |
| `scriptwidget new <名字>` | 从模板创建一个包 | 否 |
| `scriptwidget check <目录>` | 校验清单并编译，不执行 | 否 |
| `scriptwidget run <目录>` | 执行，输出元素树、日志、错误 | 否 |
| `scriptwidget render <目录> --family medium --output <png>` | 执行并画成图片 | 否 |
| `scriptwidget timeline <目录>` | 输出时间线 | 否 |
| `scriptwidget pack <目录>` | 导出 `.swt` | 否 |
| `scriptwidget install <.swt 或目录>`、`list`、`templates` | 管理已安装的包 | 否 |
| `scriptwidget add <包> [--family]`、`remove`、`widgets`、`refresh` | 管理桌面上的小组件 | 是 |
| `scriptwidget dev <目录>` | 监视文件，保存后刷新桌面上的小组件 | 是 |
| `scriptwidget peek`、`arrange` | 提到最上层、进入摆放模式 | 是 |
| `scriptwidget watch`、`tap`、`move`、`screen`、`theme`、`menu` | 给显示端用，见 4.8 | 是 |
| `scriptwidget doctor` | 环境自检 | 否 |

### 4.7 Omarchy 插件

```
omarchy-plugin/
  manifest.json      schemaVersion 1，id、name、version、author、description、license、
                     kinds: ["service", "bar-widget"]，keepLoaded: true
  Service.qml        运行 watch，维护小组件列表，为每个小组件建一个窗口
  WidgetWindow.qml   一个 PanelWindow：图片、点击区、摆放模式下的拖动和右键菜单
  BarWidget.qml      状态栏入口
  README.md、LICENSE
```

种类 `service` 加 `bar-widget`。`service` 负责桌面层的显示（见 4.4）。`bar-widget` 是状态栏上的入口：点击打开管理窗口；菜单里有"提到最上层"和"摆放模式"。

插件越小越好。它和外壳在同一个进程里，没有沙箱，所以它只显示图片、转发编号和坐标，不读包的内容，不拼接命令行字符串（`Process` 的命令是参数列表，不经过 shell）。

本地开发：把 `Linux/omarchy-plugin/` 链接到 `~/.config/omarchy/plugins/<id>/`，保存即热重载。

### 4.8 显示协议

后台服务和显示端之间只有下面这些消息。显示端拿不到包的任何内容，只有图片路径、几何信息和编号。

`scriptwidget watch` 的输出，一行一个 JSON：

| 事件 | 字段 | 含义 |
| --- | --- | --- |
| `hello` | `protocol`（整数，第一版是 1）、`dark`、`arrange`、`peek` | 连接建立后的第一行 |
| `widget` | `id`、`screen`、`x`、`y`、`width`、`height`（逻辑像素）、`image`（PNG 的绝对路径）、`version`（整数）、`regions`（`[{n, x, y, width, height}]`）、`frames`（可选，见下） | 新增或更新一个小组件。`version` 每次换图加一 |
| `remove` | `id` | 移除一个小组件 |
| `mode` | `arrange`、`peek` | 摆放模式或"提到最上层"的开关变了 |
| `bye` | `reason` | 后台服务要退出 |

显示端发回的命令，都是参数列表，不经过 shell：

| 命令 | 含义 |
| --- | --- |
| `scriptwidget tap <id> <n>` | 用户点了编号为 `n` 的区域 |
| `scriptwidget move <id> <screen> <x> <y>` | 拖动结束后的新位置 |
| `scriptwidget screen <name> <scale> <width> <height>` | 显示器的名字、缩放和逻辑尺寸；启动时和变化时各报一次 |
| `scriptwidget theme <dark 或 light>` | 当前主题的明暗 |
| `scriptwidget menu <id> <resize-small 等固定的词>` | 右键菜单里选了一项。可选的词是写死的一个列表 |

规则：

- `id` 是后台服务生成的随机标识，`n` 是整数。后台服务对两者都做校验，不认识的直接拒绝。
- 图片放在 `$XDG_RUNTIME_DIR/scriptwidget/frames/` 下，目录权限 0700。新图先写临时文件再改名，显示端不会读到写了一半的文件。旧图在显示端换图之后删除。
- 协议版本不匹配时，显示端显示"请更新 ScriptWidget"，不尝试解析。
- `watch` 进程退出时，显示端每隔几秒重连，期间保留最后一张图。

**GIF**：由后台服务用 Rust 解码，不交给 QML 解析（GIF 来自包，不可信；外壳进程不应该解析它）。上限：每个小组件最多 60 帧，解码后的总像素有上限，超出的只显示第一帧。后台服务把每一帧按完整排版画成图片，在 `frames` 里给出 `[{image, ms}]`，显示端按时间循环换图。窗口被遮住、锁屏或"提到最上层"关闭且有全屏窗口时暂停。

### 4.9 平台契约

- `$system.platform()` 返回 `"linux"`。
- 尺寸：`small` 170×170、`medium` 329×170、`large` 329×345、`extraLarge` 639×345 点，乘以显示缩放。和 Mac、Windows 相同，没有锁屏尺寸。
- 渲染模式固定 `fullColor`；`backgroundMaterial` 用不透明的 `background` 回退；时间线在每个切换点重新执行脚本。和 Windows 相同。
- `<gif>` 会动（见 4.8）；`animation` 属性的过渡动画第一版不做，显示最终状态。
- `<date>` 的计时样式每秒重画，时钟样式每分钟重画。

| API | Linux 第一版 |
| --- | --- |
| `$device`、`$system`、`$storage`、`$file`、`fetch`、`$http`、`$xml` | 支持，权限、域名声明、私有地址拒绝、预算和其他平台相同 |
| `$dataSource` | 支持 |
| `$weather` | 支持，和 Android、Windows 一样用 MET Norway |
| `$music`（MPRIS）、`$notifications` | 之后 |
| `$calendar`、`$reminders`、`$health`、`$photos`、`$contacts`、`$documents`、`$home`、`$icloud`、`$alarms`、`$maps`、`$services`、`$location` | 不支持。`isAvailable()` 返回 `false`，调用以 `[unsupported_platform]` 拒绝 |
| Live Activity、Control Widget、Siri 动作、推送刷新 | 不支持 |

用到最后两行 API 的模板不出现在模板列表里。所有差异写进 `docs/linux/README.md` 和 `docs/platform-support.md` 的新增一列。

## 5. 发到手机

第一版：管理窗口和 `scriptwidget pack` 导出 `.swt`，用户自己传到手机打开。iOS 和 Android 应用现在就能打开 `.swt`，不需要改应用。

之后：扫码导入。需要给 iOS 和 Android 各加一个导入入口，属于新增契约，要单独做安全评审和回归测试，并等两个应用过审。设计见旧稿，不在第一版范围内。

## 6. 安全

脚本、导入的压缩包、网络响应仍然全部视为不可信。Linux 上要重新落实并带测试的：

- **包路径**：规范化后拒绝穿越、绝对路径、符号链接、硬链接、反斜杠、大小写冲突。打开文件用 `openat2` 的 `RESOLVE_BENEATH` 和 `O_NOFOLLOW`，读取前检查链接数。
- **压缩包**：条目数、单文件大小、展开后总大小限制；先预检再解压；唯一的临时目录；事务式安装。
- **网络**：见 4.2。
- **`$file`** 限制在包内，**`$storage`** 按包隔离并有上限。
- 清单存在但格式错误时直接失败，不当作旧格式处理。
- **socket**：仅本用户可访问，核对对端用户 ID。
- **显示端**：插件只收到图片路径、位置、尺寸和点击区域的编号，见 4.8。
- **引擎隔离**：第一版包代码在后台服务的进程里运行，QuickJS 不暴露任何系统接口，内存、栈、时间都有上限，和其他平台现状相同。之后把执行放进单独的子进程，用 Landlock 和 seccomp 限制。
- 不做 AI 客户端的话不保存任何密钥；如果之后把 AI 生成搬过来，密钥放 Secret Service（系统钥匙串），不写进配置文件。第一版的管理窗口**不含 AI 生成**。

每条安全规则都要有一个测试；安全修复要有修复前会失败的回归测试。

## 7. 分发

| 内容 | 渠道 |
| --- | --- |
| 三个程序 | GitHub Releases，标签 `linux-v<版本>`，x86_64 和 aarch64 各一个压缩包，附 SHA-256 |
| Arch 和 Omarchy 用户 | AUR 包 `scriptwidget-bin`（装程序、systemd 用户单元、桌面文件、`.swt` 的文件关联） |
| Omarchy 插件 | 一个单独的公开仓库，根目录是插件；通过插件目录的表单提交 |

安装是两步，和 ai-usagebar 的惯例相同：`omarchy pkg aur add scriptwidget-bin`，然后 `omarchy plugin add <插件仓库> --enable`。两样都要装：没有插件，小组件显示不到桌面上；没有程序，插件只显示安装提示。

按仓库的规则，预览版的 release 不标 Latest。

## 8. 阶段

不给时间估算：没有可以校准的依据。每个阶段有通过标准，没通过就不进下一个。

### 阶段 0：验证（在 RiftVM 里）

验证用的代码放在 `Linux/spikes/`，每个问题一个小工程，通过后删掉或并入正式代码。按下面的顺序做，前一项不通过不做后一项：

1. 连上虚拟机，装 Rust、cmake、Node；记录 Omarchy、Quickshell、Qt、ICU 的版本。
2. `spikes/quickjs`：编译仓库里的 QuickJS-NG，跑共用内核，对比 164 棵一致性树。
3. `spikes/skia`：用 `skia-safe` 画文字和 10 个模板。
4. `spikes/plugin`：一个本地 QML 插件加一个假的 `watch`（只打印写死的事件），验证显示、换图、点击、拖动、换层、GIF 换帧。
5. `spikes/gpui`：一个带编辑器的 GPUI 窗口。
6. 把结果写进 `docs/linux/testing.md`，每项写明通过、不通过或没法测，并附截图。


| 要回答的问题 | 通过标准 |
| --- | --- |
| 我能不能从 Mac 的命令行驱动虚拟机 | 通过 SSH 同步代码、编译、运行图形程序、用 `grim` 截图传回，全程不需要你操作 |
| 引擎结果是否一致 | 164 棵一致性树在 aarch64 上逐字节相同（含 `Intl` 和本地时间） |
| Skia 能不能用 | `skia-safe` 在 aarch64 的 Arch 上能构建并画出文字；画 10 个有代表性的模板，和 Windows 版 `swcli` 画的参考图对比，中文、表情、图表各至少一个 |
| QML 显示端是否可行 | 一个本地插件把一张图显示在 Omarchy 的桌面层，位置正确；文件更新后 1 秒内换图；点击和拖动能通过 `Process` 传回；`peek` 能提到最上层再放回；外壳重启后恢复 |
| GPUI 能不能用 | 一个 GPUI 窗口在虚拟机里能打开，里面的 gpui-component 编辑器能显示一段 JSX、高亮、弹出我们给的补全、输入中文。不通过就改用退路（4.5） |
| Omarchy 版本 | 虚拟机里的 4.0.6 能不能升到 4.5；不能的话记录下来，以 4.0.6 为测试基线 |

任何一项不通过，先停下来告诉你，再决定换方案还是调整范围。

### 阶段 1：运行时和命令行

`sw-quickjs`、`sw-core`、`sw-render`、`sw-cli`。移植 Windows 版的测试。GitHub Actions 加 Linux 任务（x86_64 和 aarch64）。

通过标准：`scriptwidget render` 在没有图形会话的机器上画出所有不依赖系统数据的内置模板；一致性树、包和压缩包的安全测试、网络策略测试在 CI 的两种架构上通过。

### 阶段 2：后台服务和显示端

`sw-host`、需要它的那些命令，以及 Omarchy 插件的桌面层显示和状态栏入口。包括 GIF 动画和每秒重画的计时。

通过标准（在 RiftVM 的 Omarchy 上）：桌面上放多个小组件，按时间线刷新，按钮和开关生效，能拖动摆放，`peek` 可用，外壳重启、后台服务重启、虚拟机重启后都能恢复，锁屏时暂停。有一个不看屏幕就能跑的自检，像 Windows 版的 `desktop-check`。

### 阶段 3：管理窗口

`sw-studio`。

通过标准：从模板添加一个小组件到桌面、编辑并看到实时预览、导出 `.swt`、导入 `.swt`，每一步都截图记录；中英文界面各检查一遍。

### 阶段 4：打包、发布预览版

插件的公开仓库；AUR 包；`docs/linux/README.md`、`testing.md`、`TODO.md`；`docs/platform-support.md` 加 Linux 列；仓库 README 加 Linux。发布 `linux-v0.1.0` 预览版。

通过标准：在一台干净的 Omarchy 虚拟机上，按 README 的两步安装后能用；卸载后不留文件。

### 之后

扫码发到手机；`$music`；受限的执行子进程；`animation` 过渡动画；提交插件目录；其他桌面的显示端（直接用 layer-shell 协议的 Rust 程序覆盖 Sway、KDE、niri 等，GNOME 扩展加 `.deb` 包覆盖默认的 Ubuntu 和 Fedora）。

## 9. 测试

- **CI 里跑的**：一致性树、安全测试、网络策略测试、`render` 的截图回归。后台服务和命令行之间的协议在 CI 里测；显示端只能在 Omarchy 里测。**[待验证]**
- **RiftVM 里跑的**：桌面层显示、缩放、点击、拖动、主题切换、恢复、管理窗口。每次记录到 `docs/linux/testing.md`，写明 Omarchy 版本、RiftVM 版本、架构。
- **改动共用代码时**：`Web/preview-engine` 和 QuickJS 宿主脚本被四端共用，改动后要跑预览引擎自己的测试、Android 的 JVM 和设备测试、Windows 的测试、Linux 的测试。

**测不到的，不会写成测过的**：

- x86_64 的真机。RiftVM 是 aarch64，x86_64 只有 CI 上的构建和无界面测试，窗口行为没有人看过。
- 真实显卡。RiftVM 是虚拟的 OpenGL ES 3.0。
- 多显示器、睡眠和唤醒。RiftVM 只有一个显示器，睡眠和唤醒本身还没验证过。
- Omarchy 之外的桌面：第一版没有显示端，只有命令行和管理窗口。
- 如果 GPUI 在虚拟机里跑不动，管理窗口在这里就测不了，只能靠你在真机上看。

## 10. 需要你做的

**现在就需要（阶段 0 的前提），都在 RiftVM 的窗口里，我不能代做：**

1. 打开 RiftVM，点 **Prepare Omarchy**，等约 4.4 GB 的镜像下载和校验完成。
2. 点 **Start Omarchy**。
3. 填首次开机表单：用户名、密码（两遍）、键盘、主机名、时区。
4. 先在 Mac 的终端里把公钥放进共享文件夹：`mkdir -p ~/riftvm-shared && cp ~/.ssh/id_ed25519.pub ~/riftvm-shared/`。然后在虚拟机里按 Command-Return 打开终端，运行三条命令（没有在虚拟机里试过，报错的话把输出发给我）：
   - 开启 SSH 并装入公钥：`omarchy-setup-security-sshd --key="$(cat /mnt/mac/riftvm-shared/id_ed25519.pub)"`
   - 给这个用户免密码的 sudo（装包要用；这只是一台测试虚拟机）：`echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/99-dev`
   - 关掉屏保和自动锁屏：`omarchy-toggle-idle stay-awake`
5. RiftVM 的窗口保持开着，可以放在后台。虚拟机或 Mac 重启后，需要你重新点 Start 并输入密码。

**之后需要：**

6. 一个 AUR 账号，用来发布 `scriptwidget-bin`（阶段 4）。注册和上传是你的账号，我不代做。
7. 一个放 Omarchy 插件的公开仓库（阶段 4）。你说可以的话我用 `gh` 建。
8. 提交插件目录前，问维护者对关联商业应用的插件有没有限制。我可以起草。

**可以否决的两个选择**：Skia、第一版引擎和后台服务同进程。见第 1 节。

## 11. 不做的事

- 第一版不做：扫码发到手机、AI 生成、Gallery 界面、`$music`、`animation` 过渡动画。
- 不支持 Omarchy 3 及更早版本、X11、GNOME。
- 不做只有 Linux 才有的新标签或新能力（例如读取 Hyprland 工作区）。这是新的契约范围，等第一版有用户之后再提。
- 不用 QML 排版或绘制小组件的内容（QML 只显示画好的图片），不在 Quickshell 的 JS 引擎里执行包代码。
- 第一版不支持 Omarchy 之外的桌面显示小组件。

## 资料来源

- [Omarchy 仓库](https://github.com/omacom/omarchy)（分支 `quattro`）及其 `docs/omarchy-shell.md`
- [Omarchy 4.5 发布说明](https://omarchy.org/news/2026/11/omarchy-4-5/)
- [插件开发](https://plugins.omarchy.org/develop.html)、[插件上架](https://plugins.omarchy.org/publish.html)
- [Quickshell 0.3.2 文档](https://quickshell.org/docs/v0.3.2/)
- [gpui-component](https://github.com/longbridge/gpui-component)、[GPUI 改用 wgpu 的提交](https://git.secluded.site/zed/commit/af8ea0d6c26192c45f44f473c0d4a7d6f72ed018)
- [AGS](https://github.com/Aylur/ags)（参照对象，本次未重新查证）
- [Omalauncher](https://github.com/SimonSchubert/omalauncher-omarchy-plugin)、[ai-usagebar](https://github.com/akitaonrails/ai-usagebar)、[omaclock](https://github.com/ubeyidah/omaclock)
- RiftVM 源码及其 `docs/`
- [ScriptWidget for Windows](../windows/README.md)、[Android 版的调研与规划](../android/android-port-research-and-plan.md)
