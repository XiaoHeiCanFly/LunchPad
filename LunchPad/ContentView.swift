import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Thread-safe wallpaper cache. Blur is expensive, so it is pre-computed off
/// the main thread; NSCache, ImageIO and Core Image are all safe to use from
/// any thread, so the cache itself is deliberately nonisolated.
nonisolated final class LauncherWallpaperCache: @unchecked Sendable {
    static let shared = LauncherWallpaperCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 3
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func image(for url: URL?, screenSize: CGSize, blurRadius: CGFloat) -> NSImage? {
        guard let url else { return nil }
        // Retaining native 5K/6K wallpaper pixels only wastes memory without
        // improving visible detail (the image is blurred anyway).
        // A zero-blur backdrop must retain Retina detail. Blurred launcher
        // backgrounds can remain smaller because their high frequencies are
        // intentionally removed, but Exposé uses the sharp wallpaper.
        let requestedScale: CGFloat = blurRadius <= 0.5 ? 2 : 1
        let maximumPixelSize = min(
            blurRadius <= 0.5 ? 3_840 : 1_600,
            max(1_024, Int(max(screenSize.width, screenSize.height) * requestedScale))
        )
        let key = "\(url.path)#\(maximumPixelSize)#blur\(Int(blurRadius))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { return nil }
        let base = NSImage(cgImage: thumbnail, size: screenSize)
        guard blurRadius > 0.5 else {
            cache.setObject(base, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height)
            return base
        }
        // Pre-blur the wallpaper once so the backdrop never re-evaluates a
        // SwiftUI `.blur()` filter while a gesture is scaling the panels.
        let blurred = Self.gaussianBlur(base, radius: blurRadius)
        cache.setObject(blurred, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height)
        return blurred
    }

    /// Gaussian blur with clamped edges so the result keeps the input's exact
    /// extent — no transparent margins, no edge darkening.
    nonisolated private static func gaussianBlur(_ image: NSImage, radius: CGFloat) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return image }
        filter.setValue(ciImage.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return image }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let result = context.createCGImage(output, from: ciImage.extent) else { return image }
        return NSImage(cgImage: result, size: image.size)
    }
}

@MainActor
private final class ApplicationIconCache {
    static let shared = ApplicationIconCache()

    private let cache = NSCache<NSString, NSImage>()
    private let pixelSize = 192

    private init() {
        cache.countLimit = 256
        cache.totalCostLimit = 30 * 1024 * 1024
    }

    func image(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let rendered = autoreleasepool { () -> NSImage in
            let source = NSWorkspace.shared.icon(forFile: path)
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelSize,
                pixelsHigh: pixelSize,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return source }
            bitmap.size = NSSize(width: pixelSize, height: pixelSize)
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                NSGraphicsContext.current = context
                context.imageInterpolation = .high
                source.draw(
                    in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
                context.flushGraphics()
            }
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
            image.addRepresentation(bitmap)
            return image
        }
        cache.setObject(rendered, forKey: key, cost: pixelSize * pixelSize * 4)
        return rendered
    }
}

private struct LauncherGridMetrics: Equatable {
    let columns: Int
    let rows: Int
    let iconSize: CGFloat
    let cellWidth: CGFloat

    var pageSize: Int { columns * rows }
    var gridItems: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 44), spacing: 14), count: columns)
    }
}

/// The page strip (HStack of per-page LazyVGrids) inside `pagedGrid`.
///
/// Its inputs — metrics, page width, height, content width — are stable while
/// the user swipes, so a finger-offset change on the wrapper does not re-run
/// this body (the offset is applied above it). The page slide itself is
/// animated here against `currentPage`; the finger rebound is animated on the
/// wrapper, giving a continuous release transition.
private struct PagesGrid: View {
    @EnvironmentObject private var store: LauncherStore
    @EnvironmentObject private var controller: LauncherController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The entries to page through. Passed in (rather than read from the
    /// store) so the full grid and the search-results grid can be two separate
    /// live views — see ContentView.body.
    let entries: [LauncherEntry]
    let metrics: LauncherGridMetrics
    let pageWidth: CGFloat
    let height: CGFloat
    let launcherContentWidth: CGFloat

    var body: some View {
        let fullGridHeight = CGFloat(metrics.rows) * (metrics.iconSize + 52)
            + CGFloat(max(0, metrics.rows - 1)) * 6
        let pages = entries.chunked(into: metrics.pageSize)
        HStack(spacing: 0) {
            ForEach(Array(pages.enumerated()), id: \.offset) { pageIndex, page in
                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { controller.hide() }
                        // Dropping an app dragged out of a folder onto blank
                        // space places it at the end of the root grid.
                        .onDrop(of: [UTType.fileURL, UTType.utf8PlainText], isTargeted: nil) { _ in
                            store.dropDraggedFolderAppToRoot()
                            return true
                        }

                    if abs(pageIndex - store.currentPage) <= 1 {
                        LazyVGrid(columns: metrics.gridItems, spacing: 6) {
                            ForEach(Array(page.enumerated()), id: \.element.id) { position, entry in
                                LauncherTile(
                                    entry: entry,
                                    iconSize: metrics.iconSize,
                                    tileWidth: metrics.cellWidth,
                                    store: store,
                                    controller: controller,
                                    isDragged: store.draggedEntryID == entry.id,
                                    isDragTarget: store.dragTargetID == entry.id && store.draggedEntryID != entry.id,
                                    isFolderCandidate: store.folderCandidateID == entry.id && store.draggedEntryID != entry.id,
                                    isSelected: store.selectedEntryID == entry.id,
                                    optionIsPressed: store.optionIsPressed
                                )
                                .equatable()
                            }
                        }
                        .padding(.horizontal, 22)
                        // Reserve the height of a complete page even when the
                        // last page has fewer rows. Its first row then shares
                        // the same vertical origin as every other page.
                        .frame(
                            width: launcherContentWidth,
                            height: min(height, fullGridHeight),
                            alignment: .top
                        )
                        .frame(width: launcherContentWidth, height: height, alignment: .center)
                        .offset(y: height > 700 ? -8 : 0)
                        // Animate reorder previews so the icons at the squeezed
                        // slot slide aside instead of jumping. This spring used to
                        // re-layout the whole grid on every mutation (janky), but
                        // reorders are now throttled in the store and a pure
                        // reorder keeps every tile's params equal — `.equatable()`
                        // skips all tile bodies, so this only animates the
                        // position shifts. Drop/folder animations still apply their
                        // own `withAnimation` at the call site.
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.82, blendDuration: 0.12),
                            value: store.entries
                        )
                    }
                }
                .frame(width: pageWidth, height: height, alignment: .center)
            }
        }
        .offset(x: -CGFloat(store.currentPage) * pageWidth)
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: store.currentPage)
        .frame(width: pageWidth, height: height, alignment: .leading)
        .clipped()
    }
}

