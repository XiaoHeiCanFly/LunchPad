// SPDX-License-Identifier: GPL-3.0-or-later
// Dock hover preview portions adapted from DockDoor.
// Copyright (C) 2024 ejbills.

import AppKit
import Combine
import SwiftUI

// MARK: - Preview state (observed by the hover views)

@MainActor
final class DockPreviewState: ObservableObject {
    @Published var windows: [PreviewWindow] = []
    @Published var selectionIndex: Int = -1
}

// MARK: - Preview panel (DockDoor's SharedPreviewWindowCoordinator)

/// The floating panel that shows a dock app's windows next to its icon. It is
/// a nonactivating borderless NSPanel with an animated, dock-anchored frame.
@MainActor
final class DockPreviewPanel: NSPanel {
    static let shared = DockPreviewPanel()

    /// Replaced atomically when a preview is dismissed. Keeping the retired
    /// state alive briefly lets the launcher paint its first frames before the
    /// potentially large window-image graph is released.
    private(set) var state = DockPreviewState()

    private(set) var currentlyDisplayedPID: pid_t?
    var mouseIsWithinPreviewWindow: Bool = false
    private var onWindowTap: (() -> Void)?
    private var pendingShowWorkItem: DispatchWorkItem?
    /// 鼠标移出图标后等待隐藏；期间抑制所有其他逻辑。
    private(set) var pendingHide = false
    private var pendingHideWorkItem: DispatchWorkItem?

    private var previousHoverWindowOrigin: CGPoint?
    private var currentDockPosition: DockPosition = .bottom
    private var currentPreviewScreen: NSScreen?
    private var anchoredDockItem: (element: AXUIElement, iconRect: CGRect)?

    /// Thread-safe flag for the CGEvent tap (runs on a background thread).
    nonisolated private static let presentationFlag = PreviewPresentationFlag()
    nonisolated static var isPresentedOnScreen: Bool { presentationFlag.isSet }

    private init() {
        let styleMask: NSWindow.StyleMask = [.nonactivatingPanel, .fullSizeContentView, .borderless]
        super.init(contentRect: .zero, styleMask: styleMask, backing: .buffered, defer: false)
        setupWindow()
    }

    private func setupWindow() {
        level = Defaults.shared.raisedWindowLevel ? .statusBar : .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    // MARK: - Show pipeline

    func cancelPendingShow() {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
    }

    /// 鼠标移出图标后 0.15s 隐藏窗口。期间 `pendingHide` 为 true，抑制所有其他逻辑。
    func schedulePendingHide() {
        guard !pendingHide else { return }
        pendingHide = true
        pendingHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.pendingHide else { return }
                self.pendingHide = false
                self.hideWindow(animated: true)
            }
        }
        pendingHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func cancelPendingHide() {
        pendingHideWorkItem?.cancel()
        pendingHideWorkItem = nil
        pendingHide = false
    }

    func hideWindow(cancelPendingShow shouldCancelPendingShow: Bool = true, animated: Bool = false) {
        if shouldCancelPendingShow {
            cancelPendingShow()
        }
        cancelPendingHide()
        guard isVisible else { return }

        let cleanup = { [weak self] in
            guard let self else { return }
            // Make the preview disappear before touching its SwiftUI/image
            // graph. Clearing state.windows and destroying NSHostingView used
            // to happen synchronously here, blocking launcher activation for
            // hundreds of milliseconds when many snapshots were displayed.
            Self.presentationFlag.set(false)
            orderOut(nil)

            let retiredContentView = contentView
            let retiredState = state
            state = DockPreviewState()
            contentView = nil
            onWindowTap = nil
            currentlyDisplayedPID = nil
            mouseIsWithinPreviewWindow = false
            anchoredDockItem = nil
            currentPreviewScreen = nil

            // Retire the detached view after the launcher's ~0.35s transition
            // has completed. The closure deliberately owns both objects so
            // their images/views cannot deallocate on the activation path.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                withExtendedLifetime(retiredContentView) {}
                withExtendedLifetime(retiredState) {}
            }
        }

