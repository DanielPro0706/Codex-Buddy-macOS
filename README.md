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

## 构建

1. 使用 Xcode 26.6 或兼容的稳定版本打开 `Codex Buddy.xcodeproj`。
2. 选择 `Codex Buddy Mac` scheme。
3. 如需自己的签名与 iCloud，请替换 Team、Bundle Identifier、App Group 和 CloudKit Container。
4. Debug 配置对应直接分发能力；Release 配置对应 Mac App Store 沙盒能力。

项目最低部署目标为 macOS 26。

## 隐私

应用只处理额度状态、刷新时间、配对信息和本地授权。它不会读取或上传对话正文、提示词、项目文件、Apple ID 或支付信息。CloudKit 数据保存在用户自己的私有数据库中。

## License

MIT License。详见 [LICENSE](LICENSE)。