struct ContentView: View {
    let wallpaperURL: URL?
    /// Full-screen window (== the display frame). The backdrop spans this.
    let screenSize: CGSize
    /// Rect inside the window where the launcher content lives — the display
    /// area above/outside the Dock. The grid/search never enter the Dock zone.
    let contentRect: CGRect
    let searchTopObstruction: CGFloat
    let screenSafeInsets: EdgeInsets
    @EnvironmentObject private var store: LauncherStore
    @EnvironmentObject private var controller: LauncherController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.openSettings) private var openSettings
    @FocusState private var searchFocused: Bool
    /// Finger-follow offset during a page swipe. `@GestureState` resets to zero
    /// automatically when the drag ends, in the same transaction as the
    /// `currentPage` change, so the release animation (driven by the wrapper's
    /// `.animation(value: store.currentPage)`) rides one continuous curve.
    /// Stored here — not in `store` — so a swipe never invalidates the tiles.
    @GestureState private var pageDragOffset: CGFloat = 0
    @AppStorage("grid-columns") private var columnCount = 7
    @AppStorage("grid-rows") private var rowCount = 5
    @AppStorage("icon-size") private var iconSize = 104.0
    @AppStorage("background-blur-radius") private var backgroundBlurRadius = 34.0

    private var pageSize: Int { max(1, store.pageCapacity) }
    private var contentSize: CGSize { contentRect.size }
    private var horizontalScreenMargin: CGFloat {
        min(96, max(60, contentSize.width * 0.047))
    }
    private var bottomScreenMargin: CGFloat { 14 + screenSafeInsets.bottom }
    private var launcherContentWidth: CGFloat {
        max(
            320,
            contentSize.width
                - horizontalScreenMargin * 2
                - screenSafeInsets.leading
                - screenSafeInsets.trailing
        )
    }
    private var launcherContentHeight: CGFloat {
        max(320, contentSize.height - screenSafeInsets.top - bottomScreenMargin)
    }

    /// The right-click menu for blank space (formerly the backdrop's
    /// `.contextMenu`), now hosted by `BlankAreaCatcher`.
    private var backdropMenuItems: [ContextMenuItem] {
        [
            ContextMenuItem(title: "排序方式", submenu: [
                ContextMenuItem(title: "自定义排序") { store.sortMode = .custom },
                ContextMenuItem(title: "名称排序") { store.sortMode = .name },
                ContextMenuItem(title: "安装时间排序") { store.sortMode = .installDate },
                ContextMenuItem(title: "使用频率排序") { store.sortMode = .frequency }
            ]),
            ContextMenuItem(title: "重新扫描应用") { store.scanApplications() },
            ContextMenuItem(title: nil),
            ContextMenuItem(title: "退出 LunchPad") { NSApp.terminate(nil) }
        ]
    }

    var body: some View {
        ZStack {
            // The backdrop is one continuous full-screen surface, including the
            // area under the Dock — no separate Dock strip, so there is no
            // seam or blank bar when the launcher appears.
            LauncherBackdrop(
                reduceTransparency: reduceTransparency,
                wallpaperURL: wallpaperURL,
                screenSize: screenSize,
                blurRadius: backgroundBlurRadius
            )
                .frame(width: screenSize.width, height: screenSize.height)

            // Any click on blank space dismisses on the FIRST click — an
            // NSView-backed surface, because SwiftUI's `.onTapGesture` would
            // swallow the first click while the search field is focused. It sits
            // above the backdrop but below the content, so it only receives the
            // clicks no interactive view above it claims. Right-clicking it
            // shows the backdrop's sort/scan/quit menu.
            BlankAreaCatcher(
                onDismiss: { controller.hide() },
                menuItems: backdropMenuItems
            )
                .frame(width: screenSize.width, height: screenSize.height)

            VStack(spacing: 0) {
                HStack {
                    SearchField(
                        text: $store.searchText,
                        isFocused: $searchFocused,
                        onSubmit: {
                            if let application = store.filteredApplications.first {
                                controller.launch(application)
                            }
                        },
                        onSettings: {
                            openSettings()
                            controller.presentSettingsAboveLauncher()
                        }
                    )
                        .frame(maxWidth: 250)
                }
                    .padding(.horizontal, 20)
                    .offset(y: searchTopObstruction > 0 ? searchTopObstruction + 2 : 24)

                Group {
                    if store.isScanning && store.entries.isEmpty {
                        ProgressView("正在整理应用…")
                            .controlSize(.large)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ZStack {
                            // The full grid stays in the hierarchy — hidden
                            // while searching — so deleting the last search
                            // character doesn't rebuild every tile in one frame
                            // (a narrow query leaves most of the page to be
                            // recreated); it simply reappears. The search grid
                            // overlays it on top.
                            pagedGrid(entries: store.displayEntries)
                                .opacity(store.searchText.isEmpty ? 1 : 0)
                                .allowsHitTesting(store.searchText.isEmpty)
                            if !store.searchText.isEmpty {
                                if store.visibleEntries.isEmpty {
                                    // No matches — the paged grid would be blank.
                                    searchResults
                                } else {
                                    pagedGrid(entries: store.visibleEntries)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 32 + (searchTopObstruction > 0 ? 22 : 0))

                if !store.visibleEntries.isEmpty {
                    pageIndicator
                        .padding(.top, 8)
                }
            }
            // Keep the launcher inside an explicit per-screen content rectangle.
            // Padding changes a SwiftUI view's ideal size and caused the wider
            // external-display grid to be clipped on the built-in display.
            .frame(width: launcherContentWidth, height: launcherContentHeight)
            .offset(
                x: (screenSafeInsets.leading - screenSafeInsets.trailing) / 2,
                y: (screenSafeInsets.top - bottomScreenMargin) / 2
            )
            // The window is full-screen but the content sits only in the
            // Dock-excluded rect. `contentRect.midY` is in AppKit (bottom-up)
            // coordinates; SwiftUI's position is top-down.
            .frame(width: contentSize.width, height: contentSize.height)
            .position(
                x: contentRect.midX,
                y: screenSize.height - contentRect.midY
            )
            .opacity(store.openFolderID == nil ? 1 : 0.08)
            .scaleEffect(store.openFolderID == nil ? 1 : 0.96)
            .blur(radius: store.openFolderID == nil ? 0 : 8)
            .animation(.spring(response: 0.36, dampingFraction: 0.86), value: store.openFolderID)

            if let folderID = store.openFolderID, let folder = store.folder(id: folderID) {
                FolderOverlay(folder: folder)
                    .transition(.scale(scale: 0.94, anchor: .center).combined(with: .opacity))
                    .frame(width: contentSize.width, height: contentSize.height)
                    .position(
                        x: contentRect.midX,
                        y: screenSize.height - contentRect.midY
                    )
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        // Backdrop + content opacity/scale are driven by the panel's layer
        // (via the gesture animator) — no SwiftUI-level opacity/scaleEffect,
        // so a gesture never re-renders this view tree.
        .preferredColorScheme(.dark)
        .alert("LunchPad", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .alert("应用显示名称", isPresented: Binding(
            get: { store.aliasRequest != nil },
            set: { if !$0 { store.aliasRequest = nil } }
        )) {
            TextField("名称", text: $store.aliasDraft)
            Button("取消", role: .cancel) { store.aliasRequest = nil }
            Button("保存") { store.commitAlias() }
        } message: {
            Text("只改变 LunchPad 中显示的名称，不会修改应用本身。")
        }
        .alert("切换到自定义排序？", isPresented: Binding(
            get: { store.reorderToCustomPrompt },
            set: { if !$0 { store.cancelReorderToCustom() } }
        )) {
            Button("取消", role: .cancel) { store.cancelReorderToCustom() }
            Button("切换并调整位置") { store.confirmReorderToCustom() }
        } message: {
            Text("调整位置需要切换到「自定义排序」，之后你手动排好的顺序会一直保留。")
        }
        .onChange(of: store.searchText) { _, _ in store.currentPage = 0 }
        .onChange(of: store.uninstallRequest?.id) { _, _ in
            controller.synchronizeUninstallPresentation()
        }
        .onAppear { searchFocused = true }
        .onChange(of: controller.isPresented) { _, presented in
            guard presented else { return }
            // `.onAppear` only fires when the view is first mounted, so a
            // re-invoked launcher wouldn't re-focus the search field (breaking
            // instant typing). `show()` flips `isPresented` before the panel is
            // ordered front and made key, so defer focus to the next main-loop
            // tick.
            Task { @MainActor in searchFocused = true }
        }
    }

    private func pagedGrid(entries: [LauncherEntry]) -> some View {
        GeometryReader { proxy in
            // Page transitions use the full display width so icons travel across
            // the whole screen. Grid metrics still use the centered content width.
            let metrics = adaptiveMetrics(for: CGSize(
                width: launcherContentWidth,
                height: proxy.size.height
            ))
            let pages = entries.chunked(into: metrics.pageSize)
            PagesGrid(
                entries: entries,
                metrics: metrics,
                pageWidth: proxy.size.width,
                height: proxy.size.height,
                launcherContentWidth: launcherContentWidth
            )
            // The finger-follow offset lives OUTSIDE the page strip. Its inputs
            // (metrics, sizes) are stable during a swipe, so moving the strip by
            // `pageDragOffset` never re-evaluates the tiles — only this cheap
            // wrapper body runs per mouse move. On release the `@GestureState`
            // resets this offset while `currentPage` changes in the same
            // transaction, so this animation eases it back to zero as the strip
            // slides onto the new page — one continuous motion.
            .offset(x: pageDragOffset)
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: store.currentPage)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 24)
                    .updating($pageDragOffset) { value, state, _ in
                        let horizontal = value.translation.width
                        let atFirst = store.currentPage == 0 && horizontal > 0
                        let atLast = store.currentPage == max(0, pages.count - 1) && horizontal < 0
                        state = (atFirst || atLast) ? horizontal * 0.2 : horizontal
                    }
                    .onEnded { value in
                        let threshold = proxy.size.width * 0.12
                        let predicted = value.predictedEndTranslation.width
                        if predicted < -threshold {
                            store.currentPage = min(store.currentPage + 1, max(0, pages.count - 1))
                        } else if predicted > threshold {
                            store.currentPage = max(store.currentPage - 1, 0)
                        }
                    }
            )
            .overlay {
                if store.draggedEntryID != nil {
                    HStack {
                        DragPageEdge(direction: -1)
                        Spacer()
                        DragPageEdge(direction: 1)
                    }
                }
            }
            .onAppear {
                store.updateAdaptiveGrid(columns: metrics.columns, rows: metrics.rows)
            }
            .onChange(of: metrics) { _, value in
                store.updateAdaptiveGrid(columns: value.columns, rows: value.rows)
            }
            // Clamp the current page when the visible set shrinks (typing in
            // search filters to fewer pages, or apps were removed) — otherwise
            // the strip would rest past the last page and show blank.
            .onChange(of: store.visibleEntries.count) { _, count in
                let last = max(0, Int(ceil(Double(count) / Double(metrics.pageSize))) - 1)
                if store.currentPage > last { store.currentPage = last }
            }
        }
        .frame(width: screenSize.width)
    }

    /// Shown only when a search has no matches (the paged grid handles results).
    private var searchResults: some View {
        ContentUnavailableView.search(text: store.searchText)
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                BlankAreaCatcher(onDismiss: { controller.hide() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }

    private func adaptiveMetrics(for size: CGSize) -> LauncherGridMetrics {
        let usableWidth = max(280, size.width - 44)
        // 44pt is the compact icon floor. Keep another 28pt for the tile's
        // horizontal breathing room and 14pt between columns.
        let maximumColumns = max(1, Int((usableWidth + 14) / 86))
        let columns = min(max(1, columnCount), maximumColumns)

        // A compact tile needs 100pt (44pt icon + 56pt label/padding), plus
        // the 6pt inter-row spacing. Never force more rows than actually fit.
        let usableHeight = max(100, size.height)
        let maximumRows = max(1, Int((usableHeight + 6) / 106))
        let rows = min(max(1, rowCount), maximumRows)

        let cellWidth = (usableWidth - CGFloat(max(0, columns - 1)) * 14) / CGFloat(columns)
        let rowHeight = (usableHeight - CGFloat(max(0, rows - 1)) * 6) / CGFloat(rows)
        // A tile consumes icon + 8pt spacing + 32pt label + 12pt vertical padding.
        // Keep an extra 4pt reserve so LazyVGrid never overlaps rows on compact displays.
        let fittedIcon = min(cellWidth - 28, rowHeight - 56)
        let effectiveIcon = min(CGFloat(iconSize), max(44, fittedIcon))
        return LauncherGridMetrics(
            columns: columns,
            rows: rows,
            iconSize: effectiveIcon,
            cellWidth: cellWidth
        )
    }

    private var pageIndicator: some View {
        let count = max(1, Int(ceil(Double(store.visibleEntries.count) / Double(pageSize))))
        return HStack(spacing: 9) {
            ForEach(0..<count, id: \.self) { page in
                Circle()
                    .fill(page == store.currentPage ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .contentShape(Rectangle().inset(by: -5))
                    .onTapGesture { store.currentPage = page }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: Capsule())
    }
}

struct UninstallConfirmationView: View {
    @EnvironmentObject private var store: LauncherStore
    let request: UninstallRequest
    @State private var groups: [UninstallFileGroup] = []
    @State private var selectedFileIDs: Set<String> = []
    @State private var expandedGroupIDs: Set<String> = []
    @State private var isScanning = true
    @State private var isDeleting = false

    private var selectedFiles: [UninstallFileCandidate] {
        groups.flatMap(\.files).filter { selectedFileIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: request.application.path))
                    .resizable()
                    .scaledToFit()
                .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text("卸载“\(request.application.name)”？")
                        .font(.title2.weight(.semibold))
                    Text("应用及勾选的关联文件将被永久删除，此操作无法恢复。")
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "appstore")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(request.application.url.lastPathComponent)
                                .fontWeight(.medium)
                            Text((request.application.path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    if isScanning {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("正在查找关联文件和缓存…")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 24)
                        .padding(.vertical, 12)
                    } else if groups.isEmpty {
                        Text("没有找到可确认归属于此应用的关联文件。")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 24)
                            .padding(.vertical, 10)
                    } else {
                        ForEach(groups) { group in
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedGroupIDs.contains(group.id) },
                                    set: { expanded in
                                        if expanded { expandedGroupIDs.insert(group.id) }
                                        else { expandedGroupIDs.remove(group.id) }
                                    }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 7) {
                                    ForEach(group.files) { file in
                                        Toggle(isOn: Binding(
                                            get: { selectedFileIDs.contains(file.id) },
                                            set: { selected in
                                                if selected { selectedFileIDs.insert(file.id) }
                                                else { selectedFileIDs.remove(file.id) }
                                            }
                                        )) {
                                            HStack(spacing: 8) {
                                                Image(systemName: file.isDirectory ? "folder.fill" : "doc.fill")
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 18)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(file.url.lastPathComponent)
                                                        .lineLimit(1)
                                                    Text((file.url.path as NSString).abbreviatingWithTildeInPath)
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                        .truncationMode(.middle)
                                                }
                                                Spacer(minLength: 8)
                                                Text(file.formattedSize)
                                                    .font(.caption.monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .toggleStyle(.checkbox)
                                    }
                                }
                                .padding(.leading, 22)
                                .padding(.vertical, 5)
                            } label: {
                                HStack {
                                    Text(group.name).fontWeight(.medium)
                                    Text("\(group.files.count) 项")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(group.formattedSize)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(height: 330)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Text(isScanning ? "正在计算…" : "将同时处理 \(selectedFiles.count) 个关联项目")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { store.cancelUninstall() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isDeleting)
                Button("永久删除", role: .destructive) {
                    isDeleting = true
                    store.confirmUninstall(
                        request.application,
                        relatedFiles: selectedFiles.map(\.url)
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isScanning || isDeleting)
            }
        }
        .padding(22)
        // Fill the full panel frame (700×520) so the material background reaches
        // the edges. The content is naturally ~488pt tall, so without filling,
        // the outer fixed-size frame centers it and leaves transparent strips at
        // the top and bottom that show the dimming layer behind as black bands.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.42), radius: 30, y: 14)
        .interactiveDismissDisabled(isDeleting)
        .task(id: request.id) {
            let discoveredGroups = await UninstallFileScanner.scan(for: request.application)
            guard !Task.isCancelled else { return }
            groups = discoveredGroups
            selectedFileIDs = Set(discoveredGroups.flatMap(\.files).map(\.id))
            expandedGroupIDs = Set(discoveredGroups.map(\.id))
            isScanning = false
        }
    }
}

struct LauncherBackdrop: View {
    let reduceTransparency: Bool
    let wallpaperURL: URL?
    let screenSize: CGSize
    let blurRadius: CGFloat

    var body: some View {
        ZStack {
            // Keep a fully opaque base under every backdrop variant. In
            // particular, never sample the windows behind the launcher.
            Color.black
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                if let wallpaper = wallpaperImage {
                    Image(nsImage: wallpaper)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(nsColor: .windowBackgroundColor)
                }
                LinearGradient(
                    colors: [.black.opacity(0.12), .black.opacity(0.30)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [.white.opacity(0.10), .clear],
                    center: .top,
                    startRadius: 20,
                    endRadius: 760
                )
            }
        }
        .ignoresSafeArea()
    }

    /// The wallpaper is pre-blurred and cached (keyed by blur radius), so the
    /// backdrop never runs a live `.blur()` filter while panels are scaling.
    private var wallpaperImage: NSImage? {
        guard let wallpaperURL else { return nil }
        return LauncherWallpaperCache.shared.image(
            for: wallpaperURL,
            screenSize: screenSize,
            blurRadius: blurRadius
        )
    }
}

/// Right-click menu item model for `BlankAreaCatcher`. A `nil` title with no
/// action or submenu renders as a separator.
private struct ContextMenuItem {
    var title: String?
    var keyEquivalent: String = ""
    var submenu: [ContextMenuItem]?
    var action: (() -> Void)?
}

/// Retains an `NSMenuItem` action closure. `NSMenuItem.target` is weak, so the
/// owning menu must keep its targets alive — see
/// `BlankAreaCatcherView.menuTargets`.
private final class MenuActionTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func perform(_ sender: Any?) { action() }
}

/// Full-screen blank-space hit target for the launcher window.
///
/// SwiftUI's `.onTapGesture` swallows the first click while a text field is
/// focused — the click is consumed re-affirming focus — so clicking blank space
/// next to the search field only dismissed the launcher on the second click. A
/// plain NSView's `mouseDown` fires on the first click regardless of the
/// window's first responder, so the launcher's blank surfaces are backed by
/// this view: any click that reaches it dismisses immediately.
private struct BlankAreaCatcher: NSViewRepresentable {
    var onDismiss: () -> Void
    var menuItems: [ContextMenuItem] = []

    func makeNSView(context: Context) -> BlankAreaCatcherView {
        let view = BlankAreaCatcherView()
        view.onDismiss = onDismiss
        view.contextMenuModel = menuItems
        return view
    }

    func updateNSView(_ view: BlankAreaCatcherView, context: Context) {
        view.onDismiss = onDismiss
        view.contextMenuModel = menuItems
    }

    final class BlankAreaCatcherView: NSView {
        var onDismiss: (() -> Void)?
        var contextMenuModel: [ContextMenuItem] = [] {
            didSet { rebuildMenu() }
        }
        /// `NSMenuItem.target` is weak, so the menu's action objects must be
        /// retained here for as long as the menu is installed.
        private var menuTargets: [NSObject] = []

        override func mouseDown(with event: NSEvent) {
            onDismiss?()
        }

        private func rebuildMenu() {
            menuTargets.removeAll()
            let menu = NSMenu()
            fill(menu, with: contextMenuModel)
            self.menu = menu
        }

        private func fill(_ menu: NSMenu, with items: [ContextMenuItem]) {
            for item in items {
                if let submenu = item.submenu {
                    let sub = NSMenu()
                    fill(sub, with: submenu)
                    let menuItem = NSMenuItem(title: item.title ?? "", action: nil, keyEquivalent: "")
                    menuItem.submenu = sub
                    menu.addItem(menuItem)
                } else if let action = item.action {
                    let target = MenuActionTarget(action)
                    menuTargets.append(target)
                    let menuItem = NSMenuItem(
                        title: item.title ?? "",
                        action: #selector(MenuActionTarget.perform(_:)),
                        keyEquivalent: item.keyEquivalent
                    )
                    menuItem.target = target
                    menu.addItem(menuItem)
                } else {
                    menu.addItem(.separator())
                }
            }
        }
    }
}

private struct SearchField: View {
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.72))
            TextField("搜索应用", text: $text)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .font(.system(size: 16, weight: .medium))
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.62))
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    Button("设置…", action: onSettings)
                    Divider()
                    Button("退出 LunchPad") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多")
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 42)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Sort-mode picker shown next to the search field. The icon mirrors the active
/// mode so the current ordering is visible at a glance.
/// A single icon tile. Pure data: everything it renders — the entry, the
/// per-tile drag/selection flags, and the store/controller references — arrives
/// as a parameter from the parent grid, which is the only view observing
/// `store`. Combined with `.equatable()` at the call site, a store change
/// (drag target, folder candidate, reorder) re-evaluates only the one or two
/// tiles whose flags actually changed, instead of all ~120 page tiles.
private struct LauncherTile: View, Equatable {
    let entry: LauncherEntry
    let iconSize: CGFloat
    let tileWidth: CGFloat
    let store: LauncherStore
    let controller: LauncherController
    let isDragged: Bool
    let isDragTarget: Bool
    let isFolderCandidate: Bool
    let isSelected: Bool
    let optionIsPressed: Bool

    static func == (lhs: LauncherTile, rhs: LauncherTile) -> Bool {
        lhs.entry == rhs.entry
            && lhs.iconSize == rhs.iconSize
            && lhs.tileWidth == rhs.tileWidth
            && lhs.store === rhs.store
            && lhs.controller === rhs.controller
            && lhs.isDragged == rhs.isDragged
            && lhs.isDragTarget == rhs.isDragTarget
            && lhs.isFolderCandidate == rhs.isFolderCandidate
            && lhs.isSelected == rhs.isSelected
            && lhs.optionIsPressed == rhs.optionIsPressed
    }

    private var iconScale: CGFloat {
        isFolderCandidate ? 1.11 : (isDragTarget ? 1.035 : 1)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                icon
                    .frame(width: iconSize, height: iconSize)
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .onTapGesture(perform: activate)
                    .scaleEffect(iconScale)
                    .background {
                        if isSelected {
                            GlassSelectionHighlight(size: iconSize + 14)
                                .transition(.scale(scale: 0.90).combined(with: .opacity))
                        }
                    }
                    .background {
                        if isDragTarget {
                            RoundedRectangle(cornerRadius: iconSize * 0.27, style: .continuous)
                                .fill(.white.opacity(isFolderCandidate ? 0.13 : 0.06))
                                .padding(-10)
                                .scaleEffect(isFolderCandidate ? 1.04 : 0.94)
                        }
                    }
                    .overlay {
                        if isFolderCandidate {
                            RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous)
                                .stroke(.white.opacity(0.72), lineWidth: 1.5)
                                .padding(-8)
                        }
                    }
                    .animation(.spring(response: 0.34, dampingFraction: 0.68), value: isDragTarget)
                    .animation(.spring(response: 0.30, dampingFraction: 0.62), value: isFolderCandidate)
                    .animation(.spring(response: 0.26, dampingFraction: 0.78), value: isSelected)

                if optionIsPressed, let application = store.application(in: entry), !application.isProtected {
                    Button { store.requestUninstall(application) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray.opacity(0.95))
                            .shadow(radius: 3)
                    }
                    .buttonStyle(.plain)
                    .offset(x: -8, y: -7)
                }
            }
            .modifier(NativeJiggleModifier(
                active: optionIsPressed,
                phase: Double(abs(entry.id.hashValue % 997)) / 997.0 * .pi * 2
            ))

            Text(store.title(for: entry))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 32, alignment: .top)
                .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .scaleEffect(isDragged ? 0.88 : 1)
        .opacity(isDragged ? 0.24 : 1)
        .animation(.spring(response: 0.30, dampingFraction: 0.74), value: isDragged)
        .zIndex(isDragTarget ? 2 : (isDragged ? 1 : 0))
        .transition(.scale(scale: 0.78).combined(with: .opacity))
        .onDrag {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.74)) {
                store.beginDrag(entry)
            }
            if let application = store.application(in: entry) {
                return NSItemProvider(object: application.url as NSURL)
            }
            return NSItemProvider(object: entry.id as NSString)
        } preview: {
            dragPreview
                .padding(12)
                .background(.black.opacity(0.10), in: RoundedRectangle(cornerRadius: iconSize * 0.30, style: .continuous))
                .shadow(color: .black.opacity(0.34), radius: 18, y: 12)
        }
        .onDrop(
            of: [UTType.fileURL, UTType.utf8PlainText],
            delegate: EntryDropDelegate(target: entry, tileWidth: tileWidth, store: store)
        )
        .contextMenu {
            switch entry {
            case .application(let application):
                Button("打开") { controller.launch(application) }
                Button("重命名…") { store.requestAlias(for: application) }
                Button("在访达中显示") { store.revealInFinder(application) }
                Button("从 LunchPad 隐藏") { store.hide(application) }
                Divider()
                if !application.isProtected {
                    Button("卸载应用", role: .destructive) { store.requestUninstall(application) }
                }
            case .folder(let folder):
                Button("打开文件夹") { store.openFolder(folder) }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch entry {
        case .application(let application):
            ApplicationIcon(path: application.path)
        case .folder(let folder):
            FolderIcon(folder: folder, size: iconSize * 0.92)
        }
    }

    @ViewBuilder
    private var dragPreview: some View {
        switch entry {
        case .application(let application):
            HighResolutionApplicationDragPreview(path: application.path, size: iconSize)
        case .folder(let folder):
            FolderIcon(folder: folder, size: iconSize * 0.92)
                .frame(width: iconSize, height: iconSize)
        }
    }

    private func activate() {
        switch entry {
        case .application(let application): controller.launch(application)
        case .folder(let folder):
            withAnimation(.snappy(duration: 0.3)) { store.openFolder(folder) }
        }
    }
}

