# ScriptWidget Linux 版：测过什么

每一条都写明跑了什么、在哪台机器上、结果是什么。没跑的检查写成"没跑"，不写成通过。

## 机器

| 名称 | 系统 | 说明 |
| --- | --- | --- |
| 测试虚拟机 | Omarchy 4.0.6（Arch Linux ARM，aarch64），在 Mac 上的 RiftVM 0.6.10 里，6 核、16 GB 内存、1920×1080 一块屏、缩放 1 | Hyprland 0.57.1，Quickshell 0.3.2，Qt 6.12.0，ICU 78.3，gcc 16.1.1，Rust 1.100.0。显卡是虚拟的（VirGL，只有 GLES，Vulkan 是软件实现） |
| Mac | macOS，Apple 芯片 | 只用来写代码、生成共用的 JavaScript，以及通过 SSH 驱动虚拟机 |

没有在真实的 Linux 电脑上测过，也没有在 x86_64 上测过。

## 怎么重跑

```
node Linux/scripts/build-shared-js.mjs        # 需要先在 Web/studio 里 npm ci 一次
cd Linux
cargo test --locked                           # 全部测试
cargo test --locked -p sw-core --test parity -- --nocapture   # 只跑一致性对比
```

需要系统里有 ICU 的头文件和 C 编译器。QuickJS 用的是 `Android/core/src/main/cpp/quickjs` 里的源码，没有改动。

## 2026-11-17，测试虚拟机：阶段 0

阶段 0 要回答 [plan.md](plan.md) 第 8 节的六个问题。结论：六项里五项通过；"Omarchy 版本"一项是升级了但有一步没成功。下面逐项写。

### 1. 能不能从 Mac 的命令行驱动虚拟机：通过，有两步要人做

- 通过 SSH 同步代码、编译、运行图形程序、用 `grim` 截图传回，都可以，不需要人操作。
- 要人做的两步，各一次：在 RiftVM 的首次开机表单里设密码；在虚拟机终端里运行一个脚本打开 SSH（要输一次密码）。
- Omarchy 默认对 SSH 端口限速（30 秒内 6 个新连接），并发连接会被拒绝。测试时加了一条只对 Mac 地址放开的防火墙规则，并让所有命令复用一个 SSH 连接。
- 虚拟机里 `pacman -S` 装不了包：镜像里的包数据库比已装的系统新，会变成部分升级。Rust 用 rustup 装，CMake 和 Ninja 用 mise 装，都在用户目录里。
- 鼠标操作是用 `/dev/uinput` 造的虚拟指针做的（`Linux/spikes/plugin/pointer.py`），不是人手操作。

### 2. 引擎结果是否一致：通过

代码在 `Linux/crates/sw-quickjs` 和 `Linux/crates/sw-core`，是正式代码的开头，不是一次性的验证工程。

| 检查 | 结果 |
| --- | --- |
| 一致性：仓库里不需要实时数据的包，元素树和 JavaScriptCore 的参考逐字节对比 | 127 个里 127 个相同（参考文件有 164 棵树，其中 127 个包不需要实时数据，和 Windows 版跑的是同一批） |
| 进程用 `TZ=Asia/Tokyo`、`LANG=de_DE.UTF-8` 启动后再跑 | 仍是 127 个相同：结果不受机器的时区和语言影响 |
| 反向检查：把参考的时区改成东京、语言改成德语 | 只有 118 个相同，说明有 9 个包确实依赖时区或语言，上面的结果不是碰巧 |
| 引擎绑定的测试（内存上限、超时、栈上限等） | 15 个全过 |
| 本地时间跨夏令时 | 通过。Linux 上 QuickJS 向 C 库问每个时刻的偏移，没有 Windows 上那个问题，所以源码不用打补丁 |
| 运行时测试、单元测试 | 11 个和 6 个，全过 |
| `$system.platform()` | 不带测试前置脚本时返回 `"linux"` |
| 耗时（127 个包合计） | 编译约 4.7 秒，每个约 37 毫秒；执行约 0.43 秒，每个约 3.4 毫秒，最慢的 6 毫秒 |
| 在 Mac 上用 Homebrew 的 ICU 79.1 跑 | 也是 127 个相同 |

结论：用系统的 ICU 就够了，不需要随程序带固定版本的 ICU 数据（依据是 78.3 和 79.1 两个版本）。

没跑：AddressSanitizer；x86_64；别的 ICU 版本；多个进程同时写 `$storage`；时间线计划；`render.js`。`$xml`、`fetch`、`$weather`、数据源插件、设备信息还没有移植。

### 3. Skia 能不能用：通过，范围比计划的小

工程在 `Linux/spikes/skia`。

| 检查 | 结果 |
| --- | --- |
| `skia-safe` 0.157.0 在 aarch64 上构建 | 通过。直接下载预编译的 Skia（18.5 MB），不用从源码编译；干净构建 8 秒 |
| 画一张 658×340 的图：渐变圆角背景、英文、中文、彩色表情、自动换行并截断的混排段落、折线、缩放的图片 | 都画出来了，见 `Linux/spikes/skia/out/widget.png` |
| 耗时和大小 | 第一次绘制 84 毫秒（冷启动找字体），之后每次 0.5 毫秒左右；编码 PNG 6 到 8 毫秒；峰值内存 24 MB；程序 16.7 MB |

发现的问题：这台机器没有配置中文字体偏好，中文落到了 "Noto Sans CJK KR"。正式的画笔要自己指定中文字体的顺序，否则部分汉字会是韩文字形。

没跑：计划里写的"10 个模板和 Windows 版参考图对比"。那需要先把画笔移植过来，放到阶段 1。随程序带的字体、显卡加速的画布也没试。

### 4. QML 显示端是否可行：通过

工程在 `Linux/spikes/plugin`：一个本地插件（`service` 类型）加一个假的后台脚本，脚本用 ImageMagick 画图并按行输出 JSON 事件。

| 检查 | 结果 |
| --- | --- |
| 图片显示在桌面层 | 通过。`hyprctl layers` 显示两个窗口在 `bottom` 层，在壁纸上面、普通窗口下面，位置和大小与事件里的一致，圆角外是透明的 |
| 新图出来后换图 | 通过。发出指令后 0.5 秒截图，已经是新图 |
| 点击传回后台 | 通过。点按钮区域，后台收到 `tap a 1`，图上的计数从 0 变成 1 |
| 拖动 | 通过。从 (80,80) 拖到 (580,400)，后台收到 `move a 580 400`，窗口停在新位置 |
| 提到最上层再放回 | 通过。运行中把层从 `Bottom` 改成 `Overlay` 再改回去都生效，不用另建一组窗口 |
| GIF 换帧 | 通过。四帧图用定时器轮换，相隔 0.3 秒的两张截图不同 |
| 外壳重启后恢复 | 通过。`omarchy-restart-shell` 之后插件自动加载，旧的后台脚本被结束，新的被启动 |
| 本地开发流程 | 插件放进 `~/.config/omarchy/plugins/<id>/`，`omarchy plugin validate` 通过，`omarchy-shell shell rescanPlugins` 和 `omarchy plugin enable` 之后生效；改文件后外壳自动重新加载 |

实现上定下来的两点：每个版本的图用新文件名（同名文件改内容，QML 不一定重新读）；QML 用参数数组启动命令，不拼接命令行字符串。

没跑：大于 1 的显示缩放；多块显示器；右键菜单；状态栏入口（`bar-widget`）；真人用鼠标操作；长时间运行。

截图：`Linux/spikes/plugin/out/`。

### 5. GPUI 能不能用：通过，两项没能测

工程在 `Linux/spikes/gpui`。

| 检查 | 结果 |
| --- | --- |
| 依赖 | `gpui-kit` 0.10.0（原来的 gpui-component，仓库搬到了 `longbridge/gpui-kit`），它依赖 crates.io 上的 `gpui-pre` 0.3.12。不需要钉 Zed 仓库的提交。许可证都是 Apache-2.0（核对了 crates.io 的元数据和仓库里的许可证文件） |
| 构建 | 通过。98 秒，编译器峰值内存 1.7 GB，没有另装系统包；程序 38.7 MB |
| 窗口 | 通过。原生 Wayland 窗口，编辑器显示 32 行 JSX，有行号、缩进线、语法高亮 |
| 补全 | 通过。输入 `$` 弹出我们给的三项（`$storage`、`$device`、`fetch`）和说明，回车插入 |
| 中文 | 字符能输入和显示（用 `wtype` 直接送字符） |
| 用的显卡后端 | 软件渲染的 Vulkan（llvmpipe）。虚拟显卡的 GLES 不满足 wgpu 的要求，被跳过 |
| 软件渲染下的开销 | 窗口空闲时占约半个核，内存 246 MB |

