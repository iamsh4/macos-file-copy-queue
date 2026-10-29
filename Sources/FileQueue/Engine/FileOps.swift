import Foundation

enum FileOps {
    struct Tally: Equatable {
        var bytes: Int64 = 0
        var files: Int = 0
    }

    private static let tallyKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

    /// Files that Finder or network file systems may create on their own; ignored so verification stays stable.
    private static func isNoise(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._")
    }

    /// Sum of regular-file sizes plus count of non-directory entries (symlinks count as files).
    static func tally(_ url: URL, cancelled: () -> Bool = { false }) -> Tally {
        var t = Tally()
        guard let rv = try? url.resourceValues(forKeys: Set(tallyKeys)) else { return t }
        guard rv.isDirectory == true, rv.isSymbolicLink != true else {
            t.files = 1
            t.bytes = Int64(rv.fileSize ?? 0)
            return t
        }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: tallyKeys, options: [],
                                                     errorHandler: { _, _ in true }) else { return t }
        for case let child as URL in e {
            if cancelled() { break }
            if isNoise(child.lastPathComponent) { continue }
            guard let v = try? child.resourceValues(forKeys: Set(tallyKeys)) else { continue }
            if v.isRegularFile == true {
                t.files += 1
                t.bytes += Int64(v.fileSize ?? 0)
            } else if v.isDirectory != true || v.isSymbolicLink == true {
                t.files += 1
            }
        }
        return t
    }

    /// lstat-based existence check, so broken symlinks still count as "existing".
    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func isFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func isSameOrDescendant(_ child: URL, of parent: URL) -> Bool {
        let c = child.resolvingSymlinksInPath().standardizedFileURL.path
        let p = parent.resolvingSymlinksInPath().standardizedFileURL.path
        return c == p || c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { return false }
        return va.isEqual(vb)
    }

    static func isLocalVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? false
    }

    static func availableCapacity(_ url: URL) -> Int64? {
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, v > 0 {
            return v
        }
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity, v > 0 {
            return Int64(v)
        }
        return nil
    }

    /// Mount point (e.g. `/Volumes/NAS`) for paths under /Volumes, used to detect unmounted shares.
    static func mountRoot(of url: URL) -> URL? {
        let comps = url.standardizedFileURL.pathComponents
        guard comps.count >= 3, comps[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes/\(comps[2])", isDirectory: true)
    }

    /// Finder-style "name 2.ext" naming.
    static func uniqueURL(named name: String, in folder: URL, isDirectory: Bool) -> URL {
        let ns = name as NSString
        let ext = isDirectory ? "" : ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let url = folder.appendingPathComponent(candidate)
            if !exists(url) { return url }
            n += 1
        }
    }

    static func discard(_ url: URL, preferTrash: Bool) throws {
        if preferTrash {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                return
            } catch {
                // Most network volumes have no Trash; fall through to a permanent delete like Finder does.
            }
        }
        try FileManager.default.removeItem(at: url)
    }

    static func removeQuietly(_ url: URL) {
        if exists(url) { try? FileManager.default.removeItem(at: url) }
    }
}
