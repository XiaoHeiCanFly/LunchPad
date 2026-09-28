import AppKit
import Foundation
import SQLite3

/// A download or install the App Store is running right now — the data behind
/// one "downloading" tile in the grid.
struct AppStoreDownload: Identifiable, Equatable {
    enum Phase: Equatable {
        case downloading
        case installing
        case unknown

        var label: String {
            switch self {
            case .downloading: "下载中"
            case .installing: "安装中"
            case .unknown: "处理中"
            }
        }
    }

    /// `app_install.pid` — stable for the whole operation.
    let pid: Int64
    /// AdamID (`item_id`) — what the App Store's log lines are keyed by.
    let itemID: Int64?
    var bundleIdentifier: String
    var name: String
    var artworkURL: URL?
    var totalBytes: Int64?
    var phase: Phase
    /// 0…1 from the live log stream; `nil` means "no percentage source", which
    /// the tile renders without a progress wedge.
    var fraction: Double?
    var icon: NSImage?
    /// The database row is gone: the tile plays its reveal animation and is
    /// removed shortly after instead of vanishing in one frame.
    var isFinished = false

    var id: Int64 { itemID ?? pid }

    /// Stable synthetic path for the display-only grid entry. It never points
    /// at a real file, so nothing can mistake it for an installed app.
    var entryID: String { "lunchpad-downloading://\(id)" }
}

/// Watches the App Store's own state for downloads in flight and reports them.
///
/// Everything here is event driven — there is no polling loop and no timer:
/// - `storeSystem.db` (+ its WAL) is watched with vnode sources, so the store
///   only reads when SQLite actually writes; reads are debounced and coalesced.
/// - `log stream` is spawned only while a download exists and torn down when
///   the last one finishes, so it costs nothing while idle.
/// - Snapshot callbacks are throttled (≥200 ms) so a 20 Hz log stream never
///   turns into a 20 Hz SwiftUI invalidation.
@MainActor
final class AppStoreDownloadMonitor {
    /// Called on the main actor with the full current set. Replacing the array
    /// keeps the UI diff trivial and makes removal (download finished) a no-op
    /// beyond one publish.
    var onSnapshot: (([AppStoreDownload]) -> Void)?

    /// One `app_install` row plus its package size.
    private struct Row: Sendable {
        let pid: Int64
        let itemID: Int64?
        let bundleIdentifier: String
        let name: String
        let phaseRaw: Int64
        let artworkURL: URL?
        let totalBytes: Int64?
    }

    private struct PendingIcon: Hashable {
        let downloadID: Int64
        let url: URL
    }

    private let directoryURL: URL
    private let databaseURL: URL

    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    private var refreshWork: DispatchWorkItem?
    private var started = false

    private var downloads: [Int64: AppStoreDownload] = [:]
    private var logFractions: [Int64: Double] = [:]
    private var pendingIcons: Set<PendingIcon> = []
    private var lastEmit: TimeInterval = 0
    private var lastSnapshot: [AppStoreDownload] = []
    private var trailingEmit: DispatchWorkItem?

    private var logProcess: Process?
    private var logHandle: FileHandle?
    private var logRemainder = Data()
    /// Cap the per-line buffer so a pathological log line cannot grow memory.
    private static let maxLogLineBytes = 64 * 1024
    /// One-shot delay between "row gone" and tile removal so the reveal
    /// animation (≈0.12 s snap + 0.55 s expand) can play first.
    private var finishedRemovalWork: DispatchWorkItem?
    private static let finishedHoldInterval: TimeInterval = 0.85

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        directoryURL = caches.appendingPathComponent("com.apple.appstoreagent", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("storeSystem.db")
    }

    deinit {
        // Sources and the child process must not outlive the monitor.
        directorySource?.cancel()
        fileSources.values.forEach { $0.cancel() }
        refreshWork?.cancel()
        if let handle = logHandle { handle.readabilityHandler = nil }
        if let process = logProcess, process.isRunning { process.terminate() }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        // No App Store activity on this machine → nothing to watch, no fds.
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        started = true
        armDirectoryWatch()
        armFileWatches()
        refresh()
    }