没能测：中文输入法的组字（虚拟机里没有装中文输入法，`wtype` 也绕过输入法）；真实显卡上的流畅度和开销；X11；悬停提示和诊断；鼠标操作。这两项要在真实的 Linux 电脑上测。

要注意：`gpui-kit` 每周发一个版本，接口变得快，正式开发时要锁定版本。

截图：`Linux/spikes/gpui/out/`。

### 6. Omarchy 版本：升级了，有一步失败

- `omarchy update -y` 把系统包和 `omarchy` 包从 4.0.6-1 升到了 4.5.0-3。
- 升级的最后阶段有一个迁移步骤失败："给浮动工作区装标题栏"要装 `omarchy-hyprland-titlebars`，它要求 `hyprland=0.56.2`，而 aarch64 的软件源里的 Hyprland 版本对不上。更新命令因此以错误结束。
- 升级后没有重启虚拟机，Hyprland 还是升级前启动的那个进程。只重启了外壳。
- 在这个状态下重跑：显示端的显示、点击、换层都正常；一致性对比仍是 127 个相同。

所以现在的测试基线是"4.0.6 镜像升到 4.5.0-3、未重启、浮动标题栏没装上"。4.5 的浮动桌面模式没有测。重启后能不能正常进桌面没有验证。

为了让无人值守的更新能跑，在虚拟机里给测试用户加了 `sudo` 免密码的规则。这只是这台一次性测试机的设置，不是产品的要求。

## 2026-11-17，测试虚拟机：阶段 1（运行时、画笔、命令行）

这时虚拟机已经升到 Omarchy 4.5.0-3（没有重启，见上面第 6 项）。ICU 78.3，fontconfig 2.18.3，Rust 1.100.0。测试都通过 SSH 运行，没有设置 `DISPLAY` 和 `WAYLAND_DISPLAY`。

### 自动测试

| 检查 | 结果 |
| --- | --- |
| `cargo test --locked --workspace`，测试虚拟机 | 418 个通过，0 个失败，1 个忽略 |
| 同一套测试在 Mac 上（ICU 79.1） | 412 个通过，0 个失败，1 个忽略。少的 6 个是只在 Linux 上编译的安全测试 |
| 被忽略的那个测试（导出的压缩包能被 Info-ZIP 和 Python 的 `zipfile` 读，它们写的压缩包能导入） | 单独用 `--ignored` 跑过，通过 |
| 一致性：不需要实时数据的包，元素树和 JavaScriptCore 的参考逐字节对比 | 127 个里 127 个相同 |
| 引擎绑定测试，QuickJS 和绑定用 AddressSanitizer 编译（`sh Linux/scripts/asan-test.sh`） | 15 个里 15 个通过 |
| 画笔：一致性里的每个包按 170×170、329×170、329×345、缩放 2 各画一次 | 381 张图，没有出错，没有空图 |
| 命令行：分阶段安装的目录（程序在 `bin`，数据在 `share/scriptwidget`），清空环境变量后把内置模板逐个画成中等尺寸 | 列出的 130 个模板里 116 个画出来，没有出错，没有空图。另外 14 个要访问网络，没有画 |
| 发布版程序 `scriptwidget` 的大小 | 25.3 MB，去掉符号后 22.4 MB |

各部分的测试数（各部分合并前在测试虚拟机上各自统计的，合并后只核对了总数 418）：引擎 16 个；包和压缩包 126 个，其中 6 个只在 Linux 上跑（`openat2`、不替换已有文件的重命名、大小写冲突、Unicode 规范化别名、非 UTF-8 文件名、跨文件系统的暂存目录）；网络、天气、设备信息、XML、数据源插件、时间线共 152 个；画笔 63 个；命令行 31 个；运行时门面和模板库 18 个；其余是阶段 0 已有的。

安全规则各有测试，其中这些是在测试虚拟机上真正对着文件系统跑的：符号链接、硬链接、权限为 000 的文件、路径穿越、压缩包里的穿越条目、绝对路径、反斜杠、符号链接条目、大小写冲突、谎报大小的条目。包这一层还做过反向检查：故意改坏 26 条安全规则，看测试会不会失败；有两个测试因此加强了，剩下 6 处改坏后测试仍通过的地方，各有第二层检查拒绝同样的输入。网络这一层去掉"只连接检查过的地址"和"跨源不带凭据"后，有 5 个测试失败。

网络测试不访问公网：测试把夹具域名解析成公网地址，再把这些地址接到本机的监听端口上，所以检查本身仍然生效。

### 手工检查

- 在分阶段安装的目录里、清空环境变量后运行 `scriptwidget render`，画了"Month Calendar"（大尺寸）、"Personal Dashboard"、"Lunar Date"、柱状图组件，图都看过，内容正确，中文是简体字形。
- `scriptwidget doctor` 的六项检查里五项通过，`service` 一项是"没跑"（后台服务还不存在）。
- `scriptwidget add x` 以退出码 69 结束，并说明需要后台服务。
- 画笔的图看过约 25 张：时钟、图表、进度环、图标、中文、彩色表情、图片、锥形渐变、阴影、细体和粗体。

### 没跑的

- GitHub Actions 的 Linux 任务（`.github/workflows/linux.yml`）还没有运行过：它在提 PR 或推到 `main` 时才启动。所以 x86_64、Ubuntu 的 ICU 74 都没有结果。
- 和 Windows 或 iPhone 的图逐像素对比：仓库里没有可用的参考图。
- 访问真实的互联网主机，包括 MET Norway；14 个要联网的模板。
- 真实的 Linux 电脑、真实显卡、大于 2 的缩放、`extraLarge` 配真实模板。
- 没有中日韩字体或表情字体的机器。
- 真正装到 `/usr/share/scriptwidget`；两个 `install` 同时运行。
- 测试虚拟机上的 `clippy`（那里没装）；Mac 上跑过，`sw-render` 有风格类的警告没有改。

### 遇到的问题

- 一个原有的测试（脚本无限分配内存，应当报"超出资源限制"）在测试虚拟机上不稳定：内存耗尽时引擎有时连错误对象都建不出来，抛出的是 `null`。现在把这种情况也归为超出资源限制，代价是脚本自己 `throw null` 也会被这样归类。记在 [TODO.md](TODO.md)。
- `sw-core` 的构建脚本把 ICU 的链接参数放在了用到它的静态库前面，在 Linux 上会让用到 `Intl` 的单元测试链接失败。已改。
- 系统字体按名字向 Skia 要不一定给对（要等宽字体得到了无衬线字体），改为用 fontconfig 自己的匹配结果。
- Skia 的段落排版有三处要绕开：行的位置按 UTF-16 单位计数；比容器宽的单词；布局宽度被向下取整导致刚好放得下的一行被截断。各有回归测试。

## 2026-11-17，第二台测试虚拟机：干净的 Omarchy 4.5

第一台虚拟机是从 4.0.6 升上来的，而且升级后没有重启。这一台是用 RiftVM 新建的，装好就是 Omarchy 4.5.0-3：Hyprland 0.57.2，Quickshell 0.3.2，Qt 6.12.0，ICU 78.3，fontconfig 2.18.3，内核 7.3.5，aarch64，6 核、16 GB，1920×1080、缩放 1。这台机器上 `pacman` 能正常装包，Rust（经 rustup）、CMake、Ninja、clang 都是用它装的。

| 检查 | 结果 |
| --- | --- |
| `cargo test --locked --workspace`，没有 `DISPLAY` 和 `WAYLAND_DISPLAY` | 418 个通过，0 个失败，1 个忽略 |
| 引擎绑定测试带 AddressSanitizer | 15 个里 15 个通过 |
| 显示端验证插件（`Linux/spikes/plugin`）：校验、启用、显示在 `bottom` 层 | 通过 |
| 点击、拖动（虚拟指针） | 通过：后台收到 `tap a 1` 和 `move a 580 400` |
| GIF 换帧 | 通过：相隔 0.3 秒的两张截图不同 |
| 运行中换层 | 通过：`overlay` 再回到 `bottom` |
| 外壳重启后恢复 | 通过 |
| 4.5 的浮动布局（工作区布局切到 `floating`） | 小组件照常显示，点击有效；截图在 `Linux/spikes/plugin/out/omarchy-4.5-floating-layout.png` |

在 4.5 上看到的、阶段 2 要考虑的：

