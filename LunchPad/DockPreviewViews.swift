// SPDX-License-Identifier: GPL-3.0-or-later
// Dock hover preview portions adapted from DockDoor.
// Copyright (C) 2024 ejbills.

import AppKit
import QuartzCore
import SwiftUI

// MARK: - Constants (DockDoor CardRadius / HoverContainerPadding)

enum ArrowDirection {
    case left, right, up, down
}

enum CardRadius {
    // Close to the radius used by standard macOS windows. The previous
    // DockDoor-derived values became excessively round at this smaller scale.
    nonisolated static let base: Double = 10
    nonisolated static let innerPadding: Double = 4
    nonisolated static let outerPadding: Double = 10
    nonisolated static let fallback: Double = 8

    static func outer(for padding: Double) -> Double {
        Defaults.shared.uniformCardRadius ? base + (padding * Defaults.shared.globalPaddingMultiplier) : fallback
    }

    static var inner: Double { outer(for: innerPadding) }
    static var container: Double { outer(for: outerPadding) }
    static var image: Double { max(fallback, inner - innerPadding) }

    static func switcherToolbarHorizontalPadding(uniformCardRadius: Bool) -> CGFloat {
        guard uniformCardRadius else { return 0 }
        return CGFloat(innerPadding / 2)
    }
}

enum HoverContainerPadding {
    static let container: CGFloat = 24
    static let dockStyleOuter: CGFloat = 2
    static let scrollOuter: CGFloat = 2
    static let contentInner: CGFloat = 20
    static let itemSpacing: CGFloat = 24

    static func totalPerSide() -> CGFloat {
        container + dockStyleOuter + scrollOuter + (contentInner * Defaults.shared.globalPaddingMultiplier)
    }
}

// MARK: - Global padding (DockDoor GlobalPadding)

extension View {
    /// Padding scaled by the global padding multiplier.
    func globalPadding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View {
        let multiplier = Defaults.shared.globalPaddingMultiplier
        let adjustedLength = length.map { $0 * multiplier }
        return padding(edges, adjustedLength)
    }

    /// Padding scaled by the global padding multiplier.
    func globalPadding(_ length: CGFloat) -> some View {
        padding(length * Defaults.shared.globalPaddingMultiplier)
    }
}

// MARK: - Glass background (DockDoor BlurView / liquid glass)

/// The Tahoe liquid-glass surface used for the container and cards.
struct GlassBlurView: View {
    let cornerRadius: CGFloat

    var body: some View {
        DockLiquidGlassRepresentable(cornerRadius: cornerRadius)
    }
}

/// DockDoor's native macOS 26 Liquid Glass implementation. A native
/// `NSGlassEffectView` is required here because the preview is a nonactivating
/// floating panel; SwiftUI's `glassEffect` does not keep the same backdrop
/// quality and saturation in that window configuration.
@available(macOS 26.0, *)
private struct DockLiquidGlassRepresentable: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> DockLiquidGlassContainerView {
        let view = DockLiquidGlassContainerView()
        view.cornerRadius = cornerRadius
        view.updateCornerRadius()
        return view
    }

    func updateNSView(_ view: DockLiquidGlassContainerView, context: Context) {
        view.cornerRadius = cornerRadius
        view.updateCornerRadius()
        view.applyAppearance()
    }
}

@available(macOS 26.0, *)
private final class DockLiquidGlassContainerView: NSView {
    var cornerRadius: CGFloat = 14

    private let glassOpacity: CGFloat = 0.95
    private let tintOpacity: CGFloat = 0.18
    private let saturation: CGFloat = 1.8
    private let glassVariant = 4

