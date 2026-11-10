# CloudSpace

iOS 和 macOS 共用 `CloudSpaceTab`。未配置时显示开源部署说明与 [Codex iCloud Workspace](https://github.com/DanielPro0706/codex-icloud-workspace)；保存地址后在应用内展示用户自己的 gateway。

配置仅保存网页 URL，使用当前应用的 `UserDefaults` 键 `cloudSpace.gatewayURL`，不包含个人默认服务器。用户可以随时修改或清除配置。地址只允许 HTTP(S)，拒绝 URL 内的账号、密码、查询参数和片段；实际部署应使用 HTTPS。

网页沿用 gateway 原有认证。现有开源服务器通过 Tailscale 私网识别受信任身份，应用不会代存 Apple 密码、WebDAV 密钥或 Tailscale enrollment key。连接失败时可重试，或在系统浏览器完成 gateway 自身认证。WebKit 使用系统证书校验，未增加信任例外或 ATS 例外。

目录浏览、工作区选择等行为由服务器已有网页提供；服务器与 Cloud 环境仍需按开源文档部署。本地功能编译通过并不代表服务器认证、Cloud 写回或通知送达已经通过真实验收。Web Push 设置保留系统浏览器入口，沿用原有 Safari 主屏幕网页流程。

独立地址校验：

```sh
xcrun swiftc -module-cache-path /private/tmp/buddy-cloudspace-module-cache \
  BuddyCloudSpace/CloudSpaceConfiguration.swift Tests/CloudSpaceConfigurationTests.swift \
  -o /private/tmp/buddy-cloudspace-tests
/private/tmp/buddy-cloudspace-tests
```
