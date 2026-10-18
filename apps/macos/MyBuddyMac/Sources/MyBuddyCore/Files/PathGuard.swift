import Darwin
import Foundation

/// A folder the user explicitly granted on the Mac. Files are only ever resolved inside one.
public struct GrantedFolder: Codable, Sendable, Identifiable, Equatable {
    public let id: String          // rootId sent over the protocol (never a path)
    public var displayName: String
    public var path: String        // absolute path on this Mac (never sent to the phone)
    public var bookmark: Data?     // security-scoped bookmark (Host module)

    public init(id: String, displayName: String, path: String, bookmark: Data? = nil) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.bookmark = bookmark
    }
}

public enum PathGuardError: Error, Equatable, Sendable {
    case invalidPath(String)
    case outsideRoot
    case notFound
    case rootUnavailable
}

/// Resolves phone-supplied relative paths inside a granted root, rejecting traversal,
/// absolute paths, NUL bytes and symlink escapes (docs/PROTOCOL.md §8).
public enum PathGuard {
    public static let maxPathBytes = 1024

    /// Lexical validation. Returns the path components ("" means the root itself).
    public static func components(of relativePath: String) throws(PathGuardError) -> [String] {
        guard relativePath.utf8.count <= maxPathBytes else { throw .invalidPath("too long") }
        guard !relativePath.unicodeScalars.contains("\u{0}") else { throw .invalidPath("NUL byte") }
        if relativePath.isEmpty { return [] }
        guard !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else { throw .invalidPath("absolute path") }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            guard !part.isEmpty else { throw .invalidPath("empty segment") }
            guard part != ".", part != ".." else { throw .invalidPath("dot segment") }
        }
        return parts
    }

    /// realpath(3): resolves every symlink; fails for paths that do not exist.
    public static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Resolves `relativePath` inside `rootPath` and returns the real, contained path.
    public static func resolve(rootPath: String, relativePath: String) throws(PathGuardError) -> URL {
        let parts = try components(of: relativePath)
        guard let root = realPath(rootPath) else { throw .rootUnavailable }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { throw .rootUnavailable }
        let candidate = parts.reduce(URL(fileURLWithPath: root, isDirectory: true)) { $0.appendingPathComponent($1) }
        guard let resolved = realPath(candidate.path) else { throw .notFound }
        guard isContained(resolved, in: root) else { throw .outsideRoot }
        return URL(fileURLWithPath: resolved)
    }

    public static func isContained(_ path: String, in root: String) -> Bool {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        return path == base || path.hasPrefix(base + "/") || base.isEmpty
    }
}