    private var glassView: NSGlassEffectView?
    private var tintView: NSView?
    private var backdropLayers: [CALayer] = []
    private var configuredBackdrop = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGlass()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGlass()
    }

    private func setupGlass() {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let tint = NSView()
        tint.translatesAutoresizingMaskIntoConstraints = false
        tint.wantsLayer = true
        addSubview(tint)

        let glass = NSGlassEffectView()
        glass.style = .clear
        setNativeVariant(on: glass, glassVariant)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        for view in [tint, glass] {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        tintView = tint
        glassView = glass
        applyAppearance()
    }

    func updateCornerRadius() {
        layer?.cornerRadius = cornerRadius
    }

    func applyAppearance() {
        glassView?.alphaValue = glassOpacity
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        tintView?.layer?.backgroundColor = (isDark ? NSColor.black : NSColor.white)
            .withAlphaComponent(tintOpacity).cgColor
        for backdrop in backdropLayers {
            backdrop.setValue(true, forKey: "windowServerAware")
            backdrop.setValue(1.0, forKey: "scale")
            backdrop.setValue(saturation, forKey: "saturationFactor")
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !configuredBackdrop else { return }
        configuredBackdrop = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.configureBackdropLayers()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func setNativeVariant(on view: NSView, _ variant: Int) {
        let selector = NSSelectorFromString("set_variant:")
        guard view.responds(to: selector), let implementation = view.method(for: selector) else { return }
        typealias Setter = @convention(c) (NSObject, Selector, Int64) -> Void
        unsafeBitCast(implementation, to: Setter.self)(view, selector, Int64(variant))
    }

    private func configureBackdropLayers() {
        guard let rootLayer = glassView?.layer else { return }
        backdropLayers = collectBackdropLayers(in: rootLayer)
        applyAppearance()
    }

    private func collectBackdropLayers(in layer: CALayer) -> [CALayer] {
        var result: [CALayer] = []
        if NSStringFromClass(type(of: layer)).contains("CABackdropLayer") {
            result.append(layer)
        }
        layer.sublayers?.forEach { result.append(contentsOf: collectBackdropLayers(in: $0)) }
        return result
    }
}

/// Directional rim-light stroke that reads as lit glass (DockDoor's border).
func glassBorderGradient(opacity: CGFloat) -> LinearGradient {
    let scale = opacity / 0.15
    return LinearGradient(
        colors: [
            .white.opacity(0.35 * scale),
            .white.opacity(0.12 * scale),
            .white.opacity(0.05 * scale),
            .white.opacity(0.12 * scale),
            .white.opacity(0.28 * scale),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension View {
    func borderedBackground(_ content: some ShapeStyle, lineWidth: CGFloat = 1.0, shape: some InsettableShape) -> some View {
        padding(lineWidth * 0.75)
            .background {
                shape
                    .strokeBorder(content, lineWidth: lineWidth)
            }
            .clipShape(shape)
    }
}

struct DockStyleModifier: ViewModifier {
    let cornerRadius: Double
    let backgroundOpacity: CGFloat
    let outerPadding: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                GlassBlurView(cornerRadius: cornerRadius)
                    .borderedBackground(glassBorderGradient(opacity: 0.15), lineWidth: 1, shape: shape)
                    .opacity(backgroundOpacity)
                    .clipShape(shape)
            }
            .padding(outerPadding)
    }
}

extension View {
    func dockStyle(
        cornerRadius: Double = CardRadius.container,
        backgroundOpacity: CGFloat = 1.0,
        outerPadding: CGFloat = HoverContainerPadding.dockStyleOuter
    ) -> some View {
        modifier(DockStyleModifier(
            cornerRadius: cornerRadius,
            backgroundOpacity: backgroundOpacity,
            outerPadding: outerPadding
        ))
    }
}

/// Blur pill used for the window title and traffic lights (DockDoor materialPill).
extension View {
    func materialPill() -> some View {
        padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                GlassBlurView(cornerRadius: 11)
            }
            .clipShape(Capsule(style: .continuous))
            .borderedBackground(.primary.opacity(0.1), lineWidth: 1.5, shape: Capsule(style: .continuous))
    }
}

// MARK: - Shared app icon helper

enum SharedHoverUtils {
    static func loadAppIcon(for bundleIdentifier: String) -> NSImage? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
           let icon = app.icon
        {
            return icon
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        return nil
    }
}

// MARK: - Preview dimensions (DockDoor sizing calculations)

enum PreviewDimensionCalculator {
    static let dynamicMaxAspectRatio: CGFloat = 1.5

    nonisolated private static func orientedDimensions(for window: PreviewWindow) -> CGSize {
        let maxWidth = Defaults.shared.previewWidth
        let maxHeight = Defaults.shared.previewHeight
        let inset = CGFloat(CardRadius.innerPadding)
        guard let image = window.image, image.width > 0, image.height > 0 else {
            return CGSize(width: maxWidth, height: maxHeight)
        }

        let aspectRatio = CGFloat(image.width) / CGFloat(image.height)
        if aspectRatio >= 1 {
            // Landscape: width is authoritative, height follows the image.
            let innerWidth = max(50, maxWidth - inset * 2)
            return CGSize(
                width: maxWidth,
                height: max(50, innerWidth / aspectRatio + inset * 2)
            )
        }

        // Portrait: height is authoritative, width follows the image. Keep a
        // practical minimum so the controls and truncated title remain usable.
        let innerHeight = max(50, maxHeight - inset * 2)
        return CGSize(
            width: max(200, innerHeight * aspectRatio + inset * 2),
            height: maxHeight
        )
    }

    static func calculateOverallMaxDimensions(windows: [PreviewWindow], dockPosition: DockPosition, sharedPanelWindowSize: CGSize) -> CGSize {
        let sizes = windows.map(orientedDimensions(for:))
        return CGSize(
            width: sizes.map(\.width).max() ?? Defaults.shared.previewWidth,
            height: sizes.map(\.height).max() ?? Defaults.shared.previewHeight
        )
    }

    static func precomputeWindowDimensions(
        windows: [PreviewWindow],
        overallMaxDimensions: CGSize,
        dockPosition: DockPosition
    ) -> [Int: CGSize] {
        Dictionary(uniqueKeysWithValues: windows.enumerated().map { index, window in
            (index, orientedDimensions(for: window))
        })
    }

    // MARK: - Grid chunking (DockDoor chunkArray)

    static func calculateEffectiveMaxColumnsAndRows(
        bestGuessMonitor: NSScreen,
        overallMaxDimensions: CGSize,
        dockPosition: DockPosition,
        previewMaxColumns: Int,
        previewMaxRows: Int,
        totalItems: Int
    ) -> (maxColumns: Int, maxRows: Int) {
        // Keep a real screen-edge gutter. Without it, an exact fourth column
        // could fit mathematically while the glass stroke and panel shadow
        // still painted beyond the display edge.
        let edgeGutter: CGFloat = 16
        let screenWidth = max(1, bestGuessMonitor.visibleFrame.width - edgeGutter * 2)
        let screenHeight = max(1, bestGuessMonitor.visibleFrame.height - edgeGutter * 2)
        let itemSpacing = HoverContainerPadding.itemSpacing
        let globalPadding = HoverContainerPadding.totalPerSide() * 2

        let previewWidth = overallMaxDimensions.width
        let previewHeight = overallMaxDimensions.height

        let calculatedMaxColumns = max(1, Int((screenWidth - globalPadding + itemSpacing) / (previewWidth + itemSpacing)))
        let calculatedMaxRows = max(1, Int((screenHeight - globalPadding + itemSpacing) / (previewHeight + itemSpacing)))

        if dockPosition == .bottom {
            return (calculatedMaxColumns, previewMaxRows)
        }
        return (previewMaxColumns, calculatedMaxRows)
    }

    static func chunkArray<T>(
        items: [T],
        isHorizontal: Bool,
        maxColumns: Int,
        maxRows: Int,
        reverse: Bool = false
    ) -> [[T]] {
        let totalItems = items.count
        guard totalItems > 0, maxColumns > 0, maxRows > 0 else { return [] }

        var chunks: [[T]]
        if isHorizontal {
            let actualRowsNeeded = min(maxRows, Int(ceil(Double(totalItems) / Double(maxColumns))))
            let itemsPerRow = Int(ceil(Double(totalItems) / Double(actualRowsNeeded)))
            chunks = []
            var startIndex = 0
            while startIndex < totalItems {
                let endIndex = min(startIndex + itemsPerRow, totalItems)
                chunks.append(Array(items[startIndex ..< endIndex]))
                startIndex = endIndex
            }
        } else {
            let actualColumnsNeeded = min(maxColumns, Int(ceil(Double(totalItems) / Double(maxRows))))
            let itemsPerColumn = Int(ceil(Double(totalItems) / Double(actualColumnsNeeded)))
            chunks = []
            var startIndex = 0
            while startIndex < totalItems {
                let endIndex = min(startIndex + itemsPerColumn, totalItems)
                chunks.append(Array(items[startIndex ..< endIndex]))
                startIndex = endIndex
            }
        }

        if reverse {
            chunks = chunks.reversed()
        }
        return chunks
    }

    /// Arrow-key navigation over the chunked grid (DockDoor navigateInGrid).
    static func navigateInGrid(
        from currentIndex: Int,
        direction: ArrowDirection,
        totalItems: Int,
        isHorizontal: Bool,
        maxColumns: Int,
        maxRows: Int,
        reverse: Bool = false
    ) -> Int {
        guard totalItems > 0, currentIndex >= 0, currentIndex < totalItems else {
            return currentIndex
        }

        let items = Array(0 ..< totalItems)
        let chunks = chunkArray(
            items: items,
            isHorizontal: isHorizontal,
            maxColumns: maxColumns,
            maxRows: maxRows,
            reverse: reverse
        )

        var currentChunkIndex = 0
        var currentPositionInChunk = 0
        for (chunkIdx, chunk) in chunks.enumerated() {
            if let posInChunk = chunk.firstIndex(of: currentIndex) {
                currentChunkIndex = chunkIdx
                currentPositionInChunk = posInChunk
                break
            }
        }

        var targetChunkIndex = currentChunkIndex
        var targetPositionInChunk = currentPositionInChunk

        if isHorizontal {
            switch direction {
            case .left:
                targetPositionInChunk -= 1
                if targetPositionInChunk < 0 {
                    targetChunkIndex = (currentChunkIndex - 1 + chunks.count) % chunks.count
                    targetPositionInChunk = chunks[targetChunkIndex].count - 1
                }
            case .right:
                targetPositionInChunk += 1
                if targetPositionInChunk >= chunks[currentChunkIndex].count {
                    targetChunkIndex = (currentChunkIndex + 1) % chunks.count
                    targetPositionInChunk = 0
                }
            case .up:
                targetChunkIndex = (currentChunkIndex - 1 + chunks.count) % chunks.count
                targetPositionInChunk = min(currentPositionInChunk, chunks[targetChunkIndex].count - 1)
            case .down:
                targetChunkIndex = (currentChunkIndex + 1) % chunks.count
                targetPositionInChunk = min(currentPositionInChunk, chunks[targetChunkIndex].count - 1)
            }
        } else {
            switch direction {
            case .up:
                targetPositionInChunk -= 1
                if targetPositionInChunk < 0 {
                    targetChunkIndex = (currentChunkIndex - 1 + chunks.count) % chunks.count
                    targetPositionInChunk = chunks[targetChunkIndex].count - 1
                }
            case .down:
                targetPositionInChunk += 1
                if targetPositionInChunk >= chunks[currentChunkIndex].count {
                    targetChunkIndex = (currentChunkIndex + 1) % chunks.count
                    targetPositionInChunk = 0
                }
            case .left:
                targetChunkIndex = (currentChunkIndex - 1 + chunks.count) % chunks.count
                targetPositionInChunk = min(currentPositionInChunk, chunks[targetChunkIndex].count - 1)
            case .right:
                targetChunkIndex = (currentChunkIndex + 1) % chunks.count
                targetPositionInChunk = min(currentPositionInChunk, chunks[targetChunkIndex].count - 1)
            }
        }

        return chunks[targetChunkIndex][targetPositionInChunk]
    }
}

// MARK: - Window card (DockDoor WindowPreview)

private enum WindowCardAction {
    case quit
    case close
    case minimize
    case toggleFullScreen
    case hide

    var symbol: String {
        switch self {
        case .quit: "power"
        case .close: "xmark"
        case .minimize: "minus"
        case .toggleFullScreen: "arrow.up.left.and.arrow.down.right"
        case .hide: "eye.slash"
        }
    }

    var color: Color {
        switch self {
        case .quit: Color(red: 0.16, green: 0.0, blue: 0.2)
        case .close: Color(red: 0.49, green: 0.02, blue: 0.04)
        case .minimize: Color(red: 0.6, green: 0.34, blue: 0.07)
        case .toggleFullScreen: Color(red: 0.05, green: 0.4, blue: 0.05)
        case .hide: Color(red: 0.1, green: 0.2, blue: 0.5)
        }
    }

    var fillColor: Color {
        switch self {
        case .quit: .purple
        case .close: .red
        case .minimize: .yellow
        case .toggleFullScreen: .green
        case .hide: .indigo
        }
    }
}

struct PreviewWindowCard: View {
    let window: PreviewWindow
    let dimensions: CGSize
    let maxDimensions: CGSize
    let isSelected: Bool
    let onWindowTap: (() -> Void)?
    fileprivate let onWindowAction: (WindowCardAction) -> Void

    @State private var isHovering = false

    private var isInactive: Bool {
        (window.isMinimized || window.isHidden) && Defaults.shared.showMinimizedHiddenLabels
    }

    private var finalIsSelected: Bool { isSelected || isHovering }

    private var cornerRadius: Double {
        CardRadius.base + (CardRadius.innerPadding * Defaults.shared.globalPaddingMultiplier)
    }

    private var imageCornerRadius: Double {
        max(0, cornerRadius - CardRadius.innerPadding)
    }

    private var showTitle: Bool {
        Defaults.shared.showWindowTitle
    }

    private var titleToShow: String? {
        if let windowTitle = window.title, !windowTitle.isEmpty {
            windowTitle
        } else {
            window.app.localizedName
        }
    }

    private func symbol(for action: WindowCardAction) -> String {
        if action == .toggleFullScreen, window.isFullscreen {
            return "arrow.down.right.and.arrow.up.left"
        }
        return action.symbol
    }

    var body: some View {
        previewCoreContent
            .fixedSize()
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
            }
            .onTapGesture {
                if window.isMinimized {
                    onWindowAction(.minimize)
                } else if window.isHidden {
                    onWindowAction(.hide)
                } else {
                    window.bringToFront()
                    onWindowTap?()
                }
            }
            .contextMenu {
                if window.closeButton != nil {
                    Button(action: { onWindowAction(.minimize) }) {
                        Label(window.isMinimized ? "还原窗口" : "最小化", systemImage: window.isMinimized ? "arrow.up.left.and.arrow.down.right.square" : "minus.square")
                    }
                    Button(action: { onWindowAction(.toggleFullScreen) }) {
                        Label("切换全屏", systemImage: "arrow.up.left.and.arrow.down.right.square")
                    }
                    Divider()
                    Button(action: { onWindowAction(.close) }) {
                        Label("关闭窗口", systemImage: "xmark.square")
                    }
                    Button(role: .destructive, action: { onWindowAction(.quit) }) {
                        Label("退出应用", systemImage: "power")
                    }
                }
            }
    }

    private var previewCoreContent: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                // DockDoor default (`topTrailing`): traffic lights on the
                // leading side and the title pill on the trailing side.
                HStack(spacing: 4) {
                    trafficLights
                    Spacer(minLength: 8)
                    if let title = titleToShow, showTitle {
                        Text(title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .materialPill()
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .padding(.horizontal, CardRadius.switcherToolbarHorizontalPadding(uniformCardRadius: Defaults.shared.uniformCardRadius))
                .padding(.bottom, 2)

                windowContent
                    .frame(width: dimensions.width, height: dimensions.height, alignment: .center)
            }
            // As in DockDoor, the configured dimensions belong to the image
            // surface; the toolbar contributes additional card height.
            .frame(width: dimensions.width)
            .background {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                GlassBlurView(cornerRadius: cornerRadius)
                    .clipShape(shape)
                    .borderedBackground(.primary.opacity(0.1), lineWidth: 1.75, shape: shape)
                    .overlay {
                        if finalIsSelected {
                            let highlightColor = Color(nsColor: .controlAccentColor)
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(highlightColor.opacity(Defaults.shared.selectionOpacity))
                        }
                    }
                    .overlay {
                        if finalIsSelected {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2.5)
                        }
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    private var windowContent: some View {
        Group {
            if let image = window.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            }
        }
        .opacity(isInactive ? Defaults.shared.unselectedContentOpacity : 1)
        .overlay {
            if isInactive, Defaults.shared.showMinimizedHiddenLabels {
                Image(systemName: "eye.slash")
                    .font(.largeTitle)
                    .foregroundColor(.primary)
                    .shadow(radius: 2)
                    .transition(.opacity)
            }
        }
        .animation(Defaults.shared.showAnimations ? .easeInOut(duration: 0.15) : nil, value: isInactive)
        .clipShape(RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous))
        .frame(
            width: max(dimensions.width - CardRadius.innerPadding * 2, 50),
            height: max(dimensions.height - CardRadius.innerPadding * 2, 50),
            alignment: .center
        )
        .opacity(finalIsSelected ? 1.0 : Defaults.shared.unselectedContentOpacity)
    }

    @ViewBuilder
    private var trafficLights: some View {
        let canShowControls = Defaults.shared.showMinimizedHiddenLabels
            ? (!window.isMinimized && !window.isHidden)
            : true

        if window.closeButton != nil, canShowControls {
            let buttons: [WindowCardAction] = [.quit, .close, .minimize, .toggleFullScreen]
            HStack(spacing: 5) {
                ForEach(buttons, id: \.self) { action in
                    ZStack {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(.secondary)
                        Image(systemName: "\(symbol(for: action)).circle.fill")
                    }
                    .foregroundStyle(action.color, action.fillColor)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onWindowAction(action)
                    }
                }
            }
            .padding(2)
            .opacity((finalIsSelected || isHovering) ? 1.0 : 0.25)
            .materialPill()
        } else if window.isMinimized || window.isHidden {
            // 与流量灯按钮（14pt 图标 + 2pt 内边距 + 胶囊）完全同构同高，
            // 文字用 caption 字号避免在定高框内溢出。
            Text(window.isMinimized ? "最小化" : "已隐藏")
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
                .frame(height: 14)
                .padding(2)
                .materialPill()
        }
    }
}

// MARK: - Hover container (DockDoor WindowPreviewHoverContainer + BaseHoverContainer)

struct DockPreviewHoverContainer: View {
    let appName: String
    let onWindowTap: (() -> Void)?
    let dockPosition: DockPosition
    let bestGuessMonitor: NSScreen
    let dockItemElement: AXUIElement?
    @ObservedObject var state: DockPreviewState

    @State private var appIcon: NSImage?
    @State private var scrolledFromStart = false

    private var isHorizontal: Bool { dockPosition.isHorizontalFlow }

    private var overallMaxDimensions: CGSize {
        PreviewDimensionCalculator.calculateOverallMaxDimensions(
            windows: state.windows,
            dockPosition: dockPosition,
            sharedPanelWindowSize: bestGuessMonitor.visibleFrame.size
        )
    }

    private var dimensionsMap: [Int: CGSize] {
        PreviewDimensionCalculator.precomputeWindowDimensions(
            windows: state.windows,
            overallMaxDimensions: overallMaxDimensions,
            dockPosition: dockPosition
        )
    }

    private var chunks: [[Int]] {
        let count = state.windows.count
        guard count > 0 else { return [] }
        let (maxColumns, maxRows) = PreviewDimensionCalculator.calculateEffectiveMaxColumnsAndRows(
            bestGuessMonitor: bestGuessMonitor,
            overallMaxDimensions: overallMaxDimensions,
            dockPosition: dockPosition,
            previewMaxColumns: Defaults.shared.previewMaxColumns,
            previewMaxRows: Defaults.shared.previewMaxRows,
            totalItems: count
        )
        let shouldReverse = dockPosition == .bottom || dockPosition == .right
        return PreviewDimensionCalculator.chunkArray(
            items: Array(0 ..< count),
            isHorizontal: isHorizontal,
            maxColumns: maxColumns,
            maxRows: maxRows,
            reverse: shouldReverse
        )
    }

    var body: some View {
        BaseHoverContainer(bestGuessMonitor: bestGuessMonitor) {
            windowGridContent
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Clicking blank space inside the preview activates the app.
            if let app = state.windows.first?.app {
                if app.isHidden { app.unhide() }
                app.activate(options: [.activateAllWindows])
            }
        }
        .onAppear {
            loadAppIcon()
        }
    }

    private var windowGridContent: some View {
        ScrollView(isHorizontal ? .horizontal : .vertical, showsIndicators: false) {
            Group {
                if isHorizontal {
                    VStack(alignment: .leading, spacing: HoverContainerPadding.itemSpacing) {
                        ForEach(Array(chunks.enumerated()), id: \.offset) { _, rowItems in
                            HStack(spacing: HoverContainerPadding.itemSpacing) {
                                ForEach(rowItems, id: \.self) { index in
                                    windowCard(index)
                                }
                            }
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: HoverContainerPadding.itemSpacing) {
                        ForEach(Array(chunks.enumerated()), id: \.offset) { _, columnItems in
                            VStack(spacing: HoverContainerPadding.itemSpacing) {
                                ForEach(columnItems, id: \.self) { index in
                                    windowCard(index)
                                }
                            }
                        }
                    }
                }
            }
            .frame(alignment: .topLeading)
            .globalPadding(HoverContainerPadding.contentInner)
        }
        .trackScrollOffset(axis: isHorizontal ? .horizontal : .vertical, scrolledFromStart: $scrolledFromStart)
        .padding(HoverContainerPadding.scrollOuter)
        .animation(Defaults.shared.showAnimations ? .smooth(duration: 0.1) : nil, value: state.windows.count)
        .fadeOnEdges(axis: isHorizontal ? .horizontal : .vertical, fadeLength: 20, disableLeading: !scrolledFromStart)
        .padding(.top, (Defaults.shared.showAppName) ? 25 : 0)
        .overlay(alignment: .topLeading) {
            if Defaults.shared.showAppName {
                hoverTitleBaseView
            }
        }
        .overlay {
            DockPreviewDismissalContainer(
                dockPosition: dockPosition,
                dockItemElement: dockItemElement
            )
            .allowsHitTesting(false)
        }
    }

    private var hoverTitleBaseView: some View {
        HStack(spacing: 6) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
            } else {
                ProgressView()
                    .frame(width: 24, height: 24)
            }
            Text(appName.trimmingCharacters(in: .whitespaces))
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .shadow(radius: 2)
        .globalPadding(.top, 12)
        .globalPadding(.leading, 20)
    }

    private func windowCard(_ index: Int) -> some View {
        let windows = state.windows
        guard index < windows.count else { return AnyView(EmptyView()) }
        let window = windows[index]
        let size = dimensionsMap[index] ?? CGSize(width: Defaults.shared.previewWidth, height: Defaults.shared.previewHeight)

        return AnyView(
            PreviewWindowCard(
                window: window,
                dimensions: size,
                maxDimensions: overallMaxDimensions,
                isSelected: state.selectionIndex == index,
                onWindowTap: onWindowTap,
                onWindowAction: { action in
                    handleWindowAction(action, window: window, index: index)
                }
            )
            .id(window.id)
        )
    }

    private func handleWindowAction(_ action: WindowCardAction, window: PreviewWindow, index: Int) {
        switch action {
        case .quit:
            window.app.terminate()
            onWindowTap?()
        case .close:
            window.closeWindow()
            onWindowTap?()
        case .minimize:
            var updated = window
            if updated.toggleMinimize() != nil {
                state.windows[index] = updated
                // 保留最后捕获的窗口内容，最小化卡片仍显示窗口画面。
            }
        case .toggleFullScreen:
            var updated = window
            if updated.toggleFullScreen() != nil {
                state.windows[index] = updated
            }
            onWindowTap?()
        case .hide:
            var updated = window
            if updated.toggleHidden() != nil {
                state.windows[index] = updated
                onWindowTap?()
            }
        }
    }

    private func loadAppIcon() {
        guard let app = state.windows.first?.app, let bundleID = app.bundleIdentifier else { return }
        appIcon = SharedHoverUtils.loadAppIcon(for: bundleID)
    }
}

/// The container surface: dock-style glass background + outer padding
/// (DockDoor BaseHoverContainer).
struct BaseHoverContainer<Content: View>: View {
    let bestGuessMonitor: NSScreen
    @ViewBuilder let content: Content

    var body: some View {
        let edgeGutter: CGFloat = 16
        content
            .dockStyle(
                backgroundOpacity: Defaults.shared.hideContainerBackground ? 0 : Defaults.shared.previewBackgroundOpacity
            )
            .padding(.all, HoverContainerPadding.container)
            .frame(
                maxWidth: max(1, bestGuessMonitor.visibleFrame.width - edgeGutter * 2),
                maxHeight: max(1, bestGuessMonitor.visibleFrame.height - edgeGutter * 2),
                alignment: .topLeading
            )
            .clipped()
    }
}

// MARK: - Scroll modifiers (DockDoor fadeOnEdges / trackScrollOffset)

extension View {
    func trackScrollOffset(axis: Axis.Set, scrolledFromStart: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: Bool.self) { geo in
            let offset = axis == .vertical ? geo.contentOffset.y : geo.contentOffset.x
            return offset > 1
        } action: { _, isScrolled in
            scrolledFromStart.wrappedValue = isScrolled
        }
    }

    func fadeOnEdges(axis: Axis, fadeLength: Double, disableLeading: Bool = false, disableTrailing: Bool = false) -> some View {
        mask {
            GeometryReader { geo in
                let containerSize = axis == .horizontal ? geo.size.width : geo.size.height
                let fadeLength = min(fadeLength, containerSize * 0.05)
                HStack(spacing: 0) {
                    if disableLeading {
                        Color.black
                            .frame(width: axis == .horizontal ? fadeLength : nil, height: axis == .vertical ? fadeLength : nil)
                    } else {
                        LinearGradient(
                            gradient: Gradient(colors: [.black.opacity(0), .black]),
                            startPoint: axis == .horizontal ? .leading : .top,
                            endPoint: axis == .horizontal ? .trailing : .bottom
                        )
                        .frame(width: axis == .horizontal ? fadeLength : nil, height: axis == .vertical ? fadeLength : nil)
                    }
                    Color.black.frame(maxWidth: .infinity)
                    if disableTrailing {
                        Color.black
                            .frame(width: axis == .horizontal ? fadeLength : nil, height: axis == .vertical ? fadeLength : nil)
                    } else {
                        LinearGradient(
                            gradient: Gradient(colors: [.black.opacity(0), .black]),
                            startPoint: axis == .horizontal ? .trailing : .bottom,
                            endPoint: axis == .horizontal ? .leading : .top
                        )
                        .frame(width: axis == .horizontal ? fadeLength : nil, height: axis == .vertical ? fadeLength : nil)
                    }
                }
            }
        }
    }
}

