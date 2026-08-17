// SPDX-License-Identifier: GPL-3.0-or-later
// Dock hover preview portions adapted from DockDoor.
// Copyright (C) 2024 ejbills.

import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

// MARK: - DockDoor-style private APIs
//
// The hover-preview feature follows DockDoor's implementation, which relies on
// a few stable private/underscored system symbols: CoreDock for dock position,
// SkyLight (CGS) for window snapshots and space IDs, and the AX window-ID
// bridge. They ship in DockDoor via Sparkle; keep that distribution path in
// mind (they disqualify the App Store).

struct CGSWindowCaptureOptions: OptionSet {
    let rawValue: UInt32
    nonisolated static let ignoreGlobalClipShape = CGSWindowCaptureOptions(rawValue: 1 << 11)
    nonisolated static let nominalResolution = CGSWindowCaptureOptions(rawValue: 1 << 9)
    nonisolated static let bestResolution = CGSWindowCaptureOptions(rawValue: 1 << 8)
}

/// Returns the CGWindowID of the provided AXUIElement (macOS 10.10+).
@_silgen_name("_AXUIElementGetWindow") nonisolated
func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ wid: inout CGWindowID) -> AXError

/// Returns CoreDock orientation and pinning state.
@_silgen_name("CoreDockGetOrientationAndPinning") nonisolated
func CoreDockGetOrientationAndPinning(_ outOrientation: UnsafeMutablePointer<Int32>, _ outPinning: UnsafeMutablePointer<Int32>)

/// Retrieves the current magnification state of the Dock.
@_silgen_name("CoreDockIsMagnificationEnabled") nonisolated
func CoreDockIsMagnificationEnabled() -> Bool

typealias CGSConnectionID = UInt32
typealias CGSWindowCount = UInt32
typealias CGSSpaceID = UInt64
typealias CGSSpaceMask = UInt64

nonisolated let kCGSAllSpacesMask: CGSSpaceMask = 0xFFFF_FFFF_FFFF_FFFF

@_silgen_name("CGSMainConnectionID") nonisolated
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSHWCaptureWindowList") nonisolated
func CGSHWCaptureWindowList(
    _ cid: CGSConnectionID,
    _ windowList: UnsafePointer<UInt32>,
    _ count: CGSWindowCount,
    _ options: CGSWindowCaptureOptions
) -> CFArray?

/// Returns array of space IDs corresponding to the provided windows.
@_silgen_name("CGSCopySpacesForWindows") nonisolated
func CGSCopySpacesForWindows(
    _ cid: CGSConnectionID,
    _ mask: CGSSpaceMask,
    _ windowIDs: CFArray
) -> CFArray?

/// Returns managed display spaces info (current space per display).
@_silgen_name("CGSCopyManagedDisplaySpaces") nonisolated
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray?

@_silgen_name("CGSGetWindowLevel") nonisolated
func CGSGetWindowLevel(_ cid: CGSConnectionID, _ windowID: UInt32, _ level: UnsafeMutablePointer<Int32>) -> CGError

/// Create AXUIElement from a remote token (brute-force window enumeration).
@_silgen_name("_AXUIElementCreateWithRemoteToken") nonisolated
func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

// MARK: - SkyLight window focusing

struct ProcessSerialNumber {
    var highLongOfPSN: UInt32 = 0
    var lowLongOfPSN: UInt32 = 0
}

@_silgen_name("GetProcessForPID") nonisolated
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

enum SLPSMode: UInt32 {
    case allWindows = 0x100
    case userGenerated = 0x200
    case noWindows = 0x400
}

typealias SLPSSetFrontProcessWithOptionsType = @convention(c) (
    UnsafeMutableRawPointer,
    CGWindowID,
    UInt32
) -> CGError

nonisolated(unsafe) private let skyLightHandle: UnsafeMutableRawPointer? = {
    let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    return dlopen(path, RTLD_LAZY)
}()

nonisolated private let setFrontProcessPtr: SLPSSetFrontProcessWithOptionsType? = {
    guard let handle = skyLightHandle,
          let symbol = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else { return nil }
    return unsafeBitCast(symbol, to: SLPSSetFrontProcessWithOptionsType.self)
}()

nonisolated func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ wid: CGWindowID, _ mode: SLPSMode.RawValue) -> CGError {
    guard let fn = setFrontProcessPtr else { return CGError(rawValue: -1)! }
    return fn(psn, wid, mode)
}

// MARK: - Dock position

enum DockPosition {
    case top
    case bottom
    case left
    case right
    case unknown

    var isHorizontalFlow: Bool {
        switch self {
        case .top, .bottom: true
        case .left, .right, .unknown: false
        }
    }
}

