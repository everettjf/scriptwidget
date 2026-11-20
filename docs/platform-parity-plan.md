# 各平台功能对齐：计划与进度

更新日期：2026-11-20。打勾的项按各自一节所写验证过；Windows 本轮的真实 DeepSeek 测试和本地回归见 [Windows 测试记录](windows/testing.md)，真机和桌面交互的未验部分单独列出。目标：同一个 Package 2.0 小组件在各平台能做的事尽量一样，创作工具（AI、Gallery、Skills）每个平台都有。什么在哪里能用，以 [Platform support](platform-support.md) 为准。

Windows 已在 Windows 11 x64 开发机开始对齐，当前工作树尚未发布，进度列在最后。

## 界面语言：只用英文（2026-11-19 的决定）

所有平台的应用界面、命令行、安装程序和网站只用英文，不做翻译，也不跟随系统语言。README 可以有其他语言。小组件自己画的文字不受影响。

查到的原状：iPhone、iPad 的中文翻译从 2026 年 1 月起就没有进应用；Mac 没有翻译；Android 只有 AI 对话一屏有中文（当天加的）；Windows 和 Linux 两个预览版有完整的中英两套。

- [x] iPhone、iPad、Mac：删掉全部 `zh-Hans.lproj` 和工程里的引用，保留英文的单复数表。
- [x] Android：删掉 `values-b+zh+Hans`；界面文字留在资源文件里，只有英文。
- [x] Linux：管理窗口的中文一列、语言选择、Omarchy 插件的 `zh-CN.json`。
- [x] Windows：管理窗口、桌面宿主、安装程序的中文。在 Mac 上改，没法在 Windows 上编译运行，要靠 CI 和之后在 Windows 电脑上验证。
- [x] 文档里“界面跟随系统语言”的说法和中文界面的截图。

留给所有者自己删的（2026-11-19 的决定）：

- [ ] Windows 商店（Partner Center）里的简体中文商品页。
- [ ] 仓库里两份中文的商店更新说明：`Resource/appstore/27.1.3/whats-new-zh-Hans.txt` 和 macstore 下对应的那份，以及 App Store Connect 里如果有的中文商品页。

没有动的：中文写的计划和测试记录。

## 在哪里验证

| 平台 | 在这台 Mac 上能做的 | 需要所有者的 |
| --- | --- | --- |
| iPhone、iPad | 模拟器、单元测试、把 iOS 应用当作“为 iPad 设计”的应用运行 | 真机 |
| Mac | 直接运行 | 无 |
| Android | 连着的 Pixel 6 和模拟器 | 其他厂商的手机；真实模型要所有者自己填密钥 |
| Linux | RiftVM 里的 Omarchy 4.5（aarch64），通过 SSH 编译、运行、截图、录屏 | 真实电脑和真实显卡；真实模型要所有者自己存密钥 |
| Windows | 不能 | 一台 Windows 11 电脑 |

## 第一步：Linux 的 AI 和动画（做完，没有提交）

- [x] **`animation` 属性在桌面上播放**。标准表针每秒或每分钟重画；摆动和自定义周期的表针做成一组帧，每 50 毫秒一帧，最多 60 帧，沿用播放 GIF 的机制，和 Omarchy 插件之间的协议没有改。周期超过 60 秒的动作改为每秒重画。
- [x] **AI 对话**：Android 的实现移植到 `sw-core`（`src/ai/`），有 `scriptwidget ai` 命令，管理窗口的编辑器旁有对话面板，设置页有服务商和密钥。密钥只进 Secret Service，不写进任何文件。
- [x] 在 RiftVM 的 Omarchy 4.5 上验证：全部测试 682 个通过；动画录屏逐帧测过；密钥对着真实的 gnome-keyring 存、读、删；命令行和管理窗口各用脚本模型走通一轮对话并应用。细节和没验证的部分见 [Linux 测试记录](linux/testing.md) 和 [Linux 待办](linux/TODO.md)。
- [x] 真实模型：2026-11-19 晚用 DeepSeek 在 Mac、Linux、Android 三端都跑过，结果在 [AI 对话计划](ai-conversation-plan.md) 里。
- [ ] 还差：打 0.1.5 的包。