- 浮动布局下 Omarchy 自己有一个程序坞（`omarchy.dock`），在 `top` 层，占屏幕底部约 207 像素高的一条。小组件放在那一条里会被它盖住，摆放时要避开。
- 这个 aarch64 镜像里没有装 `omarchy-hyprland-titlebars`（浮动窗口的标题栏），和第一台虚拟机升级时装不上是同一个包。不影响小组件。

没跑：大于 1 的缩放、多显示器、真人操作鼠标。

## 2026-11-17，GitHub Actions：PR 77 的第一次运行

工作流 `.github/workflows/linux.yml`，运行 44242201617，提交 `eb9d75b`。

| 机器 | 结果 |
| --- | --- |
| `ubuntu-24.04`（x86_64） | 通过：构建、全部测试（含被忽略的那个）、带 AddressSanitizer 的引擎绑定测试、clippy |
| `ubuntu-24.04-arm`（aarch64） | 通过，同上 |

这是 x86_64 和 Ubuntu 自带的 ICU 第一次跑这套测试；一致性对比是测试的一部分，所以在这两台机器上也是 127 个相同。Ubuntu 24.04 的 ICU 版本没有从日志里读出来核对（发行版自带的是 74）。两台机器都没有图形会话。

没有人看过 CI 上画出来的图，CI 只检查没有出错、没有空图。

## 2026-11-17，第二台测试虚拟机：阶段 2、3、4（后台服务、插件、管理窗口、安装包）

机器同上：干净的 Omarchy 4.5.0-3，aarch64，Hyprland 0.57.2，Quickshell 0.3.2，ICU 78.3，1920×1080、缩放 1。鼠标操作都是虚拟指针（`/dev/uinput`），不是人手。中途这台虚拟机因为 Mac 桌面崩溃重启过一次，重启后要在登录界面输密码才有图形会话。

### 自动测试

| 检查 | 结果 |
| --- | --- |
| `cargo test --locked --workspace`，三部分合并之后 | 512 个通过，0 个失败，1 个忽略 |
| 其中后台服务：26 个单元测试、13 个集成测试（进程内起一个真的服务，走真的 socket）、4 个用编译好的程序做服务和客户端的测试 | 通过 |
| 其中管理窗口不需要窗口的逻辑（模板库、保存和读取、防抖、单实例握手、语言选择及回退、两种语言的键是否齐全） | 49 个通过 |
| 插件对着按协议写的替身程序，在真实会话里跑 `Linux/omarchy-plugin/tests/check.sh` | 64 项里 64 项通过（合并前的最后一次完整运行；之后把"丢弃没被再次点名的小组件"的等待从 3 秒改成 12 秒，没有重跑这个脚本） |

### 从发布包安装后的端到端检查

用 `Linux/scripts/package.sh` 在这台机器上打出 `scriptwidget-0.1.0-linux-aarch64.tar.gz`，解压到另一个目录，运行 `install.sh`，之后全部用装好的程序。

| 检查 | 结果 |
| --- | --- |
| `install.sh`：程序进 `~/.local/bin`，systemd 用户单元启动，插件启用 | 通过。第一版脚本在外壳还没发现新插件时就去启用，失败了；改成等一下并重试后通过 |
| `scriptwidget doctor` | 六项全过，含 `service` |
| 安装四个模板并放到桌面（`install`、`add`） | 四个都出现在 `bottom` 层，位置和尺寸与服务报告的一致 |
| GIF（Nyan Cat，12 帧） | 在动：相隔 0.35 秒的两张截图不同 |
| 点按钮（Mood Check-in 的第五个表情） | 脚本重新运行，图变成"Great" |
| 点小组件上不是按钮的位置 | 什么都不运行 |
| 摆放模式里拖动 | 从 (60,80) 拖到 (740,520)，服务保存了新位置；摆放时自动提到最上层，结束后恢复 |
| `menu <id> edit` | 打开管理窗口并直接进入那个小组件的编辑器；预览和桌面上的小组件用同一份存储 |
| 管理窗口里点"Add to desktop" | 服务里多出一个小组件 |
| `menu` 改尺寸、`remove` | 生效；移除后图片文件被清掉 |
| 不认识的小组件编号、不在列表里的菜单词 | 被拒绝，退出码 2 |
| 重启服务 | 四个小组件原位恢复 |
| 重启 Omarchy 外壳 | 四个窗口重建 |
| 停掉服务 | 插件保留最后的图，状态变成 `stopped`；命令行以 69 退出；再启动后恢复 |
| 服务空闲时的开销（四个小组件） | 20 秒内 0 个 CPU 时间片；常驻内存 59 MB |
| `uninstall.sh`（不带 `--purge`） | 程序、单元、插件都没了，小组件数据留着 |
| 用新打的包重新安装 | 四个小组件自己回到桌面 |
| 发布包里有没有字体文件 | 没有；打包脚本发现字体就失败 |

管理窗口的各页（我的小组件、模板、模板详情、编辑器、设置，英文和中文）都截了图并看过，在 `docs/linux/images/`。窗口空闲时：我的小组件页 0% CPU、237 MB；编辑器里光标闪烁时占四分之一个核（软件渲染）。

### 没跑的

- 高于 1 的缩放、多显示器、浅色主题、真实显卡、真人操作鼠标、中文输入法的组字。
- 电脑重启后服务随会话自动启动（单元是启用状态，但没有重启验证）。
- 真的睡眠和唤醒；会话锁定时暂停刷新（Omarchy 的锁屏不发 logind 信号，插件也没有上报）。
- 时间线切换点的端到端；要联网的模板。
- x86_64 的安装包在桌面上的任何表现。
- 管理窗口的读屏和 Tab 键导航；从文件管理器双击 `.swt`。

### 发布包（提交 `469350d2`）

| 包 | 怎么来的 | 检查 |
| --- | --- | --- |
| `scriptwidget-0.1.0-linux-aarch64.tar.gz` | 在这台测试虚拟机上用 `package.sh` 构建 | 构建前全部测试 512 个通过；解压、`install.sh` 重装后 `doctor` 全过，四个小组件回到桌面 |
| `scriptwidget-0.1.0-linux-x86_64.tar.gz` | GitHub Actions 的"Linux release archive"工作流（运行 44265856469），在 `archlinux:latest` 容器里构建，ICU 78.3 | 全部测试通过；解压后清空环境变量运行 `doctor` 和 `render`（画出日历模板，图不为空），`scriptwidget-studio --version` 能运行，包里没有字体文件。没有图形会话，没有人看过它在桌面上的表现 |

这个工作流第一次运行失败过：一个画笔测试靠"系统字体和 Inter 的宽度不同"来判断用了哪种字体，而 Arch 上的 Noto Sans 和 Inter 在那段文字上只差不到半个像素。测试改成按字体的族名判断后通过。

阶段 0 的验证工程（`Linux/spikes`）在这之后从仓库里删掉了，它们在提交 `9846e47` 及更早的历史里。

## 2026-11-18，第二台测试虚拟机：刷新、x86_64 的包、0.1.1

机器同上（干净的 Omarchy 4.5.0-3，aarch64）。这一轮补上 0.1.0 发布时没有做的两件事，并因此发现和修掉了一个问题。

### 刷新，在桌面上

用的是从 0.1.0 的发布包安装的服务，四个小组件一直放在桌面上。

| 检查 | 结果 |
| --- | --- |
| 定时刷新（默认 15 分钟） | 服务在 00:30:11 启动，01:34:33 查看时每个小组件运行了 5 次：启动时 1 次，之后 15、30、45、60 分钟各 1 次。桌面上的世界时钟从 23:50 走到了 1:30（截图看过） |
| 画面没变时不换图 | 日历、心情、Nyan Cat 运行了 5 次，图片版本仍是 1；时钟每次都换了新版本 |
| 手动刷新（`scriptwidget refresh`） | 每个小组件的运行次数加 1 |
| 计时器样式的 `<date>`（`component/date`） | 不重新运行脚本，每秒重画：8 秒里图片版本从 4 到 12，运行次数一直是 1；相隔 3 秒的两张桌面截图不同 |
| 时间线切换点 | 把 Day Rhythm 模板复制一份，`dailyTimes` 改成 2 分钟和 3 分钟之后（01:37、01:38）。每 15 秒看一次：01:36:51 还是第 1 次运行，01:37:07 是第 2 次，01:38:07 是第 3 次；桌面上的图在两个状态之间按时切换 |

### x86_64 的发布包，在这台 Omarchy 4.5 上