private struct GlassSelectionHighlight: View {
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.245, style: .continuous)
        shape
            .fill(.white.opacity(0.035))
            .frame(width: size, height: size)
            .glassEffect(.regular, in: shape)
            .overlay {
                shape
                    .stroke(.white.opacity(0.42), lineWidth: 1.15)
            }
            .shadow(color: .black.opacity(0.16), radius: 9, y: 4)
    }
}

private struct NativeJiggleModifier: ViewModifier {
    let active: Bool
    let phase: Double

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: !active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let rotation = active
                ? sin(time * 18.5 + phase) * 1.28 + sin(time * 29 + phase * 0.63) * 0.28
                : 0
            let x = active ? sin(time * 20 + phase * 1.31) * 0.92 : 0
            let y = active ? cos(time * 16.5 + phase * 0.81) * 0.62 : 0
            let scale = active ? 1 + sin(time * 14 + phase) * 0.003 : 1
            content
                .rotationEffect(.degrees(rotation), anchor: UnitPoint(x: 0.49, y: 0.54))
                .offset(x: x, y: y)
                .scaleEffect(scale)
        }
    }
}

private struct ApplicationIcon: View {
    let path: String
    var showsShadow = true

    var body: some View {
        Image(nsImage: ApplicationIconCache.shared.image(for: path))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .shadow(color: .black.opacity(showsShadow ? 0.28 : 0), radius: showsShadow ? 7 : 0, y: showsShadow ? 5 : 0)
    }
}

