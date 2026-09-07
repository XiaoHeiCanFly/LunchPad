# LunchPad

面向 macOS 26+ 的原生启动台替代品。界面沿用旧 Launchpad 的空间与操作习惯，并使用 Tahoe / Liquid Glass 视觉语言重新实现。

## 当前实现

- 扫描 `/Applications`、`/System/Applications` 和 `~/Applications`，跳过应用包内的嵌套应用并按真实路径去重
- 全屏、多显示器覆盖层；动态壁纸模糊、Liquid Glass 搜索框/分页器/文件夹
- 多显示器只呈现一个启动台，可选择跟随鼠标所在的活动显示器或固定到指定显示器
- F4 全局热键，并兼容旧键盘的 `NX_KEYTYPE_LAUNCH_PANEL` 媒体键
- 全局捏合打开、反向捏合关闭；透明度、缩放和模糊直接跟随手势进度
- 不使用固定 60Hz 定时器，交互由窗口所在屏幕的原生合成节拍呈现，可适配 120Hz ProMotion
- 鼠标拖拽、触控板滑动、滚轮、鼠标侧键和 `⌘←` / `⌘→` 翻页；拖页过程跟手
- 方向键选择、Return 打开、Esc 分层退出；自动记住最后页
- 实时搜索，支持显示名、Bundle ID、英文缩写、中文全拼和拼音首字母
- 应用拖到应用上创建文件夹，拖到文件夹继续合并，文件夹重命名、移出应用和自动解散
- 文件夹采用接近全宽的独立玻璃面板，标题悬浮在面板上方；打开/关闭时背景、面板和内容使用分层弹簧动画
- 拖拽经过项目时实时让位，悬停中央显示文件夹候选反馈，拖到屏幕边缘自动翻页
- 应用以文件 URL 对外拖拽，可直接放入 Dock
- 按住 Option 显示卸载按钮；确认后使用系统废纸篓，系统应用受保护
- Option 编辑态使用 120Hz 时间轴抖动，松键立即停止；切到其他应用或点击启动台空白区域会自动关闭
- 右键打开、重命名显示名称、隐藏、访达定位、卸载、排序和重新扫描
- 可调每页行列数与图标尺寸，支持布局 JSON 备份/恢复和重新显示隐藏应用
- 小屏幕会按可用宽高同步降低列数、行数和图标尺寸，并同步更新分页容量与键盘导航步长
- 首次升级会将系统 Utilities 目录及常用系统工具整理到“实用工具”文件夹；用户解散后不会反复自动创建
- 分页指示器读取目标显示器的 `visibleFrame`，在底部 Dock 常驻时自动上移
- Magic Mouse/触控板精确滚动以一个手势周期为单位锁定，每次最多翻一页并忽略惯性阶段
- 可分别控制 Dock 图标与菜单栏图标显隐，并使用系统登录项服务设置开机启动
- Dock 图标、菜单栏图标和 F4 都可以重复开关 LunchPad
- 鼠标停留在 Dock 中正在运行的应用图标上，在图标旁以 DockDoor 同款方式弹出该应用的窗口预览浮层：毛玻璃卡片、应用名头部、方向键/Return 键盘导航、移开鼠标自动淡出
- Reduce Motion 与 Reduce Transparency 无障碍降级

## 构建

使用 Xcode 26.6 或更新版本打开 `LunchPad.xcodeproj`，选择 `LunchPad` scheme 运行。工程最低部署目标是 macOS 26.5。

首次使用全局触控板手势时，在 LunchPad 设置中授予“辅助功能”权限。LunchPad 会实时检查授权结果；F4 的 Carbon 全局热键不依赖该权限。

## GitHub 自动构建与发布

工作流：`.github/workflows/build.yml`。推送这些配置到 GitHub 后生效，无需配置个人 Token 或证书。

- 推送 `main` 或提交 PR：在 `macos-26` 上编译 Release 通用应用（arm64 + x86_64）。
- GitHub → Actions → **Build and package macOS** → **Run workflow**：编译并打包，在运行结果的 **Artifacts → LunchPad-packages** 下载 DMG、源码和校验文件；不会创建 Release。
- 推送 `v主版本.次版本.补丁版本` 标签：构建成功后自动发布 GitHub Release，附带 DMG、对应提交的源码归档和 SHA-256 校验文件。例如：

```bash
git tag v1.0.1
git push github v1.0.1
```

标签版本自动写入应用版本号，构建号取 Actions 的运行序号。只支持正式版本标签，例如 `v1.0.1`；不支持 `v1.0.1-beta`。请确认标签指向已经包含工作流的提交。已公开的 Release 不会被覆盖，需要使用新版本标签；发布中断留下的草稿可通过重新运行工作流继续上传。

构建使用运行器自带的 Xcode，启动时检查 SDK 至少为 macOS 26.5，不降低项目部署目标。运行器配置参考 [GitHub 官方 macOS 镜像说明](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)。PR 和构建任务只有仓库读取权限，仅标签发布任务获得 `contents: write`。

当前是**无开发者证书构建**：仅在打包副本上进行 ad-hoc 签名，未做 Developer ID 签名、公证或 stapling。Gatekeeper 可能拦截，权限授权及登录项仍需实机确认，详见 [安装说明](docs/UNSIGNED-BUILD.md)。未来接入证书时，使用 GitHub Secrets 保存证书和公证凭据，不应提交到仓库。

本地打包已编译的通用应用：

```bash
bash scripts/package-dmg.sh /path/to/LunchPad.app /path/to/output
```

打包脚本不会覆盖已有产物，也不会改动输入的应用；源码归档来自当前 Git `HEAD`，因此本地正式打包前应先提交代码，并用同一提交构建应用。

## 系统 API 边界

辅助功能授权后，LunchPad 可在其他应用处于前台时通过全局 `NSEvent` 监视器接收捏合进度和 Option 键状态。公开事件提供连续的 magnification 与 phase，但不提供触点数量，因此具体手指数仍由系统触控板映射决定。项目没有使用私有 MultitouchSupport API，便于后续签名、公证和分发。

开机启动使用 `SMAppService.mainApp`，要求应用经过代码签名；Xcode 正常运行或归档的签名构建可直接注册，使用 `CODE_SIGNING_ALLOWED=NO` 生成的临时调试包只能验证界面与编译。

“卸载”只把应用本体移到废纸篓，不会静默清除容器、缓存或偏好设置，避免误删用户数据。

Dock 悬停预览基于 [DockDoor](https://github.com/ejbills/DockDoor) 的 GPLv3 源码迁移并针对 LunchPad 做了集成：通过辅助功能订阅 Dock 的 `kAXSelectedChildrenChangedNotification` 获得悬停图标（不依赖鼠标坐标命中检测），窗口列表来自 AX/CGWindow 联合筛选，预览图使用 CGS 硬件窗口捕获，面板定位依赖 Dock 方向。该功能同时依赖辅助功能和屏幕录制权限，并使用了若干稳定的私有符号（`CoreDockGetOrientationAndPinning`、`CGSHWCaptureWindowList`、`_AXUIElementGetWindow`、SkyLight 置顶等，与 DockDoor 相同）；这些符号不适用于 App Store 分发，仅适合开发者签名/Sparkle 类分发渠道。版权与许可说明见 [NOTICE.md](NOTICE.md) 和 [LICENSE](LICENSE)。

功能取舍参考了 [LaunchOS 的功能说明](https://launchosapp.com/features/)，实现代码为本项目独立编写。