// MARK: - Dismissal (DockDoor MouseTrackingNSView)

struct DockPreviewDismissalContainer: NSViewRepresentable {
    let dockPosition: DockPosition
    let dockItemElement: AXUIElement?

    func makeNSView(context: Context) -> DockPreviewTrackingView {
        DockPreviewTrackingView(dockPosition: dockPosition, dockItemElement: dockItemElement)
    }

    func updateNSView(_ nsView: DockPreviewTrackingView, context: Context) {}
}

final class DockPreviewTrackingView: NSView {
    private let dockPosition: DockPosition
    private let dockItemElement: AXUIElement?
    private var fadeOutTimer: Timer?
    private var inactivityCheckTimer: Timer?
    private var mouseOutsideSince: Date?
    /// 隐藏动画进行中：忽略 tracking area 事件，避免反向滑入时 frame 移动触发虚假 mouseExited。
    var isHiding = false

    init(dockPosition: DockPosition, dockItemElement: AXUIElement?) {
        self.dockPosition = dockPosition
        self.dockItemElement = dockItemElement
        super.init(frame: .zero)
        // 延迟设置 tracking area，等面板滑入动画完成后再监听鼠标事件，
        // 避免动画期间 frame 变化触发虚假的 mouseExited/mouseEntered。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.setupTrackingArea()
            self?.startInactivityMonitoring()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        clearTimers()
    }

