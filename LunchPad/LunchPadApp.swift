import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@main
struct LunchPadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            LauncherSettingsView()
                .environmentObject(LauncherController.shared.store)
                .environmentObject(LauncherController.shared)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = NSImage(named: "LaunchpadIcon") {
            NSApp.applicationIconImage = resizedDockIcon(from: icon)
        }
        configureStatusItem()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                (NSApp.delegate as? AppDelegate)?.configureStatusItem()
            }
        }
        // Always launch silently. The launcher appears on demand (hotkey,
        // Dock icon, or menu bar) — never as a surprise window at startup,
        // whether the app was started at login or opened by hand.
        LauncherController.shared.start(silently: true)
        DispatchQueue.main.async {
            NSApp.windows.forEach { $0.orderOut(nil) }
        }
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        LauncherController.shared.toggle()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        LauncherController.shared.terminateImmediately()
    }

    private func resizedDockIcon(from image: NSImage) -> NSImage {
        let targetSize = NSSize(width: 128, height: 128)
        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .sourceOver, fraction: 1.0)
        resized.unlockFocus()
        return resized
    }

    private func configureStatusItem() {
        let shouldShow = UserDefaults.standard.object(forKey: "show-menu-bar-icon") as? Bool ?? true
        guard shouldShow else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
            return
        }
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "LunchPad") {
            image.isTemplate = true
            item.button?.image = image
        }
        item.button?.toolTip = "LunchPad"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addMenuItem(
            LauncherController.shared.isPresented ? "关闭 LunchPad" : "打开 LunchPad",
            action: #selector(toggleLauncher),
            to: menu
        )
        addMenuItem("重新扫描应用", action: #selector(rescanApplications), to: menu)
        menu.addItem(.separator())
        addMenuItem("设置…", action: #selector(openSettings), to: menu)
        addMenuItem("退出 LunchPad", action: #selector(terminateApplication), to: menu)
    }

    private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func toggleLauncher() {
        LauncherController.shared.toggle()
    }

    @objc private func rescanApplications() {
        LauncherController.shared.store.scanApplications()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // The classic `showSettingsWindow:` hack no longer opens the SwiftUI
        // Settings scene on macOS 26 — `sendAction` returns true but nothing
        // happens. The scene is actually driven by the "Settings…" menu item
        // that SwiftUI generates, so invoke that item directly.
        if let item = Self.settingsMenuItem(in: NSApp.mainMenu), let action = item.action {
            _ = NSApp.sendAction(action, to: item.target, from: nil)
        } else {
            _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: self)
        }
        LauncherController.shared.presentSettingsAboveLauncher()
    }

    /// Recursively finds the "Settings…" menu item (⌘,) SwiftUI generates for
    /// the app's `Settings` scene. Matched by key equivalent because it is
    /// stable across localizations, unlike the item's localized title.
    private static func settingsMenuItem(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.keyEquivalent == "," { return item }
            if let submenu = item.submenu, let found = settingsMenuItem(in: submenu) { return found }
        }
        return nil
    }

    @objc private func terminateApplication() {
        NSApp.terminate(nil)
    }

    private static func resizedDockIcon(from source: NSImage) -> NSImage {
        let size = NSSize(width: 128, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        image.unlockFocus()
        return image
    }
}

