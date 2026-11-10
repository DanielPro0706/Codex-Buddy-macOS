# Codex Buddy 支持

Codex Buddy 的 Limits 在 Apple 设备上查看 Codex 额度，SnapInsert 把 iPhone 拍摄的加密照片接到 Mac，CloudSpace 则仅在 iOS 原生访问用户自己的工作区。Mac 侧栏包含 Limits、SnapInsert、连接和设置四项。它是独立开发的工具，不提供 Codex 账号、模型访问或额外额度，也不能改变 OpenAI 的额度规则。

开发者：Weitao Feng。问题反馈入口：[GitHub Issues](https://github.com/DanielPro0706/Codex-Buddy-macOS/issues)。[隐私政策](PRIVACY.md)说明本机、iCloud 及开发者推送服务处理的数据。

## 开始使用

1. 在 Mac 上安装 Codex Buddy，并确保本机 Codex 已登录。
2. Mac App Store 版需要在设置中选择 `.codex` 或其 `sessions` 文件夹，才可读取已经记录的额度事件。直接分发的完整版可使用本机 Codex CLI 查询状态，并在失败时回退到本地记录。
3. 在 Mac 独立的“连接”页显示统一二维码；iPhone 从 Limits 或 SnapInsert 扫描一次即可同时保存两个功能的配对。二维码包含访问令牌和照片加密密钥，请勿分享。Limits 的局域网直连需要两端位于同一网络，同一 Apple Account 的设备也可通过 iCloud 私人数据库同步额度。
4. SnapInsert 接收照片会覆盖 Mac 剪贴板；开启 Mac 辅助功能权限后可向目标应用发出粘贴指令。
5. 按需要添加小组件、连接 Apple Watch 或开启实时活动。推送、后台刷新和小组件更新由 Apple 系统调度，不保证每次状态变化立即显示。

主 App 最低系统版本为 macOS 26、iOS/iPadOS 18、watchOS 11；当前 iPhone/iPad 小组件目标要求 iOS/iPadOS 26。具体功能还取决于设备、系统授权和所安装版本。

## 常见问题

### 显示“尚未读取”或旧额度

先查看快照的更新时间。Mac App Store 版读取的是 Codex 已写入的额度事件；如果 Codex 没有留下新的事件，重复读取不会产生新的官方额度查询。确认文件夹授权仍有效，必要时在设置中重新选择。直接分发版则需确认本机 Codex 已登录且可正常访问其服务。

### Mac 已更新，其他设备没有更新

确认 Mac 端正在运行、两端使用同一 Apple Account，且允许 iCloud 与相应网络访问。局域网配对时，检查设备是否在同一可信网络，并确认地址和令牌匹配。后台推送还依赖开发者推送服务和 Apple APNs；关闭通知、实时活动、网络访问或系统后台限制都可能影响显示。不要把设备上的旧快照误认为新的查询结果。

### 夜间仍有网络流量

请将 Mac 端 Codex Buddy 更新至 1.1.2 或更新版本。旧版反复启动本地服务可能产生较高流量。新版直接分发版会复用服务，并在确认空闲后降低刷新频率；任务开始或恢复使用后返回正常频率。该任务识别仅覆盖所选 Codex 数据目录中正常保存历史的本机会话；无法确认时保持正常刷新。

Mac App Store 沙盒版不启动外部 CLI，也不扫描其他进程；按接电 15 秒、电池 30 秒读取授权日志。完整的任务联动低频检查属于直接分发版。最新 macOS 完整版见[公开 Releases](https://github.com/DanielPro0706/Codex-Buddy-macOS/releases/latest)。

### 想断开连接或清除数据

Limits 的“断开连接”只移除该功能的本机 Mac 配对；“清除 Limits 本机数据”还会清除对应缓存与同步密钥、停止实时活动，并通知 Apple Watch 清除副本。SnapInsert 的移除配对单独操作。CloudSpace 的“清除工作区连接”仅清除当前地址及该 origin 的独立访问凭据，不删除 iCloud、gateway、预览临时副本或已共享文件，也不会取消订阅。远程数据及停止发送的方法见[隐私政策](PRIVACY.md#保存清除与停止处理)。

### CloudSpace 状态可读，但无法浏览目录

CloudSpace 仅在 iOS 提供，使用原生 JSON 与 WebDAV 接口，不依赖网页 Cookie 登录。确认已连接用户自己的 Tailscale 网络，填写最终 HTTPS 根地址；现有 gateway 的目录浏览还需要独立 WebDAV 用户名和密码，请勿填写 Apple 账户密码。读取连接状态并不证明目录权限、Apple 登录或云环境写回当前正常。

预览和共享会按需下载本机临时副本，单文件上限 32 MiB。当前界面不提供文件上传、编辑或删除。清除连接不会撤回临时或共享副本。

## 提交反馈

请在 Issues 中说明应用版本与构建号、系统版本、设备类型、安装来源（Mac App Store 或直接分发版）、发生步骤和预期结果。截图可帮助定位问题，但请先遮挡个人信息及配对信息。

请勿公开提交 Codex 对话正文、项目文件、配对二维码、访问令牌、同步密钥、推送 token 或登录凭据。隐私请求可先提交简短、不含敏感数据的说明，再由开发者说明后续处理方式。此页面不承诺固定回复时限。