private struct HighResolutionApplicationDragPreview: View {
    let image: NSImage
    let size: CGFloat

    init(path: String, size: CGFloat) {
        self.size = size
        self.image = Self.renderIcon(path: path, pointSize: size)
    }

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private static func renderIcon(path: String, pointSize: CGFloat) -> NSImage {
        let source = NSWorkspace.shared.icon(forFile: path)
        let scale = max(3, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
        let pixels = max(1, Int(ceil(pointSize * scale)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return source }
        bitmap.size = NSSize(width: pointSize, height: pointSize)
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            source.draw(
                in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
        let rendered = NSImage(size: bitmap.size)
        rendered.addRepresentation(bitmap)
        return rendered
    }
}

private struct FolderIcon: View {
    let folder: LauncherFolder
    let size: CGFloat
    @State private var isReceivingApplication = false

    var body: some View {
        let spacing = max(1.5, size * 0.03)
        let padding = size * 0.085
        let miniatureSize = (size - padding * 2 - spacing * 2) / 3
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(miniatureSize), spacing: spacing), count: 3),
            spacing: spacing
        ) {
            ForEach(folder.applications.prefix(9)) { application in
                ApplicationIcon(path: application.path, showsShadow: false)
                    .frame(width: miniatureSize, height: miniatureSize)
            }
        }
        .padding(padding)
        .frame(width: size, height: size)
        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .scaleEffect(isReceivingApplication ? 1.08 : 1)
        .compositingGroup()
        .onChange(of: folder.applications.count) { oldCount, newCount in
            guard newCount > oldCount else { return }
            withAnimation(.spring(response: 0.20, dampingFraction: 0.56)) {
                isReceivingApplication = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.64)) {
                    isReceivingApplication = false
                }
            }
        }
    }
}

