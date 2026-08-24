import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import CoreGraphics
import QuartzCore
import ServiceManagement
import SwiftUI

struct LauncherDisplayOption: Identifiable, Hashable {
    let id: Int
    let name: String
}

@MainActor
final class LauncherController: ObservableObject {
    static let shared = LauncherController()

    @Published private(set) var isPresented = false
    @Published private(set) var accessibilityPermissionGranted = false
    @Published private(set) var loginItemEnabled = false
    /// Raw ServiceManagement status so the settings view can branch on
    /// `.requiresApproval` (registration exists but the user must approve it
    /// in 系统设置 → 通用 → 登录项与扩展 before it actually launches at login).
    @Published private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    @Published private(set) var displayOptions: [LauncherDisplayOption] = []

    let store = LauncherStore()

    /// Display-link-driven progress engine for all open/close/gesture
    /// animation. Never publishes state, so gestures don't re-render SwiftUI.
    private let animator = LauncherGestureAnimator()

    private var panels: [LauncherPanel] = []
    private var uninstallDimmingPanel: NSPanel?
    private var uninstallDialogPanel: NSPanel?
    private var globalSystemKeyMonitor: Any?
    private var globalModifierMonitor: Any?
    private var localMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private var permissionPollTimer: Timer?
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var spaceSwitchingHotKeys: [EventHotKeyRef] = []
    private var systemEventTap: CFMachPort?
    private var systemEventTapSource: CFRunLoopSource?
    private var systemEventTapThread: Thread?
    private var scrollAccumulator: CGFloat = 0
    private var scrollGestureDidTurnPage = false
    private var scrollGestureEndTimer: Timer?
    private var lastPageTurn = Date.distantPast
    private var lastShortcutTrigger = Date.distantPast
    private var panelDisplayID: Int?
    /// The on-screen point every panel scales around (this screen's center),
    /// captured when the panels were built.
    private var presentationScreenCenter: CGPoint = .zero

    private var isPinching = false
    /// Gesture progress base: 1 if the launcher was already presented when a
    /// gesture began, 0 otherwise.
    private var baseProgressForGesture: CGFloat = 0
    /// Cumulative NSEvent magnification for the magnify fallback gesture.
    private var magnifyOffset: CGFloat = 0
    /// Whether the user's last intent was to show (true) or hide (false).
    /// Set immediately on user action, before animation completes.
    private var showIntent = false
    /// Identifies the latest presentation attempt so delayed visibility probes
    /// never report stale state after a later show/hide operation.
    private var presentationAttemptID = UUID()
    private var lastDiagnosticsProgressBucket = -1

    // Thread-safe flag for the CGEvent tap (runs on a background thread).
    private let _isPresentedOnScreen = AtomicBool()
    nonisolated var isPresentedOnScreen: Bool { _isPresentedOnScreen.value }

    /// 拖拽指针约束（见 DragConstraintBox）：拖拽期间指针不允许
    /// 离开启动台所在显示器。
    nonisolated static let dragConstraint = DragConstraintBox()

    /// 启动台窗口的 AppKit frame（左下原点屏幕坐标），供文件夹面板
    /// 区域换算使用。
    var presentedWindowFrame: NSRect? { panels.first?.frame }

    private func setPresented(_ value: Bool) {
        isPresented = value
        _isPresentedOnScreen.set(value)
    }

    private init() {
        UserDefaults.standard.register(defaults: [
            "show-dock-icon": true,
            "show-menu-bar-icon": true,
            "background-blur-radius": 34.0,
            "display-mode": "active",
            "keyboard-shortcut-key-code": kVK_F4,
            "keyboard-shortcut-modifiers": 0,
            "keyboard-shortcut-label": "F4"
        ])
        accessibilityPermissionGranted = AXIsProcessTrusted()
        let loginStatus = SMAppService.mainApp.status
        loginItemStatus = loginStatus
        loginItemEnabled = Self.loginItemIsOn(loginStatus)
    }

    // MARK: - Lifecycle