## AI 功能的逐项对照（2026-11-19）

三套实现（Swift、Kotlin、Rust）的核心一致：每轮 4 次尝试、30 个版本、50 段对话、请求 4,000 字、发送最近 12 轮、编辑块的格式和失败提示、JSX 校验的文字、标签清单都相同。Android 和 Linux 的对话文件格式相同；Apple 的字段名和日期写法不同，三端的文件不能互换（没有打算互换）。

查到的差异，按平台列出要补的；做完的打勾。

**Apple（iPhone、iPad、Mac 共用的 Swift）**

- [x] **AI 请求会跟随重定向**，密钥可能被带到重定向的目标。Android 和 Linux 都拒绝。安全修正，要带回归测试。
- [x] 回复被长度上限截断时没有发现（Android、Linux 会让模型重写）；空回复、拒绝回答也没有单独处理。
- [x] 没有 Anthropic 的 Messages 接口（Android、Linux 的默认服务商）。
- [x] 密钥只做了去空白，没有长度和字符检查；错误摘要没有截到 600 字。
- [x] “Fixed automatically N times”、差异里的行数等几句是拼出来的，没法翻译。

**Android**

- [x] **提示词里“不支持”的清单过时**：说 `$health`、`$photos`、`$calendar`、`$location`、`$services`、`$notifications`、`$dataSource` 没有实现，参考里也去掉了相应的例子，而这些在 Android 上都有。
- [x] 修复提示里的日志行没有截到 300 字（文档说会截，Apple 截了）。
- [x] `widget.json` 读不出来时被当成旧式小组件，应当拒绝。
- [x] 重试是从当前版本接着来，应当先回到这一轮开始时的版本（Apple 是这样）。
- [x] 进度里“第 X 次，共 4 次”的 4 是写死的；设置里的“最多尝试次数”对对话不起作用。
- [x] 没有“修复运行错误”和日志页。
- [x] Skills 是全局开关，不是每段对话各选各的（Apple 是每段对话保存自己选的）。
- [x] AI 设置页等处的文字写死在代码里，搬进资源文件（只要英文）。
- [x] 流式请求在还没收到字之前断开，不会改用普通请求再试（Apple 会）。

**Linux**

- [x] 日志行截断、重试、“从这里另起一段”、接着一段草稿继续：核心里的函数都有，命令行和窗口没有接上。
- [x] 差异是和已保存的代码比，其他平台是和上一个版本比。
- [x] 管理窗口：设置页没有模型列表；对话面板不能前后翻版本、不能看三个尺寸；不能从一句话新建小组件，没有示例；没有“修复运行错误”。
- [x] Skills。

**三端要统一的数字**

- 一个新小组件最多声明几个联网主机：Apple 是 8 个、4 KB，Android 和 Linux 是 16 个、8 KiB。已统一到 Apple 的 8 个（更保守，也是文档写的）。
- 一轮里保留哪一句说明：统一为最后一句（第一句描述的可能是没能运行的那次尝试）。Swift 已改。

**有意保留的差别**（都在文档里写明）：Android 和 Linux 只接受 `https://`；Android 没有 OpenAI 登录；Apple 的私有云计算只在 Apple 上，尝试 3 次、不流式；`<list>` 只在 Android；各平台的提示词去掉本平台没有的 API；Linux 在试运行时会真的画出小组件，其他平台只生成元素树。

## 第二步：Linux 的创作工具

- [x] **Gallery**：目录校验、离线索引、事务安装在 `sw-core`，`scriptwidget gallery` 命令，管理窗口里的一页。信任的根地址、字节数和 SHA-256 校验与其他平台相同。
- [x] **Skills**：导入、列出、删除，生成时附加到提示词。只影响提示词，不给权限。
- [x] **管理窗口**：“新建文件”按钮、关闭时有未保存的修改要问。（组件和 API 两页 0.1.4 已经有了。）
- [x] **模板列表的过滤**：现在只读 `main.jsx`，会列出用不了的 “Local Weather (Location)”。

