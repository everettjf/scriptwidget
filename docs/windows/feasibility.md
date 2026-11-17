# Windows 版值得做，但要排在共用核心之后

ScriptWidget 值得做 Windows 版，但不应作为一个独立的新项目立刻开工：建议先把 Linux 计划里的 Rust 核心（QuickJS 宿主、共用渲染器、画笔、命令行）做出来，再让 Windows 成为这套核心的第二个展示端，并且排在 Omarchy 插件之前。理由有三条。第一，Windows 11 的官方小组件面板只接受 Adaptive Card，不能自绘，也没有任何官方的"桌面小组件"位置，所以主形态只能是自己画的桌面窗口，官方面板最多作为附加出口。第二，桌面小组件的需求是真实的（Rainmeter 最近 100 个版本累计下载 7,566 万次，Windows 11 设备超过 10 亿台），而"普通人能写脚本、能安全安装别人的小组件、还能带到手机上"这个位置目前没有成规模的产品占着。第三，对一位在中国的个人开发者，微软商店的 MSIX 是唯一不花钱、不弹警告的分发方式：注册免费，微软代为签名和托管；商店之外的签名服务 Artifact Signing 不对中国的个人或公司开放。最大的不确定性集中在三处：Rust 文字渲染在 Windows 字体上的保真度、桌面窗口在 Win+D 等场景下的行为、以及官方面板能否接受位图。这三处都没有在 Windows 真机上验证过，本报告的全部结论都以一轮 1 到 2 周的原型为前提。

状态：调研稿，2026-11-16。**调研之后的决定（同日）**：先做 Windows，用 C++ 加 Direct2D 和 DirectWrite，Linux 搁置；因此本文"先做与 Linux 共用的 Rust 核心"的建议不再采用，其余事实和待验证事项仍然有效。现行计划见 [Windows 开发计划](plan.md)。对比的背景是 [Linux（Omarchy）开发计划](../linux/plan.md)；四份原始调研笔记（英文）在 [notes/](notes/) 下：[官方小组件平台](notes/official_widget_platform.md)、[竞品与市场](notes/competitors_and_market.md)、[分发与签名](notes/distribution_and_signing.md)、[技术路线](notes/technical_route.md)。

标注约定沿用 Linux 计划：**[已核实]** 指调研时直接读到官方页面、项目源码或本仓库文件；**[二手]** 指媒体、论坛、第三方估算或只看到搜索摘要；**[待验证]** 指没有可靠来源，或必须在 Windows 真机上做原型才能确认。调研日期为 2026-11-16，期间没有在任何 Windows 机器上运行过代码。

## 官方面板只收 Adaptive Card，桌面上没有官方位置