    func start(silently: Bool = false) {
        LauncherDiagnostics.shared.startSession(silently: silently)
        diagnosticRecord("lifecycle", "controller-start accessibility=\(AXIsProcessTrusted()) screens=\(NSScreen.screens.count)")
        applyDockIconPreference()
        installHotKey()
        installEventMonitors()
        installRawTrackpadMonitorIfAllowed()
        DockHoverObserver.shared.start()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in LauncherController.shared.rebuildPanels() }
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let c = LauncherController.shared
                // Don't hide during a gesture — the gesture owns the lifecycle.
                guard !c.isPinching, c.isPresented,
                      c.store.draggedEntryID == nil else { return }
                c.hide()
            }
        }
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let c = LauncherController.shared
                c.diagnosticRecord("space", "active-space-changed presented=\(c.isPresented) panels=\(c.panels.count)")
                if c.isPresented { c.hide(animated: false) }
            }
        }
        store.scanApplications()
        store.startObservingApplicationChanges()
        store.startObservingSystemLaunches()
        preWarmWallpaperCache()
        rebuildPanels()
        setupAnimator()
        if silently {
            animator.snap(to: 0)
            setPresented(false)
            panels.forEach { $0.orderOut(nil) }
            setSpaceSwitchingHotKeysEnabled(false)
        } else {
            show(animated: false)
        }
    }

    func terminateImmediately() {
        diagnosticRecord("lifecycle", "controller-terminate presented=\(isPresented) panels=\(panels.count)")
        store.stopObservingApplicationChanges()
        animator.stop()
        _isPresentedOnScreen.set(false)
        isPresented = false
        isPinching = false
        if let tap = systemEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            systemEventTap = nil
        }
        if let source = systemEventTapSource {
            CFRunLoopSourceInvalidate(source)
            systemEventTapSource = nil
        }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = globalSystemKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = globalModifierMonitor { NSEvent.removeMonitor(m) }
        DockHoverObserver.shared.stop()
        DockPreviewPanel.shared.hideWindow()
        Self.dragConstraint.setActive(false)
        panels.forEach { $0.contentView = nil; $0.orderOut(nil); $0.close() }
        panels.removeAll()
        uninstallDialogPanel?.contentView = nil; uninstallDialogPanel?.close()
        uninstallDimmingPanel?.contentView = nil; uninstallDimmingPanel?.close()
    }

    // MARK: - Show / Hide

    func show(animated: Bool = true) {
        let attemptID = UUID()
        presentationAttemptID = attemptID
        lastDiagnosticsProgressBucket = -1
        diagnosticRecord("presentation", "show-request id=\(attemptID.uuidString) animated=\(animated) presented=\(isPresented) intent=\(showIntent) progress=\(diagnosticNumber(animator.visualProgress)) panels=\(panels.count) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
        // The launcher and the Dock-hover preview never coexist.
        DockPreviewPanel.shared.hideWindow()
        showIntent = true
        // Defensive: if a drag was interrupted without ever reaching a drop,
        // make sure the launcher never reappears with a stuck dragged icon.
        store.endDrag()
        guard !isPresented || animator.visualProgress < 0.99 else {
            diagnosticRecord("presentation", "show-skipped id=\(attemptID.uuidString) reason=already-presented \(diagnosticPanelsSummary())")
            schedulePresentationProbes(for: attemptID)
            return
        }
        preparePresentationPanelsIfNeeded()
        guard !panels.isEmpty else {
            diagnosticRecord("error", "show-no-panels id=\(attemptID.uuidString) mode=\(displayMode) screens=\(NSScreen.screens.count)")
            showIntent = false
            setPresented(false)
            return
        }
        setPresented(true)
        setSpaceSwitchingHotKeysEnabled(true)
        store.optionIsPressed = NSEvent.modifierFlags.contains(.option)
        NSApp.activate(ignoringOtherApps: true)
        if animated && animator.visualProgress < 0.99 {
            // Apply the current (scaled-down) state before ordering front so
            // there is no one-frame full-opacity flash, then spring open.
            applyVisualChange(animator.visualProgress)
            for panel in panels { panel.orderFront(nil) }
            // Re-assert after display: ordering front can make AppKit re-sync
            // the content layer's anchor/position, which would otherwise move
            // the scale origin off-center for the first frame.
            applyVisualChange(animator.visualProgress)
            animator.beginSettling(to: 1)
        } else {
            animator.snap(to: 1)
            for panel in panels { panel.orderFront(nil) }
            applyVisualChange(1)
        }
        // The panel is a nonactivating panel, so ordering it front never makes
        // it key — and a non-key window consumes the first click just to become
        // key, so blank clicks would need two after a re-invoke. Make it key so
        // the first click always reaches the content view.
        panels.first?.makeKey()
        diagnosticRecord("presentation", "show-ordered id=\(attemptID.uuidString) \(diagnosticPanelsSummary())")
        schedulePresentationProbes(for: attemptID)
    }

    func hide(animated: Bool = true) {
        presentationAttemptID = UUID()
        diagnosticRecord("presentation", "hide-request animated=\(animated) presented=\(isPresented) progress=\(diagnosticNumber(animator.visualProgress)) panels=\(panels.count)")
        showIntent = false
        guard isPresented else { return }
        if animated {
            animator.beginSettling(to: 0)
        } else {
            animator.snap(to: 0)
            resetAndFinishHide()
        }
    }

    private func resetAndFinishHide() {
        store.cancelUninstall()
        closeUninstallPresentation()
        store.folderOverlayIsDimmed = false
        store.openFolderID = nil
        store.searchText = ""
        store.optionIsPressed = false
        // 关闭界面时清掉错误提示，避免上次打开失败的信息残留到下次打开。
        store.errorMessage = nil
        // A drag can be interrupted when the launcher closes mid-drag (the
        // window is hidden before the drop completes, so `performDrop` never
        // runs). End it so the dragged icon isn't left in the dragged state
        // when the launcher is shown again.
        store.endDrag()
        finishHide()
    }

    private func finishHide() {
        setPresented(false)
        for panel in panels {
            panel.orderOut(nil)
        }
        setSpaceSwitchingHotKeysEnabled(false)
        diagnosticRecord("presentation", "hide-finished \(diagnosticPanelsSummary())")
    }

    func toggle() {
        diagnosticRecord("presentation", "toggle intent=\(showIntent) presented=\(isPresented) progress=\(diagnosticNumber(animator.visualProgress))")
        showIntent ? hide() : show()
    }

    // MARK: - Presentation helpers

    private var reduceMotion: Bool {
        UserDefaults.standard.bool(forKey: "reduceMotion")
    }

    // MARK: - Diagnostics

    var diagnosticLogPath: String { LauncherDiagnostics.shared.logURL.path }

    func revealDiagnosticLog() {
        LauncherDiagnostics.shared.record("diagnostics", "reveal-log")
        NSWorkspace.shared.activateFileViewerSelecting([LauncherDiagnostics.shared.logURL])
    }

    func copyDiagnosticLog() {
        let text = LauncherDiagnostics.shared.readRecentText()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text.isEmpty ? "暂无诊断日志" : text, forType: .string)
        LauncherDiagnostics.shared.record("diagnostics", "copy-log bytes=\(text.utf8.count)")
    }

    func clearDiagnosticLog() {
        LauncherDiagnostics.shared.clear()
        LauncherDiagnostics.shared.record("diagnostics", "log-cleared")
    }

    private func diagnosticRecord(_ category: String, _ message: String) {
        LauncherDiagnostics.shared.record(category, message)
    }

    private func diagnosticNumber(_ value: CGFloat) -> String {
        String(format: "%.3f", Double(value))
    }

    private func diagnosticPanelsSummary() -> String {
        guard !panels.isEmpty else { return "panels=[]" }
        let summaries = panels.enumerated().map { index, panel in
            let opacity = panel.contentView?.layer?.opacity ?? -1
            return "#\(index){visible=\(panel.isVisible),key=\(panel.isKeyWindow),activeSpace=\(panel.isOnActiveSpace),occlusion=\(panel.occlusionState.rawValue),window=\(panel.windowNumber),level=\(panel.level.rawValue),alpha=\(diagnosticNumber(panel.alphaValue)),layerOpacity=\(diagnosticNumber(CGFloat(opacity))),frame=\(NSStringFromRect(panel.frame))}"
        }
        return "panels=[\(summaries.joined(separator: ","))]"
    }

    private func schedulePresentationProbes(for attemptID: UUID) {
        for delay in [0.08, 0.35, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.presentationAttemptID == attemptID else { return }
                let visiblePanelCount = self.panels.filter(\.isVisible).count
                let layerVisibleCount = self.panels.filter {
                    ($0.contentView?.layer?.opacity ?? 0) > 0.02
                }.count
                let anomalous = self.isPresented && (visiblePanelCount == 0 || layerVisibleCount == 0)
                self.diagnosticRecord(
                    anomalous ? "error" : "probe",
                    "show-probe id=\(attemptID.uuidString) delay=\(String(format: "%.2f", delay)) presented=\(self.isPresented) intent=\(self.showIntent) progress=\(self.diagnosticNumber(self.animator.visualProgress)) visiblePanels=\(visiblePanelCount) visibleLayers=\(layerVisibleCount) appActive=\(NSApp.isActive) \(self.diagnosticPanelsSummary())"
                )
            }
        }
    }

    // MARK: - Gesture (animator-driven, no SwiftUI re-render)

    /// Apply the current gesture progress to every panel's layer. This mutates
    /// CALayer properties only — no @Published change, so the SwiftUI view
    /// tree is never re-evaluated during a gesture.
    private func applyVisualChange(_ progress: CGFloat) {
        let scale: CGFloat
        let opacity: CGFloat
        if reduceMotion {
            scale = 1
            opacity = min(1, max(0, progress))
        } else {
            // One curve for both directions: opening travels progress 0→1,
            // closing travels 1→0, so closing is exactly the reverse of
            // opening. The grid arrives oversized (1.25) and settles to 1.0
            // while fading in; closing grows back to 1.25 while fading out.
            // Clamp progress to [0, 1] so a spring overshoot can never push
            // the scale below the final size (which would read as an end-of-
            // open bounce). Fade-in starts almost immediately (~5% progress)
            // and reaches full opacity near 55%, so the launcher reads as
            // "started" with very little finger travel while still tracking.
            let p = min(1, max(0, progress))
            scale = 1 + 0.25 * (1 - p)
            opacity = min(1, max(0, (p - 0.05) / 0.5))
        }
        let center = presentationScreenCenter
        for panel in panels {
            guard let layer = panel.contentView?.layer else { continue }
            let f = panel.targetFullFrame
            // Pin the layer's anchor to the shared screen center. Re-asserted
            // every frame because AppKit sets a window content layer's anchor
            // to (0,0) — with that default, a plain scale grows from the
            // panel's corner instead of the center. With
            //   anchorPoint = pivot / size  and  position = pivot,
            // the frame stays (0,0,size) (no shift) and the scale expands
            // toward the on-screen center shared by every panel (no seams).
            let pivot = CGPoint(x: center.x - f.origin.x,
                                y: center.y - f.origin.y)
            layer.anchorPoint = CGPoint(x: pivot.x / f.width,
                                        y: pivot.y / f.height)
            layer.position = pivot
            layer.bounds = CGRect(origin: .zero, size: f.size)
            layer.opacity = Float(opacity)
            layer.transform = CATransform3DMakeScale(scale, scale, 1)
        }
        let bucket = min(4, max(0, Int((min(1, max(0, progress)) * 4).rounded(.down))))
        if bucket != lastDiagnosticsProgressBucket {
            lastDiagnosticsProgressBucket = bucket
            diagnosticRecord("animation", "progress=\(diagnosticNumber(progress)) scale=\(diagnosticNumber(scale)) opacity=\(diagnosticNumber(opacity)) panels=\(panels.count)")
        }
    }

    /// Called once per gesture when the fingers have moved meaningfully.
    /// Presents the panels if the gesture is opening the launcher.
    private func prepareGesturePresentation() {
        guard !isPresented else {
            diagnosticRecord("gesture", "prepare-skipped reason=already-presented progress=\(diagnosticNumber(animator.visualProgress))")
            return
        }
        let attemptID = UUID()
        presentationAttemptID = attemptID
        lastDiagnosticsProgressBucket = -1
        diagnosticRecord("gesture", "prepare-presentation id=\(attemptID.uuidString) progress=\(diagnosticNumber(animator.visualProgress))")
        DockPreviewPanel.shared.hideWindow()
        preparePresentationPanelsIfNeeded()
        guard !panels.isEmpty else {
            diagnosticRecord("error", "gesture-no-panels id=\(attemptID.uuidString) mode=\(displayMode)")
            isPinching = false
            return
        }
        setPresented(true)
        setSpaceSwitchingHotKeysEnabled(true)
        store.optionIsPressed = NSEvent.modifierFlags.contains(.option)
        NSApp.activate(ignoringOtherApps: true)
        applyVisualChange(animator.visualProgress)
        for panel in panels { panel.orderFront(nil) }
        // Re-assert after display (AppKit re-syncs layer geometry on order).
        applyVisualChange(animator.visualProgress)
        panels.first?.makeKey()
        diagnosticRecord("gesture", "panels-ordered id=\(attemptID.uuidString) \(diagnosticPanelsSummary())")
        schedulePresentationProbes(for: attemptID)
    }

    /// Main-thread entry point for a new four-finger contact (one hop per
    /// gesture from the raw-trackpad callback thread).
    func rawTrackpadGestureBegan() {
        guard !animator.isTracking else {
            diagnosticRecord("gesture", "raw-begin-skipped reason=already-tracking")
            return
        }
        diagnosticRecord("gesture", "raw-begin presented=\(isPresented) progress=\(diagnosticNumber(animator.visualProgress))")
        isPinching = true
        baseProgressForGesture = isPresented ? 1 : 0
        animator.beginTracking(base: baseProgressForGesture) { [weak self] in
            guard let self else { return 0 }
            return self.baseProgressForGesture
                + TrackpadContactState.shared.motion / LauncherGestureAnimator.rawSensitivity
        }
        animator.trackingContactActive = { TrackpadContactState.shared.contactActive }
    }

    private func setupAnimator() {
        animator.onVisualChange = { [weak self] progress in
            self?.applyVisualChange(progress)
        }
        animator.onGestureBegin = { [weak self] in
            self?.prepareGesturePresentation()
        }
        animator.onSettleComplete = { [weak self] didOpen in
            self?.handleSettleComplete(didOpen)
        }
        animator.start(on: presentationScreen())
    }

    private func handleSettleComplete(_ didOpen: Bool) {
        diagnosticRecord("animation", "settle-complete opened=\(didOpen) progress=\(diagnosticNumber(animator.visualProgress)) \(diagnosticPanelsSummary())")
        isPinching = false
        if !didOpen {
            resetAndFinishHide()
        }
    }

    // MARK: - NSEvent magnify (fallback when raw trackpad is unavailable)

    private func handleMagnify(_ event: NSEvent) {
        if event.phase == .began || !animator.isTracking {
            isPinching = true
            magnifyOffset = 0
            baseProgressForGesture = isPresented ? 1 : 0
            animator.beginTracking(base: baseProgressForGesture) { [weak self] in
                guard let self else { return 0 }
                return self.baseProgressForGesture
                    - self.magnifyOffset / LauncherGestureAnimator.magnifySensitivity
            }
            animator.trackingContactActive = nil
        }
        magnifyOffset = CGFloat(event.magnification)
        if event.phase == .ended || event.phase == .cancelled {
            animator.endTracking()
        }
    }

    // MARK: - Event monitors

    private func installEventMonitors() {
        installGlobalEventMonitors()
        installSystemEventTap()
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.magnify, .swipe, .flagsChanged, .keyDown, .systemDefined, .scrollWheel, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .magnify:
                guard !RawTrackpadGestureMonitor.shared.isRunning else { return event }
                self.handleMagnify(event)
                return nil
            case .flagsChanged:
                self.store.optionIsPressed = event.modifierFlags.contains(.option)
            case .keyDown:
                return self.handleKeyDown(event)
            case .systemDefined:
                if DockPreviewPanel.shared.isVisible {
                    if self.isMissionControlKeyDown(event) { DockPreviewPanel.shared.hideWindow(); return event }
                }
                if self.isPresented && self.isMissionControlKeyDown(event) {
                    self.hide(animated: false); return event
                }
                if self.isLaunchPanelKeyDown(event) { self.toggle(); return nil }
            case .scrollWheel:
                // Paging works during search too — search results are paginated
                // like the full grid, so scroll/swipe must turn pages there as
                // well (the old ScrollView list scrolled on its own instead).
                if self.isPresented, event.window is LauncherPanel,
                   self.store.uninstallRequest == nil, self.store.openFolderID == nil {
                    self.handleScroll(event); return nil
                }
            case .swipe:
                if DockPreviewPanel.shared.isVisible { DockPreviewPanel.shared.hideWindow(); return event }
                if self.isPresented { self.hide(animated: false); return event }
            case .otherMouseDown:
                if event.buttonNumber == 3 { self.store.pageBackward(); return nil }
                if event.buttonNumber == 4 { self.store.pageForward(); return nil }
            default: break
            }
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // While the Dock-hover preview is up it owns the keyboard:
        // Esc dismisses it and everything else is consumed so shortcuts
        // (⌘Q, ⌘W…) can't reach the backgrounded app through our key panel.
        if DockPreviewPanel.shared.isVisible {
            if event.keyCode == UInt16(kVK_Escape) {
                DockPreviewPanel.shared.hideWindow()
            } else {
                _ = DockPreviewPanel.shared.handleNavigationKey(Int(event.keyCode))
            }
            return nil
        }
        if isPresented {
            let arrows = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
            if event.keyCode == UInt16(kVK_F3)
                || (event.modifierFlags.contains(.control) && arrows.contains(Int(event.keyCode))) {
                hide(animated: false); return event
            }
        }
        if event.keyCode == UInt16(kVK_Escape) {
            if store.uninstallRequest != nil { store.cancelUninstall() }
            else if !store.searchText.isEmpty { store.searchText = "" }
            else if store.openFolderID != nil { store.openFolderID = nil }
            else { hide() }
            return nil
        }
        if event.modifierFlags.contains(.command), event.keyCode == UInt16(kVK_LeftArrow) {
            store.pageBackward(); return nil
        }
        if event.modifierFlags.contains(.command), event.keyCode == UInt16(kVK_RightArrow) {
            store.pageForward(); return nil
        }
        if store.searchText.isEmpty, store.openFolderID == nil {
            switch Int(event.keyCode) {
            case kVK_LeftArrow: store.moveSelection(by: -1); return nil
            case kVK_RightArrow: store.moveSelection(by: 1); return nil
            case kVK_UpArrow: store.moveSelection(by: -store.gridColumns); return nil
            case kVK_DownArrow: store.moveSelection(by: store.gridColumns); return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if let entry = store.selectedEntry {
                    switch entry {
                    case .application(let app): launch(app)
                    case .folder(let folder): store.openFolder(folder)
                    }
                    return nil
                }
            default: break
            }
        }
        return event
    }

    private func installGlobalEventMonitors() {
        if let m = globalSystemKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = globalModifierMonitor { NSEvent.removeMonitor(m) }
        globalSystemKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { event in
            Task { @MainActor in
                let c = LauncherController.shared
                if c.isLaunchPanelKeyDown(event) { c.toggle() }
            }
        }
        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            Task { @MainActor in
                LauncherController.shared.store.optionIsPressed = event.modifierFlags.contains(.option)
            }
        }
    }

    // MARK: - CGEvent Tap (system gesture blocking)

    private func installSystemEventTap() {
        guard AXIsProcessTrusted(), systemEventTap == nil else { return }
        // scrollWheel is deliberately NOT in the mask: when presented, the
        // launcher is key and full-screen, so scroll events are delivered to
        // it and handled by the local event monitor. Blocking them here would
        // only add work to this callback.
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDragged.rawValue)
            | CGEventMask(1 << 14) // NX_SYSDEFINED
            | CGEventMask(1 << 18) // rotate
            | CGEventMask(1 << 19) // beginGesture
            | CGEventMask(1 << 20) // endGesture
            | CGEventMask(1 << 29) // gesture
            | CGEventMask(1 << 30) // magnify
            | CGEventMask(1 << 31) // swipe
        let pointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let c = Unmanaged<LauncherController>.fromOpaque(userInfo).takeUnretainedValue()
                // Re-enable on a tap timeout. This callback must never block:
                // a slow callback is exactly what gets the tap disabled by
                // timeout, which is what lets the system's own gestures
                // through. All state read below is thread-safe (AtomicBool /
                // NSLock / UserDefaults / event fields) — no main-thread hop.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if let t = c.systemEventTap { CGEvent.tapEnable(tap: t, enable: true) }
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }
                // Block system gesture events when presented or during a pinch.
                if [18, 19, 20, 29, 30, 31].contains(type.rawValue) {
                    if c.isPresentedOnScreen { return nil }
                    if RawTrackpadGestureMonitor.hasFourFingerContact { return nil }
                }
                // 拖拽期间把指针拉回启动台所在显示器：图标无法被拖到其他显示器。
                // 拖拽时鼠标移动以 leftMouseDragged 形式上报，因此一并处理。
                if (type == .mouseMoved || type == .leftMouseDragged
                    || type == .rightMouseDragged || type == .otherMouseDragged),
                   let clamped = c.clampDragPointer(event.location)
                {
                    CGWarpMouseCursorPosition(clamped)
                }
                // A drop outside every SwiftUI destination has no
                // `performDrop` callback. Observe the session's real mouse-up
                // and clear any surviving drag state after AppKit has had a
                // chance to deliver a valid destination drop on the main run
                // loop. This prevents the launcher remaining stuck in drag UI.
                if type == .leftMouseUp {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        MainActor.assumeIsolated {
                            c.store.finishAbandonedDragIfNeeded()
                        }
                    }
                }
                // Preemptive beginGesture block with timeout release.
                if type.rawValue == 19 {
                    RawTrackpadGestureMonitor.pendingBeginGesture = true
                    DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.06) {
                        if RawTrackpadGestureMonitor.pendingBeginGesture {
                            RawTrackpadGestureMonitor.pendingBeginGesture = false
                        }
                    }
                    return nil
                }
                if type.rawValue == 20, RawTrackpadGestureMonitor.pendingBeginGesture {
                    RawTrackpadGestureMonitor.pendingBeginGesture = false
                    return nil
                }
                // The dock-hover preview panel keeps the background application
                // inactive, so navigation keys are handled at the session tap.
                if type == .keyDown, DockPreviewPanel.isPresentedOnScreen {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let handledKeys: Set<Int64> = [36, 53, 76, 123, 124, 125, 126]
                    if handledKeys.contains(keyCode) {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                if keyCode == 53 {
                                    DockPreviewPanel.shared.hideWindow()
                                } else {
                                    _ = DockPreviewPanel.shared.handleNavigationKey(Int(keyCode))
                                }
                            }
                        }
                        return nil
                    }
                }
                // keyDown: trigger the configured shortcut even when the app is
                // backgrounded. The trigger is dispatched async — never sync.
                if type == .keyDown, c.matchesConfiguredShortcut(event) {
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { c.triggerConfiguredShortcut() }
                        }
                    }
                    return nil
                }
                // Everything else is handled by the local event monitor when
                // the launcher is presented — pass through untouched.
                return Unmanaged.passUnretained(event)
            }, userInfo: pointer
        ) else { return }
        systemEventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap); systemEventTap = nil; return
        }
        systemEventTapSource = source
        let ctx = EventTapThreadContext(tap: tap, source: source)
        let t = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), ctx.source, .commonModes)
            CGEvent.tapEnable(tap: ctx.tap, enable: true)
            CFRunLoopRun()
        }
        t.name = "com.king.LunchPad.event-tap"
        t.qualityOfService = .userInteractive
        systemEventTapThread = t
        t.start()
    }

    // Presented-state key/scroll handling moved entirely to the local event
    // monitor (installEventMonitors): the launcher is key and full-screen while
    // presented, so it receives those events directly. Keeping them out of the
    // tap removes the main-thread hop that could stall and disable the tap.

    // MARK: - Scroll pagination

    private func handleScroll(_ event: NSEvent) {
        guard store.uninstallRequest == nil, store.openFolderID == nil else { return }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { resetScrollGesture() }
        if !event.momentumPhase.isEmpty {
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { resetScrollGesture() }
            return
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { resetScrollGesture(); return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            scrollGestureEndTimer?.invalidate()
            scrollGestureEndTimer = Timer.scheduledTimer(withTimeInterval: 0.24, repeats: false) { _ in
                Task { @MainActor in LauncherController.shared.resetScrollGesture() }
            }
            guard !scrollGestureDidTurnPage else { return }
            scrollAccumulator += delta
            guard abs(scrollAccumulator) >= 42 else { return }
            if scrollAccumulator < 0 { store.pageForward() } else { store.pageBackward() }
            scrollGestureDidTurnPage = true; scrollAccumulator = 0; lastPageTurn = Date()
        } else {
            guard abs(delta) >= 1, Date().timeIntervalSince(lastPageTurn) > 0.32 else { return }
            if delta < 0 { store.pageForward() } else { store.pageBackward() }
            lastPageTurn = Date()
        }
    }

    private func resetScrollGesture() {
        scrollGestureEndTimer?.invalidate(); scrollGestureEndTimer = nil
        scrollAccumulator = 0; scrollGestureDidTurnPage = false
    }

    // MARK: - Raw trackpad monitor

    private func installRawTrackpadMonitorIfAllowed() {
        guard AXIsProcessTrusted() else { return }
        RawTrackpadGestureMonitor.shared.start()
    }

    // MARK: - Hot key

    private func installHotKey() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            let s = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard s == noErr else { return noErr }
            let c = Unmanaged<LauncherController>.fromOpaque(userData).takeUnretainedValue()
            if id.id == 1 { Task { @MainActor in c.triggerConfiguredShortcut() } }
            return noErr
        }, 1, &type, pointer, &eventHandler)
        registerLauncherHotKey(
            keyCode: UInt32(UserDefaults.standard.integer(forKey: "keyboard-shortcut-key-code")),
            modifiers: UInt32(UserDefaults.standard.integer(forKey: "keyboard-shortcut-modifiers")),
            label: UserDefaults.standard.string(forKey: "keyboard-shortcut-label") ?? "F4"
        )
    }

    private func registerLauncherHotKey(keyCode: UInt32, modifiers: UInt32, label: String) {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        let id = EventHotKeyID(signature: 0x4C4E5044, id: 1)
        let s = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        if s != noErr && !AXIsProcessTrusted() {
            store.errorMessage = "快捷键 \(label) 已被其他应用占用，请录制其他组合。"
        }
    }

    private func triggerConfiguredShortcut() {
        guard Date().timeIntervalSince(lastShortcutTrigger) > 0.28 else { return }
        lastShortcutTrigger = Date(); toggle()
    }

    private func setSpaceSwitchingHotKeysEnabled(_ enabled: Bool) {
        spaceSwitchingHotKeys.forEach { UnregisterEventHotKey($0) }
        spaceSwitchingHotKeys.removeAll()
    }

    // MARK: - Helpers

    /// 拖拽约束：指针越出启动台所在显示器时返回应拉回的位置。
    nonisolated private func clampDragPointer(_ location: CGPoint) -> CGPoint? {
        let (frame, active) = Self.dragConstraint.get()
        guard active, !frame.isEmpty, !frame.contains(location) else { return nil }
        return CGPoint(
            x: min(max(location.x, frame.minX), frame.maxX),
            y: min(max(location.y, frame.minY), frame.maxY)
        )
    }

    /// Reads only thread-safe state (UserDefaults + CGEvent fields), so the
    /// CGEvent tap can call it on its own thread without a main-thread hop.
    nonisolated private func matchesConfiguredShortcut(_ event: CGEvent) -> Bool {
        let d = UserDefaults.standard
        guard Int(event.getIntegerValueField(.keyboardEventKeycode)) == d.integer(forKey: "keyboard-shortcut-key-code") else { return false }
        let cfg = UInt32(d.integer(forKey: "keyboard-shortcut-modifiers"))
        var got: UInt32 = 0
        if event.flags.contains(.maskCommand) { got |= UInt32(cmdKey) }
        if event.flags.contains(.maskAlternate) { got |= UInt32(optionKey) }
        if event.flags.contains(.maskControl) { got |= UInt32(controlKey) }
        if event.flags.contains(.maskShift) { got |= UInt32(shiftKey) }
        return got == cfg
    }

    private func isLaunchPanelKeyDown(_ event: NSEvent) -> Bool {
        (event.data1 & 0xFFFF0000) >> 16 == 13 && (event.data1 & 0x0000FF00) >> 8 == 0x0A
    }

    private func isMissionControlKeyDown(_ event: NSEvent) -> Bool {
        (event.data1 & 0xFFFF0000) >> 16 == 32 && (event.data1 & 0x0000FF00) >> 8 == 0x0A
    }

    // MARK: - Display / Panels

    private func preWarmWallpaperCache() {
        let blurRadius = UserDefaults.standard.double(forKey: "background-blur-radius")
        DispatchQueue.global(qos: .userInitiated).async {
            for screen in NSScreen.screens {
                let url = NSWorkspace.shared.desktopImageURL(for: screen)
                _ = LauncherWallpaperCache.shared.image(for: url, screenSize: screen.frame.size, blurRadius: blurRadius)
            }
        }
    }

    private func rebuildPanels() {
        diagnosticRecord("panel", "rebuild-start existing=\(panels.count) mode=\(displayMode) screens=\(NSScreen.screens.count)")
        panels.forEach { $0.close() }
        // Reset presented state so the next show()/toggle() starts clean.
        // Without this, unplugging the display that held the launcher leaves
        // isPresented = true with an empty panels array, which jams the
        // show/hide state machine (show() returns early, toggle() calls
        // hide() on an already-hidden controller, menu bar stays stuck on
        // "关闭 LunchPad").
        animator.snap(to: 0)
        setPresented(false)
        showIntent = false
        store.resetAdaptiveGrid()
        refreshDisplayOptions()
        guard let screen = presentationScreen() else {
            panels = []; panelDisplayID = nil
            diagnosticRecord("error", "rebuild-no-screen")
            return
        }
        panelDisplayID = displayID(for: screen)
        // 拖拽指针约束到该显示器（CG 坐标：左上原点）。
        Self.dragConstraint.setFrame(screen.cgFrame)
        let dockL = max(0, screen.visibleFrame.minX - screen.frame.minX)
        let dockR = max(0, screen.frame.maxX - screen.visibleFrame.maxX)
        let dockB = max(0, screen.visibleFrame.minY - screen.frame.minY)
        let safe = screen.safeAreaInsets
        let menuBarH = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        // On displays without a notch (external monitors, non-notched built-ins)
        // `safe.top` is 0, so the search box would hug the top edge under the
        // short menu bar. Give those displays a baseline drop similar to what
        // the notch provides, so the search box sits at a consistent height.
        let topObstruction = max(menuBarH, safe.top > 0 ? safe.top : 34)
        let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: screen)
        let screenCenter = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        presentationScreenCenter = screenCenter
        // One full-screen window. It spans the whole display including the
        // Dock area, so the blurred wallpaper is a single continuous surface —
        // no separate Dock backdrop strip (which showed a seam/blank bar).
        // The panel's window level sits below the Dock, so the Dock still
        // renders on top of the wallpaper.
        let fullFrame = screen.frame
        let contentRect = NSRect(x: dockL, y: dockB,
                                 width: screen.frame.width - dockL - dockR,
                                 height: screen.frame.height - dockB)
        let rootView = ContentView(wallpaperURL: wallpaperURL,
            screenSize: fullFrame.size,
            contentRect: contentRect,
            searchTopObstruction: topObstruction,
            screenSafeInsets: EdgeInsets(top: safe.top, leading: safe.left, bottom: safe.bottom, trailing: safe.right))
            .environmentObject(store).environmentObject(self)
            .frame(width: fullFrame.width, height: fullFrame.height)
        let hv = NSHostingView(rootView: rootView)
        hv.frame = NSRect(origin: .zero, size: fullFrame.size)
        hv.autoresizingMask = [.width, .height]
        let panel = LauncherPanel(contentRect: fullFrame)
        panel.contentView = hv
        panel.setFrame(fullFrame, display: false)
        panel.targetFullFrame = fullFrame
        hv.wantsLayer = true
        // Scaling is pivoted around the screen center via `layer.transform`
        // only (see applyVisualChange), so anchorPoint/position/bounds are
        // left to AppKit — no per-panel anchor setup needed here.
        panels = [panel]
        diagnosticRecord("panel", "rebuild-finished display=\(panelDisplayID ?? -1) screen=\(screen.localizedName) frame=\(NSStringFromRect(fullFrame)) visible=\(NSStringFromRect(screen.visibleFrame)) safe=\(screen.safeAreaInsets) panelLevel=\(panel.level.rawValue)")
        if isPresented { panels.forEach { $0.orderFront(nil) } }
    }

    private func preparePresentationPanelsIfNeeded() {
        guard let screen = presentationScreen() else {
            diagnosticRecord("error", "prepare-panels-no-screen mode=\(displayMode)")
            return
        }
        let requestedDisplayID = displayID(for: screen)
        let needsRebuild = panels.isEmpty || panelDisplayID != requestedDisplayID
        diagnosticRecord("panel", "prepare mode=\(displayMode) requested=\(requestedDisplayID) current=\(panelDisplayID ?? -1) panels=\(panels.count) rebuild=\(needsRebuild)")
        if needsRebuild { rebuildPanels() }
    }

    private var displayMode: String { UserDefaults.standard.string(forKey: "display-mode") ?? "active" }

    private func presentationScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        if displayMode == "fixed" {
            let id = UserDefaults.standard.integer(forKey: "fixed-display-id")
            if let f = screens.first(where: { displayID(for: $0) == id }) { return f }
        }
        let mouse = NSEvent.mouseLocation
        return screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? screens[0]
    }

    private func displayID(for screen: NSScreen) -> Int {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? screen.hashValue
    }

    // MARK: - Settings helpers

    func refreshAccessibilityPermission() {
        let was = accessibilityPermissionGranted
        accessibilityPermissionGranted = AXIsProcessTrusted()
        if accessibilityPermissionGranted && !was {
            installGlobalEventMonitors(); installSystemEventTap(); installRawTrackpadMonitorIfAllowed()
            DockHoverObserver.shared.start()
        }
    }

    func setDockIconVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: "show-dock-icon"); applyDockIconPreference()
    }

    func setKeyboardShortcut(keyCode: Int, modifiers: UInt32, label: String) {
        UserDefaults.standard.set(keyCode, forKey: "keyboard-shortcut-key-code")
        UserDefaults.standard.set(Int(modifiers), forKey: "keyboard-shortcut-modifiers")
        UserDefaults.standard.set(label, forKey: "keyboard-shortcut-label")
        registerLauncherHotKey(keyCode: UInt32(keyCode), modifiers: modifiers, label: label)
    }

    func presentSettingsAboveLauncher() {
        let promote = { () -> Bool in
            // 优先找已可见的非 Launcher 窗口
            if let w = NSApp.windows.first(where: { $0.isVisible && !($0 is LauncherPanel) && $0.styleMask.contains(.titled) }) {
                w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
                w.hidesOnDeactivate = true
                NSApp.activate(ignoringOtherApps: true)
                w.orderFront(nil); w.makeKeyAndOrderFront(nil)
                return true
            }
            // 兜底：找标题含 "Settings"/"设置" 的窗口（可能尚未可见）
            if let w = NSApp.windows.first(where: {
                !$0.isVisible && !($0 is LauncherPanel) && $0.styleMask.contains(.titled)
                    && ($0.title.localizedCaseInsensitiveContains("settings")
                        || $0.title.localizedCaseInsensitiveContains("设置")
                        || $0.title.contains("LunchPad"))
            }) {
                w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
                w.hidesOnDeactivate = true
                NSApp.activate(ignoringOtherApps: true)
                w.orderFront(nil); w.makeKeyAndOrderFront(nil)
                return true
            }
            return false
        }
        DispatchQueue.main.async {
            if !promote() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { _ = promote() } }
        }
    }

    func synchronizeUninstallPresentation() {
        guard isPresented, let r = store.uninstallRequest else { closeUninstallPresentation(); return }
        presentUninstallDialog(r)
    }

    private func presentUninstallDialog(_ request: UninstallRequest) {
        closeUninstallPresentation()
        guard let screen = panels.first?.screen ?? presentationScreen() else { return }
        let dp = UninstallDimmingPanel(contentRect: screen.frame)
        dp.contentView = NSHostingView(rootView: Color.black.opacity(0.32).ignoresSafeArea())
        dp.setFrame(screen.frame, display: false)
        let sz = NSSize(width: 700, height: 520)
        let fr = NSRect(x: screen.frame.midX - 350, y: screen.frame.midY - 260, width: 700, height: 520)
        let rp = UninstallDialogPanel(contentRect: fr)
        let rv = UninstallConfirmationView(request: request).environmentObject(store).frame(width: 700, height: 520)
        let rhv = NSHostingView(rootView: rv)
        rhv.frame = NSRect(origin: .zero, size: sz); rhv.autoresizingMask = [.width, .height]
        rp.contentView = rhv; rp.setFrame(fr, display: false)
        uninstallDimmingPanel = dp; uninstallDialogPanel = rp
        dp.orderFront(nil); rp.orderFront(nil); rp.makeKey()
    }

    private func closeUninstallPresentation() {
        uninstallDialogPanel?.orderOut(nil); uninstallDialogPanel?.close(); uninstallDialogPanel = nil
        uninstallDimmingPanel?.orderOut(nil); uninstallDimmingPanel?.close(); uninstallDimmingPanel = nil
    }

    func setDisplayMode(_ mode: String) {
        UserDefaults.standard.set(mode == "fixed" ? "fixed" : "active", forKey: "display-mode"); rebuildPanels()
    }

    func setFixedDisplayID(_ id: Int) {
        UserDefaults.standard.set(id, forKey: "fixed-display-id")
        if displayMode == "fixed" { rebuildPanels() }
    }

    func refreshDisplayOptions() {
        displayOptions = NSScreen.screens.map { s in
            LauncherDisplayOption(id: displayID(for: s), name: "\(s.localizedName)（\(Int(s.frame.width)) × \(Int(s.frame.height))）")
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                if !enabled { try SMAppService.mainApp.unregister() }
            default:
                if enabled { try SMAppService.mainApp.register() }
            }
            refreshLoginItemStatus()
            if enabled, SMAppService.mainApp.status == .requiresApproval {
                store.errorMessage = "开机自启已设置，但还需在\u{201C}系统设置 → 通用 → 登录项与扩展\u{201D}中批准 LunchPad。"
            }
        } catch { refreshLoginItemStatus(); store.errorMessage = "无法修改开机启动：\(error.localizedDescription)" }
    }

    func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        loginItemStatus = status
        loginItemEnabled = Self.loginItemIsOn(status)
    }

    /// A successful `register()` on macOS 13+ lands the login item in
    /// `.requiresApproval` until the user approves it in System Settings —
    /// from the user's perspective launch-at-login is already turned on, so
    /// both `.enabled` and `.requiresApproval` count as on.
    private static func loginItemIsOn(_ status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    func requestAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityPermissionGranted = AXIsProcessTrustedWithOptions(opts)
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                let c = LauncherController.shared; c.refreshAccessibilityPermission()
                if c.accessibilityPermissionGranted { c.permissionPollTimer?.invalidate(); c.permissionPollTimer = nil }
            }
        }
    }

    private func applyDockIconPreference() {
        let visible = UserDefaults.standard.object(forKey: "show-dock-icon") as? Bool ?? true
        let wins = NSApp.windows.filter { $0.isVisible && !($0 is LauncherPanel) }
        let keyWin = wins.first(where: \.isKeyWindow)
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        DispatchQueue.main.async {
            if visible, let icon = NSImage(named: "LaunchpadIcon") { NSApp.applicationIconImage = Self.resizedDockIcon(from: icon) }
            guard let w = keyWin ?? wins.first else { return }
            NSApp.activate(ignoringOtherApps: true); w.orderFront(nil); w.makeKeyAndOrderFront(nil)
        }
    }

    private static func resizedDockIcon(from src: NSImage) -> NSImage {
        let sz = NSSize(width: 128, height: 128)
        let img = NSImage(size: sz); img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(origin: .zero, size: sz), from: .zero, operation: .sourceOver, fraction: 1)
        img.unlockFocus(); return img
    }

    func launch(_ application: LauncherApplication) {
        // Frequency is counted system-wide via the workspace launch observer,
        // so launching here needs no separate recording.
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
        let name = application.name
        // Hide FIRST so the launcher closes while the app launches — previously
        // hide() ran in openApplication's completion, which only fires after the
        // target app has launched AND activated, adding a visible beat before
        // the close animation even started.
        hide()
        NSWorkspace.shared.openApplication(at: application.url, configuration: cfg) { _, error in
            guard let err = error?.localizedDescription else { return }
            Task { @MainActor in
                let c = LauncherController.shared
                c.store.errorMessage = "无法打开\u{201C}\(name)\u{201D}：\(err)"
                // 界面已在启动时关闭，提示不可见且会残留到下次打开；
                // 把启动台带回来显示错误，用户关闭界面后提示即被清除。
                if !c.isPresented { c.show() }
            }
        }
    }
}

