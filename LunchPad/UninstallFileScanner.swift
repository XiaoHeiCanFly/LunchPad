import Foundation

struct UninstallFileCandidate: Identifiable, Hashable, Sendable {
    var id: String { url.standardizedFileURL.path }
    let url: URL
    let size: Int64
    let isDirectory: Bool

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct UninstallFileGroup: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let files: [UninstallFileCandidate]

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file)
    }
}

enum UninstallFileScanner {
    static func scan(for application: LauncherApplication) async -> [UninstallFileGroup] {
        await Task.detached(priority: .userInitiated) {
            scanSynchronously(for: application)
        }.value
    }

    nonisolated private static func scanSynchronously(
        for application: LauncherApplication
    ) -> [UninstallFileGroup] {
        guard let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty else { return [] }
        let fileManager = FileManager.default
        let library = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        let appName = URL(fileURLWithPath: application.path).deletingPathExtension().lastPathComponent
        let pathsByGroup: [(String, [URL])] = [
            ("应用支持", exactPaths(in: library.appendingPathComponent("Application Support"), names: [bundleIdentifier, appName])),
            ("缓存", exactAndPrefixedPaths(in: library.appendingPathComponent("Caches"), names: [bundleIdentifier, appName])),
            ("偏好设置", exactAndPrefixedPaths(in: library.appendingPathComponent("Preferences"), names: ["\(bundleIdentifier).plist", bundleIdentifier])),
            ("沙盒容器", exactPaths(in: library.appendingPathComponent("Containers"), names: [bundleIdentifier])),
            ("应用脚本", exactPaths(in: library.appendingPathComponent("Application Scripts"), names: [bundleIdentifier])),
            ("保存的窗口状态", exactPaths(in: library.appendingPathComponent("Saved Application State"), names: ["\(bundleIdentifier).savedState"])),
            ("WebKit 数据", exactPaths(in: library.appendingPathComponent("WebKit"), names: [bundleIdentifier])),
            ("网络缓存", exactAndPrefixedPaths(in: library.appendingPathComponent("HTTPStorages"), names: [bundleIdentifier])),
            ("Cookie", exactAndPrefixedPaths(in: library.appendingPathComponent("Cookies"), names: [bundleIdentifier])),
            ("日志", exactAndPrefixedPaths(in: library.appendingPathComponent("Logs"), names: [bundleIdentifier, appName])),
            ("登录代理", exactAndPrefixedPaths(in: library.appendingPathComponent("LaunchAgents"), names: [bundleIdentifier]))
        ]

        var representedPaths = Set<String>()
        return pathsByGroup.compactMap { groupName, urls in
            let files = urls.compactMap { url -> UninstallFileCandidate? in
                let standardizedURL = url.standardizedFileURL
                guard representedPaths.insert(standardizedURL.path).inserted,
                      standardizedURL.path.hasPrefix(library.path + "/"),
                      fileManager.fileExists(atPath: standardizedURL.path) else { return nil }
                let values = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey])
                return UninstallFileCandidate(
                    url: standardizedURL,
                    size: allocatedSize(of: standardizedURL),
                    isDirectory: values?.isDirectory == true
                )
            }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
            return files.isEmpty ? nil : UninstallFileGroup(name: groupName, files: files)
        }
    }

    nonisolated private static func exactPaths(in directory: URL, names: [String]) -> [URL] {
        names.map { directory.appendingPathComponent($0) }
    }

    nonisolated private static func exactAndPrefixedPaths(in directory: URL, names: [String]) -> [URL] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return exactPaths(in: directory, names: names) }
        return contents.filter { url in
            names.contains { name in
                url.lastPathComponent == name
                    || url.lastPathComponent.hasPrefix(name + ".")
                    || url.lastPathComponent.hasPrefix(name + "-")
            }
        }
    }

    nonisolated private static func allocatedSize(of url: URL) -> Int64 {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