这台机器是 aarch64，不能直接运行 x86_64 的程序。做法：在虚拟机里装 `qemu-user-static`，用 Docker 起一个 `linux/amd64` 的 `archlinux:latest` 容器（ICU 78.3），把用户的主目录和 `/run/user/1000` 原路径挂进去，在容器里运行从 GitHub 发布页下载的 `scriptwidget-0.1.0-linux-x86_64.tar.gz`（校验和核对过）里的程序。这样 x86_64 的服务用的是真实的数据目录和真实的 socket，显示它的是这台机器上真实的 Omarchy 外壳和插件；宿主上的 `scriptwidget` 换成一个转进容器的包装脚本，所以插件运行的 `watch`、`tap`、`move` 等命令也都是 x86_64 的。

| 检查 | 结果 |
| --- | --- |
| `scriptwidget doctor`（x86_64） | 通过 |
| `scriptwidget render` 画日历模板 | 通过，图不为空 |
| x86_64 的服务接管桌面 | 四个小组件显示在 Omarchy 桌面的 `bottom` 层，位置是之前保存的位置 |
| 点按钮 | 心情小组件的脚本重新运行，图变成"Low" |
| 手动刷新 | 运行次数加 1 |
| 摆放模式里拖动 | 时钟从 (740,520) 到 (1140,120)，位置保存 |
| GIF | 在动 |
| `add`、`remove` | 通过 |
| x86_64 的管理窗口（容器里另装了 Wayland、xkbcommon、Vulkan 软件实现） | 10 秒内在真实的 Wayland 会话里开出窗口；我的小组件页和模板页画出来了，点侧栏能切换页面 |
| 服务被直接结束后留下的旧 socket | 之后启动的服务照常接管 |

这个测试的局限要写清楚：程序是经过指令模拟运行的，不是在 x86_64 处理器上；它用的系统库来自 Arch Linux 的 x86_64 容器，不是一台 x86_64 的 Omarchy；容器里没有设置时区，所以时钟显示的是 UTC；速度没有参考意义（画一张大尺寸日历用了 0.5 秒）。它能说明的是：x86_64 的包里的程序是完整的，能在 Omarchy 4.5 的桌面上显示小组件并响应点击、拖动、刷新。真正的 x86_64 电脑仍然没有测过。

### 发现的问题：用过摆放模式后，小组件停在窗口上面

上面看 x86_64 的管理窗口时，四个小组件盖在窗口上。原因和架构无关，0.1.0 的两个包都有：摆放模式期间服务会把"提到最上层"打开，结束时恢复；插件在摆放模式里把小组件的窗口藏起来，而窗口在隐藏前后收到的换层没有在重新显示时生效，于是窗口回来时留在了 `overlay` 层，直到重启外壳。0.1.0 的端到端检查里拖动之后没有看层，所以漏掉了。

修法：插件只在摆放模式之外理会"提到最上层"，只在窗口显示时设置层，并在窗口重新显示之后再设一次。

| 检查 | 结果 |
| --- | --- |
| 摆放模式开、关（之前没有提到最上层） | 回到 `bottom` 层 |
| 先提到最上层，再摆放模式开、关 | 仍在 `overlay` 层，状态里"提到最上层"仍是开 |
| 关掉"提到最上层"，再摆放一次 | `bottom` 层 |
| 插件的检查脚本，替身程序改成和真服务一样在摆放时打开"提到最上层" | 修复后 64 项里 64 项通过；换回旧的 `WidgetWindow.qml`，"摆放结束后窗口回到 bottom 层"这一项失败（另有一项跟着失败） |

这个修复在 0.1.1 里。

### 0.1.1 的发布包（提交 `7878d884`）

| 包 | 怎么来的 | 检查 |
| --- | --- | --- |
| `scriptwidget-0.1.1-linux-aarch64.tar.gz` | 在这台测试虚拟机上用 `package.sh` 构建 | 构建前全部测试 512 个通过；用 `install.sh` 覆盖安装 0.1.0 并重启外壳后，`doctor` 全过，四个小组件回到桌面；摆放模式里拖动一个小组件再退出，四个窗口都在 `bottom` 层 |
| `scriptwidget-0.1.1-linux-x86_64.tar.gz` | GitHub Actions 的"Linux release archive"工作流（运行 44280183662），Arch Linux 容器 | 工作流里的测试和解包自检通过；另在这台虚拟机上经指令模拟运行：`doctor` 通过，它的服务接管桌面后四个小组件显示在 `bottom` 层。没有在 x86_64 的电脑上运行过 |

PR 78 的检查（两种架构的 Linux 测试、Apple 平台、编辑器）全部通过后合并。0.1.0 的发布说明里加了"已被 0.1.1 取代"。

## 2026-11-18，第二台测试虚拟机：主题、缩放、第二块显示器、睡眠，以及 0.1.2

机器同上。用的是装好的 0.1.1。这一轮把之前列为"没跑"的项目尽量补上，又发现并修了三个问题。

### 补上的检查

| 检查 | 怎么做的 | 结果 |
| --- | --- | --- |
| 浅色主题 | `omarchy-theme-set "Catppuccin Latte"`，再切回 Tokyo Night | 插件的状态从 `dark: true` 变成 `false` 再变回；每次切换每个小组件运行一次；心情小组件画成了浅色（截图看过），切回后的图和最初的逐字节相同 |
| 缩放 2（修复之后） | 运行中把显示器的缩放改成 2 | 服务按 2 倍画：日历的图从 329×345 像素变成 658×690；截图里文字清晰；点第三个表情有效；摆放模式里拖动 Nyan Cat，位置保存，结束后四个窗口在 `bottom` 层 |
| 缩放来回改 | 1 → 1.5 → 2 → 1 | 每次改完 5 秒内服务里的缩放跟上 |
| 第二块显示器 | `hyprctl output create headless` 加一块虚拟显示器（它的缩放是 2，主屏是 1） | 把日历 `move` 到第二块屏：窗口出现在那块屏的 (100,100)，按 2 倍画，主屏上的仍按 1 倍；`grim -o` 截第二块屏，日历清晰；摆放模式在两块屏上各开一个画布 |
| 显示器断开（修复之后） | `hyprctl output remove` | 原来在第二块屏上的日历出现在主屏的同一坐标；再加一块屏、移过去、再断开，同样回到主屏 |
| 睡眠和唤醒 | 这台虚拟机的时钟不能设唤醒闹钟，真的睡下去没法从 SSH 叫醒。改用内核的测试模式：`echo freezer > /sys/power/pm_test` 后 `systemctl suspend`，走完 logind 的睡眠流程，冻结进程 5 秒后自己恢复 | 日志里有完整的 Suspend 流程；恢复后每个小组件的运行次数加 1 |

睡眠测试的局限：没有真的断电睡眠，硬件没有进入低功耗状态。恢复之后 Omarchy 锁了屏；锁屏期间服务仍在刷新（见 [TODO.md](TODO.md)）。第二块显示器是虚拟的，没有用测试指针在它上面点过或拖过。

### 发现并修掉的三个问题（都在 0.1.1 里存在）

- **运行中改缩放，小组件仍按旧缩放画，发虚。** 插件用的是外壳自己的屏幕对象，缩放在运行中改变后它不更新，有时还给出改之前的值。现在只报合成器（`hyprctl -j monitors`）说的数：启动时、重连后、外壳的屏幕对象有变化时、合成器报告显示器或配置变化时各问一次，另外每 30 秒问一次以防没有通知。
- **小组件所在的显示器断开后，小组件不见了。** 窗口随显示器一起消失，换到别的显示器后不会重新出现。现在显示器变了就把窗口藏一下再显示，它会出现在主屏的同一坐标。
- **`scriptwidget-studio --edit <不存在的小组件>` 让程序直接退出。** 启动时的请求在窗口建好之前处理，失败时要弹提示，而提示需要窗口自己的状态。现在等窗口建好之后再处理启动请求。从桌面小组件点"编辑"而那个包已经被删掉时会走到这里。

管理窗口这一项是在锁屏期间验证的，真实会话用不了，所以在这台机器上另起了一个无屏的 sway（`WLR_BACKENDS=headless`）：0.1.1 的程序在里面以 101 退出，日志里有 panic；修复后的程序开出窗口，停在"我的小组件"页（截图看过）。

修复之后全部测试 512 个通过。插件的检查脚本在这些修改之后没有重跑，因为它需要真实会话。

### 0.1.2 的发布包（提交 `7d14728a`）

| 包 | 怎么来的 | 检查 |
| --- | --- | --- |
| `scriptwidget-0.1.2-linux-aarch64.tar.gz` | 在这台测试虚拟机上用 `package.sh` 构建 | 构建前全部测试 512 个通过；`install.sh` 覆盖安装后 `doctor` 全过。安装时真实会话锁着，所以装好之后没有在桌面上再看一遍；插件的两处修改就是上面在桌面上测过的那两个文件 |
| `scriptwidget-0.1.2-linux-x86_64.tar.gz` | GitHub Actions 的"Linux release archive"工作流（运行 44292298183），Arch Linux 容器 | 工作流里的测试和解包自检通过。这一版的 x86_64 包没有再做指令模拟的运行 |