// MARK: - Thread-safe atomic helpers

/// 拖拽期间把指针约束在启动台所在显示器内的线程安全状态：
/// tap 线程读取，主线程写入。
final class DragConstraintBox: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var frame = CGRect.zero
    nonisolated(unsafe) private var active = false
    nonisolated init() {}
    nonisolated func setFrame(_ frame: CGRect) { lock.lock(); self.frame = frame; lock.unlock() }
    nonisolated func setActive(_ active: Bool) { lock.lock(); self.active = active; lock.unlock() }
    nonisolated func get() -> (frame: CGRect, active: Bool) { lock.lock(); defer { lock.unlock() }; return (frame, active) }
}

private final class AtomicBool: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    /// `unsafe` is fine: every access is guarded by `lock` above.
    nonisolated(unsafe) private var _value = false
    nonisolated init() {}
    nonisolated var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    nonisolated func set(_ v: Bool) { lock.lock(); _value = v; lock.unlock() }
}

// MARK: - Drag icon compositor

/// Owns the visible drag icon independently from SwiftUI's NSDraggingSession.
/// The native dragging image is deliberately transparent, which lets this
/// panel switch from pointer-following to the return animation in the same
/// frame instead of waiting for AppKit's dragging-image fade to finish.
@MainActor
final class DragIconWindowController {
    static let shared = DragIconWindowController()