        guard animated, Defaults.shared.showAnimations else {
            cleanup()
            return
        }

        // 消失动画：打开动画的反向（滑回 Dock）
        let animationOffset: CGFloat = 7.0
        var endFrame = frame
        switch currentDockPosition {
        case .bottom: endFrame.origin.y -= animationOffset
        case .left:   endFrame.origin.x -= animationOffset
        case .right:  endFrame.origin.x += animationOffset
        default:      endFrame.origin.y -= animationOffset
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.175
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(endFrame, display: true)
            self.animator().alphaValue = 0
        }, completionHandler: cleanup)
    }

    /// Schedules a preview show after the hover delay, then re-validates the
    /// pointer before presenting.
    func showWindow(
        appName: String,
        windows: [PreviewWindow],
        mouseLocation: CGPoint?,
        mouseScreen: NSScreen?,
        dockItemElement: AXUIElement?,
        overrideDelay: Bool = false,
        onWindowTap: (() -> Void)? = nil
    ) {
        let expectedPID = windows.first?.app.processIdentifier
        let expectedBundleID = windows.first?.app.bundleIdentifier

        let shouldSkipDelay = overrideDelay || (Defaults.shared.useDelayOnlyForInitialOpen && isVisible)
        let delay = shouldSkipDelay ? 0 : Defaults.shared.hoverOpenDelay

        pendingShowWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            // The pointer moved into the preview while a different app's show
            // was pending — the preview owns the pointer now.
            if mouseIsWithinPreviewWindow,
               let currentPID = currentlyDisplayedPID,
               let expectedPID,
               currentPID != expectedPID
            {
                return
            }

            // Final validation: still hovering the same app.
            let currentStatus = DockHoverObserver.shared.getDockItemAppStatusUnderMouse()
            let matches: Bool = switch currentStatus.status {
            case let .success(app):
                app.bundleIdentifier == expectedBundleID
            case let .notRunning(bundleId):
                bundleId == expectedBundleID
            case .notFound:
                false
            }
            guard matches else { return }

            Task { @MainActor [weak self] in
                self?.performDisplay(
                    appName: appName,
                    windows: windows,
                    mouseLocation: mouseLocation,
                    mouseScreen: mouseScreen,
                    dockItemElement: dockItemElement,
                    onWindowTap: onWindowTap
                )
            }
        }
        pendingShowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: - Display

    private func performDisplay(
        appName: String,
        windows: [PreviewWindow],
        mouseLocation: CGPoint?,
        mouseScreen: NSScreen?,
        dockItemElement: AXUIElement?,
        onWindowTap: (() -> Void)?
    ) {
        guard !windows.isEmpty else { return }

        let screen = mouseScreen ?? NSScreen.main ?? NSScreen.screens[0]
        currentPreviewScreen = screen
        let activeDockPosition = DockUtils.getDockPosition()
        currentDockPosition = activeDockPosition

        var dockIconRect: CGRect?
        if let dockItemElement,
           let position = try? dockItemElement.position(),
           let size = try? dockItemElement.size()
        {
            let rect = CGRect(origin: position, size: size)
            dockIconRect = rect
            anchoredDockItem = (element: dockItemElement, iconRect: rect)
        } else {
            anchoredDockItem = nil
        }

        self.onWindowTap = onWindowTap
        currentlyDisplayedPID = windows.first?.app.processIdentifier
        state.windows = windows
        Self.presentationFlag.set(true)

        updateContentViewSizeAndPosition(
            mouseLocation: mouseLocation,
            mouseScreen: screen,
            dockItemElement: dockItemElement,
            dockIconRect: dockIconRect,
            animated: true,
            appName: appName
        )
    }

    private func updateContentViewSizeAndPosition(
        mouseLocation: CGPoint?,
        mouseScreen: NSScreen,
        dockItemElement: AXUIElement?,
        dockIconRect: CGRect?,
        animated: Bool,
        appName: String
    ) {
        let hoverView = DockPreviewHoverContainer(
            appName: appName,
            onWindowTap: onWindowTap,
            dockPosition: currentDockPosition,
            bestGuessMonitor: mouseScreen,
            dockItemElement: dockItemElement,
            state: state
        )
        let newHostingView = NSHostingView(rootView: hoverView)

        if let oldContentView = contentView {
            oldContentView.removeFromSuperview()
        }
        contentView = newHostingView

        let fittingSize = newHostingView.fittingSize
        let panelGutter: CGFloat = 16
        let newHoverWindowSize = CGSize(
            width: min(fittingSize.width, max(1, mouseScreen.visibleFrame.width - panelGutter * 2)),
            height: min(fittingSize.height, max(1, mouseScreen.visibleFrame.height - panelGutter * 2))
        )

        let position: CGPoint
        if let dockIconRect {
            position = calculateWindowPosition(
                mouseLocation: mouseLocation,
                windowSize: newHoverWindowSize,
                screen: mouseScreen,
                dockIconRect: dockIconRect
            )
        } else {
            position = centerWindowOnScreen(size: newHoverWindowSize, screen: mouseScreen)
        }

        let finalFrame = CGRect(origin: position, size: newHoverWindowSize)
        setFrame(finalFrame, display: false)
        applyWindowFrame(finalFrame, animated: animated)
        previousHoverWindowOrigin = position
        refreshPanelFrameToFitContent()
    }

    /// Merges refreshed windows when the displayed app is unchanged.
    @discardableResult
    func mergeWindowsIfNeeded(pid: pid_t?, windows: [PreviewWindow], dockPosition: DockPosition, bestGuessMonitor: NSScreen) -> Bool {
        guard currentlyDisplayedPID == pid else { return false }
        state.windows = windows
        refreshPanelFrameToFitContent()
        return true
    }

    // MARK: - Keyboard navigation

    /// Handles arrow/Return/Esc keys while the preview is up (the panel is
    /// nonactivating, so these come through the CGEvent tap). Returns true if
    /// the key was consumed.
    func handleNavigationKey(_ keyCode: Int) -> Bool {
        guard isVisible else { return false }
        let direction: ArrowDirection? = switch keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
        if let direction {
            navigateWithArrowKey(direction: direction)
            return true
        }
        if keyCode == 36 || keyCode == 76 { // Return / Keypad Enter
            selectAndBringToFrontCurrentWindow()
            return true
        }
        return false
    }

    private func navigateWithArrowKey(direction: ArrowDirection) {
        let count = state.windows.count
        guard count > 0 else { return }
        if state.selectionIndex < 0 {
            state.selectionIndex = 0
            return
        }
        let bestGuessMonitor = NSScreen.screenFromQuartzPoint(DockHoverObserver.getMousePosition())
        let overallMax = PreviewDimensionCalculator.calculateOverallMaxDimensions(
            windows: state.windows,
            dockPosition: currentDockPosition,
            sharedPanelWindowSize: bestGuessMonitor.visibleFrame.size
        )
        let (maxColumns, maxRows) = PreviewDimensionCalculator.calculateEffectiveMaxColumnsAndRows(
            bestGuessMonitor: bestGuessMonitor,
            overallMaxDimensions: overallMax,
            dockPosition: currentDockPosition,
            previewMaxColumns: Defaults.shared.previewMaxColumns,
            previewMaxRows: Defaults.shared.previewMaxRows,
            totalItems: count
        )
        let shouldReverse = currentDockPosition == .bottom || currentDockPosition == .right
        state.selectionIndex = PreviewDimensionCalculator.navigateInGrid(
            from: state.selectionIndex,
            direction: direction,
            totalItems: count,
            isHorizontal: currentDockPosition.isHorizontalFlow,
            maxColumns: maxColumns,
            maxRows: maxRows,
            reverse: shouldReverse
        )
    }

    private func selectAndBringToFrontCurrentWindow() {
        let index = state.selectionIndex
        guard index >= 0, index < state.windows.count else {
            hideWindow()
            return
        }
        let window = state.windows[index]
        window.bringToFront()
        hideWindow()
    }

    // MARK: - Frame

    /// Refits the panel frame to the SwiftUI content's intrinsic size after
    /// the window list changes, keeping the dock-anchored edge fixed.
    func refreshPanelFrameToFitContent() {
        guard let hostingView = contentView else { return }

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let screen = NSScreen.screenFromQuartzPoint(DockHoverObserver.getMousePosition())
        // Dock spacing is measured in the full display coordinate space. A
        // visibleFrame clamp starts above the Dock and collapses every
        // negative spacing value to the same Y coordinate.
        let screenFrame = screen.frame.insetBy(dx: 16, dy: 0)
        let newSize = CGSize(
            width: min(fittingSize.width, max(1, screenFrame.width)),
            height: min(fittingSize.height, max(1, screenFrame.height))
        )
        guard newSize != frame.size else { return }

        let wasClampedToTop = frame.maxY >= screenFrame.maxY - 1
        let wasClampedToBottom = frame.minY <= screenFrame.minY + 1

        var newOrigin = switch currentDockPosition {
        case .left:
            if wasClampedToTop {
                CGPoint(x: frame.minX, y: frame.maxY - newSize.height)
            } else if wasClampedToBottom {
                CGPoint(x: frame.minX, y: frame.minY)
            } else {
                CGPoint(x: frame.minX, y: frame.midY - newSize.height / 2)
            }
        case .right:
            if wasClampedToTop {
                CGPoint(x: frame.maxX - newSize.width, y: frame.maxY - newSize.height)
            } else if wasClampedToBottom {
                CGPoint(x: frame.maxX - newSize.width, y: frame.minY)
            } else {
                CGPoint(x: frame.maxX - newSize.width, y: frame.midY - newSize.height / 2)
            }
        case .bottom:
            CGPoint(
                x: frame.midX - newSize.width / 2,
                y: fixedBottomDockOriginY(on: screen)
            )
        default:
            CGPoint(x: frame.midX - newSize.width / 2, y: frame.midY - newSize.height / 2)
        }

        newOrigin.x = max(screenFrame.minX, min(newOrigin.x, screenFrame.maxX - newSize.width))
        newOrigin.y = max(screenFrame.minY, min(newOrigin.y, screenFrame.maxY - newSize.height))

        if Defaults.shared.showAnimations {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(CGRect(origin: newOrigin, size: newSize), display: true)
            }
        } else {
            setFrame(CGRect(origin: newOrigin, size: newSize), display: true)
        }
    }

    private func centerWindowOnScreen(size: CGSize, screen: NSScreen) -> CGPoint {
        CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2)
    }

    private func calculateWindowPosition(mouseLocation: CGPoint?, windowSize: CGSize, screen: NSScreen, dockIconRect: CGRect) -> CGPoint {
        guard let mouseLocation else { return .zero }
        let screenFrame = screen.frame.insetBy(dx: 16, dy: 0)
        let dockPosition = DockUtils.getDockPosition()

        let iconRect = (Defaults.shared.anchorDockPreviewPosition ? anchoredDockItem?.iconRect : nil) ?? dockIconRect
        let flippedIconRect = CGRect(
            origin: DockHoverObserver.cgPointFromNSPoint(iconRect.origin, forScreen: screen),
            size: iconRect.size
        )

        var xPosition: CGFloat
        var yPosition: CGFloat
        let dockSpacing = Defaults.shared.dockSpacing
        // The panel contains transparent layout padding outside its visible
        // glass surface. Position the visible edge, not the NSPanel frame.
        let visibleSurfaceInset = HoverContainerPadding.container + HoverContainerPadding.dockStyleOuter

        switch dockPosition {
        case .bottom:
            xPosition = flippedIconRect.midX - (windowSize.width / 2)
            yPosition = fixedBottomDockOriginY(on: screen)
        case .left:
            let stableDockBoundary = DockHoverObserver.shared.dockBoundary(on: screen, position: dockPosition)
            let dockRight = stableDockBoundary ?? screen.visibleFrame.minX
            xPosition = dockRight + dockSpacing - visibleSurfaceInset
            yPosition = flippedIconRect.midY - (windowSize.height / 2) - flippedIconRect.height
        case .right:
            let stableDockBoundary = DockHoverObserver.shared.dockBoundary(on: screen, position: dockPosition)
            let dockLeft = stableDockBoundary ?? screen.visibleFrame.maxX
            xPosition = dockLeft - windowSize.width - dockSpacing + visibleSurfaceInset
            yPosition = flippedIconRect.minY - (windowSize.height / 2)
        default:
            xPosition = mouseLocation.x - (windowSize.width / 2)
            yPosition = mouseLocation.y - (windowSize.height / 2)
        }

        xPosition = max(screenFrame.minX, min(xPosition, screenFrame.maxX - windowSize.width))
        yPosition = max(screenFrame.minY, min(yPosition, screenFrame.maxY - windowSize.height))

        return CGPoint(x: xPosition, y: yPosition)
    }

    /// Locks the visible glass surface—not the transparent NSPanel frame—to a
    /// fixed distance above the system's reserved Dock boundary.
    private func fixedBottomDockOriginY(on screen: NSScreen) -> CGFloat {
        let visibleSurfaceInset = HoverContainerPadding.container + HoverContainerPadding.dockStyleOuter
        return screen.visibleFrame.minY + Defaults.shared.dockSpacing - visibleSurfaceInset
    }

    /// Repositions an already visible preview when the Dock-spacing setting
    /// changes, so the settings slider provides immediate feedback.
    func refreshDockSpacing() {
        guard isVisible,
              let screen = currentPreviewScreen,
              let anchoredDockItem
        else { return }

        let position = calculateWindowPosition(
            mouseLocation: .zero,
            windowSize: frame.size,
            screen: screen,
            dockIconRect: anchoredDockItem.iconRect
        )
        setFrameOrigin(position)
        previousHoverWindowOrigin = position
    }

    private func applyWindowFrame(_ frame: CGRect, animated: Bool) {
        let shouldAnimate = animated && Defaults.shared.showAnimations

        if shouldAnimate {
            // Slide the panel out of the dock on first appearance.
            let dockPosition = DockUtils.getDockPosition()
            let animationOffset: CGFloat = 7.0
            var startFrame = frame
            switch dockPosition {
            case .bottom:
                startFrame.origin.y -= animationOffset
            case .left:
                startFrame.origin.x -= animationOffset
            case .right:
                startFrame.origin.x += animationOffset
            default:
                startFrame.origin.y -= animationOffset
            }

            setFrame(startFrame, display: true)
            orderFront(nil)

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.175
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(frame, display: true)
            }
        } else {
            setFrame(frame, display: true)
        }

        alphaValue = 1.0
        orderFront(nil)
    }

    // MARK: - Hit testing

    func containsQuartzPoint(_ point: CGPoint) -> Bool {
        guard isVisible else { return false }
        let screen = NSScreen.screenFromQuartzPoint(point)
        let appKitPoint = DockHoverObserver.nsPointFromCGPoint(point, forScreen: screen)
        let hitSlop: CGFloat = 2
        return frame.insetBy(dx: -hitSlop, dy: -hitSlop).contains(appKitPoint)
    }
}

// MARK: - Thread-safe flag for the CGEvent tap

private final class PreviewPresentationFlag: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var value = false
    nonisolated init() {}
    nonisolated var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    nonisolated func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
}