private struct FolderOverlay: View {
    @EnvironmentObject private var store: LauncherStore
    @EnvironmentObject private var controller: LauncherController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let folder: LauncherFolder
    @State private var name: String = ""
    @State private var appeared = false

    var body: some View {
        GeometryReader { proxy in
            let panelWidth = max(360, min(proxy.size.width - 40, proxy.size.width * 0.88))
            let horizontalPadding = min(72, max(24, panelWidth * 0.045))
            let horizontalSpacing = min(44, max(18, panelWidth * 0.024))
            let availableWidth = panelWidth - horizontalPadding * 2
            let columnCount = max(3, min(7, Int((availableWidth + horizontalSpacing) / 145)))
            let cellWidth = (availableWidth - CGFloat(columnCount - 1) * horizontalSpacing) / CGFloat(columnCount)
            let folderIconSize = min(110, max(58, cellWidth * 0.62))
            let rowCount = max(1, Int(ceil(Double(folder.applications.count) / Double(columnCount))))
            let requiredHeight = CGFloat(rowCount) * (folderIconSize + 40)
                + CGFloat(max(0, rowCount - 1)) * 24 + 64
            let panelHeight = min(max(190, requiredHeight), proxy.size.height * 0.56)

            ZStack {
                Color.black.opacity(appeared ? 0.24 : 0)
                    .ignoresSafeArea()

                // First-click dismiss of the folder, same rationale as the
                // root backdrop's `BlankAreaCatcher`.
                BlankAreaCatcher(onDismiss: { closeFolder() })
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    // 拖拽中：浮层空白区域吞掉落点，避免穿透到根网格磁贴
                    // 触发误关闭/误排序；落点由文件夹磁贴自行处理。
                    .onDrop(of: [UTType.fileURL, UTType.utf8PlainText], isTargeted: nil) { _ in
                        store.folderDragExited()
                        return true
                    }

                VStack(spacing: 30) {
                    TextField("文件夹名称", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: min(26, max(19, proxy.size.width * 0.013)), weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.center)
                        // The field is empty during its first layout pass and
                        // AppKit otherwise reports a height that is too short
                        // once the folder name is assigned in onAppear.
                        .frame(width: min(420, panelWidth * 0.42), height: 42)
                        .fixedSize(horizontal: false, vertical: true)
                        .onSubmit { store.renameFolder(id: folder.id, name: name) }

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(minimum: 58), spacing: horizontalSpacing),
                                count: columnCount
                            ),
                            spacing: 24
                        ) {
                            ForEach(folder.applications) { application in
                                FolderApplicationTile(
                                    application: application,
                                    folderID: folder.id,
                                    iconSize: folderIconSize,
                                    tileWidth: cellWidth
                                )
                            }
                        }
                        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.82, blendDuration: 0.12), value: folder.applications)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, 32)
                    }
                    .frame(width: panelWidth, height: panelHeight)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 38, style: .continuous))
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 38, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 38, style: .continuous)
                            .stroke(.white.opacity(0.13), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.20), radius: 42, y: 22)
                }
                .scaleEffect(appeared ? 1 : 0.94)
                .offset(y: appeared ? -16 : 8)
                .opacity(appeared ? 1 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            name = folder.name
            withAnimation(reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.84)) {
                appeared = true
                store.folderOverlayIsDimmed = true
            }
        }
        .onDisappear {
            store.renameFolder(id: folder.id, name: name)
            store.folderOverlayIsDimmed = false
        }
    }

    private func closeFolder() {
        store.renameFolder(id: folder.id, name: name)
        withAnimation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.92)) {
            appeared = false
            store.folderOverlayIsDimmed = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.18)) {
            if store.openFolderID == folder.id { store.openFolderID = nil }
        }
    }
}

