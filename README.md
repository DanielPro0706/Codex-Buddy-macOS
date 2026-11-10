# Codex Buddy

Codex Buddy 在 iOS 和 macOS 中提供三个 Tab：

| Tab | 功能 |
| --- | --- |
| limitis | 读取 Mac 的 Codex 额度，查看恢复时间，并同步至用户自己的 iPhone、Apple Watch、小组件和实时活动。 |
| snapinsert | iPhone 拍照后通过端到端加密中转至 Mac 剪贴板，可在授权后向目标应用发送粘贴指令。 |
| CloudSpace | 配置自己的 gateway 后浏览其网页；未配置时展示公开的 iCloud 工作区部署方法。 |

本项目不是 OpenAI 官方产品。版本 `1.2`（Build `12`）合并上述功能，保留原有额度读取、配对和后台刷新。

## SnapInsert 账户与购买

iOS 使用 Apple 签名的 AppTransaction 授权，服务端按运行环境与 `appTransactionID` 的摘要关联账户。免费额度为每个经 Apple 验证的 App Store 账户每个北京时间自然月 100 张。已验证邀请码或有效月订阅提供不限张数的权益，仍受共享中转容量和排队限制。App Store 购买账户可能与 iCloud 登录账户不同。

订阅产品标识为 `com.danieldev.CodexBuddyNew.snapinsert.monthly`。实际价格以 Apple 购买界面为准；App Store Connect 产品、签名校验、生产订阅服务器通知及服务端部署需配套完成，单独编译源码不会创建或上架订阅产品。付款由 Apple 处理，应用提供恢复购买；取消自动续订须在 Apple 订阅管理中完成。

照片不写入中转服务器磁盘。服务端仍持久保存账户关联摘要、月用量、传输去重标识和订阅状态及交易标识；这些记录不能表述为“不记录任何数据”。Mac 剪贴板和已插入的图片由系统及目标应用分别管理。详细范围见 [隐私政策](docs/PRIVACY.md)。

## CloudSpace

[开源部署方法](https://github.com/DanielPro0706/codex-icloud-workspace)说明如何搭建用户自己的 iCloud 工作区 gateway。Codex Buddy 保存用户填入的网页地址，并由 WebKit 展示该网页；认证、文件权限、后端同步和私有网络由用户的部署处理。源代码不包含开发者个人 gateway 地址、密钥或私人文件。

## 源码与构建

完整的 iOS、macOS、watchOS 和 Widget 源码保存在私有仓库，打开 `Codex Buddy New.xcodeproj`。公开的 [macOS 仓库](https://github.com/DanielPro0706/Codex-Buddy-macOS)仅包含 Mac 端及必需共享模块，打开其 `Codex Buddy.xcodeproj`；不包含私有 iOS 目标或个人 gateway 配置。

macOS 最低目标为 26。直接分发版可使用本机已登录的 Codex CLI；Mac App Store 沙盒版只读取用户明确授权目录中的日志。Release 的沙盒构建通过 App Store 更新，直接分发构建从 GitHub Release 检查更新。

需要自己的 Team、Bundle Identifier、CloudKit Container、签名和后端服务才能独立发布。直接分发版需 Developer ID 签名、公证及 Gatekeeper 验证；TestFlight 构建需 App Store Connect 配置。验证结果与发布状态应分别核对。