Windows 11 的官方小组件出现在三个地方：从任务栏打开的小组件面板（Widgets Board）、锁屏、任务栏按钮本身。**没有任何官方机制把小组件放在桌面上** [已核实]（[Windows Widgets overview](https://learn.microsoft.com/en-us/windows/apps/design/widgets/)）。到 2026 年 11 月为止的 Insider 版本说明里只看到面板内部的多仪表盘和导航栏（[Build 27982](http://blogs.windows.com/windows-insider/2025/11/04/announcing-windows-11-insider-preview-build-27982-canary-channel/)），没有桌面放置的迹象；这是"没找到证据"，不是微软的否定声明。

第三方接入只有两条路：打包的 Win32 应用实现 `IWidgetProvider`（进程外 COM 服务，在 MSIX 清单里注册），或者 PWA。**必须有包身份，未打包的应用不能注册小组件** [已核实]（[Widget providers](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-providers)、[清单格式](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-provider-manifest)）。对 ScriptWidget 影响最大的限制有四条，全部来自微软文档。

其一，渲染模型。在欧洲经济区之外，小组件就是一份 Adaptive Card 模板加一份 JSON 数据，由宿主用自己的控件和 Segoe UI 字体渲染；没有自绘、自定义字体、自由变换或动画的接口。能显示任意画面的只有 `Image` 和 `backgroundImage`。HTML 形式的"web widget"从 Windows App SDK 1.6.3 起存在，但文档明确写着**只对欧洲经济区用户开放**（[Web widget providers](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/web-widget-providers)）。因此全球可用的做法和 Android 版一样：把元素树画成位图，作为整幅图片放进卡片。这是推断，官方示例里的图片全部是 HTTPS 地址；`data:` 地址能否使用只有一个社区示例支持 [二手]（[tutorialr/windows-widget-workshop](https://github.com/tutorialr/windows-widget-workshop)），微软没有公布载荷大小上限、图片格式或尺寸限制 [待验证]。

其二，不能动态创建小组件定义，也不能替用户固定小组件。`WidgetManager` 的说明是"只能对已存在的小组件操作"，定义是包清单里的静态条目（[WidgetManager](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.windows.widgets.providers.widgetmanager)）。可行的替代是声明一个通用的"脚本小组件"定义，`AllowMultiple` 为真并开启自定义，每个实例通过设置卡片和 `CustomState` 绑定到一个用户脚本；代价是面板的选择器里看不到每个脚本自己的名字、图标和截图。这是推断，需要原型确认 [待验证]。

其三，尺寸和交互。只有 small、medium、large 三种尺寸，宽度固定 300 像素，官方只给出了 medium 的高度 304 像素（[选择器截图规范](https://learn.microsoft.com/en-us/windows/apps/design/widgets/widgets-picker-integration)）。交互只有 `Action.Execute` 和 `Action.OpenUrl`，建议的可点击点数是小 1 个、中 3 个、大 4 个（[交互设计](https://learn.microsoft.com/en-us/windows/apps/design/widgets/widgets-interaction-design)）。Adaptive Card 没有绝对定位，所以一张位图上的任意点击区域无法表达，按钮只能退化成图片下方的原生按钮行，或者整卡一个点击动作。

其四，刷新由提供方自己负责。宿主可以随时激活和释放提供方进程，不替它安排定时刷新；微软没有公布刷新频率、载荷、内存的任何数字上限（[C# 教程](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/implement-widget-provider-cs)）。锁屏方面，声明了 small 尺寸的第三方小组件可以被用户加到锁屏（[微软支持页](https://support.microsoft.com/en-US/Windows/Experience/Personalization/customize-the-lock-screen-in-windows)），但锁屏上按钮是否可用，文档和 2025 年的媒体描述互相矛盾 [待验证]。

微软对这个平台的态度是维护而不扩张。2026 年的改动是"默认安静"：悬停不再自动打开、任务栏角标默认关闭、面板首次打开显示小组件而不是新闻流（[Build 26220.8680 说明](https://learn.microsoft.com/en-us/windows-insider/release-notes/beta/preview-build-26220-8680)）。开发者文档在 2026 年 10 月下旬全部修订过，没有废弃迹象；但面向全球的渲染契约自 2022 至 2023 年以来没有变过，更丰富的能力仍是欧洲经济区专属。没有找到面板的使用量数据，媒体的评价是第三方小组件很少 [二手]（[Windows Central](https://www.windowscentral.com/microsoft/windows-11/microsoft-build-ignored-the-most-barren-part-of-windows-11-and-its-one-only-third-party-developers-can-fix)）。

结论很直接：官方面板撑不起 ScriptWidget 的卖点（渐变、旋转、阴影、自定义字体、按位置点击），只适合做一个保真度打折的附加出口。主形态必须是自己的桌面窗口，而桌面窗口不需要包身份，也不受上述任何限制。

## 需求都在桌面上，"可编程且安全"的位置空着

Windows 桌面小组件的产品分成三类，彼此几乎不重叠。下表的数字除注明外都是 2026-11-16 直接从 GitHub、微软商店（美国区）和 Steam 的公开接口读到的 [已核实]；SteamSpy 的拥有者数量是估算 [二手]。

| 类别 | 代表产品 | 创作方式 | 沙箱与权限 | 规模指标 |
| --- | --- | --- | --- | --- |
| 老牌皮肤引擎 | [Rainmeter](https://github.com/rainmeter/rainmeter) | INI、Lua、原生插件 DLL | 无；皮肤可执行命令 | 6,153 星；最近 100 个版本累计下载 7,566 万次（含更新重复下载） |
| 现成小组件 | [Widget Launcher](https://apps.microsoft.com/detail/9wzdncrdqfbt)、[BeWidgets](https://apps.microsoft.com/detail/9nq07fg50h2q)、[DeskBox](https://github.com/Tianyu199509/DeskBox) | 用户不能编程 | 商店打包或无说明 | 商店评分数 5,262 和 1,788；DeskBox 创建 5 个月 9,237 星 |
| 网页技术外壳 | [Seelen UI](https://github.com/eythaann/Seelen-UI)、[Zebar](https://github.com/glzr-io/zebar)、[YASB](https://github.com/amnweb/yasb) | HTML/CSS/JS 或 YAML 加 Python | 没有成文的按小组件权限模型 | 18,529 星、3,126 星（累计下载约 9.1 万）、5,804 星 |
| 壁纸引擎（相邻品类） | [Wallpaper Engine](https://steamspy.com/app/431960)、[Lively](https://github.com/rocksdanister/lively) | 场景、视频、网页 | 本次未查清 | 估算 2,000 万到 5,000 万拥有者；Lively 商店评分数 19,230 |

从这张表能读出三件事。第一，**用户量最大的产品要么不能编程（Wallpaper Engine、Widget Launcher），要么能编程但不安全（Rainmeter）**。Rainmeter 带插件的皮肤包里可以有原生 DLL，有安全厂商报告过恶意皮肤包 [二手]（[Gridinsoft](https://blog.gridinsoft.com/rainmeter-virus/)）。有声明式权限清单、能放心安装别人作品的产品，在有规模的玩家里没有找到。第二，需求在上升而且新进入者押的是"好看的现成小组件"：DeskBox 五个月九千多星，Steam 上有三款小组件应用排队待发布（[DeskDash](https://store.steampowered.com/app/5385210)、[Wisp](https://store.steampowered.com/app/5265790)、[Widget Engine](https://store.steampowered.com/app/5325820)），媒体把"小组件固定在桌面上、没有新闻流"称为 Windows 11 小组件本该有的样子 [二手]（[Beebom](https://beebom.com/bewidgets-is-what-windows-11-widgets-should-be)）。第三，用网页技术写小组件的人群集中在平铺窗口管理器的圈子里，技术水平高但绝对数量小。

"同一个小组件也能在手机上运行"这个位置没有找到成规模的占位者。最接近的是面向应用开发者的库 [tauri-plugin-widgets](https://docs.rs/tauri-plugin-widgets)（一份 JSON 配置在各平台分别渲染，不是给终端用户的工具）[二手]，以及 Wallpaper Engine 的 Android 伴侣应用（壁纸而非小组件，第三方估算安装量九百多万 [二手]，[AppGoblin](https://appgoblin.info/apps/io.wallpaperengine.weclient)）。这个结论建立在"搜索没有找到"之上，小型或非英语项目不排除存在。

市场基数方面，微软在 2026 财年第二季度财报电话会上确认 Windows 11 运行在超过 10 亿台设备上 [二手，媒体转述]（[TechSpot](https://www.techspot.com/news/111114-windows-11-hits-one-billion-users-less-time.html)）。手机与电脑的搭配只有老数据：2019 年美国的一项调查里 63% 的 iOS 用户使用 Windows 电脑 [二手]（[AskWonder](https://start.askwonder.com/insights/apple-phone-consumers-use-windows-computers-xoa0ly0n6)）。这个数字陈旧且只覆盖美国，只能说明"Windows 电脑加手机"是常见组合而非小众，不能用来估算用户数。

变现要保守看待。这个品类里唯一确知卖得动的是 Wallpaper Engine（Steam 上 4.99 美元一次性购买，靠极大的规模和创意工坊）；同样在 Steam 上卖 3.99 美元、支持 JS 和 Lua 的小组件构建工具 [Infinite Widgets](https://store.steampowered.com/app/1743370) 只落在 SteamSpy 最低一档（0 到 2 万拥有者，估算 [二手]）。其余产品是免费开源加捐赠，或商店里免费加内购；Seelen UI 是第一个尝试订阅的（[Seelen Sky](https://seelen.io/sky)）。没有任何产品公布过收入。**Windows 版更合理的定位是免费的入口，收入继续来自已有的手机和 Mac 应用**，而不是指望 Windows 本身卖钱。

## 微软商店的 MSIX 是中国个人开发者唯一零成本、零警告的路

分发问题的核心是签名，而签名这件事对中国的个人开发者只剩一个好选项。

**商店路线。** 从 storedeveloper.microsoft.com 进入的新注册流程对个人和公司账号都免费，个人用政府证件加自拍验证 [已核实]（[Open a developer account](https://learn.microsoft.com/en-us/windows/apps/publish/partner-center/open-a-developer-account)，页面日期 2026-10-29）。提交 MSIX 时不需要任何证书：商店在认证通过后用微软的证书重新签名并免费托管和更新（[MSIX 包要求](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/app-package-requirements)）。认证"最多三个工作日"（[认证流程](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/app-certification-process)）。非游戏的 PC 应用可以用自己的支付系统并保留全部收入，或者用微软的商务平台付 15%（[商店收益说明](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/why-distribute-through-store)；该页最后更新于 2024 年，本次没有读开发者协议原文）。而以 EXE 或 MSI 形式上架商店则仍然要自己买证书签名、自己托管，解决不了问题。

**商店之外。** 微软推荐的签名服务 Artifact Signing（原 Trusted Signing，每月 9.99 美元起）的公共信任证书，**个人开发者必须位于美国或加拿大，组织的可用国家列表里也没有中国** [已核实]（[Artifact Signing quickstart](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart)，页面更新于 2026-10-08）。剩下的是传统证书机构的 OV 或个人验证证书：转售商标价约每年 219 美元起 [二手]（[SSL Dragon](https://www.ssldragon.com/ssl-certificates/code-signing/)），私钥必须放在硬件令牌或云 HSM 里，而且微软明确说 EV 证书已经不再让 SmartScreen 直接放行，信誉要靠"数周时间和数百次干净安装"积累 [已核实]（[SmartScreen reputation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)）。不签名的后果更重：每个新版本都会弹"Windows 已保护你的电脑"，在开启了 Smart App Control 的 Windows 11 上，没有正面信誉的未签名文件会被直接阻止执行（同一页面）。中国大陆个人能否通过证书机构的个人验证，本次没有查 [待验证]。

**政策对"运行脚本的应用"怎么说。** 现行版本是 Microsoft Store Policies 7.20（2026-10-22 生效）[已核实]（[Store Policies](https://learn.microsoft.com/en-us/windows/apps/publish/store-policies)）。全文没有禁止解释器的条款；管这件事的是 10.2.2：不得通过动态引入代码来改变或扩展产品**所描述的**功能，或引入违反政策的功能。由此推断，只要商店描述里写清楚"在沙箱解释器里运行用户编写和从 Gallery 下载的 JavaScript/JSX 小组件"，并在认证备注里说明权限清单、域名声明、不加载原生代码，就与条文一致。这是对条文的解读，没有找到微软针对内嵌 JS 引擎的官方澄清或先例 [待验证]。另外三条需要提前准备：内置的 AI 生成功能属于 11.16 的"实时生成式 AI 内容"，要在元数据和提交时披露并提供举报入口；如果将来允许用户互相发布小组件，会触发 11.12 的用户生成内容要求（条款、举报、下架）；10.8.3 规定个人账号的产品不能以要求用户输入"API 密钥"等财务信息作为主要功能，可选的 AI 服务商密钥大概率不算主要功能，但这同样是解读。

**账号类型要在第一次提交前想清楚。** 政策 10.14 和注册页都把个人账号定位于"与其业务、行业或职业无关"的分发，同时又说个人账号"通常适合独自工作的单个开发者"；而个人账号不能转成公司账号。一个卖付费升级的独立开发者处在模糊地带。结合上一节的变现判断，最省事的组合是：个人账号、Windows 版免费、不使用微软商务平台。这样也绕开了 2026 年论坛上中国个人开发者反映的两个故障点，即创建中国银行收款资料时页面报错、以及注册后迟迟不出现合作伙伴 ID [二手，个例]（[Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/6043914/partner-center-creating-a-payout-profile-always-fa)、[Q&A](https://learn.microsoft.com/en-ie/answers/questions/6046218/individual-developer-enrollment-not-created-no-par)）。微软的博客说身份验证"在所有市场可用"，但没有找到确认中国大陆在新流程下可注册的现行官方列表，证件类型也没有说明。**注册本身就是第一个要实际去试的事项**，而且不花钱。

**其他渠道。** winget 接受指向发布者自己 HTTPS 地址的清单，提交页没有把签名列为要求，但每个提交都要过多引擎杀毒扫描，一个未签名、内嵌解释器又会联网的二进制有被误报的风险 [已核实要求，风险为推断]（[winget 提交说明](https://learn.microsoft.com/en-us/windows/package-manager/package/repository)）。Steam 每个产品收 100 美元，官方列出的非游戏软件类别里没有"工具"或"桌面定制"（[Steamworks](https://partner.steamgames.com/doc/gettingstarted/onboarding)）；Wallpaper Engine 的存在说明实际尺度比列表宽，但这不是可以依赖的承诺。建议第一版只走商店，GitHub Releases 上同时放命令行二进制给开发者用户。

**在 Apple 芯片 Mac 上开发是可行的，但有边界。** Parallels Desktop 是微软唯一授权在 Apple 芯片上运行 Windows 11 Arm 的方案 [已核实，厂商页面]（[Parallels](https://www.parallels.com/products/desktop/microsoft-authorized-solution-windows-11-arm/)）；虚拟机里没有嵌套虚拟化，所以 Windows 沙盒、WSL2 用不了（[微软支持页](https://support.microsoft.com/ja-jp/windows/-cd15fd62-9b34-4b78-b0bc-121baa3c568c)）。发布构建放在 GitHub Actions 上更合适：`windows-11-arm` 运行器对公开仓库免费（[GitHub Changelog](https://github.blog/changelog/2025-04-14-windows-arm64-hosted-runners-now-available-in-public-preview/)），走商店路线时 CI 里不需要存放任何签名密钥。Rust 可以用 `cargo-xwin` 从 macOS 交叉编译到 MSVC 目标 [二手]（[cargo-xwin](https://pypi.org/project/cargo-xwin)），WinUI 3 则不能在 macOS 上构建 [二手]。小组件面板在 Arm 虚拟机里是否完整可用、HDR、混合 DPI 多显示器、现代待机这几项，虚拟机替代不了真机 [待验证]。这里有一个值得注意的对比：Omarchy 插件需要一台 x86 的 Omarchy 4 机器，现有的 Mac 完全验证不了；Windows 的大部分原型反而可以在现有 Mac 的虚拟机里做。

## 技术路线：只贴位图的常驻宿主，加一套与 Linux 共用的 Rust 核心

推荐的架构是把 Android 已经上线、Linux 计划已经选定的"元素树画成位图加点击区域"原样搬到 Windows，分成四块。

**一个共用的 Rust 核心。** 用仓库里已有的 QuickJS-NG 0.18.0 源码编译，运行共用的 `kernel.js` 和渲染器，由 Rust 画笔输出 BGRA 位图和点击区域表。让同一个包行为一致的东西已经全部是与平台无关的 JavaScript 和 C，并且已经在 Android 上脱离浏览器运行：`Web/preview-engine/src/kernel.js` 只通过 `host` 对象接触平台，渲染器只通过注入的 `measurer` 取文字度量，164 棵一致性树可以直接当验收门槛 [已核实，本仓库]。不能复用的大件只有一个：约 1,400 行绑定 `android.graphics` 的 Kotlin 画笔，需要用 Rust 重写一次，Linux 和 Windows 共用。`Intl` 在 Windows 上有现成的落点：系统从 Windows 10 1903 起自带 `icu.dll` 的 C 接口，导出的函数族和 Android 宿主实现的 `Intl` 子集一一对应 [已核实]（[ICU on Windows](https://learn.microsoft.com/en-us/windows/win32/intl/international-components-for-unicode--icu-)）；它能否通过 Android 那套 `Intl` 测试未验证 [待验证]。一个已知的小风险是 rquickjs 把 Windows MSVC 目标标为"实验性"（[rquickjs README](https://github.com/DelSkayn/rquickjs)）；Android 的 JNI 胶水只有 336 行，直接对仓库里的 C 源码写一层薄 FFI 就能绕开，还能保证三端引擎源码相同。

**一个很小的常驻宿主。** 托盘图标加若干置底的分层窗口，只负责贴位图和把点击转成一个数字发回核心，由核心从自己保存的动作表里解析，规则与 Android 列表行、Linux 的 socket 相同。置底方式应当学 Rainmeter 而不是 Lively。Windows 11 24H2 在一个服务更新（26100.2454）里重排了桌面外壳的窗口层级，把两种做法都弄坏过：Lively 的"挂到 WorkerW 下面"需要重写挂载逻辑，Rainmeter 的"顶层窗口保持在最底、检测到显示桌面再抬起来"需要重写 Win+D 检测 [已核实，两个项目的源码]（[Lively WinDesktopCore.cs](https://raw.githubusercontent.com/rocksdanister/lively/core-separation/src/Lively/Lively/Core/WinDesktopCore.cs)、[Rainmeter System.cpp](https://raw.githubusercontent.com/rainmeter/rainmeter/master/Library/System.cpp)）。小组件要在图标之上并能接收点击，适合后一种。但它依赖未公开的窗口类名和轮询式的启发判断，**每次 Windows 功能更新都可能再坏一次**，宿主需要启动自检和"退化成普通窗口"的兜底。这是 Windows 版长期维护成本里最确定的一项。具体窗口样式组合的行为来自记忆而非本次读到的文档 [待验证]。

**一个 MSIX 包。** 提供开机自启（打包的桌面应用使用 `StartupTask` 不弹同意框，用户可在设置里关闭 [已核实]，[StartupTask](https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.startuptask)）、`scriptwidget://` 协议和 `.swt` 文件关联，以及可选的官方面板提供方，复用同一条位图管线。在 Rust 里实现 `IWidgetProvider` 没有找到先例，文档只有 C++/WinRT 和 C# 两条路 [待验证]。

**一个按需打开的管理窗口。** 与 Omarchy 用户不同，Windows 用户和商店审核都预期有图形界面。最省的做法是把现有的 Web Studio（`Web/studio/`）放进一个用时创建、关掉即销毁的网页视图里，可以用 Tauri，也可以直接用 WebView2。

**为什么不让 WebView2 全天运行。** 用 WebView2 直接跑浏览器渲染器，画面与 Web Studio 预览天然一致，新代码最少，中日韩文字和表情也不用操心，这是它实打实的优势。但它与本产品的模型不合：每个用户数据目录常驻一组 Chromium 进程（浏览器、GPU、渲染进程），微软不提供内存数字；持续运行的应用会停在旧版运行时上直到释放环境 [已核实]（[Process model](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/process-model)、[Distribution](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution)）；脚本会跑在 V8 上，成为要保持一致的第三个引擎；并且与 Linux 只能共用 JavaScript。ScriptWidget 的小组件是时间线快照而不是活的网页，位图宿主更贴合。WebView2 保留为备选：如果 Rust 文字渲染和 DirectWrite 后备都过不了保真度门槛，或者测得单个隐藏 WebView2 的空闲占用可以接受，再换。

**沙箱可以分层推后。** 第一版依靠 QuickJS 的内存上限、栈上限和中断回调，以及引擎不暴露任何系统接口，与 Android 和 Linux 第一版相同。之后可以把执行脚本和画笔的子进程放进作业对象，再套一个零能力的 LPAC 令牌，所有文件、存储、网络由宿主代理；AppContainer 不要求应用本身打包 [已核实]（[Launch an AppContainer](https://learn.microsoft.com/en-us/windows/win32/secauthz/implementing-an-appcontainer)）。LPAC 子进程能否加载系统字体和 ICU 数据未验证 [待验证]。安全不变量照搬，但 Windows 的路径规范化要多覆盖一批情况：盘符、UNC 路径、`CON` 这类保留名、备用数据流、结尾的点和空格、8.3 短名，每条都要有测试。私有地址拒绝要放在自己的 HTTP 客户端里，在 DNS 解析之后、每一跳重定向上都检查。

**发到手机在 Windows 上要换方向。** Linux 计划是电脑临时开一个局域网下载、手机扫码来取。在 Windows 上，监听端口会遇到防火墙首次提示，新 Wi-Fi 默认归为"公用"网络时入站连接会被拦 [待验证，本次没有读到一手来源]。更稳的是反过来：手机监听、电脑连出去，这正是 iOS 应用已有的 Web Studio 配对方式（六位配对码，`Web/preview-engine/src/cli/deviceSync.js`）[已核实，本仓库]；Android 是否有同样的接口在 Linux 计划里就标为待验证，现在仍是。不改应用的兜底是把 `.swt` 存进手机也能访问的云盘目录。没有找到 Phone Link 或 Quick Share 的公开编程接口。

第一版的 API 范围建议与 Linux 第一版一致（`$device`、`$system`、`$storage`、`$file`、`fetch`、`$http`、`$xml`、`$dataSource`、时间线、按钮和开关），其余返回 `[unsupported_platform]`，`$system.platform()` 返回 `"windows"`。`$music`、`$notifications` 等在 Windows 上对应哪些系统接口，本次没有调研。

## 先后顺序：核心先行，Windows 展示端排在 Omarchy 插件之前

"先做 Linux 还是先做 Windows"这个问题，在共用核心的前提下大半消解了。把 Linux 计划的组件逐个对到 Windows 上：包存储与校验、QuickJS 嵌入、渲染器加画笔、时间线调度逻辑、受限的网络和存储模块、命令行、进程间协议，都只写一次；Windows 独有的是分层窗口宿主和托盘、官方面板提供方、作业对象与 LPAC 沙箱、MSIX 打包和商店上架，以及把 Unix socket 换成命名管道。Linux 计划的阶段 1（命令行）和阶段 2 里除 QML 插件以外的部分直接搬过来。无法给出有依据的百分比，Linux 计划自己也说它的周数估算"没有依据可以校准"。

两个平台的差别如下。

| | Linux（Omarchy） | Windows |
| --- | --- | --- |
| 潜在用户 | 4.0 首月下载超过 30 万次 [二手，项目自己公布] | Windows 11 设备超过 10 亿台 [二手，媒体转述财报] |
| 用户画像 | 终端和 Neovim 用户，自带 Coding Agent | 大众用户，预期有图形界面和现成小组件 |
| 展示端 | 一个很小的 QML 插件，跟随主题 | 自己维护的桌面窗口宿主，依赖未公开的外壳行为 |
| 需要图形界面 | 不需要 | 需要（复用 Web Studio） |
| 签名与上架 | 无；AUR 加插件目录 | 商店 MSIX；账号类型和中国区注册有不确定性 |
| 已有同类 | 上千个无沙箱的 QML 插件 | Rainmeter、DeskBox、Seelen UI 等，无一兼具可编程、安全、跨手机 |
| 现有 Mac 能否验证 | 不能，需要一台 x86 的 Omarchy 4 机器 | 大部分可以在 Arm 虚拟机里做；少数项需要真机 |
| 长期维护风险 | Omarchy 外壳和插件接口变动 | Windows 更新改动桌面层级；商店政策 |

建议的顺序是四步。第一步，照 Linux 计划做共用核心和命令行，但**画笔选型要把 Windows 算进去**：Cairo 加 Pango 会把 GLib 和 fontconfig 整套依赖带到 Windows 上，候选应当改成 tiny-skia 加 cosmic-text 对比 Skia，两者都跨平台；tiny-skia 自述没有文字渲染、是"研究性质的项目"，cosmic-text 的路线图仍列着"就绪"之前必须补的项目 [已核实，两个 README]（[tiny-skia](https://github.com/linebender/tiny-skia)、[cosmic-text](https://github.com/pop-os/cosmic-text)），所以文字保真度的门槛必须同时在 Windows 字体上测。这一步的产物是能在 Linux、macOS、Windows 上无图形会话运行的 `scriptwidget render`，本身就可以发布，也是 Linux 计划阶段 1 的完成标准。第二步，在 Linux 阶段 0 的同一时间窗里做 Windows 原型（下一节）。第三步，原型通过后先做 Windows 展示端，Omarchy 插件随后。第四步，官方面板提供方放在 Windows 第一版之后，视原型结果决定做不做。

把 Windows 展示端排在 Omarchy 插件之前，理由是受众相差几个数量级、目标位置空着、而且现有的 Mac 就能做大部分验证。反方的理由同样成立，应当认真对待：Omarchy 插件工作量小得多，用户正是"在桌面上写、发到手机"这个定位的理想人群，没有签名和审核；Windows 则要背上图形界面、商店账号风险和一个每逢系统更新就可能失效的窗口宿主，而且这个品类的用户预期是免费。如果 Linux 阶段 0 的社区反馈（"有没有人要"）明显强烈，或者 Windows 原型在文字保真度、Win+D 行为上不过关，顺序应当倒过来。无论哪种顺序，都不应早于仓库当前的优先事项，即稳定已有契约和把 Android 送上 Google Play。

## 结论取决于一轮 Windows 真机原型

下面这些事项没有任何来源能替代实测。前三行是否决项：任何一项不过，就应当重新评估路线或顺序。

| 待验证事项 | 通过标准或要回答的问题 | 环境 |
| --- | --- | --- |
| 微软商店个人账号注册 | 用中国大陆证件走完证件加自拍验证，拿到可提交应用的账号 | 任意，不花钱，可立即做 |
| Rust 画笔的文字保真度 | 10 个代表性模板（简繁中文、日文、韩文、表情含组合序列、图表）与 Web Studio 截图对比，差异在 Android 当时接受的范围内；不过则试 DirectWrite 度量加绘制 | 虚拟机即可 |
| 置底分层窗口的行为 | 在图标之上、可点击、不抢焦点、不进 Alt-Tab；Win+D、显示桌面角、任务视图、资源管理器重启、睡眠唤醒后仍在；在 24H2（不低于 26100.2454）和最新 25H2 上都成立 | 虚拟机加一台真机 |
| QuickJS-NG 0.18.0 的 Windows 构建 | MSVC 和 clang-cl、x64 和 ARM64 下 164 棵一致性树逐字节相同；内存上限和中断不可被脚本捕获 | 虚拟机或 CI |
| `icu.dll` 桥接 | 通过 Android 的 `Intl` 测试集；记录各 Windows 版本的 ICU 版本 | 虚拟机 |
| 多显示器、混合 DPI、HDR、虚拟桌面 | 100/125/150/175% 下位图按物理像素渲染且清晰；HDR 下颜色正常；虚拟桌面上的可见性 | 真机 |
| 官方面板收不收位图 | `data:` 地址是否可用于 `Image` 和 `backgroundImage`；载荷上限；各尺寸在各缩放下的像素大小；`UpdateWidget` 有无节流 | 真机优先（虚拟机里面板是否可用本身未知） |
| 官方面板的点击和实例绑定 | 图片上的 `selectAction` 是否生效；本地账号下 `isUserContextAuthenticated` 是否为真；一个通用定义能否通过自定义状态绑定任意脚本；锁屏上按钮是否可用 | 同上 |
| 后台与耗电 | 现代待机一夜的定时器触发记录和耗电；节能模式下的行为；1、5、10 个小组件时宿主的内存 | 真机笔记本 |
| WebView2 对照实验 | 单个隐藏 WebView2 空闲时所有 `msedgewebview2.exe` 的内存、冷启动时间 | 虚拟机 |
| 沙箱 | 零能力 LPAC 子进程能否加载字体和 ICU 数据；进程启动开销 | 虚拟机 |
| 发到手机 | 监听端口在专用和公用网络下的防火墙表现；反向配对（电脑连手机）在 iOS 上走通；Windows 共享面板里是否出现 Quick Share 或 Phone Link | 真机加手机 |

另有几项不需要原型但尚未查清，决策前应补上：商店开发者协议原文里的分成条款；10.2.2 对内嵌脚本引擎是否有先例或官方答复（可以在提交前直接问）；微软商店客户端和小组件面板在中国大陆用户侧是否正常可用；sparse package（外部位置打包）能否承载小组件扩展，微软的文档只描述了完整 MSIX 的做法。

## 结论

这次调研改变的是问题本身。出发时的问题是"要不要接入 Windows 小组件"，答案却是 Windows 的官方小组件平台对 ScriptWidget 几乎无关紧要：它不能自绘、不在桌面上、最好的能力锁在欧洲经济区。真正的 Windows 版是一个自己画窗口的桌面宿主，这恰好是 Android 和 Linux 已经选定的位图架构的第三次复用。于是"Windows 还是 Linux"也不再是二选一，而是"同一套 Rust 核心先接哪个展示端"；这让 Linux 计划阶段 0 的画笔选型成为眼下最有杠杆的一个决定，它应当现在就把 Windows 字体纳入测试，并把 Cairo 加 Pango 从候选里换掉。

还有一个不那么显眼的含义：分发约束反过来决定了商业模式。对在中国的个人开发者，免费、个人账号、商店 MSIX、不经手微软结算，是唯一同时避开签名费用、SmartScreen 警告和收款故障的组合，这与"Windows 是入口、手机是落点"的产品定位正好一致。最便宜的下一步因此不是写代码，而是花一个晚上去注册商店账号，并在 Parallels 里装一台 Windows 11，把表格前三行跑出结果。
