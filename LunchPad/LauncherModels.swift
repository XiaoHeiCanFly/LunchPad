import AppKit
import Combine
import Darwin
import Foundation
import OSLog
import UniformTypeIdentifiers

struct LauncherApplication: Codable, Hashable, Identifiable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let bundleIdentifier: String?
    let isProtected: Bool

    var url: URL { URL(fileURLWithPath: path) }
}

/// How the grid orders its icons.
enum SortMode: String, Codable, CaseIterable, Sendable {
    /// The user's own arrangement — the stored `entries` order.
    case custom
    case name
    case installDate
    case frequency
}

struct LauncherFolder: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var applications: [LauncherApplication]
    /// When the folder was created, used by install-date sorting. Layouts saved
    /// before this field existed decode it as `nil`, and install-date sorting
    /// falls back to the earliest contained application.
    var createdAt: Date?

    init(id: UUID, name: String, applications: [LauncherApplication], createdAt: Date? = nil) {
        self.id = id
        self.name = name
        self.applications = applications
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, name, applications, createdAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        applications = try container.decode([LauncherApplication].self, forKey: .applications)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(applications, forKey: .applications)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

enum LauncherEntry: Codable, Hashable, Identifiable, Sendable {
    case application(LauncherApplication)
    case folder(LauncherFolder)

    var id: String {
        switch self {
        case .application(let application): application.id
        case .folder(let folder): "folder:\(folder.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .application(let application): application.name
        case .folder(let folder): folder.name
        }
    }
}

struct UninstallRequest: Identifiable {
    let application: LauncherApplication
    var id: String { application.id }
}

@MainActor
final class LauncherStore: ObservableObject {
    @Published private(set) var entries: [LauncherEntry] = []
    @Published var searchText = ""
    @Published var currentPage = UserDefaults.standard.integer(forKey: "last-page") {
        didSet { UserDefaults.standard.set(currentPage, forKey: "last-page") }
    }
    @Published var openFolderID: UUID?
    @Published var folderOverlayIsDimmed = false
    @Published var optionIsPressed = false
    @Published var isScanning = true
    @Published var uninstallRequest: UninstallRequest?
    @Published var errorMessage: String?
    @Published var selectedEntryID: String?
    @Published var draggedEntryID: String?
    @Published var dragTargetID: String?
    @Published var folderCandidateID: String?
    @Published var aliasRequest: LauncherApplication?
    /// 拖拽源当前所在的文件夹；nil 表示源在根网格。拖拽开始时确定，
    /// 中途合并进自动创建的文件夹时更新，落点逻辑据此路由。
    var draggedSourceFolderID: UUID?
    private var draggedFolderApplication: LauncherApplication?
    /// 拖拽开始时的 entries 快照：拖拽取消时还原，让图标动画回到原位。
    private var dragStartEntries: [LauncherEntry]?
    /// 拖拽是否正悬停在某个文件夹的磁贴上（用于“拖出文件夹自动关闭”）。
    private var folderDragIsActive = false
    /// 当前打开的文件夹浮层的面板区域（屏幕坐标，与 NSEvent.mouseLocation 一致）。
    /// 指针在面板内时文件夹保持打开；离开面板才会自动关闭。
    var folderPanelRect: CGRect?
    /// 拖拽刚自动打开文件夹的时间；宽限期内不自动关闭，
    /// 给指针时间进入面板。
    private var folderOpenedByDragAt: Date?
    /// 本次拖拽会话中已经自动打开过的文件夹；防止自动打开→关闭→
    /// 又自动打开的闪烁循环（指针移开后再次悬停才重新触发）。
    private var autoOpenedFolderID: UUID?
    private var pendingFolderAutoClose: DispatchWorkItem?
    private var lastFolderPreviewReorderAt = Date.distantPast
    @Published var aliasDraft = ""
    @Published private(set) var runtimeGridColumns = 0
    @Published private(set) var runtimeGridRows = 0
    @Published var sortMode = SortMode(rawValue: UserDefaults.standard.string(forKey: sortModeKey) ?? "") ?? .custom {
        didSet {
            guard sortMode != oldValue else { return }
            UserDefaults.standard.set(sortMode.rawValue, forKey: Self.sortModeKey)
            currentPage = 0
        }
    }
    /// False (default) = newest first. Only applies in `.installDate` mode.
    @Published var installSortAscending = UserDefaults.standard.bool(forKey: installSortKey) {
        didSet { UserDefaults.standard.set(installSortAscending, forKey: Self.installSortKey) }
    }

    private static let sortModeKey = "sort-mode"
    private static let installSortKey = "install-sort-direction"
    private let defaultsKey = "launcher-layout-v2"
    private let aliasesKey = "application-aliases-v1"
    private let hiddenKey = "hidden-applications-v1"
    private let launchEventsKey = "launch-events-v1"
    private let defaultFoldersVersionKey = "default-folders-version"
    private var dragHoverStartedAt = Date.distantPast
    private var dragIsCentered = false
    /// Last time `previewReorder` ran during a drag. Reorders mutate `entries`
    /// (re-laying out the whole grid), so they are throttled to a ~60 ms cadence
    /// instead of firing on every `dropUpdated` mouse move.
    private var lastPreviewReorderAt = Date.distantPast
    /// True while the "switch to custom sorting?" reorder confirmation is shown.
    @Published var reorderToCustomPrompt = false
    /// Where (relative to the target tile) the last reorder gesture intended to
    /// drop — captured even in sorted modes where the preview itself is skipped.
    private var lastDragPlaceAfter = false
    /// The reorder the user dropped in a sorted mode, deferred until they
    /// confirm switching to custom sorting.
    private var pendingReorderSourceID: String?
    private var pendingReorderTargetID: String?
    private var pendingReorderPlaceAfter = false
    /// a session ended by Esc or abandoned outside the window never calls
    /// `performDrop`, leaving `draggedEntryID` set. The watchdog clears it once
    /// the primary button is released (a live drag always holds it down).
    private var dragWatchdog: Timer?
    private var dragBeganAt = Date.distantPast

    private var aliases: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: aliasesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: aliasesKey) }
    }

    private var hiddenPaths: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: hiddenKey) }
    }

    var gridColumns: Int {
        runtimeGridColumns > 0
            ? runtimeGridColumns
            : max(4, UserDefaults.standard.integer(forKey: "grid-columns").nonzero(or: 7))
    }
    var gridRows: Int {
        runtimeGridRows > 0
            ? runtimeGridRows
            : max(3, UserDefaults.standard.integer(forKey: "grid-rows").nonzero(or: 5))
    }
    var pageCapacity: Int { gridColumns * gridRows }

    func updateAdaptiveGrid(columns: Int, rows: Int) {
        guard columns != runtimeGridColumns || rows != runtimeGridRows else { return }
        runtimeGridColumns = columns
        runtimeGridRows = rows
        let lastPage = max(0, Int(ceil(Double(entries.count) / Double(pageCapacity))) - 1)
        currentPage = min(currentPage, lastPage)
    }

    func resetAdaptiveGrid() {
        runtimeGridColumns = 0
        runtimeGridRows = 0
    }

    var searchableApplications: [LauncherApplication] {
        entries.flatMap { entry in
            switch entry {
            case .application(let application): [application]
            case .folder(let folder): folder.applications
            }
        }
    }

    var filteredApplications: [LauncherApplication] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return searchableApplications
            .compactMap { application -> (LauncherApplication, Int)? in
                guard let score = application.searchScore(for: query, alias: displayName(for: application)) else { return nil }
                return (application, score)
            }
            .sorted {
                $0.1 == $1.1
                    ? $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending
                    : $0.1 < $1.1
            }
            .map(\.0)
    }

    func scanApplications() {
        isScanning = true
        Task {
            let discovered = await Task.detached(priority: .userInitiated) {
                Self.discoverApplications()
            }.value
            merge(discovered)
            isScanning = false
        }
    }

    // MARK: - Auto-rescan on install/removal

    /// Watch the app roots so apps added to /Applications (or ~/Applications)
    /// appear without a manual rescan or restart. Each root is watched with a
    /// Dispatch source on the top-level directory: adding/removing/renaming a
    /// `.app` is a single directory-entry change, which fires EVFILT_VNODE on
    /// the parent directory. Edits deeper inside a bundle don't matter — the
    /// entry itself is unchanged.
    private var appRootSources: [DispatchSourceFileSystemObject] = []
    private var rescanWorkItem: DispatchWorkItem?

    func startObservingApplicationChanges() {
        guard appRootSources.isEmpty else { return }
        var roots = ["/Applications", "/System/Applications"]
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path
        if FileManager.default.fileExists(atPath: userApps) { roots.append(userApps) }

        let queue = DispatchQueue(label: "com.king.LunchPad.app-watcher", qos: .utility)
        for root in roots {
            let fd = open(root, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                // The source fires on the watcher queue, but `self` is
                // @MainActor — hop before touching rescanWorkItem.
                Task { @MainActor [weak self] in
                    self?.scheduleRescan()
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            appRootSources.append(source)
        }
    }

    func stopObservingApplicationChanges() {
        appRootSources.forEach { $0.cancel() }
        appRootSources.removeAll()
        rescanWorkItem?.cancel()
        rescanWorkItem = nil
    }

    /// Coalesce a burst of directory events (a copy writes many times) into a
    /// single rescan shortly after they settle.
    private func scheduleRescan() {
        rescanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.scanApplications()
            }
        }
        rescanWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func application(in entry: LauncherEntry) -> LauncherApplication? {
        guard case .application(let application) = entry else { return nil }
        return application
    }

    func displayName(for application: LauncherApplication) -> String {
        aliases[application.path] ?? application.name
    }

    func title(for entry: LauncherEntry) -> String {
        switch entry {
        case .application(let application): displayName(for: application)
        case .folder(let folder): folder.name
        }
    }

    /// How far back frequency sorting counts — a rolling 30-day window.
    nonisolated private static let frequencyWindow: TimeInterval = 30 * 24 * 60 * 60

    /// Matches the bundle id inside a runningboardd job message. Two formats
    /// exist: `application.<bundleID>.<token>.<token>.<UUID>(uid)` for most
    /// apps and `application.<bundleID>.<token>.<token>(uid)` (no UUID) for
    /// system apps like Calculator. The trailing token digits anchor the lazy
    /// capture so a bundle id that itself ends in digits still parses.
    nonisolated private static let launchJobPattern =
        #"application\.(.+?)\.\d+\.\d+(?:\.[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})?\(\d+\)"#

    /// Launch events keyed by bundle id (apps) or `folder:<uuid>` (folders);
    /// each value is the list of unix launch timestamps. Persisted as JSON in
    /// UserDefaults and decoded once into an in-memory cache for hot reads.
    private var launchEvents: [String: [TimeInterval]] {
        get {
            if let launchEventsCache { return launchEventsCache }
            let loaded = loadLaunchEvents()
            launchEventsCache = loaded
            return loaded
        }
        set {
            launchEventsCache = newValue
            saveLaunchEvents(newValue)
        }
    }
    private var launchEventsCache: [String: [TimeInterval]]?
    private var launchObserver: NSObjectProtocol?

    private func loadLaunchEvents() -> [String: [TimeInterval]] {
        guard let data = UserDefaults.standard.data(forKey: launchEventsKey),
              let value = try? JSONDecoder().decode([String: [TimeInterval]].self, from: data) else { return [:] }
        return value
    }

    private func saveLaunchEvents(_ events: [String: [TimeInterval]]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: launchEventsKey)
    }

    /// Drop events older than the window and remove now-empty keys.
    func pruneLaunchEvents(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.frequencyWindow).timeIntervalSince1970
        var events = launchEvents
        var changed = false
        for (key, list) in events {
            let kept = list.filter { $0 > cutoff }
            if kept.isEmpty {
                events.removeValue(forKey: key)
                changed = true
            } else if kept.count != list.count {
                events[key] = kept
                changed = true
            }
        }
        if changed { launchEvents = events }
    }

    /// A system-wide app launch — the workspace fired its launch notification
    /// for an app opened from LunchPad, the Dock, Spotlight, Finder, Terminal,
    /// or anywhere else on this Mac.
    func recordSystemLaunch(bundleID: String, at date: Date = Date()) {
        var events = launchEvents
        let cutoff = date.addingTimeInterval(-Self.frequencyWindow).timeIntervalSince1970
        var list = (events[bundleID] ?? []).filter { $0 > cutoff }
        list.append(date.timeIntervalSince1970)
        events[bundleID] = list
        launchEvents = events
    }

    /// Folder opens only happen inside LunchPad, so they are recorded here
    /// rather than from a workspace notification.
    func recordFolderOpen(_ folder: LauncherFolder, at date: Date = Date()) {
        recordSystemLaunch(bundleID: "folder:\(folder.id.uuidString)", at: date)
    }

    /// Opens within the rolling window for the given entry.
    private func openCount(for entry: LauncherEntry, at now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-Self.frequencyWindow).timeIntervalSince1970
        let key: String
        switch entry {
        case .application(let app): key = app.bundleIdentifier ?? app.path
        case .folder(let folder): key = "folder:\(folder.id.uuidString)"
        }
        return launchEvents[key]?.lazy.filter { $0 > cutoff }.count ?? 0
    }

    /// Start watching system-wide app launches. Called once at app startup and
    /// kept for the process lifetime, so every app opened while LunchPad is
    /// running is counted toward frequency sorting.
    ///
    /// Launches that happened before this run (while LunchPad wasn't running)
    /// are backfilled from the unified system log in the background, so
    /// frequency sorting reflects real usage from before the app started.
    func startObservingSystemLaunches() {
        guard launchObserver == nil else { return }
        pruneLaunchEvents()
        // The log query covers everything up to now, so events at or after
        // this instant are already being recorded live by the observer below.
        // Cutting the backfill off here keeps the two sources disjoint.
        let cutoff = Date()
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor [weak self] in
                guard let self, let bundleID else { return }
                self.recordSystemLaunch(bundleID: bundleID, at: Date())
            }
        }
        // The store query can take ~15 s even with the predicate pushed down,
        // so run it off the main actor and hop back only for the merge.
        Task.detached(priority: .utility) { [weak self] in
            let events = Self.querySystemLaunchEvents(before: cutoff)
            await MainActor.run {
                self?.mergeBackfilledEvents(events)
            }
        }
    }

    /// Query the unified system log for GUI app launches and return per-bundle
    /// launch timestamps for everything before `cutoff`.
    ///
    /// When runningboardd creates the job for a GUI app it logs
    /// `Creating and launching job for: app<application.<bundleID>…>` — the one
    /// message in the log that names the bundle id unredacted. The predicate is
    /// narrowed with `subsystem`/`category` because the `eventMessage` CONTAINS
    /// is not pushed down to logd, and scanning all of runningboardd's output
    /// is far slower. macOS only retains these debug entries for about a day,
    /// so this recovers at most that much history; the live observer fills in
    /// everything from now on.
    nonisolated private static func querySystemLaunchEvents(before cutoff: Date) -> [String: [TimeInterval]] {
        do {
            let store = try OSLogStore(scope: .system)
            let position = store.position(date: cutoff.addingTimeInterval(-frequencyWindow))
            let predicate = NSPredicate(
                format: "process == %@ AND subsystem == %@ AND category == %@ AND eventMessage CONTAINS[c] %@",
                "runningboardd", "com.apple.runningboard", "job",
                "Creating and launching job for: app<application."
            )
            let entries = try store.getEntries(with: [], at: position, matching: predicate)
            let regex = try NSRegularExpression(pattern: launchJobPattern, options: [.caseInsensitive])
            var events: [String: [TimeInterval]] = [:]
            for case let log as OSLogEntryLog in entries {
                guard log.date < cutoff else { continue }
                let message = log.composedMessage
                let range = NSRange(message.startIndex..., in: message)
                guard let match = regex.firstMatch(in: message, range: range),
                      let idRange = Range(match.range(at: 1), in: message) else { continue }
                let bundleID = String(message[idRange])
                guard !bundleID.isEmpty else { continue }
                events[bundleID, default: []].append(log.date.timeIntervalSince1970)
            }
            return events
        } catch {
            os_log(.error, "LunchPad: system-log backfill failed: %{public}@", "\(error)")
            return [:]
        }
    }

    /// Fold log-derived app events into the stored history. A launch the
    /// observer already recorded live and the same launch seen in the log are
    /// a few seconds apart (the job message fires before the "did launch"
    /// notification), so timestamps within a small tolerance are treated as the
    /// same launch. Folder events are never touched.
    private func mergeBackfilledEvents(_ newEvents: [String: [TimeInterval]]) {
        guard !newEvents.isEmpty else { return }
        var merged = loadLaunchEvents()
        let tolerance: TimeInterval = 5
        for (bundleID, newStamps) in newEvents {
            var existing = merged[bundleID] ?? []
            for ts in newStamps.sorted() {
                if existing.contains(where: { abs($0 - ts) < tolerance }) { continue }
                existing.append(ts)
            }
            if !existing.isEmpty { merged[bundleID] = existing }
        }
        launchEvents = merged
        pruneLaunchEvents()
    }

    /// Entries in the order the grid should show, per the active sort mode.
    /// Custom is the user's stored arrangement; the other modes derive an order
    /// from the immutable stored `entries`, so the user's manual layout is
    /// preserved while sorting and restored by switching back to custom.
    var displayEntries: [LauncherEntry] {
        switch sortMode {
        case .custom:
            return entries
        case .name:
            return entries.sorted {
                title(for: $0).localizedStandardCompare(title(for: $1)) == .orderedAscending
            }
        case .installDate:
            return entries.sorted {
                let a = installDate(of: $0)
                let b = installDate(of: $1)
                if a == b {
                    return title(for: $0).localizedStandardCompare(title(for: $1)) == .orderedAscending
                }
                return installSortAscending ? a < b : a > b
            }
        case .frequency:
            // Most-opened first, counting only opens within the rolling 30-day
            // window. Ties keep the user's custom layout order (stable), so apps
            // with equal or no recent opens don't jump into alphabetical order.
            let now = Date()
            return entries.enumerated().sorted {
                let a = openCount(for: $0.element, at: now)
                let b = openCount(for: $1.element, at: now)
                if a != b { return a > b }
                return $0.offset < $1.offset
            }
            .map(\.element)
        }
    }

    /// What the grid pages through right now: filtered search results while
    /// searching, otherwise the sorted full grid. Search stays paginated (like
    /// native Launchpad) instead of collapsing into a scrollable list, so the
    /// page strip, dots, and swipe gestures all keep working mid-search.
    var visibleEntries: [LauncherEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty else {
            return filteredApplications.map { .application($0) }
        }
        return displayEntries
    }

    /// Memoized `.app` bundle creation dates. Creation dates are stable, so the
    /// cache is valid for the store's lifetime — without it, install-date
    /// sorting would stat every bundle on each layout pass.
    private var installDateCache: [String: Date] = [:]

    private func installDate(of entry: LauncherEntry) -> Date {
        switch entry {
        case .application(let application):
            if let cached = installDateCache[application.path] { return cached }
            let date = Self.bundleCreationDate(at: application.url) ?? .distantPast
            installDateCache[application.path] = date
            return date
        case .folder(let folder):
            if let createdAt = folder.createdAt { return createdAt }
            return folder.applications.map { installDate(of: .application($0)) }.min() ?? .distantPast
        }
    }

    nonisolated private static func bundleCreationDate(at url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    func openFolder(_ folder: LauncherFolder) {
        recordFolderOpen(folder)
        openFolderID = folder.id
    }

    func requestAlias(for application: LauncherApplication) {
        aliasDraft = displayName(for: application)
        aliasRequest = application
    }

    func commitAlias() {
        guard let application = aliasRequest else { return }
        var values = aliases
        let name = aliasDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == application.name { values.removeValue(forKey: application.path) }
        else { values[application.path] = name }
        aliases = values
        aliasRequest = nil
        objectWillChange.send()
        save()
    }

    func hide(_ application: LauncherApplication) {
        var hidden = hiddenPaths
        hidden.insert(application.path)
        hiddenPaths = hidden
        removeEverywhere(application)
    }

    func restoreHiddenApplications() {
        hiddenPaths = []
        scanApplications()
    }

    func folder(id: UUID) -> LauncherFolder? {
        guard let entry = entries.first(where: {
            if case .folder(let folder) = $0 { return folder.id == id }
            return false
        }), case .folder(let folder) = entry else { return nil }
        return folder
    }

    func renameFolder(id: UUID, name: String) {
        guard let index = entries.firstIndex(where: {
            if case .folder(let folder) = $0 { return folder.id == id }
            return false
        }), case .folder(var folder) = entries[index] else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.name = trimmed.isEmpty ? "文件夹" : trimmed
        entries[index] = .folder(folder)
        save()
    }

    func moveDraggedEntry(onto target: LauncherEntry) {
        guard let sourceID = draggedEntryID, sourceID != target.id,
              let sourceIndex = entries.firstIndex(where: { $0.id == sourceID }) else { return }

        let source = entries.remove(at: sourceIndex)
        guard case .application(let sourceApplication) = source else {
            entries.insert(source, at: min(sourceIndex, entries.count))
            return
        }

        guard let targetIndex = entries.firstIndex(where: { $0.id == target.id }) else {
            entries.append(source)
            return
        }

        switch entries[targetIndex] {
        case .application(let targetApplication):
            entries[targetIndex] = .folder(LauncherFolder(
                id: UUID(),
                name: suggestedFolderName(for: [targetApplication, sourceApplication]),
                applications: [targetApplication, sourceApplication],
                createdAt: Date()
            ))
        case .folder(var folder):
            guard !folder.applications.contains(where: { $0.id == sourceApplication.id }) else { return }
            folder.applications.append(sourceApplication)
            entries[targetIndex] = .folder(folder)
        }
        dragStartEntries = nil
        endDrag()
        save()
    }

    func beginDrag(_ entry: LauncherEntry) {
        draggedEntryID = entry.id
        draggedSourceFolderID = nil
        draggedFolderApplication = nil
        folderDragIsActive = false
        dragStartEntries = entries
        dragTargetID = nil
        folderCandidateID = nil
        dragHoverStartedAt = .distantPast
        dragBeganAt = Date()
        startDragWatchdog()
    }

    /// Starts a drag that carries an application out of a folder. The source
    /// lives inside a folder entry, so the drop path differs from root drags.
    func beginFolderDrag(_ application: LauncherApplication, folderID: UUID) {
        draggedEntryID = application.id
        draggedSourceFolderID = folderID
        draggedFolderApplication = application
        folderDragIsActive = false
        dragStartEntries = entries
        dragTargetID = nil
        folderCandidateID = nil
        dragHoverStartedAt = .distantPast
        dragBeganAt = Date()
        startDragWatchdog()
        // 拖出文件夹：指针一旦离开文件夹面板区域，自动关闭文件夹浮层，
        // 露出根网格方便确定落点。仍在文件夹内排序时保持打开。
        scheduleFolderAutoClose(delay: 0.25)
    }

    /// 响应式自动关闭：指针在打开中的文件夹面板内则保持打开（取消计时），
    /// 离开面板（且不在任何文件夹磁贴上）则延迟后关闭。
    private func scheduleFolderAutoClose(delay: TimeInterval) {
        pendingFolderAutoClose?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.draggedEntryID != nil,
                      self.draggedSourceFolderID != nil,
                      !self.folderDragIsActive,
                      !self.folderDragIsInsidePanel()
                else { return }
                // 拖拽刚打开的文件夹给 1.5 秒宽限期，让指针有时间进入面板；
                // 之后的移动会重新调度关闭检查。
                if let openedAt = self.folderOpenedByDragAt,
                   Date().timeIntervalSince(openedAt) < 1.5 { return }
                self.folderOpenedByDragAt = nil
                self.openFolderID = nil
            }
        }
        pendingFolderAutoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 指针是否在“源所在且已打开”的文件夹面板内（屏幕坐标判定）。
    private func folderDragIsInsidePanel() -> Bool {
        guard let rect = folderPanelRect, let openID = openFolderID,
              draggedSourceFolderID == openID else { return false }
        return rect.contains(NSEvent.mouseLocation)
    }

    /// 文件夹浮层空白区域：进入/移动时按面板位置决定保持或关闭。
    func folderDragHoveringBlank() {
        folderDragIsActive = false
        if folderDragIsInsidePanel() {
            pendingFolderAutoClose?.cancel()
        } else {
            scheduleFolderAutoClose(delay: 0.3)
        }
    }

    /// 在文件夹浮层空白处松开：面板外关闭文件夹；面板内保持打开。
    func folderDragDroppedOnBlank() {
        pendingFolderAutoClose?.cancel()
        folderDragIsActive = false
        if !folderDragIsInsidePanel() {
            openFolderID = nil
        }
    }

    /// 文件夹浮层面板区域（屏幕坐标、左下原点，与 NSEvent.mouseLocation 一致）。
    func updateFolderPanelRect(_ frame: CGRect, screenHeight: CGFloat) {
        folderPanelRect = CGRect(x: frame.minX, y: screenHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    private func startDragWatchdog() {
        dragWatchdog?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkDragWatchdog()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragWatchdog = timer
    }

    private func checkDragWatchdog() {
        guard draggedEntryID != nil else {
            dragWatchdog?.invalidate(); dragWatchdog = nil
            return
        }
        // A live drag keeps the primary button held. Once it's released and
        // `draggedEntryID` is still set, the session was cancelled (Esc) or the
        // item was dropped outside any target — recover the dragged tile. The
        // grace period lets the session actually start before we watch.
        let leftButtonHeld = NSEvent.pressedMouseButtons & 1 != 0
        guard !leftButtonHeld, Date().timeIntervalSince(dragBeganAt) > 0.4 else { return }
        // 拖拽被取消（Esc / 松手在无效区域）：关闭拖拽期间打开的文件夹。
        openFolderID = nil
        endDrag(revertPreview: true)
    }

    func updateDrag(over target: LauncherEntry, locationX: CGFloat, tileWidth: CGFloat) {
        guard draggedEntryID != nil, draggedEntryID != target.id else { return }
        let targetIsFolder: Bool
        if case .folder = target { targetIsFolder = true }
        else { targetIsFolder = false }
        // 从文件夹拖出的应用：一旦进入根网格区域就关闭文件夹浮层；
        // 首次悬停到应用磁贴上时把源取出放入根网格（按落点位置），
        // 让实时让位预览与落点逻辑与根网格拖拽完全一致。
        if draggedSourceFolderID != nil {
            openFolderID = nil
            if !targetIsFolder {
                pullDraggedSourceIntoRootEntries(at: target, locationX: locationX, tileWidth: tileWidth)
            }
        }
        let centerBand = max(44, tileWidth * 0.46)
        let centered = targetIsFolder || abs(locationX - tileWidth / 2) < centerBand / 2

        if dragTargetID != target.id {
            dragTargetID = target.id
            // 新目标：允许再次自动打开文件夹（移开后重新悬停可重触发）。
            autoOpenedFolderID = nil
            folderCandidateID = targetIsFolder ? target.id : nil
            dragHoverStartedAt = Date()
            if !targetIsFolder {
                let targetID = target.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
                    guard let self, self.draggedEntryID != nil,
                          self.dragTargetID == targetID, self.dragIsCentered else { return }
                    self.folderCandidateID = targetID
                }
                // 悬停 1.5 秒：自动把两个应用合并成文件夹并打开，
                // 拖拽不结束，可继续在文件夹内排序。
                let sourceInRoot = self.draggedSourceFolderID == nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, self.draggedEntryID != nil,
                          self.dragTargetID == targetID, self.dragIsCentered,
                          self.draggedSourceFolderID == nil, sourceInRoot,
                          self.folderCandidateID == targetID
                    else { return }
                    if let folderID = self.autoCreateFolder(on: target) {
                        self.folderCandidateID = nil
                        self.openFolderID = folderID
                        self.folderOpenedByDragAt = Date()
                        self.autoOpenedFolderID = folderID
                    }
                }
            }
        }

        dragIsCentered = centered
        if targetIsFolder {
            // A folder is a stable drop target across its entire tile. Never run
            // preview reordering here, otherwise a folder at the end of a row is
            // pushed onto the next row just as the pointer enters it.
            folderCandidateID = target.id
            // 悬停 1 秒：把拖入的应用合并进文件夹并打开，
            // 之后可在文件夹内继续拖动排序。
            if case .folder(let folder) = target, folder.id != draggedSourceFolderID {
                let folderID = folder.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, self.draggedEntryID != nil,
                          self.dragTargetID == "folder:\(folderID.uuidString)",
                          self.openFolderID != folderID,
                          self.autoOpenedFolderID != folderID
                    else { return }
                    if let mergedFolderID = self.mergeDraggedIntoFolder(folderID) {
                        self.openFolderID = mergedFolderID
                        self.folderOpenedByDragAt = Date()
                        self.autoOpenedFolderID = mergedFolderID
                    }
                }
            }
            return
        }
        if centered {
            if Date().timeIntervalSince(dragHoverStartedAt) > 0.33 {
                folderCandidateID = target.id
            }
        } else {
            folderCandidateID = nil
            lastDragPlaceAfter = locationX > tileWidth / 2
            // A sorted grid owns its order, so only custom mode previews the
            // live squeeze. The drop slot is still tracked for the confirm step.
            guard sortMode == .custom else { return }
            let now = Date()
            guard now.timeIntervalSince(lastPreviewReorderAt) >= 0.06 else { return }
            lastPreviewReorderAt = now
            previewReorder(around: target, placeAfter: lastDragPlaceAfter)
        }
    }

    /// 文件夹磁贴上悬停（拖入/文件夹内排序的实时反馈）。
    func updateFolderDrag(over targetApplication: LauncherApplication, folderID: UUID, locationX: CGFloat, tileWidth: CGFloat) {
        guard draggedEntryID != nil, draggedEntryID != targetApplication.id else { return }
        folderDragIsActive = true
        pendingFolderAutoClose?.cancel()
        dragTargetID = targetApplication.id
        dragHoverStartedAt = Date()
        let centerBand = max(44, tileWidth * 0.46)
        let centered = abs(locationX - tileWidth / 2) < centerBand / 2
        dragIsCentered = centered
        if centered {
            folderCandidateID = targetApplication.id
            return
        }
        folderCandidateID = nil
        lastDragPlaceAfter = locationX > tileWidth / 2
        // 仅当源就在本文件夹内时实时预览排序。
        guard draggedSourceFolderID == folderID else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFolderPreviewReorderAt) >= 0.06 else { return }
        lastFolderPreviewReorderAt = now
        previewFolderReorder(over: targetApplication, folderID: folderID, placeAfter: lastDragPlaceAfter)
    }

    /// 指针离开文件夹磁贴（可能进入面板空白，由 folderDragHoveringBlank 接管）。
    func folderDragExited() {
        folderDragIsActive = false
        dragTargetID = nil
        folderCandidateID = nil
        dragHoverStartedAt = .distantPast
    }

    /// 在文件夹磁贴上松开：源已在本文件夹内则按位置排序；
    /// 否则把源从当前位置移入文件夹的目标位置。
    func completeFolderDrop(on targetApplication: LauncherApplication, folderID: UUID, locationX: CGFloat?, tileWidth: CGFloat) {
        guard let sourceID = draggedEntryID, sourceID != targetApplication.id else {
            endDrag()
            return
        }
        let placeAfter = locationX.map { $0 > tileWidth / 2 } ?? lastDragPlaceAfter
        if draggedSourceFolderID == folderID {
            // 同文件夹排序：以落点位置为准移动（实时预览仅作视觉反馈）。
            guard let application = draggedFolderApplication else {
                endDrag()
                return
            }
            remove(application: application, fromFolder: folderID, promoteSingleton: false)
            insertIntoFolder(application, folderID: folderID, near: targetApplication, placeAfter: placeAfter)
            dragStartEntries = nil
            normalizeFolders()
            save()
        } else {
            guard let application = removeDraggedSource() else {
                endDrag()
                return
            }
            insertIntoFolder(application, folderID: folderID, near: targetApplication, placeAfter: placeAfter)
            dragStartEntries = nil
            normalizeFolders()
            save()
        }
        endDrag()
    }

    /// 文件夹内磁贴上的实时让位预览。
    private func previewFolderReorder(over target: LauncherApplication, folderID: UUID, placeAfter: Bool) {
        guard let sourceID = draggedEntryID, sourceID != target.id,
              draggedSourceFolderID == folderID,
              let index = entries.firstIndex(where: {
                  if case .folder(let folder) = $0 { return folder.id == folderID }
                  return false
              }),
              case .folder(var folder) = entries[index],
              let sourceIndex = folder.applications.firstIndex(where: { $0.id == sourceID }),
              let oldTargetIndex = folder.applications.firstIndex(where: { $0.id == target.id })
        else { return }
        let desiredIndex = oldTargetIndex + (placeAfter ? 1 : 0)
        if sourceIndex == desiredIndex || sourceIndex + 1 == desiredIndex { return }
        let source = folder.applications.remove(at: sourceIndex)
        let adjusted = desiredIndex > sourceIndex ? desiredIndex - 1 : desiredIndex
        folder.applications.insert(source, at: min(max(0, adjusted), folder.applications.count))
        entries[index] = .folder(folder)
    }

    /// 把应用插入文件夹中目标应用旁边（placeAfter 决定前后）。
    private func insertIntoFolder(_ application: LauncherApplication, folderID: UUID, near target: LauncherApplication, placeAfter: Bool) {
        guard let index = entries.firstIndex(where: {
            if case .folder(let folder) = $0 { return folder.id == folderID }
            return false
        }), case .folder(var folder) = entries[index] else { return }
        if let targetIndex = folder.applications.firstIndex(where: { $0.id == target.id }) {
            let insertIndex = min(folder.applications.count, targetIndex + (placeAfter ? 1 : 0))
            folder.applications.insert(application, at: insertIndex)
        } else {
            folder.applications.append(application)
        }
        entries[index] = .folder(folder)
    }

    /// 从当前位置（根网格或源文件夹）取出拖拽中的应用。
    @discardableResult
    private func removeDraggedSource() -> LauncherApplication? {
        guard let sourceID = draggedEntryID else { return nil }
        if let folderID = draggedSourceFolderID, let application = draggedFolderApplication {
            remove(application: application, fromFolder: folderID, promoteSingleton: false)
            return application
        }
        guard let index = entries.firstIndex(where: { $0.id == sourceID }),
              case .application(let application) = entries[index] else { return nil }
        entries.remove(at: index)
        return application
    }

    /// 把拖出的源从文件夹取出，按落点位置插入根网格；
    /// 之后实时预览、落点与取消还原都走根网格逻辑。
    private func pullDraggedSourceIntoRootEntries(at target: LauncherEntry, locationX: CGFloat, tileWidth: CGFloat) {
        guard draggedSourceFolderID != nil, let application = removeDraggedSource() else { return }
        let placeAfter = locationX > tileWidth / 2
        if let targetIndex = entries.firstIndex(where: { $0.id == target.id }) {
            entries.insert(.application(application), at: min(entries.count, targetIndex + (placeAfter ? 1 : 0)))
        } else {
            entries.append(.application(application))
        }
        draggedSourceFolderID = nil
        draggedFolderApplication = nil
        // 源文件夹可能因此被清空或只剩一个应用，立即解散/合并。
        normalizeFolders()
    }

    /// 把应用合并到目标（应用 → 创建文件夹；文件夹 → 移入）。
    private func mergeApplication(_ application: LauncherApplication, onto target: LauncherEntry) {
        guard let targetIndex = entries.firstIndex(where: { $0.id == target.id }) else {
            entries.append(.application(application))
            save()
            return
        }
        switch entries[targetIndex] {
        case .application(let targetApplication):
            entries[targetIndex] = .folder(LauncherFolder(
                id: UUID(),
                name: suggestedFolderName(for: [targetApplication, application]),
                applications: [targetApplication, application],
                createdAt: Date()
            ))
        case .folder(var folder):
            guard !folder.applications.contains(where: { $0.id == application.id }) else { return }
            folder.applications.append(application)
            entries[targetIndex] = .folder(folder)
        }
        normalizeFolders()
        save()
    }

    /// 把拖拽中的应用合并进现有文件夹（拖拽状态保留，可继续排序）。
    @discardableResult
    private func mergeDraggedIntoFolder(_ folderID: UUID) -> UUID? {
        guard let application = removeDraggedSource() else { return nil }
        guard let index = entries.firstIndex(where: {
            if case .folder(let folder) = $0 { return folder.id == folderID }
            return false
        }), case .folder(var folder) = entries[index] else {
            // 目标文件夹已不存在（如被解散）：把应用放回根网格。
            entries.append(.application(application))
            normalizeFolders()
            save()
            return nil
        }
        guard !folder.applications.contains(where: { $0.id == application.id }) else {
            draggedSourceFolderID = folderID
            draggedFolderApplication = application
            return folderID
        }
        folder.applications.append(application)
        entries[index] = .folder(folder)
        draggedSourceFolderID = folderID
        draggedFolderApplication = application
        dragStartEntries = nil
        normalizeFolders()
        save()
        return folderID
    }

    /// 悬停 1.5 秒后立即创建文件夹并打开（拖拽状态保留，可继续排序）。
    @discardableResult
    private func autoCreateFolder(on target: LauncherEntry) -> UUID? {
        guard let sourceID = draggedEntryID, sourceID != target.id,
              let sourceIndex = entries.firstIndex(where: { $0.id == sourceID }),
              case .application(let sourceApplication) = entries[sourceIndex],
              let targetIndex = entries.firstIndex(where: { $0.id == target.id }),
              case .application(let targetApplication) = entries[targetIndex]
        else { return nil }
        entries.remove(at: sourceIndex)
        let adjustedTarget = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        let folder = LauncherFolder(
            id: UUID(),
            name: suggestedFolderName(for: [targetApplication, sourceApplication]),
            applications: [targetApplication, sourceApplication],
            createdAt: Date()
        )
        entries[adjustedTarget] = .folder(folder)
        // 源已进入文件夹：更新拖拽源位置，后续落点按“文件夹内”处理。
        draggedSourceFolderID = folder.id
        draggedFolderApplication = sourceApplication
        dragStartEntries = nil
        save()
        return folder.id
    }

    func completeDrop(on target: LauncherEntry, locationX: CGFloat? = nil, tileWidth: CGFloat = 0) {
        // The source currently lives inside a folder: the drop routes through
        // the folder-aware path (insert next to the target / merge).
        if draggedSourceFolderID != nil {
            completeFolderDrag(on: target, locationX: locationX, tileWidth: tileWidth)
            return
        }
        if folderCandidateID == target.id {
            // Folder merge/create keeps working in every mode — no prompt.
            moveDraggedEntry(onto: target)
            return
        }
        if sortMode == .custom {
            // The preview already reordered `entries` live; just persist it.
            endDrag(saveLayout: true)
            return
        }
        // Pure reorder in a sorted mode: the sort owns the current order, so ask
        // before mutating the user's custom layout.
        pendingReorderSourceID = draggedEntryID
        pendingReorderTargetID = target.id
        if let locationX { pendingReorderPlaceAfter = locationX > tileWidth / 2 }
        else { pendingReorderPlaceAfter = lastDragPlaceAfter }
        endDrag()
        reorderToCustomPrompt = true
    }

    /// Drop landing for an app dragged out of a folder. Centered on an app or
    /// dropped onto a folder merges it in; otherwise it is inserted into the
    /// root entries next to the target.
    private func completeFolderDrag(on target: LauncherEntry, locationX: CGFloat?, tileWidth: CGFloat) {
        guard draggedEntryID != nil else {
            endDrag()
            return
        }
        // Dropping back onto the folder it came from is a no-op.
        if case .folder(let folder) = target, folder.id == draggedSourceFolderID {
            endDrag()
            return
        }
        openFolderID = nil
        if folderCandidateID == target.id {
            guard let application = removeDraggedSource() else {
                endDrag()
                return
            }
            mergeApplication(application, onto: target)
        } else {
            guard let application = removeDraggedSource() else {
                endDrag()
                return
            }
            let placeAfter = locationX.map { $0 > tileWidth / 2 } ?? false
            if let targetIndex = entries.firstIndex(where: { $0.id == target.id }) {
                let insertIndex = min(entries.count, targetIndex + (placeAfter ? 1 : 0))
                entries.insert(.application(application), at: insertIndex)
            } else {
                entries.append(.application(application))
            }
            normalizeFolders()
            save()
        }
        dragStartEntries = nil
        endDrag()
    }

    /// Drop on blank space: pull the app out of its folder onto the root grid.
    func dropDraggedFolderAppToRoot() {
        // 拖拽期间源已取出到根网格（有实时预览位置）：保留当前位置即可。
        guard draggedSourceFolderID != nil else {
            endDrag()
            return
        }
        guard let application = removeDraggedSource() else {
            endDrag()
            return
        }
        openFolderID = nil
        entries.append(.application(application))
        dragStartEntries = nil
        normalizeFolders()
        save()
        endDrag()
    }

    /// The user confirmed switching to custom sorting for a dropped reorder.
    func confirmReorderToCustom() {
        guard reorderToCustomPrompt else { return }
        let sourceID = pendingReorderSourceID
        let targetID = pendingReorderTargetID
        let placeAfter = pendingReorderPlaceAfter
        reorderToCustomPrompt = false
        pendingReorderSourceID = nil
        pendingReorderTargetID = nil
        guard let sourceID, let targetID else { return }

        // The user dropped next to `target` in the currently-sorted grid.
        // Reorder in that displayed order and adopt it as the new custom
        // layout, so the switch reflects where the icon actually landed — not
        // where the target happens to sit in the old custom arrangement.
        var display = displayEntries
        guard let sourceIndex = display.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = display.firstIndex(where: { $0.id == targetID }) else { return }
        let source = display.remove(at: sourceIndex)
        let reducedTargetIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        display.insert(source, at: min(display.count, reducedTargetIndex + (placeAfter ? 1 : 0)))
        entries = display
        save()
        sortMode = .custom
    }

    /// The user declined the switch — leave the sorted layout untouched.
    func cancelReorderToCustom() {
        reorderToCustomPrompt = false
        pendingReorderSourceID = nil
        pendingReorderTargetID = nil
    }

    func dragExited(_ target: LauncherEntry) {
        guard dragTargetID == target.id else { return }
        dragTargetID = nil
        folderCandidateID = nil
        dragHoverStartedAt = .distantPast
        dragIsCentered = false
    }

    func endDrag(saveLayout: Bool = false, revertPreview: Bool = false) {
        dragWatchdog?.invalidate(); dragWatchdog = nil
        pendingFolderAutoClose?.cancel()
        pendingFolderAutoClose = nil
        folderOpenedByDragAt = nil
        autoOpenedFolderID = nil
        // 拖拽取消时把实时让位预览还原，图标回到拖拽前的位置。
        if revertPreview, let dragStartEntries {
            entries = dragStartEntries
        }
        dragStartEntries = nil
        draggedEntryID = nil
        draggedSourceFolderID = nil
        draggedFolderApplication = nil
        folderDragIsActive = false
        dragTargetID = nil
        folderCandidateID = nil
        dragHoverStartedAt = .distantPast
        dragIsCentered = false
        if saveLayout { save() }
    }

    private func previewReorder(around target: LauncherEntry, placeAfter: Bool) {
        guard let sourceID = draggedEntryID, sourceID != target.id,
              let sourceIndex = entries.firstIndex(where: { $0.id == sourceID }),
              let oldTargetIndex = entries.firstIndex(where: { $0.id == target.id }) else { return }
        let desiredIndex = oldTargetIndex + (placeAfter ? 1 : 0)
        if sourceIndex == desiredIndex || sourceIndex + 1 == desiredIndex { return }
        let source = entries.remove(at: sourceIndex)
        let adjusted = desiredIndex > sourceIndex ? desiredIndex - 1 : desiredIndex
        entries.insert(source, at: min(max(0, adjusted), entries.count))
    }

    func moveApplication(_ application: LauncherApplication, fromFolder folderID: UUID, onto target: LauncherEntry) {
        remove(application: application, fromFolder: folderID, promoteSingleton: false)
        guard let targetIndex = entries.firstIndex(where: { $0.id == target.id }) else {
            entries.append(.application(application))
            save()
            return
        }
        switch entries[targetIndex] {
        case .application(let targetApplication):
            entries[targetIndex] = .folder(LauncherFolder(
                id: UUID(), name: suggestedFolderName(for: [targetApplication, application]),
                applications: [targetApplication, application],
                createdAt: Date()
            ))
        case .folder(var folder):
            folder.applications.append(application)
            entries[targetIndex] = .folder(folder)
        }
        normalizeFolders()
        save()
    }

    func requestUninstall(_ application: LauncherApplication) {
        guard !application.isProtected else {
            errorMessage = "“\(application.name)”受系统保护，无法删除。"
            return
        }
        uninstallRequest = UninstallRequest(application: application)
    }

    func revealInFinder(_ application: LauncherApplication) {
        NSWorkspace.shared.activateFileViewerSelecting([application.url])
    }

    func pageForward(pageSize: Int? = nil) {
        let size = pageSize ?? pageCapacity
        // Clamp against the *visible* set — during search that's the filtered
        // results, not the full grid, so paging never overshoots past a shorter
        // result list (which would rest the strip past the last page).
        let last = max(0, Int(ceil(Double(visibleEntries.count) / Double(size))) - 1)
        currentPage = min(currentPage + 1, last)
    }

    func pageBackward() {
        currentPage = max(0, currentPage - 1)
    }

    var selectedEntry: LauncherEntry? {
        guard let selectedEntryID else { return nil }
        return entries.first { $0.id == selectedEntryID }
    }

    func moveSelection(by delta: Int, columns: Int? = nil, pageSize: Int? = nil) {
        // Navigate the displayed order so arrow keys follow the visible grid
        // (which may be sorted), not the stored custom arrangement.
        let display = displayEntries
        guard !display.isEmpty else { return }
        let size = pageSize ?? pageCapacity
        let currentIndex = selectedEntryID.flatMap { id in display.firstIndex { $0.id == id } }
            ?? min(currentPage * size, display.count - 1)
        let nextIndex = min(display.count - 1, max(0, currentIndex + delta))
        selectedEntryID = display[nextIndex].id
        currentPage = nextIndex / size
    }

    func exportLayout() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LunchPad 布局.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let archive = LayoutArchive(entries: entries, aliases: aliases, hiddenPaths: Array(hiddenPaths))
        do {
            let data = try JSONEncoder.pretty.encode(archive)
            try data.write(to: url, options: .atomic)
        } catch { errorMessage = "无法备份布局：\(error.localizedDescription)" }
    }

    func importLayout() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let archive = try JSONDecoder().decode(LayoutArchive.self, from: Data(contentsOf: url))
            entries = archive.entries
            aliases = archive.aliases
            hiddenPaths = Set(archive.hiddenPaths)
            currentPage = 0
            normalizeFolders()
            save()
            scanApplications()
        } catch { errorMessage = "无法恢复布局：\(error.localizedDescription)" }
    }

    func removeFromFolder(_ application: LauncherApplication, folderID: UUID) {
        remove(application: application, fromFolder: folderID, promoteSingleton: true)
        entries.append(.application(application))
        save()
    }

    func cancelUninstall() {
        uninstallRequest = nil
    }

    func confirmUninstall(_ application: LauncherApplication, relatedFiles: [URL]) {
        uninstallRequest = nil
        let applicationURL = application.url.standardizedFileURL
        let targets = [applicationURL] + relatedFiles.map(\.standardizedFileURL)
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let runningInstances = NSWorkspace.shared.runningApplications.filter { runningApplication in
            guard runningApplication.processIdentifier != currentProcessID else { return false }
            if let bundleIdentifier = application.bundleIdentifier,
               runningApplication.bundleIdentifier == bundleIdentifier {
                return true
            }
            if runningApplication.bundleURL?.standardizedFileURL == applicationURL {
                return true
            }
            if let executablePath = runningApplication.executableURL?.standardizedFileURL.path {
                return executablePath.hasPrefix(applicationURL.path + "/")
            }
            return false
        }
        let runningProcessIDs = runningInstances.map(\.processIdentifier)
        runningInstances.forEach { _ = $0.forceTerminate() }

        Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            var failures: [String] = []
            var permissionDeniedTargets: [URL] = []
            if !runningProcessIDs.isEmpty {
                for _ in 0..<40 {
                    guard runningProcessIDs.contains(where: Self.processIsAlive) else { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                for processID in runningProcessIDs where Self.processIsAlive(processID) {
                    Darwin.kill(processID, SIGKILL)
                }
                for _ in 0..<20 {
                    guard runningProcessIDs.contains(where: Self.processIsAlive) else { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            for target in targets {
                guard fileManager.fileExists(atPath: target.path) else { continue }
                do {
                    try fileManager.removeItem(at: target)
                } catch {
                    if Self.isPermissionDenied(error) {
                        permissionDeniedTargets.append(target)
                    } else {
                        failures.append("\(target.lastPathComponent)：\(error.localizedDescription)")
                    }
                }
            }
            if !permissionDeniedTargets.isEmpty {
                if let authorizationError = Self.removeWithAdministratorPrivileges(permissionDeniedTargets) {
                    failures.append(authorizationError)
                } else {
                    for target in permissionDeniedTargets where fileManager.fileExists(atPath: target.path) {
                        failures.append("\(target.lastPathComponent)：管理员授权后仍无法删除")
                    }
                }
            }
            let applicationWasDeleted = !fileManager.fileExists(atPath: applicationURL.path)
            let failureSnapshot = failures
            await MainActor.run {
                let store = LauncherController.shared.store
                if applicationWasDeleted {
                    store.removeEverywhere(application)
                }
                if !failureSnapshot.isEmpty {
                    store.errorMessage = "部分项目无法永久删除：\n" + failureSnapshot.prefix(4).joined(separator: "\n")
                }
            }
        }
    }

    nonisolated private static func processIsAlive(_ processID: pid_t) -> Bool {
        Darwin.kill(processID, 0) == 0 || errno == EPERM
    }

    nonisolated private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           [Int(EACCES), Int(EPERM)].contains(nsError.code) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionDenied(underlying)
        }
        return false
    }

    nonisolated private static func removeWithAdministratorPrivileges(_ urls: [URL]) -> String? {
        let arguments = urls.map { shellQuoted($0.standardizedFileURL.path) }.joined(separator: " ")
        let command = "/bin/rm -rf -- \(arguments)"
        let encodedCommand = Data(command.utf8).base64EncodedString()
        let privilegedCommand = "/bin/echo '\(encodedCommand)' | /usr/bin/base64 -D | /bin/sh"
        let escapedCommand = privilegedCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(
            source: "do shell script \"\(escapedCommand)\" with administrator privileges"
        ) else {
            return "无法创建管理员授权请求"
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return nil }
        let code = errorInfo[NSAppleScript.errorNumber] as? Int
        if code == -128 {
            return "已取消管理员授权，未删除需要授权的项目"
        }
        let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "未知错误"
        return "管理员授权删除失败：\(message)"
    }

    nonisolated private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func removeEverywhere(_ application: LauncherApplication) {
        entries.removeAll {
            if case .application(let item) = $0 { return item.id == application.id }
            return false
        }
        for index in entries.indices {
            if case .folder(var folder) = entries[index] {
                folder.applications.removeAll { $0.id == application.id }
                entries[index] = .folder(folder)
            }
        }
        normalizeFolders()
        save()
    }

    private func remove(application: LauncherApplication, fromFolder folderID: UUID, promoteSingleton: Bool) {
        guard let index = entries.firstIndex(where: {
            if case .folder(let folder) = $0 { return folder.id == folderID }
            return false
        }), case .folder(var folder) = entries[index] else { return }
        folder.applications.removeAll { $0.id == application.id }
        entries[index] = .folder(folder)
        if promoteSingleton { normalizeFolders() }
    }

    private func normalizeFolders() {
        entries = entries.flatMap { entry -> [LauncherEntry] in
            guard case .folder(let folder) = entry else { return [entry] }
            switch folder.applications.count {
            case 0: return []
            case 1: return [.application(folder.applications[0])]
            default: return [entry]
            }
        }
        if let openFolderID, folder(id: openFolderID) == nil { self.openFolderID = nil }
    }

    private func merge(_ discovered: [LauncherApplication]) {
        let visible = discovered.filter { !hiddenPaths.contains($0.path) }
        let byPath = Dictionary(uniqueKeysWithValues: visible.map { ($0.path, $0) })
        var represented = Set<String>()
        let persisted = load()

        entries = persisted.compactMap { entry in
            switch entry {
            case .application(let old):
                guard let fresh = byPath[old.path] else { return nil }
                represented.insert(fresh.path)
                return .application(fresh)
            case .folder(var folder):
                folder.applications = folder.applications.compactMap { old in
                    guard let fresh = byPath[old.path] else { return nil }
                    represented.insert(fresh.path)
                    return fresh
                }
                guard !folder.applications.isEmpty else { return nil }
                return folder.applications.count == 1 ? .application(folder.applications[0]) : .folder(folder)
            }
        }

        entries.append(contentsOf: visible
            .filter { !represented.contains($0.path) }
            .map(LauncherEntry.application))
        organizeDefaultFoldersIfNeeded()
        save()
    }

    private func organizeDefaultFoldersIfNeeded() {
        let installedVersion = UserDefaults.standard.integer(forKey: defaultFoldersVersionKey)
        guard installedVersion < 2 else { return }

        if installedVersion < 1 {
            organizeTopLevelApplications(into: "实用工具", matching: isDefaultUtility)
        }
        if installedVersion < 2 {
            organizeTopLevelApplications(into: "游戏", matching: isDefaultGame)
            organizeTopLevelApplications(into: "其他", matching: isDefaultOtherSystemApplication)
        }
        UserDefaults.standard.set(2, forKey: defaultFoldersVersionKey)
    }

    private func organizeTopLevelApplications(
        into folderName: String,
        matching predicate: (LauncherApplication) -> Bool
    ) {
        let matchingIDs = Set(entries.compactMap { entry -> String? in
            guard case .application(let application) = entry,
                  predicate(application) else { return nil }
            return application.id
        })
        guard matchingIDs.count > 1,
              let firstIndex = entries.firstIndex(where: { matchingIDs.contains($0.id) }) else { return }

        let applications = entries.compactMap { entry -> LauncherApplication? in
            guard case .application(let application) = entry,
                  matchingIDs.contains(application.id) else { return nil }
            return application
        }
        let insertionIndex = entries[..<firstIndex].filter { !matchingIDs.contains($0.id) }.count
        entries.removeAll { matchingIDs.contains($0.id) }
        entries.insert(.folder(LauncherFolder(
            id: UUID(),
            name: folderName,
            applications: applications,
            createdAt: Date()
        )), at: min(insertionIndex, entries.count))
    }

    private func isDefaultUtility(_ application: LauncherApplication) -> Bool {
        let path = application.path
        if path.contains("/System/Applications/Utilities/") || path.contains("/Applications/Utilities/") {
            return true
        }
        let knownUtilityBundleIDs: Set<String> = [
            "com.apple.ActivityMonitor",
            "com.apple.audio.AudioMIDISetup",
            "com.apple.BluetoothFileExchange",
            "com.apple.ColorSyncUtility",
            "com.apple.Console",
            "com.apple.DigitalColorMeter",
            "com.apple.DiskUtility",
            "com.apple.grapher",
            "com.apple.MigrationAssistant",
            "com.apple.ScriptEditor2",
            "com.apple.SystemProfiler",
            "com.apple.Terminal",
            "com.apple.VoiceOverUtility"
        ]
        return application.bundleIdentifier.map(knownUtilityBundleIDs.contains) ?? false
    }

    private func isDefaultGame(_ application: LauncherApplication) -> Bool {
        let knownGameBundleIDs: Set<String> = [
            "com.apple.Chess",
            "com.apple.GameCenter"
        ]
        if application.bundleIdentifier.map(knownGameBundleIDs.contains) == true { return true }
        guard let bundle = Bundle(url: application.url),
              let category = bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String else {
            return false
        }
        return category == "public.app-category.games"
            || category.hasSuffix("-games")
    }

    private func isDefaultOtherSystemApplication(_ application: LauncherApplication) -> Bool {
        guard application.isProtected else { return false }
        let knownOtherBundleIDs: Set<String> = [
            "com.apple.Automator",
            "com.apple.Dictionary",
            "com.apple.FontBook",
            "com.apple.Image_Capture",
            "com.apple.PhotoBooth",
            "com.apple.Stickies",
            "com.apple.VoiceMemos",
            "com.apple.appleseed.FeedbackAssistant"
        ]
        return application.bundleIdentifier.map(knownOtherBundleIDs.contains) ?? false
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func load() -> [LauncherEntry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode([LauncherEntry].self, from: data) else { return [] }
        return value
    }

    private func suggestedFolderName(for applications: [LauncherApplication]) -> String {
        let identifiers = applications.compactMap(\.bundleIdentifier)
        if identifiers.allSatisfy({ $0.hasPrefix("com.apple.") }) { return "Apple" }
        return "文件夹"
    }

    nonisolated private static func discoverApplications() -> [LauncherApplication] {
        let fileManager = FileManager.default
        var roots = ["/Applications", "/System/Applications"]
        let userApplications = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        if fileManager.fileExists(atPath: userApplications) { roots.append(userApplications) }
        var results: [String: LauncherApplication] = [:]

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isApplicationKey, .isDirectoryKey, .nameKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                enumerator.skipDescendants()
                guard let bundle = Bundle(url: url) else { continue }
                // macOS 的启动台不显示纯菜单栏应用（LSUIElement）和后台代理
                // 应用（LSBackgroundOnly），LunchPad 保持一致。注意：不做
                // Launch Services 注册检查——未注册/当前系统不支持的应用
                // （如仅支持到 macOS 26 的 Xcode）仍然展示。
                let lsuiElement = (bundle.object(forInfoDictionaryKey: "LSUIElement") as? NSNumber)?.boolValue ?? false
                let lsBackgroundOnly = (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? NSNumber)?.boolValue ?? false
                if lsuiElement || lsBackgroundOnly { continue }
                let standardizedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
                let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let protected = standardizedPath.hasPrefix("/System/")
                results[standardizedPath] = LauncherApplication(
                    name: displayName,
                    path: standardizedPath,
                    bundleIdentifier: bundle.bundleIdentifier,
                    isProtected: protected
                )
            }
        }

        return results.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private extension LauncherApplication {
    func searchScore(for rawQuery: String, alias: String) -> Int? {
        let query = rawQuery.searchNormalized
        let compactQuery = query.filter { $0.isLetter || $0.isNumber }
        let foldedName = alias.searchNormalized
        if foldedName == query { return 0 }
        if foldedName.hasPrefix(query) { return 1 }
        if foldedName.localizedStandardContains(query) { return 2 }

        let latin = alias.applyingTransform(.toLatin, reverse: false)?
            .searchNormalized ?? ""
        let compactLatin = latin.filter { $0.isLetter || $0.isNumber }
        if latin.hasPrefix(query) || compactLatin.hasPrefix(query) { return 3 }

        // StringTransform inserts word boundaries between transliterated Han
        // characters, so this covers both Chinese pinyin initials (微信 -> wx)
        // and Latin word initials (Microsoft Word -> mw).
        let initials = latin
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .compactMap(\.first)
            .map(String.init)
            .joined()
        if !compactQuery.isEmpty, initials.hasPrefix(compactQuery) { return 4 }

        let capitals = alias.filter(\.isUppercase).lowercased()
        if !compactQuery.isEmpty, !capitals.isEmpty, capitals.hasPrefix(compactQuery) { return 4 }
        if latin.contains(query) || compactLatin.contains(query) { return 5 }
        if bundleIdentifier?.localizedCaseInsensitiveContains(rawQuery) == true { return 6 }
        return nil
    }
}

private extension String {
    var searchNormalized: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct LayoutArchive: Codable {
    let entries: [LauncherEntry]
    let aliases: [String: String]
    let hiddenPaths: [String]
}

private extension Int {
    func nonzero(or fallback: Int) -> Int { self == 0 ? fallback : self }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