private struct FolderApplicationTile: View {
    @EnvironmentObject private var store: LauncherStore
    @EnvironmentObject private var controller: LauncherController
    let application: LauncherApplication
    let folderID: UUID
    let iconSize: CGFloat
    let tileWidth: CGFloat

    private var isDragged: Bool {
        store.draggedEntryID == application.id && store.draggedSourceFolderID == folderID
    }

    private var isFolderDropTarget: Bool {
        store.draggedEntryID != nil
            && store.draggedEntryID != application.id
            && store.dragTargetID == application.id
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                ApplicationIcon(path: application.path)
                    .frame(width: iconSize, height: iconSize)
                    .contentShape(RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous))
                    .onTapGesture { controller.launch(application) }
                if store.optionIsPressed, !application.isProtected {
                    Button { store.requestUninstall(application) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: max(18, iconSize * 0.22), weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray.opacity(0.95))
                    }
                    .buttonStyle(.plain)
                    .offset(x: -7, y: -6)
                }
            }
            .modifier(NativeJiggleModifier(
                active: store.optionIsPressed,
                phase: Double(abs(application.id.hashValue % 997)) / 997.0 * .pi * 2
            ))

            Text(store.displayName(for: application))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
        }
        .frame(maxWidth: .infinity)
        .scaleEffect(isDragged ? 0.88 : (isFolderDropTarget ? 1.06 : 1))
        .opacity(isDragged ? 0.24 : 1)
        .animation(.spring(response: 0.30, dampingFraction: 0.74), value: isDragged)
        .animation(.spring(response: 0.30, dampingFraction: 0.74), value: isFolderDropTarget)
        .onDrag {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.74)) {
                store.beginFolderDrag(application, folderID: folderID)
            }
            return NSItemProvider(object: application.url as NSURL)
        } preview: {
            HighResolutionApplicationDragPreview(path: application.path, size: iconSize)
                .padding(12)
                .background(.black.opacity(0.10), in: RoundedRectangle(cornerRadius: iconSize * 0.30, style: .continuous))
                .shadow(color: .black.opacity(0.34), radius: 18, y: 12)
        }
        .onDrop(
            of: [UTType.fileURL, UTType.utf8PlainText],
            delegate: FolderEntryDropDelegate(
                application: application,
                folderID: folderID,
                tileWidth: tileWidth,
                store: store
            )
        )
        .contextMenu {
            Button("打开") { controller.launch(application) }
            Button("重命名…") { store.requestAlias(for: application) }
            Button("移出文件夹") { store.removeFromFolder(application, folderID: folderID) }
            Button("在访达中显示") { store.revealInFinder(application) }
            if !application.isProtected {
                Divider()
                Button("卸载应用", role: .destructive) { store.requestUninstall(application) }
            }
        }
    }
}

