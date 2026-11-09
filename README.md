# Codex Buddy for macOS

Codex Buddy 是一款原生 SwiftUI 菜单栏应用，用于在 Mac 上读取本机 Codex 额度状态，并把最新状态同步到用户自己的 Apple 设备。

> 本项目不是 OpenAI 官方产品，也不提供、修改或绕过 Codex 服务。

## 功能

- 显示 5 小时与每周额度窗口、恢复时间和可用重置次数
- 支持菜单栏快速查看与手动刷新
- 保留局域网配对和本地状态服务
- 可通过用户自己的 CloudKit 私有数据库同步最新状态
- App Store 沙盒版支持手动授权 `.codex` 文件夹
- 直接分发版可通过本机 `codex app-server` 读取状态，并回退到本地会话日志

本次发行候选版本：`1.1.2`（Build `11`）。本仓库只包含 macOS App 与 Mac 所需的同步、状态模型和界面代码，不包含 iOS/watchOS App、Widget、资源或构建目标。GitHub DMG 为直接分发版。

## 后台刷新与流量

- 正常使用或检测到活动对话时，接电每 15 秒刷新，使用电池每 30 秒刷新。
- 所有显示器休眠，或者 Mac 合盖且没有外接显示器，或者合盖并且外接显示处于锁屏、屏保或系统休眠状态时，可进入空闲检查。
- 确认没有活动对话后，先等待 30 分钟；到期再次确认仍空闲后，改为每小时检查。恢复使用或新任务开始会立即返回正常频率。
- 正常刷新复用一个已初始化的 `codex app-server`。低频检查之间关闭该服务，避免其自身的目录刷新任务持续联网；失败重建也有退避。
- 活动判断只覆盖当前 `CODEX_HOME`（默认 `~/.codex`）内正常保存历史的本机会话。不保存记录的临时上下文不在识别范围内；实际检测失败时保持正常刷新频率。

完整的任务联动低频模式用于直接分发版。Mac App Store 沙盒版按用户授权的本地日志读取额度；它采用接电 15 秒、电池 30 秒的正常频率，不扫描其他进程或启动外部 CLI。

显示、电源与任务检测在本机完成，不通过启动新的 Codex 服务来检测任务。外接显示器的休眠、断开等状态以 macOS 上报为准。

## 构建

1. 使用 Xcode 27.1 或兼容版本打开 `Codex Buddy.xcodeproj`。
2. 选择 `Codex Buddy Mac` scheme。
3. 如需自己的签名与 iCloud，请替换 Team、Bundle Identifier、App Group 和 CloudKit Container。
4. Debug 配置对应直接分发能力；Release 配置对应 Mac App Store 沙盒能力。

项目最低部署目标为 macOS 26。

## 隐私

应用处理额度状态、刷新时间、配对信息和本地授权。任务检测仅在本机解析已保存日志的任务生命周期元数据；日志、对话正文、提示词和项目文件不上传到 CloudKit。CloudKit 仅保存用户自己的额度状态快照。

云中继和推送还会使用开发者的 Cloudflare 服务，保存必要的额度快照、同步标识和推送路由信息。完整的数据范围及本地／远程清除区别见[隐私政策](docs/PRIVACY.md)；问题反馈见[支持说明](docs/SUPPORT.md)。

## License

MIT License。详见 [LICENSE](LICENSE)。

## 直接分发构建

Release 配置可用 `ENABLE_APP_SANDBOX=NO CODE_SIGN_ENTITLEMENTS="Codex Buddy Mac/CodexBuddyMacDirect.entitlements"` 构建直接分发版。正式 DMG 使用 Developer ID 签名，并在 Apple 公证及 staple、Gatekeeper 验证通过后发布。
