# Codex Buddy

Codex Buddy 的 iOS 版设有 Limits、SnapInsert、CloudSpace 和设置四个 Tab，功能设置集中在独立的设置页；macOS 主窗口侧栏包含 Limits、SnapInsert、连接和设置四项，Limits 直接展示额度状态。

| 功能 | 平台 | 用途 |
| --- | --- | --- |
| Limits | iOS、macOS | 读取 Mac 的 Codex 额度，查看恢复时间，并同步至用户自己的 iPhone、Apple Watch、小组件和实时活动。 |
| SnapInsert | iOS、macOS | iPhone 拍照后通过端到端加密中转至 Mac 剪贴板，可在授权后向目标应用发送粘贴指令。 |
| CloudSpace | 仅 iOS | 原生查看自有 gateway 的连接状态、目录和当前工作区，按需下载预览或共享文件；未配置时展示开源部署方法。 |

本项目不是 OpenAI 官方产品。版本 `1.2.1`（Build `13`）合并上述功能，保留原有额度读取、配对和后台刷新。

## 统一配对

在 Mac 侧栏的“连接”页显示统一二维码；SnapInsert 的“配对 iPhone”也会打开同一页面。iPhone 从 Limits 或 SnapInsert 扫描一次，即可同时保存两个功能的配对信息。旧版单功能二维码仍只连接对应功能，并提示扫描新版统一二维码补齐另一项连接。

统一二维码同时包含 Limits 的 Mac 地址与访问令牌，以及 SnapInsert 的配对信息和照片加密密钥。仅在自己的设备间扫描，请勿公开分享二维码、配对链接或截图。

## SnapInsert 账户与购买

iOS 使用 Apple 签名的 AppTransaction 授权，服务端按运行环境与 `appTransactionID` 的摘要关联账户。免费额度为每个经 Apple 验证的 App Store 账户每个北京时间自然月 100 张。已验证邀请码或有效月订阅提供不限张数的权益，仍受共享中转容量和排队限制。App Store 购买账户可能与 iCloud 登录账户不同。

月订阅名称为 **Buddy Pro**，中国大陆定价为 **¥1.50/月**；其他地区以 App Store 显示为准。订阅产品标识为 `com.danieldev.CodexBuddyNew.snapinsert.monthly`。实际价格以 Apple 购买界面为准；App Store Connect 产品、签名校验、生产订阅服务器通知及服务端部署需配套完成，单独编译源码不会创建或上架订阅产品。付款由 Apple 处理，应用提供恢复购买；取消自动续订须在 Apple 订阅管理中完成。

照片不写入中转服务器磁盘。服务端仍持久保存账户关联摘要、月用量、传输去重标识和订阅状态及交易标识；这些记录不能表述为“不记录任何数据”。Mac 剪贴板和已插入的图片由系统及目标应用分别管理。详细范围见 [隐私政策](docs/PRIVACY.md)。

## CloudSpace（仅 iOS）

[开源部署方法](https://github.com/DanielPro0706/codex-icloud-workspace)说明如何搭建用户自己的 iCloud 工作区 gateway。CloudSpace 使用原生 SwiftUI 界面和 URLSession，通过 HTTPS 直接访问该 gateway 的现有 JSON 与 WebDAV 接口，展示连接状态、目录和当前工作区，并可选择供新对话使用的工作区。应用不内嵌浏览器，也不使用浏览器 Cookie 登录。

服务器地址保存在本机偏好设置中；可选的独立 WebDAV 用户名与密码按 gateway origin 保存在当前设备钥匙串中。现有 gateway 的目录浏览需要这组独立凭据；只读状态可按部署使用 Tailscale 身份。私人网络需要先连接用户自己的 Tailscale。此处不是 Apple 登录入口，请勿填写 Apple 账户密码。源代码不包含开发者个人 gateway 地址、密钥或私人文件。

文件在用户选择预览或共享时才下载到本机临时目录，单文件上限为 32 MiB。Quick Look、共享接收方及系统临时目录可能保留副本；清除连接不会撤回这些副本。当前原生界面不提供文件上传、修改或删除操作。

## 设置与本机数据

iOS 第四个 Tab 为独立的设置页，Limits、SnapInsert 和 CloudSpace 的配置集中在同一表单，隐私说明使用同一页面。“清除 Limits 本机数据”只处理 Limits 的配对、缓存和同步密钥；SnapInsert 的移除配对单独操作。CloudSpace 的“清除工作区连接”移除当前地址及该 origin 保存的独立 WebDAV 凭据，不等于删除 iCloud、gateway 或共享出去的文件，也不会取消订阅。

## 源码与构建

完整的 iOS、macOS、watchOS 和 Widget 源码保存在私有仓库，打开 `Codex Buddy New.xcodeproj`。公开的 [macOS 仓库](https://github.com/DanielPro0706/Codex-Buddy-macOS)仅包含 Mac 端及必需共享模块，打开其 `Codex Buddy.xcodeproj`；不包含私有 iOS 目标或个人 gateway 配置。

macOS 最低目标为 26。直接分发版可使用本机已登录的 Codex CLI；Mac App Store 沙盒版只读取用户明确授权目录中的日志。Release 的沙盒构建通过 App Store 更新，直接分发构建从 GitHub Release 检查更新。

需要自己的 Team、Bundle Identifier、CloudKit Container、签名和后端服务才能独立发布。直接分发版需 Developer ID 签名、公证及 Gatekeeper 验证；TestFlight 构建需 App Store Connect 配置。验证结果与发布状态应分别核对。