    private let panel: NSPanel
    private let imageView = NSImageView()
    private var trackingTimer: Timer?
    private var iconSize: CGFloat = 0

    private init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = false
        panel.contentView = imageView
    }

    func begin(path: String, size: CGFloat) {
        stopTracking()
        panel.orderOut(nil)
        iconSize = size
        imageView.image = NSWorkspace.shared.icon(forFile: path)
        imageView.alphaValue = 1
        panel.alphaValue = 1
        positionAtPointer()
        panel.orderFrontRegardless()

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.positionAtPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    /// `destination` uses the launcher's top-left CG coordinate system.
    func returnTo(destination: CGRect, targetSize: CGFloat) {
        guard panel.isVisible else { return }
        stopTracking()
        guard let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height else {
            hide()
            return
        }
        let size = max(1, targetSize)
        let targetFrame = NSRect(
            x: destination.midX - size / 2,
            y: primaryHeight - destination.midY - size / 2,
            width: size,
            height: size
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.78, 0.22, 1)
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in self?.hide() }
        }
    }

    func hide() {
        stopTracking()
        panel.orderOut(nil)
        imageView.image = nil
    }

    private func positionAtPointer() {
        guard panel.isVisible || imageView.image != nil else { return }
        let mouse = NSEvent.mouseLocation
        panel.setFrame(
            NSRect(
                x: mouse.x - iconSize / 2,
                y: mouse.y - iconSize / 2,
                width: iconSize,
                height: iconSize
            ),
            display: true
        )
    }

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }
}