enum DockUtils {
    static func getDockPosition() -> DockPosition {
        var orientation: Int32 = 0
        var pinning: Int32 = 0
        CoreDockGetOrientationAndPinning(&orientation, &pinning)
        switch orientation {
        case 1: return .top
        case 2: return .bottom
        case 3: return .left
        case 4: return .right
        default: return .unknown
        }
    }

    /// Returns the dock size in points based on the screen's visible frame.
    static func getDockSize(on screen: NSScreen? = nil) -> CGFloat {
        let dockPosition = getDockPosition()
        if let screen {
            return dockSize(on: screen, dockPosition: dockPosition)
        }
        return NSScreen.screens.map { dockSize(on: $0, dockPosition: dockPosition) }.max() ?? 0
    }

    private static func dockSize(on screen: NSScreen, dockPosition: DockPosition) -> CGFloat {
        switch dockPosition {
        case .right: screen.frame.maxX - screen.visibleFrame.maxX
        case .left: screen.visibleFrame.minX - screen.frame.minX
        case .bottom: screen.visibleFrame.minY - screen.frame.minY
        case .top: screen.frame.maxY - screen.visibleFrame.maxY
        case .unknown: 0
        }
    }
}

// MARK: - AX helpers

enum AxError: Error {
    case runtimeError
}

// Missing from AXAttributeConstants in the SDK.
nonisolated let kAXFullscreenAttribute = "AXFullScreen"

extension AXUIElement {
    nonisolated func axCallWhichCanThrow<T>(_ result: AXError, _ successValue: inout T) throws -> T? {
        switch result {
        case .success: return successValue
        // .cannotComplete can happen if the app is unresponsive; throw to retry
        case .cannotComplete: throw AxError.runtimeError
        // other errors are pointless to retry
        default: return nil
        }
    }

    nonisolated func cgWindowId() throws -> CGWindowID? {
        var id = CGWindowID(0)
        return try axCallWhichCanThrow(_AXUIElementGetWindow(self, &id), &id)
    }

    nonisolated func pid() throws -> pid_t? {
        var pid = pid_t(0)
        return try axCallWhichCanThrow(AXUIElementGetPid(self, &pid), &pid)
    }

    nonisolated func attribute<T>(_ key: String, _: T.Type) throws -> T? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(self, key as CFString, &value)
        return try axCallWhichCanThrow(result, &value) as? T
    }

    nonisolated private func value<T>(_ key: String, _ target: T, _ type: AXValueType) throws -> T? {
        if let axValue = try attribute(key, AXValue.self) {
            var value = target
            let success = withUnsafeMutablePointer(to: &value) { ptr in
                AXValueGetValue(axValue, type, ptr)
            }
            return success ? value : nil
        }
        return nil
    }

    nonisolated func position() throws -> CGPoint? {
        try value(kAXPositionAttribute, CGPoint.zero, .cgPoint)
    }

    nonisolated func size() throws -> CGSize? {
        try value(kAXSizeAttribute, CGSize.zero, .cgSize)
    }

    nonisolated func title() throws -> String? {
        try attribute(kAXTitleAttribute, String.self)
    }

    nonisolated func children() throws -> [AXUIElement]? {
        try attribute(kAXChildrenAttribute, [AXUIElement].self)
    }

    nonisolated func windows() throws -> [AXUIElement]? {
        try attribute(kAXWindowsAttribute, [AXUIElement].self)
    }

    nonisolated func role() throws -> String? {
        try attribute(kAXRoleAttribute, String.self)
    }

    nonisolated func subrole() throws -> String? {
        try attribute(kAXSubroleAttribute, String.self)
    }

    nonisolated func isMinimized() throws -> Bool {
        try attribute(kAXMinimizedAttribute, Bool.self) == true
    }

    nonisolated func isFullscreen() throws -> Bool {
        try attribute(kAXFullscreenAttribute, Bool.self) == true
    }

    nonisolated func closeButton() throws -> AXUIElement? {
        try attribute(kAXCloseButtonAttribute, AXUIElement.self)
    }

    nonisolated func subscribeToNotification(_ axObserver: AXObserver, _ notification: String) throws {
        let result = AXObserverAddNotification(axObserver, self, notification as CFString, nil)
        if result == .success || result == .notificationAlreadyRegistered { return }
        if result != .notificationUnsupported, result != .notImplemented {
            throw AxError.runtimeError
        }
    }

    nonisolated func setAttribute(_ key: String, _ value: Any) throws {
        var unused: Void = ()
        let result = AXUIElementSetAttributeValue(self, key as CFString, value as CFTypeRef)
        try axCallWhichCanThrow(result, &unused)
    }

    nonisolated func performAction(_ action: String) throws {
        var unused: Void = ()
        let result = AXUIElementPerformAction(self, action as CFString)
        try axCallWhichCanThrow(result, &unused)
    }
}

