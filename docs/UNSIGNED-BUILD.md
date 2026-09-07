# 安装说明

此包适用于 macOS 26.5 或更高版本，包含 Apple Silicon 与 Intel 两种架构。

打开 DMG，将 LunchPad.app 拖到 Applications，然后从“应用程序”启动。

## 签名与权限

本构建仅使用不依赖证书的 ad-hoc 签名，**没有 Developer ID 签名，也没有 Apple 公证**。这不等于 macOS 已验证开发者身份；Gatekeeper 可能阻止打开。

请只从可信仓库下载并核对 SHA256SUMS.txt。在确认来源后，可按 macOS 的提示进入“系统设置 → 隐私与安全性”处理被阻止的应用。不要关闭系统安全保护或执行全局绕过命令。

辅助功能、屏幕录制权限仍需用户手动授予；更新构建后可能需要重新授权。开机启动等依赖签名身份的功能，不保证在此构建中正常工作。

需要面向普通用户分发时，应另行接入 Developer ID 签名和公证。

## 源码与许可

DMG 内附带 LICENSE 和 NOTICE.md。对应版本源码见同一 GitHub Release 中的 `LunchPad-版本-universal-source.tar.gz`。
