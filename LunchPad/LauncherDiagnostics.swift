import Foundation

/// Lightweight persistent diagnostics for presentation failures.
///
/// The log is deliberately file based (instead of only using unified logging)
/// so a user can collect it after the launcher was invoked but never became
/// visible. Writes are serialized and the file is rotated before it grows
/// beyond 2 MB.
final class LauncherDiagnostics: @unchecked Sendable {
    static let shared = LauncherDiagnostics()

    let directoryURL: URL
    let logURL: URL

    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()
    private let fileManager = FileManager.default
    private let maximumFileSize: UInt64 = 2 * 1_024 * 1_024

    private init() {
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directoryURL = library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("LunchPad", isDirectory: true)
        logURL = directoryURL.appendingPathComponent("launcher.log")
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func startSession(silently: Bool) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        record("lifecycle", "session-start version=\(version) build=\(build) silent=\(silently) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    func record(_ category: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try rotateIfNecessary(additionalBytes: UInt64(message.utf8.count + 96))
            if !fileManager.fileExists(atPath: logURL.path) {
                fileManager.createFile(atPath: logURL.path, contents: nil)
            }
            let timestamp = formatter.string(from: Date())
            let thread = Thread.isMainThread ? "main" : "background"
            let line = "\(timestamp) [\(thread)] [\(category)] \(message)\n"
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch {
            // Diagnostics must never affect launcher behavior.
        }
    }

    func readRecentText(maximumBytes: Int = 512 * 1_024) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: logURL) else { return "" }
        let suffix = data.suffix(maximumBytes)
        return String(decoding: suffix, as: UTF8.self)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? Data().write(to: logURL, options: .atomic)
    }

    private func rotateIfNecessary(additionalBytes: UInt64) throws {
        let attributes = try? fileManager.attributesOfItem(atPath: logURL.path)
        let currentSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard currentSize + additionalBytes > maximumFileSize else { return }
        let previousURL = directoryURL.appendingPathComponent("launcher.previous.log")
        try? fileManager.removeItem(at: previousURL)
        if fileManager.fileExists(atPath: logURL.path) {
            try fileManager.moveItem(at: logURL, to: previousURL)
        }
    }
}