extension AXUIElement {
    /// Enumerates windows by brute force through the remote-token API, which
    /// finds windows some apps don't expose via kAXWindowsAttribute.
    nonisolated static func windowsByBruteForce(_ pid: pid_t, app: NSRunningApplication? = nil) -> [AXUIElement] {
        var token = Data(count: 20)
        token.replaceSubrange(0 ..< 4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4 ..< 8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8 ..< 12, with: withUnsafeBytes(of: Int32(0x636F_636F)) { Data($0) })

        var results: [AXUIElement] = []
        for axId: UInt64 in 0 ..< 1000 {
            token.replaceSubrange(12 ..< 20, with: withUnsafeBytes(of: axId) { Data($0) })
            guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else {
                continue
            }
            if (try? element.pid()) == pid,
               (try? element.cgWindowId()) != nil,
               (try? element.position()) != nil,
               (try? element.size()) != nil
            {
                results.append(element)
            } else if let subrole = try? element.subrole(),
                      [kAXStandardWindowSubrole, kAXDialogSubrole].contains(subrole)
            {
                results.append(element)
            }
        }
        return results
    }

    nonisolated static func allWindows(_ pid: pid_t, appElement: AXUIElement, app: NSRunningApplication? = nil) -> [AXUIElement] {
        var set = Set<AXUIElement>()
        if let windows = try? appElement.windows() {
            set.formUnion(windows)
        }
        set.formUnion(windowsByBruteForce(pid, app: app))
        return Array(set)
    }
}

// MARK: - AXValue helpers

extension AXValue {
    nonisolated static func from(point: CGPoint) -> AXValue? {
        var point = point
        return AXValueCreate(.cgPoint, &point)
    }

    nonisolated static func from(size: CGSize) -> AXValue? {
        var size = size
        return AXValueCreate(.cgSize, &size)
    }
}

// MARK: - NSScreen helpers