// MARK: - Panel classes

private final class EventTapThreadContext: @unchecked Sendable {
    let tap: CFMachPort; let source: CFRunLoopSource
    init(tap: CFMachPort, source: CFRunLoopSource) { self.tap = tap; self.source = source }
}

private class LauncherPanel: NSPanel {
    var targetFullFrame: NSRect = .zero
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Below the Dock (kCGDockWindowLevel = 20) and menu bar (24) so the
        // window can extend under the Dock without covering it — the Dock
        // renders on top of the launcher's wallpaper, keeping the backdrop
        // continuous. Still above normal app windows (level 0).
        level = NSWindow.Level(rawValue: 18)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        hidesOnDeactivate = false; isReleasedWhenClosed = false
        // `.canJoinAllSpaces` lets the launcher appear on whichever Space is
        // active — without it the window is bound to the Space it was created
        // on (the app's launch Space) and can't be invoked anywhere else.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none; acceptsMouseMovedEvents = true
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Returns a frame scaled to `factor` around the center of targetFullFrame.
    func scaledFrame(_ factor: CGFloat) -> NSRect {
        let w = targetFullFrame.width * factor
        let h = targetFullFrame.height * factor
        return NSRect(
            x: targetFullFrame.midX - w / 2,
            y: targetFullFrame.midY - h / 2,
            width: w, height: h
        )
    }
}

private final class UninstallDimmingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]; animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class UninstallDialogPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]; animationBehavior = .none
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