PR 79 的检查全部通过后合并。0.1.1 的发布说明里加了"已被 0.1.2 取代"。

### 解锁之后补上的（同一天，装好的 0.1.2）

| 检查 | 结果 |
| --- | --- |
| 装好的 0.1.2 在真实桌面上 | 四个小组件在 `bottom` 层；点心情小组件的按钮，脚本重新运行；摆放模式开、关之后四个窗口仍在 `bottom` 层；缩放改成 2，6 秒内服务按 2 倍画，改回 1 同样跟上 |
| 插件的检查脚本（`Linux/omarchy-plugin/tests/check.sh`），用的是和装好的 0.1.2 逐字节相同的插件文件 | 64 项里 64 项通过，没有跳过 |
| 中文输入法的组字 | 通过。在真实会话里打开管理窗口的编辑器，把 fcitx5 切到拼音，用 `/dev/uinput` 的虚拟键盘（`Linux/omarchy-plugin/tests/keyboard.py`）输入 `nihao`：窗口收到 `preedit_string("ni hao")`，编辑器里出现带下划线的"ni hao"，候选窗出现在光标下方；按空格后窗口收到 `commit_string("你好")`，字进了编辑器；再输入 `shijie` 加空格，上屏的是第一个候选"时节"。预览随之刷新。截图在 `images/studio-pinyin.png` |

Omarchy 的空闲锁屏在这台机器上是关着的（`omarchy-toggle-idle` 的保持唤醒状态）；之前那次锁屏是睡眠测试引起的。

### 仍然没跑的

- 真实显卡；真实的 x86_64 电脑。这台 Mac 上做不到。

### 重启后服务自启

`sudo systemctl reboot` 重启虚拟机（开机时间 04:43:28）。重启后停在登录界面，登录要输密码，所以没有进真实会话，改为只看服务这一半：

| 检查 | 结果 |
| --- | --- |
| 重启后、没有图形会话时 | `scriptwidget.service` 是启用、未运行；`graphical-session.target` 未激活；没有服务的 socket。符合单元的写法：它跟着图形会话走，不是开机就跑 |
| 依赖关系 | `systemctl --user list-dependencies graphical-session.target` 里有 `scriptwidget.service` |
| 让 `graphical-session.target` 激活（登录时会话管理器做的就是这件事；这里用一个 `Wants=graphical-session.target` 的临时单元把它带起来，没有手工启动服务） | 2 秒内 `scriptwidget.service` 变成运行中，日志里是 systemd 启动它；`doctor` 的 `service` 一项通过 |
| 服务起来之后的状态 | 四个小组件都在，位置是重启前保存的（时钟 740,520；日历 440,80；心情 60,290；Nyan Cat 250,290），各运行了一次，图片写进了运行时目录 |
| 清理 | 停掉临时单元和 `graphical-session.target` 之后服务跟着停止，socket 被清掉，仍是启用状态 |

之后用户在登录界面登录了（密码由用户本人输入），于是整条路径也看到了：

| 检查 | 结果 |
| --- | --- |
| 登录后 `scriptwidget.service` 的状态 | 运行中，启动时间 05:06:18，日志里是 systemd 启动它，没有人手工启动 |
| 插件 | 已启用，状态是 `running`，报告 4 个小组件 |
| 桌面 | 四个窗口在 `bottom` 层，位置是重启前保存的；截图里日历、心情、Nyan Cat、世界时钟都在，时钟显示的是当时的时间（05:07）。截图在 `images/desktop-after-restart.png` |

所以"重启电脑 → 登录 → 小组件自己回到桌面"这一整条通过。之前试过用会话管理器（`uwsm`）在 SSH 里起一个无屏会话来代替登录，它的环境预加载步骤失败了，没有成。

## 2026-11-18，第二台测试虚拟机：0.1.3（右键菜单，以及一个会让外壳崩溃的问题）

机器同上，会话是重启后用户登录的真实会话。

### 用户反馈：小组件点了没反应，右键也没反应

属实。0.1.2 及之前：只有按钮、开关、链接的区域接收鼠标，其余地方的点击穿透到桌面；右键菜单只在摆放模式里有。桌面上四个小组件里三个没有按钮，所以怎么点都没有反应。

0.1.3 改成：整个小组件都接收鼠标；左键点在按钮区域是点击，点在别处什么都不做；右键点在小组件任何位置都弹出菜单（改尺寸、编辑、刷新、移除），菜单里多一项"Move widgets…"进入摆放模式，摆放模式里这一项变成"Done moving"。代价是小组件提到最上层时，它下面的窗口不再能透过小组件被点到。

| 检查（真实会话，虚拟指针） | 结果 |
| --- | --- |
| 在日历（没有按钮）上右键 | 菜单出现，八项；截图在 `images/widget-menu.png` |
| 选一个尺寸 | 日历变成那个尺寸，菜单关闭 |
| 在心情小组件的按钮上左键 | 脚本重新运行 |
| 右键选"Move widgets…" | 进入摆放模式；拖动时钟，位置保存 |
| 摆放模式里右键选"Done moving" | 退出摆放模式，四个窗口回到 `bottom` 层 |

### 发现：0.1.2 在显示器增减时会让 Omarchy 外壳崩溃

检查脚本因为"工作区不是空的"拒绝运行，一看是六个"Quickshell has crashed"的报告窗口。`~/.cache/quickshell/crashes` 里一共七份崩溃报告：两份在 02:58:49 和 02:59:09，五份在 05:14:07 到 05:14:42，都是段错误，栈里是 QML 绑定更新，起点是读子进程的输出。时间都对得上我在增减虚拟显示器的时候。

原因：0.1.2 为了"显示器断开后小组件回到主屏"，在小组件窗口的"屏幕变了"信号里把窗口藏一下再显示。但外壳在显示窗口的过程中也会报这个信号，于是在绑定更新的中途又改了窗口的可见性，Quickshell 在这里崩溃。外壳崩溃后 Omarchy 会自动把它重新拉起来，所以 0.1.2 当时的测试结果看上去是通过的；崩溃报告窗口开在别的工作区，没被看到。前两份崩溃报告就是 0.1.2 的这段代码产生的。

0.1.3 的做法：不再理会窗口自己的"屏幕变了"，改为在显示器列表变化（`Quickshell.screens` 变了）时把每个小组件窗口藏一下再显示。

| 检查 | 结果 |
| --- | --- |
| 六轮：加一块虚拟显示器、把两个小组件移过去、拔掉显示器 | 每轮四个窗口都在，拔掉后回到主屏；外壳的进程号没变；没有新的崩溃报告 |
| 缩放 2、1.5、1 | 都跟上，没有新的崩溃报告 |
| 外壳启动时的"Binding loop"警告 | 0.1.2 的写法每个窗口一条，0.1.3 没有 |
| 插件的检查脚本，新增"显示器增减"一组五项（含外壳进程号不变、没有新的崩溃报告），并按新的鼠标行为改了三项、加了四项 | 74 项里 74 项通过 |

教训记在这里：外壳崩溃后会被自动重启，光看"小组件还在"发现不了崩溃。检查脚本现在比对外壳的进程号和崩溃报告的数量。

### 0.1.3 的发布包（提交 `4dfc52e1`）

| 文件 | 在哪里构建 | 做了什么检查 |
| --- | --- | --- |
| `scriptwidget-0.1.3-linux-aarch64.tar.gz` | 在这台测试虚拟机上用 `package.sh` 构建 | 构建前全部测试 512 个通过；`install.sh` 覆盖安装后 `doctor` 全过，四个小组件在真实桌面上。插件的检查脚本 74 项是在合入模板改动之前跑的，之后插件文件没有变 |
| `scriptwidget-0.1.3-linux-x86_64.tar.gz` | GitHub Actions 的"Linux release archive"工作流（运行 44318067089，同一个提交），Arch Linux 容器 | 工作流里的测试和解包自检通过。没有在桌面上运行过，也没有做指令模拟的运行 |

两个文件下载到 Mac 上用各自的 `.sha256` 核对过。PR 80 的检查（Linux 两种处理器、Windows、Apple 平台、浏览器、编辑器和目录、命令行）全部通过后合并，标签 `linux-v0.1.3` 打在 `4dfc52e1`。0.1.2 的发布说明里加了"已被 0.1.3 取代"。