/// 文件夹网格磁贴的拖放委托：支持文件夹内排序与从外部拖入。
private struct FolderEntryDropDelegate: DropDelegate {
    let application: LauncherApplication
    let folderID: UUID
    let tileWidth: CGFloat
    let store: LauncherStore

    func dropEntered(info: DropInfo) {
        store.updateFolderDrag(over: application, folderID: folderID, locationX: info.location.x, tileWidth: tileWidth)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        store.updateFolderDrag(over: application, folderID: folderID, locationX: info.location.x, tileWidth: tileWidth)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        store.folderDragExited()
    }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(.spring(response: 0.48, dampingFraction: 0.76, blendDuration: 0.12)) {
            store.completeFolderDrop(
                on: application,
                folderID: folderID,
                locationX: info.location.x,
                tileWidth: tileWidth
            )
        }
        return true
    }
}

private struct EntryDropDelegate: DropDelegate {
    let target: LauncherEntry
    let tileWidth: CGFloat
    let store: LauncherStore

    func dropEntered(info: DropInfo) {
        store.updateDrag(over: target, locationX: info.location.x, tileWidth: tileWidth)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        store.updateDrag(over: target, locationX: info.location.x, tileWidth: tileWidth)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        store.dragExited(target)
    }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(.spring(response: 0.48, dampingFraction: 0.76, blendDuration: 0.12)) {
            store.completeDrop(on: target, locationX: info.location.x, tileWidth: tileWidth)
        }
        return true
    }
}

private struct DragPageEdge: View {
    @EnvironmentObject private var store: LauncherStore
    let direction: Int

    var body: some View {
        Color.clear
            .frame(width: 54)
            .contentShape(Rectangle())
            .onDrop(of: [UTType.fileURL, UTType.utf8PlainText], delegate: PageEdgeDropDelegate(direction: direction, store: store))
    }
}

private struct PageEdgeDropDelegate: DropDelegate {
    let direction: Int
    let store: LauncherStore

    func dropEntered(info: DropInfo) {
        if direction < 0 { store.pageBackward() }
        else { store.pageForward() }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { store.endDrag(saveLayout: true); return true }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
