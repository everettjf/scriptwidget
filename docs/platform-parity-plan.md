# 各平台功能对齐：计划与进度

更新日期：2026-11-19。目标：同一个 Package 2.0 小组件在 iPhone、iPad、Mac、Android、Linux 上能做的事尽量一样，创作工具（AI、Gallery、Skills）每个平台都有。什么在哪里能用，以 [Platform support](platform-support.md) 为准；这一页只写还要做什么、按什么顺序、在哪里验证。

Windows 不在这一轮：要在 Windows 电脑上做，条目列在最后。

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
- [ ] 还差：真实模型（要所有者自己在虚拟机里存密钥）；打 0.1.5 的包。

## 第二步：Linux 的创作工具

- [ ] **Gallery**：目录校验、离线索引、事务安装在 `sw-core`，`scriptwidget gallery` 命令，管理窗口里的一页。信任的根地址、字节数和 SHA-256 校验与其他平台相同。
- [ ] **Skills**：导入、列出、删除，生成时附加到提示词。只影响提示词，不给权限。
- [ ] **管理窗口**：“新建文件”按钮、关闭时有未保存的修改要问。（组件和 API 两页 0.1.4 已经有了。）
- [ ] **模板列表的过滤**：现在只读 `main.jsx`，会列出用不了的 “Local Weather (Location)”。

## 第三步：Linux 的数据 API

按“桌面上有没有对应的东西”分：

| API | 做法 | 状态 |
| --- | --- | --- |
| `$music` | MPRIS（D-Bus） | 已在计划里，没开始 |
| `$notifications` | 桌面通知（D-Bus） | 已在计划里，没开始 |
| `$services`（GitHub） | 细粒度令牌，放 Secret Service，做法同 Android | 没开始 |
| `$documents`、`$photos` | 用户在管理窗口里选的文件，做法同 Android | 没开始 |
| `$location` | GeoClue；要用户同意，先查 Omarchy 上有没有 | 待查 |
| `$calendar`、`$contacts`、`$reminders`、`$health`、`$home`、`$alarms`、`$icloud`、`$maps` | 桌面上没有统一的来源，保持 `[unsupported_platform]` | 不做 |

每加一个 API：权限声明、拒绝时的错误、测试、平台支持表、Linux 的 README。

## 第四步：Android

- [x] **内置模板复制后联网失败**：在 Pixel 6 上复现并修掉，副本只声明自己脚本里写到的主机。没有提交。
- [x] **AI 生成知道 `<list>` 和 `material.` 颜色**：提示词里加了约 250 个 token 的一节。没有用真实模型试过。
- [ ] **编辑器补全知道这两样**：补全编在和 iOS 共用的编辑器包里，要改 `Editor/editorfe`（加一份只有 Android 桥接脚本会给的清单）并重新生成两个包。
- [x] **对话界面的中文**：文字搬进了资源文件，有英文和简体中文。中文界面没有在手机上看过。
- [ ] `$maps.snapshot`：待定，要先看有没有不依赖 Google 的做法（`foss` 版不能带 Google 的库）。
- 不做：`$reminders`（Android 没有系统级的提醒事项）、`$home`。

## 第五步：iPhone、iPad、Mac

- [ ] **`<list>` 的降级**：现在显示成未知标签。改为画出放得下的前几行，不能滚动。这是往运行时里加东西，不改已有的含义；要同时改网页预览。
- [ ] **`material.<role>` 颜色的降级**：现在被忽略。改为用清单里定好的一组固定颜色。
- [ ] **Mac 的界面没有本地化**：先加语言和字符串文件，从 AI 对话开始。
- [ ] iPhone 上 “Fixed automatically N times” 一句。

## 所有平台共有

- [ ] **线性渐变缺少方向时只显示第一种颜色**：要不要给缺省方向，需要所有者决定，因为会改变已有小组件的画面。
- [ ] **每轮固定发送约 12,000 个 token** 的提示词。
- [ ] **Linux 的画面没有和其他平台逐像素比过**。
- [ ] **六种展示字体的许可**：Linux 不带；其他平台也没有记录许可。需要所有者决定。

## 留给 Windows 电脑的

AI 生成、Gallery、Skills；`<gif>` 和 `animation` 的播放（渲染器已经给出位置，Linux 的 `sw-render/src/motion.rs` 可以照着移植）；`$music`、`$notifications`、`$location`；内置模板过滤；商店认证的结果。详见 [Windows to-do](windows/TODO.md)。

## 顺序的理由

先把 Linux 做完，是因为它离其他平台最远，而且虚拟机就在这台电脑上，每一步都能实际看到。Android 的几项小，可以和 Linux 同时做，文件不重叠。Apple 那边的两项降级要动公开的运行时，放在后面，改之前先写清楚兼容性。