发布时还发现 0.1.0 到 0.1.2 的发布说明里，能用的 API 那一行的名字是空的（写说明时 `$` 开头的名字被命令行吃掉了），三份都已改正。

## 2026-11-18，模板里放不下的文字

Linux、Windows 和 Android 用 Inter 画字，比苹果的系统字体宽一点；共用的排版放不下的字会被截掉并加上"…"。在 Linux 上看到的是 Month Calendar 的大尺寸把"November"画成"Novem…"。这一轮把随应用带的模板都查了一遍，改的是模板本身，所以每个平台都受益。

这些都是在 Mac 上跑的（macOS 27.2，Apple 芯片，Rust 1.98.1，Node 24.21.0，ICU 79.1），没有在虚拟机或真实的 Linux 上跑。Mac 上没有 Linux 的系统字体，但 Inter 是程序自带的，这里要查的正是它。

### 检查的办法

```sh
node Linux/scripts/build-shared-js.mjs
cd Linux && cargo build --release -p sw-cli && cargo build --release -p sw-render --example layout_tree
node Linux/scripts/find-truncated-text.mjs --pictures <目录> --json <文件>
```

（Mac 上的 `cargo` 要加 `PKG_CONFIG_PATH="$(brew --prefix icu4c)/lib/pkgconfig"`。）

脚本把 `Script.bundle` 里的每个包复制一份，在每个源文件前面放一个固定时间的 `Date`，用命令行在四个桌面尺寸各运行一次，再用新加的 `layout_tree` 例子只排版、不画，然后在排好的元素里找四种情况：被截断（以"…"结尾）、被框裁掉、一两个词的短文字被折成多行、文字的框超出小组件。时间选了五个：9 月 16 日周三 12:59（"September"、"Wednesday"、"12:59 PM"、一年的第 259 天还剩 106 天）、11 月 18 日周三 20:48、8 月 29 日周六 22:48（跨六周的月份）、12 月 30 日 23:59、1 月 1 日 00:00。找到的只是候选，每一个都看了画出来的图再判断。

### 结果

| 检查 | 结果 |
| --- | --- |
| 改之前 | 140 个包，2800 次运行里 2766 次排了版；45 个包有候选 |
| 改之后 | 140 个包，2800 次运行里 2778 次排了版；29 个包有候选，都不在模板自己支持的尺寸上，或者是有意的省略，见下 |
| 改了的模板（22 个） | Month Calendar、Daily Command Center、Family Command Board、Travel Day Dashboard、Wellness Dashboard、World Clock Faces、Year in Dots、An Empty Widget、Birthday Countdown、Check Is Friday Today、Check Is Working Day Today、Condition Content、Daily Affirmation、Datetime Timezone、Layout Starter、Location Snapshot、Meal Planner、Music Playback、System Insights、Text Days To End Of Month、Text Days to End Of Year、Text Year Days Left。`scriptwidget new` 的起始模板和 An Empty Widget 是同一个样子，也一起改了 |
| Month Calendar，大尺寸，11 月的周三 | 改之前标题是"Novem… 2026 Wednesday"，改之后是"November 2026 Wed"；跨六周的月份（2026 年 8 月）改之前日程的最后一行超出小组件，改之后格子变小、整体不超出 |
| 苹果的参考树 | 在 iOS 27.2 模拟器（iPhone 18 Pro Max）上用 JavaScriptCore 重新生成了 `native-trees.json`、`music-playback-trees.json`、`layout-edit-trees.json`；`native-trees.json` 变了 18 项，只有树变了。macOS 的测试程序在沙盒里，写不了仓库里的文件，所以生成用的是模拟器；之后在 macOS 上不带生成开关跑了 `BrowserPreviewParityTests`、`MusicRuntimeTests`、`VisualLayoutEditorTests`、`RuntimeExecutionTests`：154 个里 11 个跳过（都是要开关才导出的测试），没有失败 |
| `cd Web/preview-engine && npm test` | 199 个通过 |
| `cd Web/studio && npm test`、`cd Editor/editorfe && npm test` | 114 个通过、52 个通过 |
| `cargo test --locked --workspace`（Mac） | 506 个通过，1 个忽略；与 JavaScriptCore 的树对比 127/127 相同 |
| `./gradlew :core:testDebugUnitTest --rerun`（Mac，JDK 21） | 482 个通过 |
| `node Scripts/validate-release.mjs`、`validate-doc-links.mjs`、`sync-gallery-templates.mjs`、`node --test Scripts/tests/*.mjs` | 都通过（Gallery 里的 Layout Starter 和 Music Playback 用 `--write` 同步过） |

哪个尺寸算"模板支持的"：模板读了 `widget-size` 并按尺寸分支的，每个尺寸都算；只有一种排法的模板，按 `Resource/WidgetDemoScreenshots` 里它的截图的尺寸算（有 `widget.json` 的按它声明的算）。

### 留下没改的候选

- 只有一种排法、截图是中等或大尺寸的模板，在小尺寸上放不下：Animation Clock、Battery & Brightness、Daily Command Center、Datetime Current、Datetime Timezone、Device Battery Percent、Family Command Board、Live Activity Demo、Monthly Budget Planner、Open Link、Personal Dashboard、Pomodoro Focus、Reading Goal、Shape、Sleep Schedule、Sunrise & Sunset、System Insights、Text Today Week、Travel Day Dashboard、Weekly Planner、Wellness Dashboard；大尺寸的 Travel Day Dashboard 和 Wellness Dashboard 在中等尺寸上也放不下。这不是字体的问题：用苹果的系统字体量同一段文字，绝大多数也放不下。这一节没做；后来做了，见下一节"模板的小尺寸排法"。
- `api/` 下的示例（health、location、storage、system）：逐行列出数值的示例，`api/system` 有 14 行，中等尺寸放不下，大尺寸放得下；另外三个只是标题在小尺寸折成两行。
- New Episode Tracker：节目名画在固定 200 点宽的框里，长名字被省略是有意的，而且内容来自网络。
- Now Playing 特大尺寸的"Midnight Drive"、Image Basic Usage 小尺寸的"Photo spotlight"：两个词在空格处折成两行，没有被截断。
- Hydration Goal iCloud：Linux 没有 iCloud，画的是出错时的卡片，里面是任意长的错误信息，小尺寸上被省略。

### 没跑的

- 要联网的模板在这台 Mac 上能跑的都跑了，但内容取决于当时的网络；Daily Quote 每次都没有画出来（返回的不是 JSON），Stock Snapshot、New Episode Tracker、Weather Display 各有一轮超过 5 秒没有画出来。
- 没有在苹果的系统上把改过的模板画成图来看：`Tools/ScriptWidgetPreview` 现在编不过（工程里缺新加的存储源文件）。"在苹果上不变差"是按排版规则和用系统字体量出的宽度判断的，不是看图。
- Windows 的测试、Android 的真机测试、`Scripts/release-readiness.sh`、Web Studio 的浏览器冒烟测试都没跑。

## 2026-11-18，模板的小尺寸排法

上一节留下两件事：只有一种排法的模板在小尺寸上放不下；Text Year Days Left 多算 31 天。这一节把这两件做了。还是在同一台 Mac 上跑的（macOS 27.2，Apple 芯片），没有在虚拟机或真实的 Linux 上跑。检查的办法和上一节一样。

### 改了什么

- 21 个模板加了小尺寸的排法，用 `$getenv("widget-size") === "small"` 分支，原来的排法放在 `else` 里：Animation Clock、Battery & Brightness、Daily Command Center、Datetime Current、Datetime Timezone、Device Battery Percent、Family Command Board、Live Activity Demo、Monthly Budget Planner、Open Link、Personal Dashboard、Pomodoro Focus、Reading Goal、Shape、Sleep Schedule、Sunrise & Sunset、System Insights、Text Today Week、Travel Day Dashboard、Weekly Planner、Wellness Dashboard。小尺寸只画模板最要紧的内容（一个时间、一个百分比、下一件事），不是把原来的排法缩小；颜色不变。上一节写的是"22 个"，实际列出来、脚本也只报出来的是这 21 个。
- 五个为大尺寸设计的模板（Daily Command Center、Family Command Board、Monthly Budget Planner、Travel Day Dashboard、Wellness Dashboard）还加了中等尺寸的排法。脚本在中等尺寸只报了后两个，但看图五个都不对：卡片叠在一起，或者下半截被切掉。
- 模板原来设计的那个尺寸的排法没有动，两处例外，都是看图发现本来就是坏的，脚本没报：
  - Monthly Budget Planner 大尺寸：三行分类的文字和进度条叠在一起，上面两张卡片挤在中间。现在各行有自己的高度，分类名用小一号的字，两张卡片撑满一行。
  - Personal Dashboard 中等尺寸：内容比小组件高，标题顶到上边、日期压在分隔线上。现在间距从 12 改成 8，去掉了"Keep it simple"这一行。