    private func setupTrackingArea() {
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    private func clearTimers() {
        fadeOutTimer?.invalidate()
        fadeOutTimer = nil
        inactivityCheckTimer?.invalidate()
        inactivityCheckTimer = nil
    }

    private func startInactivityMonitoring() {
        inactivityCheckTimer?.invalidate()
        inactivityCheckTimer = Timer.scheduledTimer(withTimeInterval: Defaults.shared.inactivityTimeout, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkInactivity()
            }
        }
    }

    private func checkInactivity() {
        // 隐藏挂起中：不做任何事。
        if DockPreviewPanel.shared.pendingHide { return }
        guard let window else { return }
        let currentMouseLocation = NSEvent.mouseLocation
        let windowFrame = window.frame.insetBy(dx: HoverContainerPadding.container, dy: HoverContainerPadding.container)

        let isMouseOverDockIcon = checkIfMouseIsOverDockIcon()

        if windowFrame.contains(currentMouseLocation) || isMouseOverDockIcon {
            resetOpacityVisually()
        } else {
            // 鼠标不在窗口内也不在图标上 → 直接隐藏。
            startFadeOut()
        }
    }

    private func checkIfMouseIsOverDockIcon() -> Bool {
        guard let originalDockItem = dockItemElement,
              let currentDockItem = DockHoverObserver.shared.getHoveredDockItemElement()
        else { return false }
        return CFEqual(originalDockItem, currentDockItem)
    }

