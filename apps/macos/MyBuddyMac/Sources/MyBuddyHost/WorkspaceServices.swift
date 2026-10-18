import AppKit
import CoreImage
import Foundation
import MyBuddyCore
import UniformTypeIdentifiers

/// An installed application that may be opened remotely (by bundle id only — never a path or command).
public struct InstalledApp: Sendable, Identifiable, Equatable, Hashable {
    public var id: String { bundleId }
    public let bundleId: String
    public let name: String
    public let path: String
}

/// Lists and opens installed apps through NSWorkspace. No shell is ever involved.
public enum WorkspaceAppCatalog {
    static let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "\(NSHomeDirectory())/Applications"]

    public static func installedApps() -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for root in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for item in items where item.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(item)
                guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier, !seen.contains(id) else { continue }
                seen.insert(id)
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? (item as NSString).deletingPathExtension
                apps.append(InstalledApp(bundleId: id, name: name, path: path))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func search(_ query: String, in apps: [InstalledApp], limit: Int = 50) -> [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(apps.prefix(limit)) }
        let ranked = apps.compactMap { app -> (InstalledApp, Int)? in
            let name = app.name.lowercased(), lq = q.lowercased()
            if name == lq { return (app, 0) }
            if name.hasPrefix(lq) { return (app, 1) }
            if name.contains(lq) || app.bundleId.lowercased().contains(lq) { return (app, 2) }
            return nil
        }
        return ranked.sorted { ($0.1, $0.0.name) < ($1.1, $1.0.name) }.prefix(limit).map(\.0)
    }

    public static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    /// Opens an app by bundle identifier. Returns the protocol status string.
    @MainActor
    public static func open(bundleId: String) async -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return "not_found" }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            return "opened"
        } catch {
            return "failed"
        }
    }
}

/// User-granted folders, persisted as security-scoped bookmarks. Only these roots are browsable.
public final class FolderAccessStore: @unchecked Sendable {
    private let lock = NSLock()
    private let file: JSONFileStore<[GrantedFolder]>
    private var folders: [GrantedFolder]

    public init(url: URL = AppDirectories.support.appendingPathComponent("granted-folders.json"), homeDirectory: String = NSHomeDirectory()) {
        file = JSONFileStore(url: url)
        folders = (try? file.load()) ?? []
        home = homeDirectory
    }

    public var all: [GrantedFolder] { lock.withLock { folders } }

    /// Top-level folders of a shared home folder that stay private (app data, mail, messages, keychains, cookies…).
    public static let privateHomeFolders: Set<String> = ["Library"]

    private let home: String

    /// Adds a folder the user picked in an NSOpenPanel.
    @discardableResult
    public func grant(_ url: URL) throws -> GrantedFolder {
        guard PathGuard.realPath(url.path) != "/", url.path != home else {
            throw PathGuardError.invalidPath("Choose a specific folder, not the whole disk or home folder.")
        }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let folder = GrantedFolder(id: uniqueId(for: url.lastPathComponent), displayName: url.lastPathComponent, path: url.path, bookmark: bookmark)
        try mutate { $0.append(folder) }
        return folder
    }

    /// Shares the whole home folder, after the user confirmed it on the Mac. Hidden items and ~/Library stay private.
    @discardableResult
    public func grantHome() throws -> GrantedFolder {
        if let existing = all.first(where: { $0.path == home }) { return existing }
        let name = URL(fileURLWithPath: home).lastPathComponent
        let folder = GrantedFolder(id: uniqueId(for: "home"), displayName: "Home (\(name))", path: home, bookmark: nil)
        try mutate { $0.append(folder) }
        return folder
    }

    public var homeShared: Bool { all.contains { $0.path == home } }

    private func uniqueId(for name: String) -> String {
        let base = name.lowercased().filter { $0.isLetter || $0.isNumber }
        var id = base.isEmpty ? "folder" : String(base.prefix(24))
        lock.withLock {
            var n = 2
            while folders.contains(where: { $0.id == id }) { id = "\(base.prefix(20))\(n)"; n += 1 }
        }
        return id
    }

