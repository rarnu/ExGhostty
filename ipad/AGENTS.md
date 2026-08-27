# ExGhostty iPad 版 — Agent 开发指南

本目录是 ExGhostty（Mac 版，位于仓库根 `/Users/rarnu/Code/github/ExGhostty`）的 **iPad 移植版**。
所有 iPad 版工作均以 Mac 版为参照进行移植；Mac 版的功能实现对齐基准在 `../macos/Sources/`。

> 注意：仓库根的 `AGENTS.md` 描述的是 Zig/Mac 工程（`zig build` 等），对本目录基本不适用。

## 项目构成

- `App/ExGhostty_iPad/` — iPad App 本体（约 42 个 Swift 文件），Xcode 工程在 `App/ExGhostty_iPad.xcodeproj`。
- `Sources/SwiftTerm/` — 内嵌的 [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 快照（终端引擎 + UIKit/AppKit 视图 + Metal 渲染），作为 SPM 本地库使用。**App 专属逻辑一律放 `App/`**。本地补丁清单（改动库代码时必须在此登记）：`iOS/iOSTextInput.swift` 的 `caretRect(for:)`/`firstRect(for:)` 从返回 `bounds` 改为返回光标视图 frame（否则物理键盘输入法候选窗无锚点）。
- `Vendor/swift-nio-ssh/` — SSH 协议栈依赖。
- SPM 远程依赖：`swift-nio`、`swift-crypto`（NIOSSH 需要）、`SWCompression`（仅用于 SFTP 目录传输的 tar.gz 本地打包/解压，见 `Features/SFTP/TarGzArchive.swift`）。
- `Sources/CaptureOutput`、`Sources/Termcast`、`Sources/SwiftTermFuzz`、`Tests/SwiftTermTests` — 上游 SwiftTerm 自带的工具与测试，与 App 无关。
- `scripts/regen_unicode_width_data.py` — 重新生成 SwiftTerm 的 `UnicodeWidthData.swift`（`make regen-unicode-width`）。

## 构建与测试

- App：用 Xcode 打开 `App/ExGhostty_iPad.xcodeproj`（scheme: `ExGhostty_iPad`），依赖通过本地 SPM 解析。
- SwiftTerm 库：`swift build` / `swift test`（在本目录执行；只测 SwiftTerm，不构建 App）。
- 命令行构建 App 示例：`xcodebuild -project App/ExGhostty_iPad.xcodeproj -scheme ExGhostty_iPad -destination 'generic/platform=iOS Simulator' build`。
- Swift 格式化遵循仓库根规则：`swiftlint lint --strict --fix`。

## App 架构（`App/ExGhostty_iPad/`）

- **入口**：`ExGhosttyApp.swift`（SwiftUI 生命周期；`init()` 先跑 `LegacyDataMigration`）。根视图 `MainSplitView`（手写 HStack：左侧连接列表 `ConnectionListView`，右侧 `TerminalTabContainerView`），强制深色模式。
- **Tab/会话**：`Features/Session/TerminalTabStore.swift` — `TerminalTab` 持有 `SSHSession` + `TerminalBox`（弱引用终端控制器）。`TerminalTabStore.shared` 是单例（MainSplitView 以 `@StateObject` 持有并注入 environment；端口转发窗口等独立 hosting controller 拿不到 environment，直接用单例）。Tab 有两种 `kind`：`.terminal`（SSH 会话）与 `.browser`（内置 WKWebView 浏览器，`Features/Browser/BrowserTabView.swift`，由转发规则的「访问页面」打开；此时 `config`/`session` 为 nil——二者是 IUO，遍历 tab 时先判 kind）。所有 tab 用 `ZStack + opacity` 常驻视图树保活，切换不销毁会话——新增面板/页面时必须保持这一模式。
- **SSH 层**（`SSH/`）：`SSHSession`（NIOSSH，`MultiThreadedEventLoopGroup(3)`，子 channel 承载 shell/exec/sftp；socket 开 `SO_KEEPALIVE`）。认证 `FlexibleAuthDelegate`（私钥优先、回落密码；**不支持 keyboard-interactive、不支持加密私钥**）。跳板机 = `openNestedTransport`（跳板机 directTCPIP 上二次握手，经 `SSHDataCodec` 做字节转换）。`SFTPClient` 是手写 SFTP v3。**端口转发**（用户需求后重新引入）：`Models/PortForwardStore.swift`（规则持久化 + app 级 runtime 注册表，关窗口不停转发）+ `SSH/PortForwardRuntime.swift`（NIO 引擎：-L/-D 起本地 `ServerBootstrap` 监听、每条入站连接开 `directTCPIP` 子 channel 粘接，-D 内置最小 SOCKS5 server，-R 走 `sendTCPForwardingRequest` + `inboundForwardedTCPIPHandler` 接回本地服务；每条规则独占一条 `SSHSession`，固定 3s 重连、连续 5 次失败放弃）。保活：进后台申请 `beginBackgroundTask` 短宽限，回前台 `resumeAfterForeground()` 就地恢复（iOS 不允许无限后台运行，长时间后台必断、靠前台恢复）。**自动重连**：iOS 锁屏/后台会杀死 TCP 连接，`SSHSession.ensureConnected()`（带 `connectInFlight` 去重）是统一重连入口；触发点有三——`TerminalHostViewController` 观察 `didBecomeActive` 调 `SshTerminalView.attemptReconnect()`（shell 死了才重开）、`shellDidClose` 时非主动退出立即重连、`TerminalSessionView` 观察同一通知调 `TerminalTab.reconnectIfNeeded()`（兜底 `.failed` 错误页场景，重连成功后 SwiftUI 切回终端并重建宿主控制器）。远端 exit-status/exit-signal 会置 `remoteExitReceived`，用户主动 exit 不重连——但此时按任意键会走 `send(source:data:)` 钩子手动重连（`reconnectOnUserInput`）。
- **终端接入**：`SSH/SshTerminalView.swift` — `class SshTerminalView: TerminalView, TerminalViewDelegate`（用 UIKit 的 `TerminalView`，**不是** `SwiftUITerminalView`，后者仅 DEBUG 内部调试用）。数据流：下行 `channelRead` → 1KB 切片 → 主线程 `feed(byteArray:)`；上行 `TerminalViewDelegate.send` → `writeAndFlush`；resize → `WindowChangeRequest`。连接物理键盘时（`GCKeyboard` 监测）自动隐藏 esc/ctrl 输入工具条，断开恢复。宿主 `TerminalHostViewController`（UIKit 容器；终端贴满屏幕底边，软键盘避让用 `keyboardWillChangeFrameNotification` 调底部约束——`keyboardLayoutGuide` 在无键盘时会留一条安全区空白；SwiftUI 侧 `TerminalSessionView` 根部还需 `.ignoresSafeArea(.container, edges: .bottom)`，否则 SwiftUI 安全区会把整个宿主视图抬离底边），经 `TerminalSessionView` 内 `UIViewControllerRepresentable` 桥接进 SwiftUI；功能条右侧常驻 `InputModeBadge`（`Models/InputModeMonitor.swift`，显示当前输入法：中/繁/EN/あ/한…）。
- **功能面板**（`Features/`，每个目录一个域）：`Session`（标签页）、`Home`（连接列表/编辑；底部栏含端口转发与设置入口）、`Settings`、`PortForward`（转发规则列表/编辑，`PortForwardViewController` 与设置页同款全屏 push 转场）、`Keys`（私钥管理，自研 OpenSSH/PEM 解析；`SSHKeyListContent` 是无导航壳的列表+导入/删除内容视图，设置页 Keys 分区直接内嵌它；`SSHKeyManagementView` 是其 push 整页包装，连接编辑页仍在用）、`SFTP`、`SessionReuse`（tmux/rmux/zellij）、`PortUsage`、`Docker`、`SystemMonitor`（远端 `xtop --all --json --stream` 流式采集，含 GPU/磁盘读写，对齐 Mac 版）、`AIAssistant`（OpenAI 兼容 SSE 流式；环境上下文 = OS 身份探测 + `xtop --all --json` 单次快照原始 JSON 直传，未装 xtop 则跳过，5 分钟 TTL 缓存，对齐 Mac 版）。所有面板注入同一个 `SSHSession`，通过 `session.exec()` / `execStream()` 跑远程命令；需要"往终端打字"的面板额外拿 `TerminalBox`。
- **设置页**（`Features/Settings/`）：Mac 风格左右分栏——左 200pt 分类 `List`（`SettingsCategory`：通用/主题/外观/AI/密钥/关于），右侧 ScrollView detail；`settingsRow(label:controlWidth:)` 统一"120pt 标签 + 定宽控件列"的行式对齐（默认控件宽 240，AI 输入框 360，行内不要再给控件单独设 `.frame(width:)`）。经 `SettingsViewController`（全屏 push 转场 + 强制深色）从主界面推出。

## 代码约定

- 命名：类型 PascalCase / 成员 camelCase，英文；面板成对出现 `XxxPanelView` + `XxxViewModel`；持久化单例 `XxxStore.shared` + `@Published`。
- **每个文件头部写 5 行左右的 block 注释**说明职责和坑——新文件必须照做。
- 注释语言现状混用：`SSH/`、`Models/` 为英文，`Features/` ViewModel 多为中文。改哪个层就跟随哪个层的语言。
- **UI 文案走应用内翻译**：所有用户可见字符串用 `L("中文原文")` 包裹（key 即简体中文原文；翻译表在 `Models/Translations*.swift`，按 area/语言分文件——`Translations.{home,session,Panels,ai}.swift` 并入 `Translations.en`，`Translations.zhHant.swift` / `Translations.ja.swift` 为整表）。支持语言：简体中文（原文）/ 繁體中文 / 日本語 / English。含 L() 的 View struct 必须加 `@StateObject private var l10n = LocalizationManager.shared` 以订阅语言切换。ViewModel 消息存中文原文，在 View 显示处包裹 L()。
- 持久化：配置 JSON → UserDefaults；秘密（密码/私钥/sudo 密码）→ Keychain（`KeychainHelper`，三个 service 前缀）。**iCloud 同步已移除**（用户需求）：kv-store 同步、设置开关、entitlement 均已删除；Keychain 新条目不再标 synchronizable，但查询仍带 `kSecAttrSynchronizableAny` 以兼容旧版本写入的条目。
- 模型 Codable 用 `decodeIfPresent` + 默认值做旧存档兼容（参考 `SSHConnectionConfig`）。
- ViewModel 轮询统一 `Task { while !Task.isCancelled { ... } }`，`deinit` cancel。
- 终端字体：`App/ExGhostty_iPad/Fonts/` 内置 5 款字体（JetBrains Mono Nerd Font 与其 Mono 变体各四字重——后者来自 nerd-fonts 官方发布包；Fira Code / JuliaMono / Monaspace Neon 单字重，均 OFL），`Info.plist` 的 `UIAppFonts` 注册；`Models/TerminalFontCatalog.swift` 应用字体+字号到 TerminalView（PS 字体名以字体文件内嵌为准，如 `JetBrainsMonoNFM-Regular`）。
- 终端主题：`App/ExGhostty_iPad/Themes/*.theme` 内置 574 套 ghostty/iTerm2 主题（拷自桌面仓库 `zig-out/share/ghostty/themes`，`key = value` 文本格式，已统一加 `.theme` 后缀以便按扩展名从 bundle 枚举）；`Models/TerminalThemeCatalog.swift` 负责解析 + 应用（`installColors` 必须恰好 16 色；"default" 是复刻库默认外观的内置条目，旧占位 id `light`/`high-contrast` 映射到 Builtin 主题）。设置页主题网格 `ThemeCell` 用主题色实时绘制预览（不像 Mac 版带 16MB 预览 PNG）。SwiftTerm 无 Theme 抽象，颜色经 `nativeForegroundColor`/`nativeBackgroundColor`/`installColors`/`caretColor`/`selectedText*Color` 运行时切换，历史行随索引色自动重染；注意远端 OSC 4/10/11/12 可覆盖主题色。
- App 自身 UI 无主题系统（黑底 + `Color.teal` 强调，不随终端主题变），UI 文本多用 `.monospaced`。

## 已知坑 / 技术债（改动前先读这里）

- `AcceptAllHostKeysDelegate` 无条件接受所有 host key（MITM 风险，无 TOFU/known_hosts）。
- `SettingsStore.terminalFontSize` / `terminalFontName` 已接线到终端（`TerminalHostViewController` 订阅变更并调用 `TerminalFontCatalog.apply`）。
- 命名已统一为 ExGhostty（`ExGhosttyApp`、文件头 `ExGhostty_iPad`、Keychain service `com.xjai.exghostty.ipad.*`、UserDefaults key `exghostty.ipad.*`）。旧的 `iosterminal.*` / `org.tirania.SwiftTerm.iosSampleApp1.*` 数据由 `Models/LegacyDataMigration.swift`（启动时）和 `KeychainHelper`（读取时懒迁移）负责迁移——新增持久化 key 时用 `exghostty.ipad.` 前缀。
- `SshTerminalView.observeIdentityPrompt` 的 sudo 密码嗅探只匹配输出尾部 256 字节里的 "password"（英文 locale 限定，很脆）。
- 每连接一个 3 线程 event loop group，线程数随 tab 线性增长；`TerminalTab.connectIfNeeded` 的 `try?` 吞掉连接错误。
- `SSHShellChannelHandler` 每 1KB 一次主线程 dispatch，大输出下调度开销可观（但保序）。
- `Info.plist` 的 `UIRequiredDeviceCapabilities` 还写着 `armv7`（模板残留）。
- SwiftTerm 快照缺上游新增的 BiDi/Powerline/SemanticPrompt 等文件；`Sources/SwiftTerm/BufferSet.swift` 和 `File.swift` 是上游遗留的空文件。

## 移植参照（Mac 版 → iPad 版）

Mac 版功能在 `../macos/Sources/Features/`，iPad 版对应关系：

| Mac 版 | iPad 版 | 差异要点 |
|---|---|---|
| Ghostty surface + expect 脚本包装系统 ssh | SwiftTerm + swift-nio-ssh 内嵌 | **最大架构差异**：iOS 无 ssh/expect 二进制 |
| `Features/Sidebar/`（SSHStore 等） | `Features/Home/` + `SSH/` | UserDefaults+JSON 持久化模式一致 |
| `Features/SFTP/`（rsync 传输） | `Features/SFTP/`（手写 SFTP v3） | iOS 无 rsync |
| `Features/AIAssistant/`、`Docker/`、`SystemMonitor/`、`SessionReuse`、`PortUsage` | 同名 Feature 目录 | 面板 UI 与交互逻辑对标 Mac 版 |
| Mac 版端口转发（`SSHStore.PortForwardStore` + ssh mux） | `Features/PortForward/` + NIO 引擎 | iOS 无 ssh 二进制；转发/重连语义对齐 Mac 版 |
| ghostty 配置文件 + `ConfigFileWriter` | 无（UserDefaults + `SettingsView`） | 配置不落地文件；主题文件复用 ghostty 主题包 |
| `Helpers/PasswordCipher`（AES 存密码） | Keychain | iPad 用 Keychain 替代 |

新增功能时：先在 `../macos/Sources/Features/` 找 Mac 版实现作为行为基准，再按本目录的 SSH/SwiftTerm 架构适配（远程命令一律走 `session.exec()`，不要引入新的连接通道）。

## Issue 与 PR 规则

遵循仓库根 `AGENTS.md`：永远不要创建 issue 或 PR。