    private func resetOpacityVisually() {
        guard !Defaults.shared.preventPreviewReentryDuringFadeOut else { return }
        cancelFadeOut()
        setWindowOpacity(to: 1.0, duration: 0.2)
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isHiding else { return }
        // 鼠标进入窗口：取消待定隐藏，窗口保持显示。
        DockPreviewPanel.shared.cancelPendingHide()
        mouseOutsideSince = nil
        resetOpacityVisually()
        DockPreviewPanel.shared.mouseIsWithinPreviewWindow = true
    }

    override func mouseExited(with event: NSEvent) {
        guard !isHiding else { return }
        DockPreviewPanel.shared.mouseIsWithinPreviewWindow = false
    }

    private func startFadeOut() {
        guard !isHiding else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window,
                  window.alphaValue > 0
            else { return }

            cancelFadeOut()
            let duration = Defaults.shared.fadeOutDuration
            if duration == 0 {
                performHideWindow()
            } else {
                setWindowOpacity(to: 0.0, duration: duration)
                fadeOutTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.performHideWindow()
                    }
                }
            }
        }
    }

    func cancelFadeOut() {
        fadeOutTimer?.invalidate()
        fadeOutTimer = nil
    }

    private func setWindowOpacity(to value: CGFloat, duration: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            if window.alphaValue == value { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                window.animator().alphaValue = value
            }
        }
    }

    private func performHideWindow() {
        isHiding = true
        DockPreviewPanel.shared.hideWindow(animated: true)
    }
}
