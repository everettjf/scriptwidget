# Omarchy 桌面 Widgets 截图研究

**日期：** 2026-08-29  
**对象：** Reddit 帖子“Desktop widgets”及所附截图  
**结论：** 图中帖子展示的是 Omarchy/Hyprland 上仿 macOS 风格的桌面卡片，不是 macOS 桌面。Omarchy 4 的 Quickshell 插件架构有能力实现这种界面，但原帖截至研究时没有公开、可核实的代码仓库或安装方法，因此不能把图中整套卡片视为 Omarchy 自带功能或现成可安装插件。

## 1. 截图到底是什么

整张图片的外层是手机上的 Reddit 页面：顶部有 iPhone 状态栏、返回 `rednote`、Reddit 帖子标题和广告。帖子内嵌的横向大图才是作者的电脑桌面。

内嵌桌面图具有 Omarchy/Hyprland 的典型结构：横向超宽桌面、顶部细状态栏、主题化壁纸，以及左侧独立的信息卡片。发帖者原文明确称它们为“Macos style desktop widgets but with omarchy theming”，意思是“macOS 风格、Omarchy 主题”，而不是说系统是 macOS。原帖评论中，作者还把行为描述成旧 macOS Dashboard 那种位于独立屏幕/工作区上的组件。[Reddit 原帖](https://www.reddit.com/r/omarchy/comments/1w1hy2o/desktop_widgets/)

## 2. Omarchy 是否支持

### 能力层面：支持实现

Omarchy 4 把桌面 shell 统一到一个长期运行的 Quickshell 进程。官方插件类型包括 `panel`（常驻或召出的浮动窗口）和 `overlay`（全屏覆盖层），因此可以用 QML/Quickshell 做桌面卡片、仪表盘或独立 workspace 面板。[Omarchy Shell Plugins 手册](https://omarchy.org/manual/shell-plugins/)

社区现成的 OmaClock 已经证明可以把 Quickshell 组件放在 Wayland bottom layer，显示在所有应用窗口之后，并跟随 Omarchy 主题颜色。这证明“壁纸上方、普通窗口下方、可点击穿透”的桌面 widget 路径是可行的。[OmaClock 项目页](https://omahub.dev/plugins/ubeyidah.omaclock)

### 产品层面：图中整套并非官方默认功能

Omarchy 官方默认 widgets 主要指顶栏中的时钟、天气、音频、网络、蓝牙、电源、媒体等组件。官方文档把顶栏称为默认持续显示的 UI，并给出了插件启用和重排方法；这与图中左侧的大号桌面卡片不是同一类默认产品。[Omarchy Top Bar 手册](https://omarchy.org/manual/the-top-bar/)

原帖发布于 2026-08-29。研究时可见的帖子正文和评论只展示效果、征求意见，并没有 GitHub 仓库、插件 ID、安装命令或版本说明。因此最稳妥的判断是：这是作者的原型或私人配置展示；它可能已经在作者机器上运行，但尚无足够证据证明公众能直接安装同一套组件。

## 3. 与 macOS WidgetKit / ScriptWidget 的关系

这不是 Apple WidgetKit widget，也不能把 `.widget`、iOS/macOS 小组件或 ScriptWidget 包直接复制到 Omarchy 运行。两边的渲染和宿主体系不同：

- macOS/iOS 使用 Apple 的 WidgetKit/SwiftUI 及系统时间线模型；
- Omarchy 4 的 shell 插件使用 QML/Quickshell，并通过 Wayland/Hyprland 显示；
- 图中“macOS style”只描述视觉布局和交互灵感，不代表二进制或 API 兼容。

若要把 ScriptWidget 的 JavaScript/JSX 小组件带到 Omarchy，需要另做 Linux 宿主：重建 JSX 映射、数据 API、权限模型、刷新机制和 Wayland 窗口层。它不是主题适配就能完成的移植。

## 4. 实际使用建议

1. 若只是想要类似效果，Omarchy 4 是合适的底座；优先找明确支持 Omarchy 4/Quickshell 的 `panel` 或 `overlay` 插件。
2. 若想要图中完全相同的一组卡片，应等待原作者发布仓库或直接询问原作者；目前没有可信的一键安装路径。
3. 安装任何第三方 Omarchy 插件前先看源码。官方手册明确提示：插件作为任意、未沙箱化代码运行在长期存活的 shell 进程中，可访问当前用户能访问的资源。[Omarchy Shell Plugins 安全说明](https://omarchy.org/manual/shell-plugins/)
4. 多显示器、缩放、点击穿透、窗口层级和 workspace 绑定是最可能踩坑的部分。社区 OmaClock 曾遇到透明全屏层阻挡桌面点击的问题，需用空输入区域修复；这说明同类实现不是单纯“画几个卡片”。[OmaClock 故障说明](https://omahub.dev/plugins/ubeyidah.omaclock)

## 5. 置信度与限制

- **高置信度：** 外层是手机 Reddit 截图；内层是 Omarchy 风格的 Linux 桌面；Omarchy 4 技术上支持此类 Quickshell 桌面组件；它不兼容 Apple WidgetKit/ScriptWidget 包。
- **中等置信度：** 图中是实际运行的作者原型，而不是纯图片 mockup。依据是帖子标签“I Made a Thing”和作者对组件行为的回答，但没有源码或视频可独立验证交互。
- **高置信度：** 截至 2026-08-29 检索时，没有从原帖发现图中整套组件的公开安装入口。

## 主要来源

- [Reddit：Desktop widgets](https://www.reddit.com/r/omarchy/comments/1w1hy2o/desktop_widgets/)，u/StayLarge，2026-08-29。
- [Omarchy Manual：Shell Plugins](https://omarchy.org/manual/shell-plugins/)，访问于 2026-08-29。
- [Omarchy Manual：The Top Bar](https://omarchy.org/manual/the-top-bar/)，访问于 2026-08-29。
- [Omahub：OmaClock](https://omahub.dev/plugins/ubeyidah.omaclock)，访问于 2026-08-29。