- Live Activity Demo 的 `widget.json` 原来只声明中等尺寸，现在加了 `systemSmall`，说明文件也改了。小尺寸画状态和标题，不画说明文字。
- Text Year Days Left：原来用 `new Date(year, 12, 31)`，那是下一年的 1 月 31 日。现在用今天和 12 月 31 日两个日历日期相减，和几点钟无关。Text Days to End Of Year 和 Text Days To End Of Month 用的是 `moment().endOf(...)` 再取整天数，查过没有这个问题，没改。
- 这些模板在 `Gallery/` 里都没有副本，`sync-gallery-templates.mjs` 不用 `--write` 就通过。

### 结果

| 检查 | 结果 |
| --- | --- |
| `find-truncated-text.mjs`，改之前 | 140 个包，2800 次运行里 2780 次排了版；29 个包有候选 |
| `find-truncated-text.mjs`，改之后 | 140 个包，2800 次运行里 2777 次排了版；8 个包有候选，都是上一节说明过、有意留下的：`api/health`、`api/location`、`api/storage`、`api/system`、New Episode Tracker、Now Playing、Image Basic Usage、Hydration Goal iCloud。没排版的 23 次是 Daily Quote 和 Stock Snapshot（要联网，返回的不是 JSON 或者超过 5 秒） |
| 看图 | 改过的 22 个模板（上面 21 个加 Text Year Days Left）在四个尺寸、五个时间各画了一张，共 440 张；小尺寸的 22 个看了三个时间（9 月 16 日、12 月 30 日、1 月 1 日），中等尺寸的 22 个和五个大尺寸模板的大尺寸看了 9 月 16 日，Monthly Budget Planner 的特大尺寸也看了。其余的图没有逐张看，靠的是脚本没有报 |
| 三个"还剩几天"的模板 | 用命令行在 America/Los_Angeles 时区、13 个时间各运行一次：12 月 31 日 00:00 和 23:59 都是 0，12 月 30 日 00:00、12:00、23:59 都是 1，2026 年 1 月 1 日是 364，2028 年（闰年）1 月 1 日是 365，3 月 7 日（跨夏令时）是 299；Text Year Days Left 和 Text Days to End Of Year 13 个数都相同。月份的那个：2 月 28 日是 0，2 月 1 日是 27，11 月 18 日是 12 |
| 苹果的参考树 | 在 iOS 27.2 模拟器（iPhone 18 Pro Max）上用 `TEST_RUNNER_SCRIPTWIDGET_UPDATE_PARITY=1` 重新生成了 `native-trees.json`，变了 7 项，只有树变了：五个大尺寸模板（参考树是中等尺寸的，现在走新的排法）、Personal Dashboard、Text Year Days Left。其余 14 个改过的模板的中等尺寸的树一个字都没变。`music-playback-trees.json` 和 `layout-edit-trees.json` 对应的模板没改，没有重新生成。之后在 macOS 上不带生成开关跑了 `BrowserPreviewParityTests`、`MusicRuntimeTests`、`VisualLayoutEditorTests`、`RuntimeExecutionTests`：154 个里 11 个跳过（都是要开关才导出的测试），没有失败 |
| `cd Web/preview-engine && npm test` | 199 个通过 |
| `cd Web/studio && npm test`、`cd Editor/editorfe && npm test` | 114 个通过、52 个通过 |
| `cargo test --locked --workspace`（Mac） | 506 个通过，1 个忽略 |
| `./gradlew :core:testDebugUnitTest --rerun`（Mac，Android Studio 自带的 JDK 25） | 482 个通过 |
| `node Scripts/validate-release.mjs`、`validate-doc-links.mjs`、`sync-gallery-templates.mjs`、`node --test Scripts/tests/*.mjs` | 都通过（最后一个是 7 个测试） |

### 没跑的

- 没有在苹果的系统上把新排法画成图来看，原因和上一节一样（`Tools/ScriptWidgetPreview` 编不过）。新排法只用了别的模板已经在用的组件和属性；苹果的小尺寸最窄是 155 点，比这里量的 170 点窄，文字宽度是按 127 点左右留的余量，但没有在 155 点上实际排过。
- 没有在 Android 或 Windows 上画图。Android 小组件的大小随桌面而变，没有量过。
- Sunrise & Sunset 要联网，画出来的时间取决于当时的网络；断网时它本来就不画，这次没改这一点。
- Live Activity Demo 只看了没有状态时的小尺寸图（"Ready"）；有进度、有倒计时、状态不合法这几种没有画图，只按字宽估过。
- Windows 的测试、Android 的真机测试、`Scripts/release-readiness.sh`、Web Studio 的浏览器冒烟测试、Linux 的 `asan-test.sh` 都没跑。

### 之后补上的：在苹果上画图，并重截了演示截图

`Tools/ScriptWidgetPreview` 仍然编不过，但 Mac 应用本身带一个批量画模板的开关，用它画了：

```sh
xcodebuild -project macOS/ScriptWidgetMac.xcodeproj -scheme ScriptWidgetMac -configuration Debug -derivedDataPath <目录> CODE_SIGNING_ALLOWED=NO build
<目录>/Build/Products/Debug/ScriptWidget.app/Contents/MacOS/ScriptWidget --render-template-previews <输出目录>
swift Tools/ScriptWidgetPreview/Scripts/contact-sheets.swift Resource/WidgetDemoScreenshots
```

| 检查（同一台 Mac，macOS 27.2，不签名的调试版） | 结果 |
| --- | --- |
| 92 个模板各画一张，尺寸是模板原来设计的那个 | 两轮；第一轮 Daily Quote 和 Stock Snapshot 超过 5 秒没画出来，第二轮只有 Stock Snapshot |
| 看图：这一节和上一节改过的模板，在苹果的系统字体下 | 设计尺寸的图都正常；Monthly Budget Planner 大尺寸不再重叠，Text Year Days Left 在 11 月 18 日是 43 天 |
| `Resource/WidgetDemoScreenshots` | 87 张换成新图（原来 70 张，缺 22 个模板的图），拼图从 4 张变成 5 张；删掉了已改名模板的旧图 Weather Now (Open-Meteo) |

没换、留着旧图的 5 张：Stock Snapshot（请求超时）；Battery & Brightness、Device Battery Percent、Gauge Battery、System Status Panel（这台 Mac 没有电池，画出来是 0%）。这几个模板在设计尺寸上的排法没有变。

仍然没做的：苹果上只画了每个模板设计的那个尺寸，新加的小尺寸、中等尺寸排法没有在苹果上画图。这台 Mac 没有签名、没有授权，所以日历、健康、照片、提醒事项、GitHub、iCloud 这些模板画出来的是"未连接"的样子。Countdown 没设置时的小尺寸标题"Your next mome…"是模板有意把标题截到 14 个字，没改。

## 2026-11-18，示例排版、加注释之后的参考文件

`Script.bundle` 和 `Script.android` 下的 191 个 `.js`、`.jsx` 示例用 Prettier 排了版，又加了给新手看的注释，`Gallery/` 里的副本也同步了。这一节记的是之后的检查：哪些随仓库保存的参考文件依赖示例的原文，重新生成了哪些，以及发现的一个问题（排版面板读不了排过版的代码，后来在面板里修了）。都是在同一台 Mac 上跑的（macOS 27.2，Apple 芯片）。

### "只动了注释和排版"是怎么查的

- 画出来的树一个字节都没变：`cd Web/preview-engine && npm test` 用现在的示例重新算出每棵树，和排版之前在苹果上录的 `native-trees.json` 逐字节比较，199 个测试都通过。这个文件这次没有重新生成。
- 加注释的几次提交，合并之前逐行核对过只多了注释和空行（这是提交的人做的，这一节没有重做）。
- 两个坑，改示例时要记住：
  - 各个运行时是在脚本的文字里找 `$render`、`moment(`、`moment.` 的，注释里不能出现这几个写法。
  - Prettier 会把 JSX 文字里连着的两个空格并成一个，所以三个动画示例的标题（"LISSAJOUS  7×11"、"ORBITAL  2:3:5"、"PHASE WAVE  Δφ=40°"）现在写成花括号里的字符串。

### 依赖示例原文的参考文件