    func stop() {
        refreshWork?.cancel()
        refreshWork = nil
        trailingEmit?.cancel()
        trailingEmit = nil
        finishedRemovalWork?.cancel()
        finishedRemovalWork = nil
        fileSources.values.forEach { $0.cancel() }
        fileSources.removeAll()
        directorySource?.cancel()
        directorySource = nil
        stopLogStream()
        started = false
        pendingIcons.removeAll()
        if !downloads.isEmpty || !lastSnapshot.isEmpty {
            downloads.removeAll()
            logFractions.removeAll()
            lastSnapshot = []
            onSnapshot?([])
        }
    }

    // MARK: - File watching (event driven, no polling)

    /// The directory source fires when `storeSystem.db` or `-wal` is created,
    /// removed or renamed — that is how a recreated WAL gets re-armed.
    private func armDirectoryWatch() {
        guard directorySource == nil else { return }
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.armFileWatches()
                self.scheduleRefresh()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
    }

    private func armFileWatches() {
        for url in [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal")] where fileSources[url.path] == nil {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .delete, .rename],
                queue: .global(qos: .utility)
            )
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                let flags = source.data
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if flags.contains(.delete) || flags.contains(.rename) {
                        self.dropFileWatch(at: url.path)
                        self.armFileWatches()
                    }
                    self.scheduleRefresh()
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            fileSources[url.path] = source
        }
    }

    private func dropFileWatch(at path: String) {
        fileSources[path]?.cancel()
        fileSources[path] = nil
    }

    /// Coalesce a burst of writes into one read. The first event arms the
    /// window and later events join it — so a database that is written
    /// continuously still gets read at a bounded rate instead of pushing the
    /// deadline away forever. Nothing re-schedules from the result, so there
    /// is no feedback loop.
    private func scheduleRefresh() {
        guard refreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshWork = nil
                self.refresh()
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func refresh() {
        Task { [databaseURL] in
            let rows = await Task.detached(priority: .utility) {
                Self.readRows(at: databaseURL.path)
            }.value
            // A busy/missing database is "unknown", not "nothing installing" —
            // keep the current tiles rather than flickering them away.
            guard let rows else { return }
            apply(rows: rows)
        }
    }

    // MARK: - Database read

    nonisolated private static func readRows(at path: String) -> [Row]? {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let db = handle else {
            if handle != nil { sqlite3_close(handle) }
            // The store being gone means there is nothing in flight.
            return openResult == SQLITE_CANTOPEN ? [] : nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)

        let sql = """
        SELECT i.pid, i.item_id, i.bundle_id, i.bundle_name, i.phase, i.artwork_url,
               (SELECT MAX(p.bytes_total) FROM app_package p WHERE p.parent_id = i.pid)
        FROM app_install i
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let query = statement else {
            return nil
        }
        defer { sqlite3_finalize(query) }

        var rows: [Row] = []
        while sqlite3_step(query) == SQLITE_ROW {
            let pid = sqlite3_column_int64(query, 0)
            let itemID: Int64? = sqlite3_column_type(query, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(query, 1)
            let bundleIdentifier = text(at: query, 2) ?? ""
            let name = text(at: query, 3) ?? ""
            let phaseRaw = sqlite3_column_int64(query, 4)
            let artworkText = text(at: query, 5)
            let totalBytes: Int64? = sqlite3_column_type(query, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(query, 6)
            rows.append(Row(
                pid: pid,
                itemID: itemID,
                bundleIdentifier: bundleIdentifier,
                name: name.isEmpty ? bundleIdentifier : name,
                phaseRaw: phaseRaw,
                artworkURL: artworkText.flatMap(URL.init(string:)),
                totalBytes: totalBytes
            ))
        }
        return rows
    }

    nonisolated private static func text(at statement: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    // MARK: - State

    private func apply(rows newRows: [Row]) {
        // A vanished row is the completion signal: flag the tile so it can
        // play the reveal animation, then remove it after a short hold.
        let livePIDs = Set(newRows.map(\.pid))
        let becameFinished = downloads.values
            .filter { !livePIDs.contains($0.pid) && !$0.isFinished }
            .map(\.id)
        for id in becameFinished { downloads[id]?.isFinished = true }
        if !becameFinished.isEmpty { scheduleFinishedRemoval() }

        for row in newRows {
            let id: Int64 = row.itemID ?? row.pid
            let phase: AppStoreDownload.Phase
            switch row.phaseRaw {
            case 30: phase = .downloading
            case 40: phase = .installing
            default: phase = .unknown
            }
            if downloads[id] != nil {
                downloads[id]?.bundleIdentifier = row.bundleIdentifier
                downloads[id]?.name = row.name
                downloads[id]?.artworkURL = row.artworkURL
                downloads[id]?.totalBytes = row.totalBytes
                downloads[id]?.phase = phase
                // The row came back (retry): cancel a pending removal.
                downloads[id]?.isFinished = false
            } else {
                downloads[id] = AppStoreDownload(
                    pid: row.pid,
                    itemID: row.itemID,
                    bundleIdentifier: row.bundleIdentifier,
                    name: row.name,
                    artworkURL: row.artworkURL,
                    totalBytes: row.totalBytes,
                    phase: phase,
                    fraction: row.itemID.flatMap { logFractions[$0] },
                    icon: nil
                )
            }
        }

        ensureLogStream(running: !downloads.isEmpty)
        applyLogFractions()
        fetchMissingIcons()
        emit(force: true)
    }

    // MARK: - Log stream (only while a download exists)

    private func ensureLogStream(running: Bool) {
        if running {
            guard logProcess == nil else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = [
                "stream", "--style", "compact", "--info",
                "--predicate", "subsystem == \"com.apple.AppState\""
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.qualityOfService = .utility
            do {
                try process.run()
            } catch {
                // No percentage source — the tile falls back to the
                // indeterminate ring driven by the database phase alone.
                return
            }
            logProcess = process
            logRemainder = Data()
            let handle = pipe.fileHandleForReading
            logHandle = handle
            handle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.consumeLog(data)
                }
            }
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.logStreamEnded()
                }
            }
        } else {
            stopLogStream()
            // No downloads left: percentages from the finished run must not
            // leak onto the next one.
            logFractions.removeAll()
        }
    }

    private func stopLogStream() {
        logHandle?.readabilityHandler = nil
        logHandle = nil
        logRemainder = Data()
        if let process = logProcess, process.isRunning { process.terminate() }
        logProcess = nil
    }

    private func logStreamEnded() {
        logHandle?.readabilityHandler = nil
        logHandle = nil
        logRemainder = Data()
        logProcess = nil
        // Fractions go stale once the stream dies; fall back to the ring.
        guard !logFractions.isEmpty else { return }
        logFractions.removeAll()
        for id in downloads.keys {
            downloads[id]?.fraction = nil
        }
        emit(force: true)
    }

    nonisolated private static func parseProgressLine(_ line: String) -> (itemID: Int64, fraction: Double)? {
        // `ASDAppQuery.resultsDidChange 595615424: … Fraction completed: 0.1000 / Completed: 100 of 1000`
        // — emitted ~20×/s for the download in flight.
        if let marker = line.range(of: "resultsDidChange "),
           let fractionMarker = line.range(of: "Fraction completed: ") {
            let idPart = line[marker.upperBound...]
            if let colon = idPart.firstIndex(of: ":"), let itemID = Int64(idPart[..<colon]) {
                let valuePart = line[fractionMarker.upperBound...]
                let digits = valuePart.prefix(while: { $0.isNumber || $0 == "." })
                if let value = Double(digits), value >= 0, value <= 1 {
                    return (itemID, value)
                }
            }
        }
        // `AppStateMachine(id: 595615424) … fractionCompleted: 0.95 …` — state
        // transitions only, a useful fallback if the data-source lines change.
        if let idMarker = line.range(of: "AppStateMachine(id: "),
           let fractionMarker = line.range(of: "fractionCompleted: ") {
            let idPart = line[idMarker.upperBound...]
            if let end = idPart.firstIndex(where: { !$0.isNumber }), let itemID = Int64(idPart[..<end]) {
                let valuePart = line[fractionMarker.upperBound...]
                let digits = valuePart.prefix(while: { $0.isNumber || $0 == "." })
                if let value = Double(digits), value >= 0, value <= 1 {
                    return (itemID, value)
                }
            }
        }
        return nil
    }

    private func consumeLog(_ data: Data) {
        logRemainder.append(data)
        if logRemainder.count > Self.maxLogLineBytes {
            // Drop the oldest data but keep the trailing fragment — a newline
            // must still be found so the buffer cannot grow without bound.
            logRemainder.removeAll(keepingCapacity: true)
            return
        }
        var updated = false
        while let newline = logRemainder.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = logRemainder[..<newline]
            logRemainder.removeSubrange(...newline)
            let line = String(decoding: lineData, as: UTF8.self)
            if let parsed = Self.parseProgressLine(line), logFractions[parsed.itemID] != parsed.fraction {
                logFractions[parsed.itemID] = parsed.fraction
                updated = true
            }
        }
        if updated {
            applyLogFractions()
            emit()
        }
    }

    private func applyLogFractions() {
        guard !logFractions.isEmpty else { return }
        for (id, download) in downloads {
            guard let itemID = download.itemID, let fraction = logFractions[itemID] else { continue }
            if download.fraction != fraction {
                downloads[id]?.fraction = fraction
            }
        }
    }

    // MARK: - Icons

    private func fetchMissingIcons() {
        for download in downloads.values {
            guard download.icon == nil, let url = download.artworkURL else { continue }
            let pending = PendingIcon(downloadID: download.id, url: url)
            guard !pendingIcons.contains(pending) else { continue }
            pendingIcons.insert(pending)
            let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pendingIcons.remove(pending)
                    // A failed fetch is retried on the next database event —
                    // bounded by events, never by a timer.
                    guard let data, let image = NSImage(data: data),
                          var current = self.downloads[pending.downloadID],
                          current.artworkURL == pending.url else { return }
                    current.icon = image
                    self.downloads[pending.downloadID] = current
                    self.emit(force: true)
                }
            }
            task.resume()
        }
    }

    // MARK: - Publishing

    /// One-shot hold: keeps finished tiles around long enough for the tile's
    /// reveal animation to finish, then drops them. Not a repeating timer.
    private func scheduleFinishedRemoval() {
        guard finishedRemovalWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.finishedRemovalWork = nil
                let finished = self.downloads.values.filter(\.isFinished).map(\.id)
                guard !finished.isEmpty else { return }
                for id in finished { self.downloads.removeValue(forKey: id) }
                self.emit(force: true)
            }
        }
        finishedRemovalWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishedHoldInterval, execute: work)
    }

    /// Throttled: the log stream runs at ~20 Hz but SwiftUI only needs ~4 Hz,
    /// and only when the value actually moved. A trailing one-shot emit covers
    /// the case where the stream goes quiet right after a change.
    private func emit(force: Bool = false) {
        let snapshot = downloads.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        guard snapshot != lastSnapshot else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastEmit >= 0.2 else {
            scheduleTrailingEmit(after: max(0.05, 0.2 - (now - lastEmit)))
            return
        }
        lastEmit = now
        trailingEmit?.cancel()
        trailingEmit = nil
        lastSnapshot = snapshot
        onSnapshot?(snapshot)
    }

    private func scheduleTrailingEmit(after delay: TimeInterval) {
        guard trailingEmit == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trailingEmit = nil
                self.emit(force: true)
            }
        }
        trailingEmit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
