// SPDX-License-Identifier: GPL-3.0-or-later
// Dock hover preview portions adapted from DockDoor.
// Copyright (C) 2024 ejbills.

import AppKit
import ApplicationServices
import Carbon.HIToolbox.Events

// MARK: - Dock hover detection (DockDoor approach)
//
// Instead of hit-testing the mouse against dock icon frames, the Dock itself
// reports which item is hovered: it marks the hovered item as its AX
// "selected child" and posts kAXSelectedChildrenChangedNotification. We
// subscribe to that notification and read the selected item's URL to find the
// app under the mouse — the same pipeline DockDoor uses.

struct DockItemAppStatus {
    enum Status {
        case success(NSRunningApplication)
        case notRunning(bundleIdentifier: String)
        case notFound
    }

    let status: Status
    let dockItemElement: AXUIElement?
}

nonisolated private func handleSelectedDockItemChangedNotification(
    observer _: AXObserver,
    element _: AXUIElement,
    notificationName _: CFString,
    context _: UnsafeMutableRawPointer?
) {
    DispatchQueue.main.async {
        DockHoverObserver.shared.processSelectedDockItemChanged()
    }
}

@MainActor
final class DockHoverObserver {
    static let shared = DockHoverObserver()
    private init() {}

    var axObserver: AXObserver?
    private var currentDockPID: pid_t?
    private var healthCheckTimer: Timer?
    private var subscribedDockList: AXUIElement?

    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    /// Window discovery/capture can outlive the hover that started it. Keep a
    /// handle so launcher activation can cancel that work immediately.
    private var windowFetchTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() {
        // Force the preview defaults to register before any hover pipeline read.
        _ = Defaults.shared
        setupSelectedDockItemObserver()
        startHealthCheckTimer()
        setupEventTap()
    }

    func stop() {
        windowFetchTask?.cancel()
        windowFetchTask = nil
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        teardownObserver()
        removeEventTap()
    }