    public func revoke(id: String) throws { try mutate { $0.removeAll { $0.id == id } } }

    public func folder(id: String) -> GrantedFolder? { lock.withLock { folders.first { $0.id == id } } }

    /// Resolves a relative path inside a granted root (traversal/symlink-safe). Hidden items are never reachable (the
    /// phone never lists them either), nor are the private folders of a shared home folder.
    public func resolve(rootId: String, path: String) throws -> URL {
        guard let folder = folder(id: rootId) else { throw PathGuardError.rootUnavailable }
        let parts = path.split(separator: "/")
        if parts.contains(where: { $0.hasPrefix(".") }) { throw PathGuardError.invalidPath("Hidden items aren’t shared.") }
        if folder.path == home, let first = parts.first, Self.privateHomeFolders.contains(String(first)) {
            throw PathGuardError.invalidPath("That folder stays private.")
        }
        return try PathGuard.resolve(rootPath: folder.path, relativePath: path)
    }

    public func list(rootId: String, path: String, limit: Int = 1000) throws -> [[String: JSONValue]] {
        let dir = try resolve(rootId: rootId, path: path)
        let homeRoot = folder(id: rootId)?.path == home && path.split(separator: "/").isEmpty
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        return items.filter { !homeRoot || !Self.privateHomeFolders.contains($0.lastPathComponent) }.prefix(limit).compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), FileNameRules.isSafe(url.lastPathComponent) else { return nil }
            var entry: [String: JSONValue] = ["name": .string(url.lastPathComponent), "kind": .string(v.isDirectory == true ? "folder" : "file")]
            if let size = v.fileSize, v.isDirectory != true { entry["size"] = .int(Int64(size)) }
            if let date = v.contentModificationDate { entry["modifiedAt"] = .string(Timestamp.string(from: date)) }
            return entry
        }
    }

    /// Opens a file with its default application (re-validating containment right before opening).
    @MainActor
    public func open(rootId: String, path: String) -> String {
        guard let url = try? resolve(rootId: rootId, path: path) else { return "denied" }
        return NSWorkspace.shared.open(url) ? "opened" : "failed"
    }

    private func mutate(_ body: (inout [GrantedFolder]) -> Void) throws {
        try lock.withLock {
            var copy = folders
            body(&copy)
            try file.save(copy)
            folders = copy
        }
    }
}

/// Watches a pasteboard for changes by change count (macOS has no change notification).
public final class PasteboardMonitor: @unchecked Sendable {
    public struct Change: Sendable, Equatable {
        public let text: String
        public let types: Set<String>
        public let changeCount: Int
    }

    private let pasteboard: NSPasteboard
    private let lock = NSLock()
    private var lastChangeCount: Int
    private var ignoredChangeCount: Int?
    private var timer: Timer?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    /// Polls once; returns a change if the pasteboard holds new plain text not written by MyBuddy.
    public func poll() -> Change? {
        let count = pasteboard.changeCount
        return lock.withLock {
            guard count != lastChangeCount else { return nil }
            lastChangeCount = count
            if count == ignoredChangeCount { return nil }
            guard let text = pasteboard.string(forType: .string) else { return nil }
            let types = Set((pasteboard.types ?? []).map(\.rawValue))
            return Change(text: text, types: types, changeCount: count)
        }
    }

    /// Writes text received from the phone. The resulting change is not reported back (loop prevention).
    public func write(_ text: String) {
        lock.withLock {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            ignoredChangeCount = pasteboard.changeCount
            lastChangeCount = pasteboard.changeCount
        }
    }

    @MainActor
    public func start(interval: TimeInterval = 0.75, onChange: @escaping @Sendable (Change) -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            if let change = self?.poll() { onChange(change) }
        }
    }

    @MainActor
    public func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// Renders pairing QR codes with Core Image (no third-party dependency).
public enum QRCodeRenderer {
    public static func image(for text: String, scale: CGFloat = 10) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent)
    }

    /// Decodes a QR image (used by tests to prove the generated code is scannable).
    public static func decode(_ image: CGImage) -> String? {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: CIImage(cgImage: image)).first as? CIQRCodeFeature)?.messageString
    }
}