## 第三步：Linux 的数据 API

按“桌面上有没有对应的东西”分：

| API | 做法 | 状态 |
| --- | --- | --- |
| `$music` | MPRIS，通过 `busctl` | 做完，在虚拟机上用 mpv 看过 |
| `$notifications` | 桌面通知，通过 `busctl`，由后台服务发出 | 做完，在虚拟机上看过 |
| `$services`（GitHub） | 细粒度令牌，放 Secret Service，做法同 Android | 做完；没有用真实令牌试过 |
| `$documents`、`$photos` | 为每个小组件选的文件和图片 | 做完，在虚拟机上看过 |
| `$location` | GeoClue | 不做：Omarchy 4.5 不带 GeoClue |
| `$calendar`、`$contacts`、`$reminders`、`$health`、`$home`、`$alarms`、`$icloud`、`$maps` | 桌面上没有统一的来源，保持 `[unsupported_platform]` | 不做 |

每加一个 API：权限声明、拒绝时的错误、测试、平台支持表、Linux 的 README。

## 第四步：Android

- [x] **内置模板复制后联网失败**：在 Pixel 6 上复现并修掉，副本只声明自己脚本里写到的主机。没有提交。
- [x] **AI 生成知道 `<list>` 和 `material.` 颜色**：提示词里加了约 250 个 token 的一节。没有用真实模型试过。
- [x] **编辑器补全知道这两样**：补全编在和 iOS 共用的编辑器包里，要改 `Editor/editorfe`（加一份只有 Android 桥接脚本会给的清单）并重新生成两个包。
- [x] **对话界面的文字搬进了资源文件**，只有英文。
- [ ] `$maps.snapshot`：待定，要先看有没有不依赖 Google 的做法（`foss` 版不能带 Google 的库）。
- 不做：`$reminders`（Android 没有系统级的提醒事项）、`$home`。

## 第五步：iPhone、iPad、Mac

- [x] **`<list>` 的降级**：现在显示成未知标签。改为画出放得下的前几行，不能滚动。这是往运行时里加东西，不改已有的含义；要同时改网页预览。
- [x] **`material.<role>` 颜色的降级**（Windows 和 Linux 也用同一张固定色板）：现在被忽略。改为用清单里定好的一组固定颜色。
- [x] “Fixed automatically N times” 等几句改成了正确的英文单复数（不做翻译）。

## 所有平台共有

- [ ] **线性渐变缺少方向时只显示第一种颜色**：要不要给缺省方向，需要所有者决定，因为会改变已有小组件的画面。
- [ ] **每轮固定发送约 12,000 个 token** 的提示词。
- [ ] **Linux 的画面没有和其他平台逐像素比过**。
- [ ] **六种展示字体的许可**：Linux 不带；其他平台也没有记录许可。需要所有者决定。

## 留给 Windows 电脑的

2026-11-20：AI 核心、CLI、编辑器对话面板和服务商设置、Gallery、Skills、桌面动画均已实现。真实 DeepSeek 跑过生成、多轮修改、已有错误代码的修复、保存和三个尺寸渲染；还测过保留未应用草稿、拒绝覆盖手工修改、重开后继续最新手工源码。模型密钥存 Windows Credential Locker。共享 JSX 清单生成器增加 C# 输出，模板过滤和不支持 API 的提示词共用一份名单。完整 Release Core 回归 375 项全部通过，无跳过。

新 AI 界面的实际操作在锁屏处暂停，未记为通过。AOT 安装包、安装器及桌面压力检查的最终结果见 [Windows 测试记录](windows/testing.md)。ARM64 真机、混合 DPI、真实登录恢复和 Store 签名安装仍需对应环境。`$music`、`$notifications`、`$location` 继续保持不支持，不属于这次创作工具对齐。详见 [Windows to-do](windows/TODO.md)。

## 顺序的理由

先把 Linux 做完，是因为它离其他平台最远，而且虚拟机就在这台电脑上，每一步都能实际看到。Android 的几项小，可以和 Linux 同时做，文件不重叠。Apple 那边的两项降级要动公开的运行时，放在后面，改之前先写清楚兼容性。