在 `Tests/ScriptWidgetRuntimeTests`、`Web/preview-engine/test`、`Web/studio/test`、`Editor/editorfe/test`、`Scripts/tests`、`Android/core/src/test`、`Linux/crates/*/tests`、`Windows/tests` 里找了带 `source` 字段、哈希、字节数、行列号或者示例代码片段的地方：

| 文件 | 存了什么 | 结果 |
| --- | --- | --- |
| `Web/preview-engine/test/parity/material-study-trees.json` | Material Study 的原文和 48 棵树 | 重新生成了。48 棵树和原来逐字相同，只有 `source` 变了（1207 个字符变成 1902 个） |
| `Web/preview-engine/test/parity/layout-edit-trees.json` | Layout Starter 的原文、在排版面板里改过之后的原文，以及两棵树 | 面板修好之后重新生成了。两棵树（改之前、改之后）和原来逐字相同，只有两段 `source` 变了 |
| `theme-edit-trees.json`、`asset-edit-trees.json` | 也有 `source`，但那是测试里自己写的一段代码，不是示例 | 不受影响，没动 |
| `Gallery/index.json` 里的字节数和 SHA-256 | Gallery 副本的 | 同步时已经更新，`sync-gallery-templates.mjs` 通过 |
| 其余的 `*-trees.json`、`native-trees.json` | 只有树 | 不受影响，没动 |

`material-study-trees.json` 是在 iOS 27.2 模拟器（iPhone 18 Pro Max）上用 `TEST_RUNNER_SCRIPTWIDGET_EXPORT_MATERIAL_TREES=1` 只跑 `testMaterialStudyCanonicalTreesAndStaticAccessibilityCaptures` 生成的；`layout-edit-trees.json` 是用 `TEST_RUNNER_SCRIPTWIDGET_EXPORT_LAYOUT_TREES=1` 只跑 `testLayoutStarterEditsRenderWithNativeJavaScriptCore` 生成的，改动是真的编辑器（WKWebView 里的排版面板）做的。面板修好之后 Material Study 的原文没有再变，`material-study-trees.json` 不用再生成。

`layout-edit-trees.json` 里改之后的原文和模板只差两处，都是面板写的：`alignment="leading"` 变成 `alignment={"trailing"}`；占三行的 `<text …>`、`Make today yours`、`</text>` 变成一行 `<text …>{"A calmer day"}</text>`。注释都还在。

### 发现的问题：排版面板打不开排过版的示例（已在面板里修好）

这不是参考文件过期，是行为变了，所以当时没有去改测试的期望值，而是报了出来。

编辑器的排版面板（`Editor/editorfe/src/visualLayout.js`）当时读不了排过版的示例，原因有两个，各自单独就够：

- Prettier 在 `$render(` 的元素后面加了一个逗号（`</vstack>,` 换行 `);`）。面板把它当成"不是直接的 `$render(<元素>)`"，只让在代码里改。
- 注释写成了 JSX 里的 `{/* … */}`。面板把它当成语法错误，提示"Fix the JavaScript/JSX syntax before using Layout"。

用 `parseVisualLayout` 把 140 个 `main.jsx` 各读一遍：

| 时候 | 面板能打开 | 只能在代码里改 | 报语法错误 |
| --- | --- | --- | --- |
| 排版之前 | 136 | 4 | 0 |
| 只排了版 | 20 | 120 | 0 |
| 排了版、加了注释，面板修之前 | 8 | 61 | 71 |
| 面板修好之后 | 136 | 4 | 0 |

修之前 Layout Starter 和 Material Study 都读不了，两个 `VisualLayoutEditorTests`（`testLayoutStarterEditsRenderWithNativeJavaScriptCore`、`testNativeMaterialPropertyEditingPreservesSourceAndHistory`）和 `Web/studio` 的两个测试因此失败，`layout-edit-trees.json` 也生成不出来。

修的是面板，不是示例（提交"Layout panel: read code as a formatter writes it"）：`$render(` 的元素后面的逗号和旁边的注释不再算作参数；`{/* … */}` 这样的注释子节点在解析用的副本里换成等长的 `{0   }`，位置不变，显示和修改读的还是原文；单独占一行的文字和写在一行里的一样可以改。两个平台的 `StudioEditor.bundle` 重新构建了。面板现在能打开的示例是 136 个，和排版之前一样，一个都没少。

### 面板的改动复查

担心的是：解析用的是换过注释的副本，改动却要落在原文上。用现在的 Layout Starter 和 Material Study 各试了改文字、改属性、加图层、删第一个和最后一个子图层、把最后一个移到最前、把第一个移到最后，共 14 次（Material Study 的改属性那一次被面板拒绝，因为那个容器没有这个属性可改，其余 13 次都做了）：

- 每个图层的位置都指在原文的 `<标签` 上、结束在 `>` 上；13 次改出来的代码都能再被面板读出来，都能运行，注释一条没少。没有发现改错位置的情况。
- 排得不好看的地方，都不影响运行，原因是面板只插入和删除文字、不重新排版：加的和移过去的图层紧贴在前一个图层后面或者收尾标签前面，不另起一行；删掉或移走的地方留下一个只有缩进的空行。
- 注释不跟着图层走：删掉或移走一个图层，原来写在它上面的注释留在原处，会变成在说下一个图层。
- 文字图层里如果夹着注释（`<text>{/* 说明 */}Hi</text>`），改文字会把这条注释一起换掉。
- 还读不了的两种写法，面板会拒绝并保留原文：注释子节点里用的是 `//`（`{` 换行 `// 说明` 换行 `}`）；前面的字符串里有 `{/*`、后面又有注释子节点时，副本会把中间一段当成注释，报语法错误。示例里没有这两种写法。

这些都没有改，只记在这里。

### 结果

面板修好、两个参考文件都重新生成之后：

| 检查 | 结果 |
| --- | --- |
| 整个 `ScriptWidgetRuntimeTests`，和 `release-readiness.sh` 一样的写法（`xcodebuild -quiet -project macOS/ScriptWidgetMac.xcodeproj -scheme ScriptWidgetRuntimeTests -destination 'platform=macOS' -derivedDataPath … CODE_SIGNING_ALLOWED=NO test`） | 809 个：777 个通过，32 个跳过，没有失败 |
| `cd Web/preview-engine && npm test` | 199 个通过 |
| `cd Web/studio && npm test` | 114 个通过 |
| `cd Editor/editorfe && npm test` | 59 个通过 |
| `node Scripts/validate-release.mjs`、`sync-gallery-templates.mjs`、`validate-doc-links.mjs`、`node --test Scripts/tests/*.mjs` | 都通过（最后一个是 7 个测试） |
| `./Scripts/release-readiness.sh`（`SCRIPTWIDGET_IOS_DESTINATION='platform=iOS Simulator,name=iPhone 18 Pro Max'`，这台机器没有装脚本默认的 iPhone 17） | 跑到最后一行，通过。里面包括：编辑器重新构建后两个 `StudioEditor.bundle` 和仓库里的一样；Web Studio 的浏览器冒烟测试都跑了（没有跳过）；macOS 的测试 809 个里 777 个通过、32 个跳过；macOS 和 iOS 的应用都能构建；iOS 模拟器上整个 `ScriptWidgetRuntimeTests` 820 个里 789 个通过、31 个跳过，没有失败 |

面板修之前的数，留着对照：同一条 macOS 命令是 809 个里 775 个通过、32 个跳过、2 个失败（上面两个 `VisualLayoutEditorTests`）；`Web/studio` 是 114 个里 2 个失败；`Editor/editorfe` 是 55 个通过；`cargo test --locked --workspace` 是 506 个通过、1 个忽略。不加 `CODE_SIGNING_ALLOWED=NO`（签了名的构建）时还多一个失败，`LegacyCutoverProcessTests.testIndependentLegacyWriterStopsBeforeMigrationAndCannotRestartAfterReady`：它不读任何示例（它把应用当子进程启动），只在签了名的构建里失败，为什么没有查。

### 没跑的

- Android 的测试（`:core:testDebugUnitTest`）、Windows 的测试这一节没跑；面板修好之后也没有再跑 `cargo test`（面板的改动不进 Linux 的程序）。
- 没有用手在真的编辑器里点开排版面板看。原生的两个测试是在 WKWebView 里真的点了面板的按钮；上面"复查"里的 14 次是直接调面板的函数。

## 没跑的（汇总）

- 真实的 Linux 电脑、真实的 x86_64 处理器、真实显卡、Omarchy 以外的桌面。
- 画笔和其他平台的图片逐像素对比。
- 真的睡眠（只跑过内核的测试模式）。
- 第二块显示器只用虚拟显示器测过；在两块屏之间拖动没有测。
- 后台服务、插件、管理窗口其余没跑的部分，见上面各节。
