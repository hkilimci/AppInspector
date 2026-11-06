import Foundation

public enum PathResolver {
    /// Resolves symlinks (e.g. /var → /private/var) for the longest existing ancestor, then appends the rest.
    /// `URL.resolvingSymlinksInPath` gives up on paths whose leaf does not exist (deleted helper, TCC client).
    public static func real(_ path: String) -> String {
        // /home and /net are automount points on macOS: probing a path under them can stall for tens of milliseconds
        // per call, and nothing the app inspects lives there.
        if path == "/home" || path == "/net" || path.hasPrefix("/home/") || path.hasPrefix("/net/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            tail.insert(url.lastPathComponent, at: 0)
            url = url.deletingLastPathComponent()
        }
        var resolved = url.resolvingSymlinksInPath().path
        for t in tail { resolved += (resolved.hasSuffix("/") ? "" : "/") + t }
        return resolved
    }
}