    private func startHealthCheckTimer() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.performHealthCheck() }
        }
    }

    private func performHealthCheck() {
        guard let currentDockPID else {
            setupSelectedDockItemObserver()
            return
        }
        let currentDockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        if currentDockApp?.processIdentifier != currentDockPID {
            reset()
            return
        }
        // The dock list element becomes invalid when the dock rebuilds its UI,
        // which silently stops notifications.
        if let subscribedElement = subscribedDockList {
            var role: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(subscribedElement, kAXRoleAttribute as CFString, &role)
            if result == .invalidUIElement || result == .cannotComplete {
                reset()
            }
        }
        // Re-enable a timed-out event tap.
        if let eventTap, !CGEvent.tapIsEnabled(tap: eventTap) {
            removeEventTap()
            setupEventTap()
        }
    }

    func reset() {
        teardownObserver()
        setupSelectedDockItemObserver()
    }

    private func teardownObserver() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        axObserver = nil
        currentDockPID = nil
        subscribedDockList = nil
    }

    private func setupSelectedDockItemObserver() {
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return
        }
        let dockAppPID = dockApp.processIdentifier
        currentDockPID = dockAppPID

        let dockAppElement = AXUIElementCreateApplication(dockAppPID)
        guard AXIsProcessTrusted() else { return }

        guard let children = try? dockAppElement.children(),
              let axList = children.first(where: { (try? $0.role()) == kAXListRole })
        else {
            return
        }

        var observer: AXObserver?
        guard AXObserverCreate(dockAppPID, handleSelectedDockItemChangedNotification, &observer) == .success,
              let observer
        else { return }

        do {
            try axList.subscribeToNotification(observer, kAXSelectedChildrenChangedNotification)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
            axObserver = observer
            subscribedDockList = axList
        } catch {
            axObserver = nil
            subscribedDockList = nil
        }
    }

    // MARK: - Hover pipeline

    func processSelectedDockItemChanged() {
        guard Defaults.shared.dockPreviewsEnabled,
              !LauncherController.shared.isPresented
        else {
            return
        }
        let panel = DockPreviewPanel.shared
        // 没有选中图标 → 启动隐藏定时器。
        let appStatus = getDockItemAppStatusUnderMouse()
        if case .notFound = appStatus.status {
            if panel.isVisible { panel.schedulePendingHide() }
            return
        }
        // 选中了图标 → 取消待定隐藏，展示预览。
        panel.cancelPendingHide()
        let mouseLocation = DockHoverObserver.getMousePosition()
        showPreviewForHoveredDockApp(mouseLocation: mouseLocation, overrideDelay: false)
    }

    private func showPreviewForHoveredDockApp(mouseLocation: CGPoint, overrideDelay: Bool) {
        let appUnderMouse = getDockItemAppStatusUnderMouse()
        guard let dockItemElement = appUnderMouse.dockItemElement else { return }
        guard case let .success(currentApp) = appUnderMouse.status else { return }

        let panel = DockPreviewPanel.shared
        // 隐藏挂起中或窗口已展示：不重新触发（避免抖动）。
        if panel.pendingHide || panel.isVisible {
            // 但如果是不同 app，需要切换。
            if let currentPID = panel.currentlyDisplayedPID,
               currentApp.processIdentifier == currentPID {
                return
            }
        }

        // Group app instances in the dock (multiple copies of one app share
        // an icon); fetch windows from every running instance.
        var appsToFetchWindowsFrom: [NSRunningApplication] = []
        if let bundleId = currentApp.bundleIdentifier, !bundleId.isEmpty {
            let potentialApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            appsToFetchWindowsFrom = potentialApps.isEmpty ? [currentApp] : potentialApps
        } else {
            appsToFetchWindowsFrom = [currentApp]
        }

        let mouseScreen = NSScreen.screenFromQuartzPoint(mouseLocation)
        let convertedMouseLocation = DockHoverObserver.nsPointFromCGPoint(mouseLocation, forScreen: mouseScreen)
        let appName = currentApp.localizedName ?? "Unknown"

        windowFetchTask?.cancel()
        windowFetchTask = Task { [weak self] in
            var windows: [PreviewWindow] = []
            do {
                for appInstance in appsToFetchWindowsFrom {
                    windows.append(contentsOf: try await PreviewWindowUtil.getActiveWindows(of: appInstance))
                }
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !LauncherController.shared.isPresented else { return }
                // Final validation: the pointer must still hover the same app.
                guard case let .success(stillHoveredApp) = getDockItemAppStatusUnderMouse().status,
                      stillHoveredApp.processIdentifier == currentApp.processIdentifier
                else {
                    return
                }

                if Defaults.shared.showCurrentSpaceOnly {
                    windows = PreviewWindowUtil.filterWindowsByCurrentSpace(windows)
                }
                if Defaults.shared.showCurrentMonitorOnly {
                    windows = PreviewWindowUtil.filterWindowsByCurrentMonitor(windows, mouseLocation: mouseLocation)
                }
                if !Defaults.shared.includeHiddenWindows {
                    windows = windows.filter { !$0.isHidden && !$0.isMinimized }
                }
                if Defaults.shared.ignoreSingleWindowApps, windows.count <= 1 {
                    windows = []
                }
                if windows.isEmpty, Defaults.shared.showWindowlessApps {
                    windows = [PreviewWindow.windowlessEntry(for: currentApp)]
                }
                guard !windows.isEmpty else { return }

                panel.showWindow(
                    appName: appName,
                    windows: windows,
                    mouseLocation: convertedMouseLocation,
                    mouseScreen: mouseScreen,
                    dockItemElement: dockItemElement,
                    overrideDelay: overrideDelay,
                    onWindowTap: { [weak self] in
                        self?.hideWindowAndResetLastApp()
                    }
                )
            }
        }
    }

    func hideWindowAndResetLastApp() {
        DockPreviewPanel.shared.hideWindow()
    }

    /// Ends every preview pipeline before the launcher begins presenting.
    /// This is intentionally lightweight: the panel orders out immediately
    /// and releases its SwiftUI/image graph after the launcher transition.
    func prepareForLauncherPresentation() {
        windowFetchTask?.cancel()
        windowFetchTask = nil
        DockPreviewPanel.shared.hideWindow()
    }

    // MARK: - Dock item queries

    /// Returns the currently selected (hovered) dock item, if any.
    func getHoveredDockItemElement() -> AXUIElement? {
        getSelectedDockItem()
    }

    /// Returns the stable edge of the Dock AX list. Unlike an individual icon
    /// frame, this boundary does not move when Dock magnification changes.
    func dockBoundary(on screen: NSScreen, position: DockPosition) -> CGFloat? {
        guard let dockList = subscribedDockList,
              let origin = try? dockList.position(),
              let size = try? dockList.size()
        else { return nil }

        switch position {
        case .bottom:
            // AX uses a top-left origin; the converted Y is the list's top edge.
            return Self.cgPointFromNSPoint(origin, forScreen: screen).y
        case .left:
            return origin.x + size.width
        case .right:
            return origin.x
        default:
            return nil
        }
    }

    private func getSelectedDockItem() -> AXUIElement? {
        guard let dockAppPID = currentDockPID else { return nil }
        let dockAppElement = AXUIElementCreateApplication(dockAppPID)

        var dockItems: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockAppElement, kAXChildrenAttribute as CFString, &dockItems) == .success,
              let dockItems = dockItems as? [AXUIElement],
              let dockList = dockItems.first
        else {
            return nil
        }

        var selectedChildren: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockList, kAXSelectedChildrenAttribute as CFString, &selectedChildren) == .success,
              let selected = selectedChildren as? [AXUIElement],
              let hoveredItem = selected.first
        else {
            return nil
        }
        return hoveredItem
    }

    private func getHoveredApplicationDockItem() -> AXUIElement? {
        guard let item = getSelectedDockItem(),
              (try? item.subrole()) == "AXApplicationDockItem"
        else {
            return nil
        }
        return item
    }

    func getDockItemAppStatusUnderMouse() -> DockItemAppStatus {
        guard let hoveredDockItem = getHoveredApplicationDockItem() else {
            return DockItemAppStatus(status: .notFound, dockItemElement: nil)
        }

        guard let appURL = try? hoveredDockItem.attribute(kAXURLAttribute, NSURL.self)?.absoluteURL else {
            return DockItemAppStatus(status: .notFound, dockItemElement: hoveredDockItem)
        }

        let bundle = Bundle(url: appURL)
        guard let bundleIdentifier = bundle?.bundleIdentifier else {
            return DockItemAppStatus(status: .notFound, dockItemElement: hoveredDockItem)
        }

        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        if let runningApp = runningApps.first {
            return DockItemAppStatus(status: .success(runningApp), dockItemElement: hoveredDockItem)
        }
        return DockItemAppStatus(status: .notRunning(bundleIdentifier: bundleIdentifier), dockItemElement: hoveredDockItem)
    }

    // MARK: - Coordinate helpers

    static func getMousePosition() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    static func nsPointFromCGPoint(_ point: CGPoint, forScreen: NSScreen?) -> CGPoint {
        guard let screen = forScreen,
              let primaryScreen = NSScreen.screens.first
        else {
            return point
        }
        let offsetTop = primaryScreen.frame.height - (screen.frame.origin.y + screen.frame.height)
        if screen == primaryScreen {
            return CGPoint(x: point.x, y: screen.frame.height - point.y)
        }
        let screenBottomOffset = primaryScreen.frame.height - (screen.frame.height + offsetTop)
        return CGPoint(x: point.x, y: screen.frame.height + screenBottomOffset - (point.y - offsetTop))
    }

    static func cgPointFromNSPoint(_ point: CGPoint, forScreen: NSScreen?) -> CGPoint {
        guard let screen = forScreen,
              let primaryScreen = NSScreen.screens.first
        else {
            return point
        }
        let offsetTop = primaryScreen.frame.height - (screen.frame.origin.y + screen.frame.height)
        return CGPoint(x: point.x, y: screen.frame.maxY - point.y + offsetTop)
    }

    // MARK: - Event tap (click dismisses the preview)

    private func setupEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        guard let eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let observer = Unmanaged<DockHoverObserver>.fromOpaque(refcon).takeUnretainedValue()
                return observer.eventTapCallback(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        self.eventTap = eventTap
        eventTapRunLoopSource = runLoopSource
    }

    private func removeEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let eventTapRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), eventTapRunLoopSource, .commonModes)
            }
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        eventTapRunLoopSource = nil
    }

    private func eventTapCallback(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                DispatchQueue.main.async {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Clicks inside the preview panel are handled by the panel itself.
        if DockPreviewPanel.shared.containsQuartzPoint(event.location) {
            return Unmanaged.passUnretained(event)
        }

        // Any other click dismisses the preview (the dock then handles the
        // click natively).
        Task { @MainActor in
            DockPreviewPanel.shared.hideWindow()
        }
        return Unmanaged.passUnretained(event)
    }
}