extension NSScreen {
    static func screenFromQuartzPoint(_ point: CGPoint) -> NSScreen {
        let pointInScreenCoordinates = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
        return NSScreen.screens.first { NSMouseInRect(pointInScreenCoordinates, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// The screen frame in CG global coordinate space (origin top-left, Y grows downward).
    var cgFrame: CGRect {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return frame }
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    func uniqueIdentifier() -> String {
        let components = [
            deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber as Any,
            frame.width,
            frame.height,
        ].compactMap { String(describing: $0) }
        return components.joined(separator: "-")
    }
}

// MARK: - CGWindowID helpers

extension CGWindowID {
    nonisolated func cgsLevel() -> Int32 {
        var level: Int32 = 0
        _ = CGSGetWindowLevel(CGSMainConnectionID(), UInt32(self), &level)
        return level
    }

    nonisolated func cgsSpaces() -> [CGSSpaceID] {
        let arr: CFArray = [NSNumber(value: UInt32(self))] as CFArray
        guard let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), kCGSAllSpacesMask, arr) as? [NSNumber] else { return [] }
        return spaces.map(\.uint64Value)
    }
}

// MARK: - Current Space IDs

nonisolated func currentActiveSpaceIDs() -> Set<Int> {
    // Primary: ask macOS directly for the current space per display.
    if let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: AnyObject]] {
        var result = Set<Int>()
        for display in displays {
            if let currentSpace = display["Current Space"] as? [String: AnyObject],
               let spaceID = (currentSpace["ManagedSpaceID"] as? NSNumber)?.intValue
            {
                result.insert(spaceID)
            }
        }
        if !result.isEmpty { return result }
    }

    // Fallback: infer from on-screen windows.
    var result = Set<Int>()
    guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] else { return result }
    for desc in list {
        let layer = (desc[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        let isOnscreen = (desc[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        guard layer == 0, isOnscreen else { continue }
        let windowID = CGWindowID((desc[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        for space in windowID.cgsSpaces() {
            result.insert(Int(space))
        }
    }
    return result
}

// MARK: - Window model

/// A discovered window of a running app: AX handle, CGWindowID, geometry and
/// a captured snapshot image.
struct PreviewWindow: Identifiable, Hashable {
    let id: CGWindowID
    let app: NSRunningApplication
    let title: String?
    let frame: CGRect
    let axElement: AXUIElement
    let appAxElement: AXUIElement
    let closeButton: AXUIElement?
    var isMinimized: Bool
    var isHidden: Bool
    var isFullscreen: Bool
    let lastAccessedTime: Date
    var image: CGImage?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(app.processIdentifier)
    }

    static func == (lhs: PreviewWindow, rhs: PreviewWindow) -> Bool {
        lhs.id == rhs.id && lhs.app.processIdentifier == rhs.app.processIdentifier
    }

    static func windowlessEntry(for app: NSRunningApplication) -> PreviewWindow {
        PreviewWindow(
            id: 0,
            app: app,
            title: app.localizedName,
            frame: .zero,
            axElement: AXUIElementCreateApplication(app.processIdentifier),
            appAxElement: AXUIElementCreateApplication(app.processIdentifier),
            closeButton: nil,
            isMinimized: false,
            isHidden: false,
            isFullscreen: false,
            lastAccessedTime: .distantPast,
            image: nil
        )
    }
}

extension PreviewWindow {
    /// Toggles the minimized state via AX.
    @MainActor
    @discardableResult
    mutating func toggleMinimize() -> Bool? {
        if isMinimized {
            if app.isHidden { app.unhide() }
            do {
                try axElement.setAttribute(kAXMinimizedAttribute, false)
                app.activate()
                bringToFront()
                isMinimized = false
                return false
            } catch {
                return nil
            }
        } else {
            do {
                try axElement.setAttribute(kAXMinimizedAttribute, true)
                isMinimized = true
                return true
            } catch {
                return nil
            }
        }
    }

    /// Toggles the hidden state of the whole app via AX.
    @MainActor
    @discardableResult
    mutating func toggleHidden() -> Bool? {
        let newHiddenState = !isHidden
        do {
            try appAxElement.setAttribute(kAXHiddenAttribute, newHiddenState)
            if !newHiddenState {
                app.activate()
                bringToFront()
            }
            isHidden = newHiddenState
            return newHiddenState
        } catch {
            return nil
        }
    }

    /// Toggles fullscreen via AX.
    @MainActor
    mutating func toggleFullScreen() -> Bool? {
        if let isCurrentlyInFullScreen = try? axElement.attribute(kAXFullscreenAttribute, Bool.self) {
            bringToFront()
            let newValue = !isCurrentlyInFullScreen
            do {
                try axElement.setAttribute(kAXFullscreenAttribute, newValue)
                isFullscreen = newValue
                return newValue
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Closes the window by pressing its AX close button.
    @MainActor
    func closeWindow() {
        guard let closeButton else { return }
        try? closeButton.performAction(kAXPressAction)
    }

    /// Brings the window to the front, unminimizing first if needed.
    @MainActor
    func bringToFront() {
        if isMinimized {
            try? axElement.setAttribute(kAXMinimizedAttribute, false)
        }
        if app.isHidden { app.unhide() }

        var psn = ProcessSerialNumber()
        _ = GetProcessForPID(app.processIdentifier, &psn)
        _ = _SLPSSetFrontProcessWithOptions(&psn, UInt32(id), SLPSMode.userGenerated.rawValue)

        try? axElement.performAction(kAXRaiseAction)
        try? axElement.setAttribute(kAXMainWindowAttribute, true)
        app.activate(options: [.activateAllWindows])
    }
}

// MARK: - Window discovery & capture

enum PreviewWindowUtil {
    /// Whether screen capture is permitted (CGSHWCaptureWindowList requires it).
    nonisolated static func shouldCaptureWindowImages() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Captures a single window by CGWindowID using the CGS hardware capture API.
    ///
    /// WindowServer occasionally returns a transitional surface whose width is
    /// only a fraction of the real window (most often while an app is updating
    /// or moving between Spaces).  Do not hand that frame to SwiftUI: its
    /// aspect ratio makes a normal landscape window look like a thin portrait
    /// slice.  Validate against the actual CG window bounds, retry briefly, and
    /// finally use ScreenCaptureKit's desktop-independent window capture.
    nonisolated static func captureWindowImage(
        windowID: CGWindowID,
        pid: pid_t,
        expectedSize: CGSize? = nil
    ) async throws -> CGImage {
        guard shouldCaptureWindowImages() else { throw captureError }

        for attempt in 0 ..< 3 {
            if let capturedImage = captureCGSWindowImage(windowID: windowID),
               captureGeometryIsValid(capturedImage, expectedSize: expectedSize)
            {
                return scaledPreviewImage(capturedImage)
            }

            // A bad WindowServer surface is normally replaced on the next
            // compositor frame. Keep this delay short so Dock hover remains
            // responsive while avoiding three captures of the same bad frame.
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(18))
            }
        }

        let fallback = try await captureScreenCaptureKitWindowImage(
            windowID: windowID,
            pid: pid,
            expectedSize: expectedSize
        )
        guard captureGeometryIsValid(fallback, expectedSize: expectedSize) else {
            throw captureError
        }
        return scaledPreviewImage(fallback)
    }

    nonisolated private static func captureCGSWindowImage(windowID: CGWindowID) -> CGImage? {
        let connectionID = CGSMainConnectionID()
        var windowIDUInt32 = UInt32(windowID)
        let quality: CGSWindowCaptureOptions = Defaults.shared.windowImageCaptureQuality == .best ? .bestResolution : .nominalResolution
        return (CGSHWCaptureWindowList(
            connectionID,
            &windowIDUInt32,
            1,
            [.ignoreGlobalClipShape, quality]
        ) as? [CGImage])?.first
    }

    nonisolated private static func captureGeometryIsValid(_ image: CGImage, expectedSize: CGSize?) -> Bool {
        guard image.width >= 2, image.height >= 2 else { return false }
        guard let expectedSize,
              expectedSize.width >= 2,
              expectedSize.height >= 2
        else { return true }

        let expectedAspect = expectedSize.width / expectedSize.height
        let capturedAspect = CGFloat(image.width) / CGFloat(image.height)
        guard expectedAspect.isFinite, capturedAspect.isFinite,
              expectedAspect > 0, capturedAspect > 0
        else { return false }

        // Title bars and app-specific window decorations can introduce a small
        // discrepancy. A half-width capture is around 2x wrong, so 30% keeps
        // legitimate windows while reliably rejecting the broken surface.
        let aspectError = max(expectedAspect / capturedAspect, capturedAspect / expectedAspect)
        return aspectError <= 1.30 && captureVisibleContentCoverageIsValid(image)
    }

    /// Some broken CGS frames retain the expected canvas size but only paint a
    /// narrow strip in its centre. Sample alpha coverage as well as dimensions
    /// so those frames cannot slip through the aspect-ratio check.
    nonisolated private static func captureVisibleContentCoverageIsValid(_ image: CGImage) -> Bool {
        let sampleWidth = 48
        let sampleHeight = 48
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * sampleHeight)
        let drewImage = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let baseAddress = storage.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: sampleWidth,
                      height: sampleHeight,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard drewImage else { return true }

        var minX = sampleWidth
        var maxX = -1
        var minY = sampleHeight
        var maxY = -1
        for y in 0 ..< sampleHeight {
            for x in 0 ..< sampleWidth {
                let alpha = pixels[y * bytesPerRow + x * bytesPerPixel + 3]
                guard alpha > 12 else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return false }
        let widthCoverage = CGFloat(maxX - minX + 1) / CGFloat(sampleWidth)
        let heightCoverage = CGFloat(maxY - minY + 1) / CGFloat(sampleHeight)
        return widthCoverage >= 0.68 && heightCoverage >= 0.68
    }

    nonisolated private static func captureScreenCaptureKitWindowImage(
        windowID: CGWindowID,
        pid: pid_t,
        expectedSize: CGSize?
    ) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let window = content.windows.first(where: {
            $0.windowID == windowID && $0.owningApplication?.processID == pid
        }) else { throw captureError }

        let sourceSize = expectedSize ?? window.frame.size
        guard sourceSize.width >= 2, sourceSize.height >= 2 else { throw captureError }

        let backingScale = NSScreen.main?.backingScaleFactor ?? 2
        let outputScale = max(1, backingScale)
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(sourceSize.width * outputScale))
        configuration.height = max(2, Int(sourceSize.height * outputScale))
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.captureResolution = .best

        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
    }

    nonisolated private static func scaledPreviewImage(_ capturedImage: CGImage) -> CGImage {
        let previewScale = max(1, Defaults.shared.windowPreviewImageScale)
        guard previewScale > 1 else { return capturedImage }

        let newWidth = capturedImage.width / previewScale
        let newHeight = capturedImage.height / previewScale
        let colorSpace = capturedImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: capturedImage.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: capturedImage.bitmapInfo.rawValue
        ) else { return capturedImage }
        context.interpolationQuality = .high
        context.draw(capturedImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? capturedImage
    }

    nonisolated static let captureError = NSError(domain: "LunchPad.Capture", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Unable to capture window image"
    ])

    /// Discovers all windows of an app via AX (including minimized/hidden and
    /// windows on other Spaces) and captures a snapshot for each.
    nonisolated static func getActiveWindows(of app: NSRunningApplication) async throws -> [PreviewWindow] {
        let pid = app.processIdentifier
        let appAX = AXUIElementCreateApplication(pid)
        let axWindows = AXUIElement.allWindows(pid, appElement: appAX, app: app)
        guard !axWindows.isEmpty else { return [] }

        let cgCandidates = cgWindowCandidates(for: pid)
        let scBackedWindowIDs = await screenCaptureWindowIDs(for: pid)
        let activeSpaceIDs = currentActiveSpaceIDs()

        let captureImages = shouldCaptureWindowImages()
        let windows = await withTaskGroup(of: PreviewWindow?.self, returning: [PreviewWindow].self) { group in
            var results: [PreviewWindow] = []
            results.reserveCapacity(axWindows.count)
            var iterator = axWindows.makeIterator()
            let concurrency = max(1, min(4, axWindows.count))

            func addNext() {
                guard let element = iterator.next() else { return }
                group.addTask {
                    try? await Self.windowInfo(
                        from: element,
                        app: app,
                        appAX: appAX,
                        captureImage: captureImages,
                        cgCandidates: cgCandidates,
                        scBackedWindowIDs: scBackedWindowIDs,
                        activeSpaceIDs: activeSpaceIDs
                    )
                }
            }
            for _ in 0 ..< concurrency { addNext() }
            while let window = await group.next() {
                if let window { results.append(window) }
                addNext()
            }
            return results
        }
        // Brute-force AX enumeration can return several remote AX elements
        // for the same real window. DockDoor's cache is keyed by CGWindowID;
        // mirror that behavior here before the view ever sees the list.
        var unique: [CGWindowID: PreviewWindow] = [:]
        for window in windows {
            if let existing = unique[window.id] {
                if existing.image == nil, window.image != nil { unique[window.id] = window }
            } else {
                unique[window.id] = window
            }
        }
        var cgOrder: [CGWindowID: Int] = [:]
        for (index, entry) in cgCandidates.enumerated() {
            guard let number = entry[kCGWindowNumber as String] as? NSNumber else { continue }
            cgOrder[CGWindowID(number.uint32Value), default: index] = index
        }
        let deduplicated = unique.values.sorted { (cgOrder[$0.id] ?? .max) < (cgOrder[$1.id] ?? .max) }
        return sortWindows(deduplicated)
    }

    nonisolated private static func windowInfo(
        from element: AXUIElement,
        app: NSRunningApplication,
        appAX: AXUIElement,
        captureImage: Bool,
        cgCandidates: [[String: AnyObject]],
        scBackedWindowIDs: Set<CGWindowID>,
        activeSpaceIDs: Set<Int>
    ) async throws -> PreviewWindow? {
        guard let windowID = try? element.cgWindowId(), windowID != 0 else { return nil }
        guard let position = try? element.position(),
              let size = try? element.size() else { return nil }

        guard let role = try? element.role(), role == kAXWindowRole,
              let subrole = try? element.subrole(),
              [kAXStandardWindowSubrole, kAXDialogSubrole].contains(subrole)
        else { return nil }
        let normalLevel = CGWindowLevelForKey(.normalWindow)
        guard windowID.cgsLevel() == normalLevel,
              size.width >= 100, size.height >= 50,
              position.x.isFinite, position.y.isFinite,
              let cgEntry = cgCandidates.first(where: {
                  (($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0) == windowID
              })
        else { return nil }

        let layer = (cgEntry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        let alpha = (cgEntry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        let sharingState = (cgEntry[kCGWindowSharingState as String] as? NSNumber)?.intValue ?? 1
        guard layer == 0, alpha > 0.01, sharingState != 0 else { return nil }

        let cgBounds: CGRect? = if let boundsDictionary = cgEntry[kCGWindowBounds as String] as? NSDictionary {
            CGRect(dictionaryRepresentation: boundsDictionary)
        } else {
            nil
        }
        let expectedCaptureSize = cgBounds?.size ?? size

        let primaryScreenMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = CGRect(
            x: position.x,
            y: primaryScreenMaxY - position.y - size.height,
            width: size.width,
            height: size.height
        )

        let title = try? element.title()
        let closeButton = try? element.closeButton()
        let isMinimized = (try? element.isMinimized()) ?? false
        let isFullscreen = (try? element.isFullscreen()) ?? false
        let isHidden = app.isHidden
        let isOnscreen = (cgEntry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        let isSCBacked = scBackedWindowIDs.contains(windowID)
        let windowSpaces = Set(windowID.cgsSpaces().map { Int($0) })
        let isOnActiveSpace = !windowSpaces.isEmpty && !windowSpaces.isDisjoint(with: activeSpaceIDs)

        // DockDoor rejects stale AX surfaces that claim the active Space but
        // are neither visible, minimized, fullscreen nor part of a hidden app.
        let isGhostWindow = !isOnscreen && isOnActiveSpace && !isMinimized && !isFullscreen && !isHidden
        guard !isGhostWindow else { return nil }
        if !isOnscreen && !isSCBacked && !isMinimized && !isFullscreen && !isHidden {
            // A valid normal window on another Space is intentionally kept
            // when “current Space only” is disabled. CGS can capture it even
            // though CGWindowList marks it offscreen.
            let isOnAnotherSpace = !windowSpaces.isEmpty && windowSpaces.isDisjoint(with: activeSpaceIDs)
            guard isOnAnotherSpace, !Defaults.shared.showCurrentSpaceOnly else { return nil }
        }

        var image: CGImage?
        // 最小化/隐藏的窗口也尝试截图：CGS 硬件捕获能取到部分最小化窗口
        // 的内容，失败时卡片自然回退到占位图。
        if captureImage {
            image = try? await captureWindowImage(
                windowID: windowID,
                pid: app.processIdentifier,
                expectedSize: expectedCaptureSize
            )
        }

        return PreviewWindow(
            id: windowID,
            app: app,
            title: title,
            frame: frame,
            axElement: element,
            appAxElement: appAX,
            closeButton: closeButton,
            isMinimized: isMinimized,
            isHidden: isHidden,
            isFullscreen: isFullscreen,
            lastAccessedTime: Date(),
            image: image
        )
    }

    nonisolated private static func cgWindowCandidates(for pid: pid_t) -> [[String: AnyObject]] {
        let all = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] ?? []
        return all.filter {
            (($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0) == pid
        }.sorted {
            let left = ($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let right = ($1[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            return left == 0 && right != 0
        }
    }

    /// ScreenCaptureKit returns real windows across all Spaces. Unlike
    /// `kCGWindowIsOnscreen`, this remains usable for windows that live on a
    /// different desktop and also avoids accepting stale AX-only surfaces.
    nonisolated private static func screenCaptureWindowIDs(for pid: pid_t) async -> Set<CGWindowID> {
        guard shouldCaptureWindowImages(),
              let content = try? await SCShareableContent.excludingDesktopWindows(
                  false,
                  onScreenWindowsOnly: false
              )
        else { return [] }

        return Set(content.windows.compactMap { window in
            guard window.owningApplication?.processID == pid,
                  window.windowLayer == 0,
                  window.frame.width >= 100,
                  window.frame.height >= 50
            else { return nil }
            return window.windowID
        })
    }

    /// Preserve the Window Server's front-to-back ordering. The previous
    /// implementation sorted by timestamps created by concurrent discovery,
    /// which made cards jump randomly every time the preview opened.
    nonisolated static func sortWindows(_ windows: [PreviewWindow]) -> [PreviewWindow] {
        var sorted = windows
        if Defaults.shared.sortMinimizedToEnd {
            let (visible, minimizedOrHidden) = sorted.reduce(into: ([PreviewWindow](), [PreviewWindow]())) { result, window in
                if window.isMinimized || window.isHidden {
                    result.1.append(window)
                } else {
                    result.0.append(window)
                }
            }
            sorted = visible + minimizedOrHidden
        }
        return sorted
    }

    static func filterWindowsByCurrentSpace(_ windows: [PreviewWindow]) -> [PreviewWindow] {
        let activeSpaceIDs = currentActiveSpaceIDs()
        return windows.filter { window in
            let windowSpaces = Set(window.id.cgsSpaces().map { Int($0) })
            if !windowSpaces.isEmpty {
                return !windowSpaces.isDisjoint(with: activeSpaceIDs)
            }
            return window.isMinimized || window.isHidden
        }
    }

    static func filterWindowsByCurrentMonitor(_ windows: [PreviewWindow], mouseLocation: CGPoint? = nil) -> [PreviewWindow] {
        let mouse = mouseLocation ?? CGEvent(source: nil)?.location ?? .zero
        let currentScreen = NSScreen.screenFromQuartzPoint(mouse)
        let id = currentScreen.uniqueIdentifier()
        return windows.filter { window in
            if !window.frame.isEmpty {
                return NSScreen.screenFromQuartzPoint(CGPoint(x: window.frame.midX, y: window.frame.midY)).uniqueIdentifier() == id
            }
            return window.isMinimized || window.isHidden
        }
    }
}

// MARK: - Preview settings (DockDoor-compatible defaults)

/// UserDefaults-backed settings mirroring DockDoor's defaults.
final class Defaults {
    nonisolated static let shared = Defaults()
    nonisolated private init() {
        UserDefaults.standard.register(defaults: [
            "dock-hover-expose": true,                 // enableDockPreviews
            "hover-open-delay": 0.2,                    // hoverWindowOpenDelay
            "anchor-dock-preview-position": true,
            "show-animations": true,
            "preview-max-columns": 2,
            "preview-max-rows": 1,
            "include-hidden-windows": true,             // includeHiddenWindowsInDockPreview
            "show-current-space-only": false,
            "show-current-monitor-only": false,
            "ignore-single-window-apps": false,
            "show-windowless-apps": false,
            "fade-out-duration": 0.4,
            "inactivity-timeout": 0.2,
            "raised-window-level": true,
            "show-minimized-hidden-labels": true,
            "window-preview-image-scale": 1,
            "preview-width": 300.0,
            "preview-height": 187.5,
            "preview-background-opacity": 1.0,
            "hide-container-background": false,
            "global-padding-multiplier": 0.7,
            "use-delay-only-for-initial-open": false,
            "allow-dynamic-image-sizing": false,
            "show-app-name": true,
            "sort-minimized-to-end": false,
            "window-image-capture-quality": "nominal",
            "prevent-preview-reentry-during-fade-out": false,
            "uniform-card-radius": true,
            "selection-opacity": 0.4,
            "unselected-content-opacity": 1.0,
            "show-window-title": true,
        ])
    }

    enum WindowImageCaptureQuality: String {
        case nominal, best
    }

    nonisolated var dockPreviewsEnabled: Bool { bool("dock-hover-expose") }
    nonisolated var hoverOpenDelay: TimeInterval { double("hover-open-delay") }
    /// DockDoor's default is computed: -25 with magnification, -18 on the
    /// right side, otherwise -20.
    var bufferFromDock: CGFloat {
        if UserDefaults.standard.object(forKey: "buffer-from-dock") == nil {
            if CoreDockIsMagnificationEnabled() { return -25 }
            return DockUtils.getDockPosition() == .right ? -18 : -20
        }
        return double("buffer-from-dock")
    }
    /// User-facing spacing where 0 is the historical -20 DockDoor baseline.
    nonisolated var dockSpacing: CGFloat {
        guard UserDefaults.standard.object(forKey: "buffer-from-dock") != nil else { return 0 }
        return double("buffer-from-dock") + 20
    }
    nonisolated var anchorDockPreviewPosition: Bool { bool("anchor-dock-preview-position") }
    nonisolated var showAnimations: Bool { bool("show-animations") }
    nonisolated var previewMaxColumns: Int { int("preview-max-columns") }
    nonisolated var previewMaxRows: Int { int("preview-max-rows") }
    nonisolated var includeHiddenWindows: Bool { bool("include-hidden-windows") }
    nonisolated var showCurrentSpaceOnly: Bool { bool("show-current-space-only") }
    nonisolated var showCurrentMonitorOnly: Bool { bool("show-current-monitor-only") }
    nonisolated var ignoreSingleWindowApps: Bool { bool("ignore-single-window-apps") }
    nonisolated var showWindowlessApps: Bool { bool("show-windowless-apps") }
    nonisolated var fadeOutDuration: TimeInterval { double("fade-out-duration") }
    nonisolated var inactivityTimeout: TimeInterval { double("inactivity-timeout") }
    nonisolated var raisedWindowLevel: Bool { bool("raised-window-level") }
    nonisolated var showMinimizedHiddenLabels: Bool { bool("show-minimized-hidden-labels") }
    nonisolated var windowPreviewImageScale: Int { max(1, int("window-preview-image-scale")) }
    nonisolated var previewWidth: CGFloat { double("preview-width") }
    nonisolated var previewHeight: CGFloat { double("preview-height") }
    nonisolated var previewBackgroundOpacity: CGFloat { double("preview-background-opacity") }
    nonisolated var hideContainerBackground: Bool { bool("hide-container-background") }
    nonisolated var globalPaddingMultiplier: CGFloat { double("global-padding-multiplier") }
    nonisolated var useDelayOnlyForInitialOpen: Bool { bool("use-delay-only-for-initial-open") }
    nonisolated var allowDynamicImageSizing: Bool { bool("allow-dynamic-image-sizing") }
    nonisolated var showAppName: Bool { bool("show-app-name") }
    nonisolated var sortMinimizedToEnd: Bool { bool("sort-minimized-to-end") }
    nonisolated var windowImageCaptureQuality: WindowImageCaptureQuality {
        WindowImageCaptureQuality(rawValue: string("window-image-capture-quality")) ?? .nominal
    }
    nonisolated var preventPreviewReentryDuringFadeOut: Bool { bool("prevent-preview-reentry-during-fade-out") }
    nonisolated var uniformCardRadius: Bool { bool("uniform-card-radius") }
    nonisolated var selectionOpacity: Double { double("selection-opacity") }
    nonisolated var unselectedContentOpacity: Double { double("unselected-content-opacity") }
    nonisolated var showWindowTitle: Bool { bool("show-window-title") }

    nonisolated private func bool(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
    nonisolated private func double(_ key: String) -> CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: key))
    }
    nonisolated private func int(_ key: String) -> Int {
        UserDefaults.standard.integer(forKey: key)
    }
    nonisolated private func string(_ key: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }
}