private struct LauncherSettingsView: View {
    @EnvironmentObject private var store: LauncherStore
    @EnvironmentObject private var controller: LauncherController
    @AppStorage("grid-columns") private var columns = 7
    @AppStorage("grid-rows") private var rows = 5
    @AppStorage("icon-size") private var iconSize = 104.0
    @AppStorage("background-blur-radius") private var backgroundBlurRadius = 34.0
    @AppStorage("show-dock-icon") private var showDockIcon = true
    @AppStorage("show-menu-bar-icon") private var showMenuBarIcon = true
    @AppStorage("keyboard-shortcut-key-code") private var keyboardShortcutKeyCode = kVK_F4
    @AppStorage("keyboard-shortcut-modifiers") private var keyboardShortcutModifiers = 0
    @AppStorage("keyboard-shortcut-label") private var keyboardShortcutLabel = "F4"
    @AppStorage("display-mode") private var displayMode = "active"
    @AppStorage("fixed-display-id") private var fixedDisplayID = 0
    @AppStorage("dock-hover-expose") private var dockHoverExpose = true
    @AppStorage("hover-open-delay") private var hoverOpenDelay = 0.2
    @AppStorage("buffer-from-dock") private var bufferFromDock = -20.0
    @AppStorage("show-app-name") private var showAppName = true
    @AppStorage("show-animations") private var showAnimations = true
    @AppStorage("include-hidden-windows") private var includeHiddenWindows = true
    @AppStorage("show-current-space-only") private var showCurrentSpaceOnly = false
    @AppStorage("show-current-monitor-only") private var showCurrentMonitorOnly = false
    @AppStorage("ignore-single-window-apps") private var ignoreSingleWindowApps = false
    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section("打开方式") {
                LabeledContent("全局键盘快捷键") {
                    ShortcutRecorder(
                        keyCode: $keyboardShortcutKeyCode,
                        modifiers: $keyboardShortcutModifiers,
                        label: $keyboardShortcutLabel
                    ) { keyCode, modifiers, label in
                        controller.setKeyboardShortcut(
                            keyCode: keyCode,
                            modifiers: UInt32(modifiers),
                            label: label
                        )
                    }
                }
                HStack {
                    LabeledContent("触控板捏合") {
                        Text(controller.accessibilityPermissionGranted ? "辅助功能已允许" : "需要辅助功能权限")
                            .foregroundStyle(controller.accessibilityPermissionGranted ? .green : .secondary)
                    }
                    if !controller.accessibilityPermissionGranted {
                        Button("授权") { controller.requestAccessibilityPermission() }
                    }
                }
            }
            Section("系统") {
                Toggle("在 Dock 中显示 LunchPad", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, visible in
                        controller.setDockIconVisible(visible)
                    }
                Toggle("显示菜单栏图标", isOn: $showMenuBarIcon)
                Toggle("登录时自动启动", isOn: Binding(
                    get: { controller.loginItemEnabled },
                    set: { controller.setLaunchAtLogin($0) }
                ))
                if controller.loginItemStatus == .requiresApproval {
                    HStack(spacing: 8) {
                        Text("已设置，还需在系统设置中批准后才会在登录时启动。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("打开系统设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }
                        .controlSize(.small)
                    }
                }
                Picker("启动台显示位置", selection: $displayMode) {
                    Text("当前活动显示器").tag("active")
                    Text("固定显示器").tag("fixed")
                }
                .onChange(of: displayMode) { _, mode in
                    if mode == "fixed", fixedDisplayID == 0,
                       let first = controller.displayOptions.first {
                        fixedDisplayID = first.id
                        controller.setFixedDisplayID(first.id)
                    }
                    controller.setDisplayMode(mode)
                }
                if displayMode == "fixed" {
                    Picker("显示器", selection: $fixedDisplayID) {
                        ForEach(controller.displayOptions) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                    .onChange(of: fixedDisplayID) { _, id in
                        controller.setFixedDisplayID(id)
                    }
                }
                if !showDockIcon && !showMenuBarIcon {
                    Text("Dock 和菜单栏图标都隐藏后，仍可用 \(keyboardShortcutLabel) 或四指捏合打开 LunchPad。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Dock 悬停") {
                Toggle("悬停 Dock 图标显示窗口", isOn: $dockHoverExpose)
                LabeledContent("悬停延迟") {
                    Slider(value: $hoverOpenDelay, in: 0.1...1.5, step: 0.1)
                        .frame(width: 180)
                    Text("\(hoverOpenDelay, specifier: "%.1f") 秒")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                LabeledContent("与 Dock 的间距") {
                    Slider(value: Binding(
                        get: { bufferFromDock + 20 },
                        set: { bufferFromDock = $0 - 20 }
                    ), in: -40...40, step: 1)
                        .frame(width: 180)
                    Text("\(Int(bufferFromDock + 20))")
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }
                .onChange(of: bufferFromDock) { _, _ in
                    DockPreviewPanel.shared.refreshDockSpacing()
                }
                Toggle("显示应用名称", isOn: $showAppName)
                Toggle("显示动画", isOn: $showAnimations)
                Toggle("包含最小化与隐藏的窗口", isOn: $includeHiddenWindows)
                Toggle("仅显示当前桌面的窗口", isOn: $showCurrentSpaceOnly)
                Toggle("仅显示当前显示器的窗口", isOn: $showCurrentMonitorOnly)
                Toggle("单窗口应用不显示预览", isOn: $ignoreSingleWindowApps)
                HStack {
                    LabeledContent("窗口预览权限") {
                        Text(screenRecordingGranted ? "屏幕录制已允许" : "需要屏幕录制权限")
                            .foregroundStyle(screenRecordingGranted ? .green : .secondary)
                    }
                    if !screenRecordingGranted {
                        Button("授权") { requestScreenRecordingPermission() }
                    }
                }
                Text("鼠标停留在 Dock 中正在运行的应用图标上，会在图标旁显示该应用的窗口预览；点击窗口切换到该窗口，移开鼠标自动关闭。辅助功能权限用于识别 Dock 悬停，屏幕录制权限用于生成窗口预览图。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("应用与布局") {
                Stepper("每行 \(columns) 个应用", value: $columns, in: 5...10)
                Stepper("每页 \(rows) 行", value: $rows, in: 3...7)
                LabeledContent("图标大小") {
                    Slider(value: $iconSize, in: 64...112, step: 4)
                        .frame(width: 180)
                    Text("\(Int(iconSize))")
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
                Picker("排序方式", selection: $store.sortMode) {
                    Text("自定义").tag(SortMode.custom)
                    Text("名称").tag(SortMode.name)
                    Text("安装时间").tag(SortMode.installDate)
                    Text("使用频率").tag(SortMode.frequency)
                }
                if store.sortMode == .installDate {
                    Picker("安装时间方向", selection: $store.installSortAscending) {
                        Text("正序（最早的在前）").tag(true)
                        Text("倒序（最近的在前）").tag(false)
                    }
                }
                Button("重新扫描应用") { store.scanApplications() }
            }
            Section("外观") {
                LabeledContent("背景模糊度") {
                    Slider(value: $backgroundBlurRadius, in: 0...64, step: 2)
                        .frame(width: 180)
                    Text("\(Int(backgroundBlurRadius))")
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
                Text("拖动滑块时，启动台背景会实时更新。背景始终不透明，不会显示后方窗口轮廓。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("数据") {
                HStack {
                    Button("备份布局…") { store.exportLayout() }
                    Button("恢复布局…") { store.importLayout() }
                }
                Button("重新显示已隐藏的应用") { store.restoreHiddenApplications() }
            }
            Section {
                Text("辅助功能权限用于优先拦截全局快捷键，并读取触控板四个原始触点。四指捏合的透明度与缩放会根据触点距离连续跟随手指。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 540, height: 620)
        .onAppear {
            controller.refreshAccessibilityPermission()
            controller.refreshLoginItemStatus()
            controller.refreshDisplayOptions()
            screenRecordingGranted = CGPreflightScreenCaptureAccess()
        }
    }

    private func requestScreenRecordingPermission() {
        guard CGRequestScreenCaptureAccess() else { return }
        Task { @MainActor in
            for _ in 0..<20 where !screenRecordingGranted {
                try? await Task.sleep(for: .milliseconds(500))
                screenRecordingGranted = CGPreflightScreenCaptureAccess()
            }
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    @Binding var label: String
    let onRecord: (Int, Int, String) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderControl {
        let control = ShortcutRecorderControl()
        control.onRecord = { newKeyCode, newModifiers, newLabel in
            keyCode = newKeyCode
            modifiers = newModifiers
            label = newLabel
            onRecord(newKeyCode, newModifiers, newLabel)
        }
        return control
    }

    func updateNSView(_ control: ShortcutRecorderControl, context: Context) {
        control.shortcutLabel = label
    }
}

private final class ShortcutRecorderControl: NSControl {
    var onRecord: ((Int, Int, String) -> Void)?
    var shortcutLabel = "F4" { didSet { needsDisplay = true } }
    private var isRecording = false
    private var recordingMonitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 156, height: 30) }

    override func mouseDown(with event: NSEvent) {
        beginRecording()
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        capture(event)
    }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.capture(event)
            return nil
        }
        needsDisplay = true
    }

    private func endRecording() {
        isRecording = false
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
            self.recordingMonitor = nil
        }
        needsDisplay = true
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            endRecording()
            window?.makeFirstResponder(nil)
            return
        }

        let carbonModifiers = Self.carbonModifiers(from: event.modifierFlags)
        let functionKeys: Set<Int> = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
        ]
        guard carbonModifiers != 0 || functionKeys.contains(Int(event.keyCode)) else {
            NSSound.beep()
            return
        }

        let newLabel = Self.displayLabel(
            keyCode: Int(event.keyCode),
            modifiers: carbonModifiers,
            characters: event.charactersIgnoringModifiers
        )
        shortcutLabel = newLabel
        endRecording()
        window?.makeFirstResponder(nil)
        onRecord?(Int(event.keyCode), Int(carbonModifiers), newLabel)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        (isRecording ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22) : NSColor.controlBackgroundColor)
            .setFill()
        shape.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        shape.lineWidth = isRecording ? 1.5 : 1
        shape.stroke()

        let text = isRecording ? "请按下快捷键…" : shortcutLabel
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static func displayLabel(keyCode: Int, modifiers: UInt32, characters: String?) -> String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }

        let specialKeys: [Int: String] = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
            kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"
        ]
        result += specialKeys[keyCode] ?? characters?.uppercased() ?? "Key \(keyCode)"
        return result
    }
}
