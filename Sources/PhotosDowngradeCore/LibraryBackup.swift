import AppKit
import CryptoKit
import Foundation

/// Backups of a library's database, stored NEXT TO the library (same folder,
/// same volume), never inside it: Photos' "Repair Library" may delete folders
/// it doesn't recognize inside a library bundle.
///
///     <Name>.photoslibrary
///     <Name> (Downgrade Backups)/<id>/
///         manifest.json      what was backed up, with SHA-256 of every file
///         database/          exact copy of the library's database/ folder
///
/// Photos' originals are never copied; they don't change during a downgrade.
/// On APFS the copy is a clone, so it takes no extra space until files change.
public struct LibraryBackup {
    /// Where versions before 0.2 kept backups (inside the library). Moved out automatically.
    public static let legacyFolderName = "PhotosDowngrade Backups"
    /// Folders (relative to the library) captured by a backup.
    public static let backedUpItems = ["database"]

    public struct Manifest: Codable {
        public var id: String
        public var created: Date
        public var sourceModelVersion: Int?
        public var tool = "Photos Downgrade 0.1"
        public var items: [String]
        /// Relative path (from the backup folder) -> SHA-256 hex.
        public var files: [String: String]
        public var totalBytes: Int64
        /// Library items moved (not copied) into `moved/` by a downgrade.
        public var moved: [String]? = nil
    }

    public struct Entry {
        public let url: URL
        public let manifest: Manifest
    }

    public enum Failure: LocalizedError {
        case photosRunning, notALibrary, noSpace(needed: Int64, free: Int64), verifyFailed([String]), missing(String)
        public var errorDescription: String? {
            switch self {
            case .photosRunning: return "Photos is open. Quit Photos and try again."
            case .notALibrary: return "This doesn't look like a Photos library (no database/Photos.sqlite)."
            case let .noSpace(n, f): return "Not enough free space: need \(fmt(n)), have \(fmt(f))."
            case let .verifyFailed(files): return "Backup verification failed for: " + files.prefix(5).joined(separator: ", ")
            case let .missing(p): return "Missing: \(p)"
            }
        }
    }

    public let library: URL
    public var root: URL {
        library.deletingLastPathComponent()
            .appendingPathComponent(library.deletingPathExtension().lastPathComponent + " (Downgrade Backups)")
    }
    var legacyRoot: URL { library.appendingPathComponent(Self.legacyFolderName) }

    /// Moves backups made inside the library by older versions of this app out
    /// next to it. Returns the names of the backups moved.
    @discardableResult
    public func moveLegacyBackupsOut() throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyRoot.path) else { return [] }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var moved: [String] = []
        for item in try fm.contentsOfDirectory(atPath: legacyRoot.path) {
            let dest = root.appendingPathComponent(item)
            if item.hasPrefix(".") || fm.fileExists(atPath: dest.path) { continue }
            try fm.moveItem(at: legacyRoot.appendingPathComponent(item), to: dest)
            moved.append(item)
        }
        if (try fm.contentsOfDirectory(atPath: legacyRoot.path)).allSatisfy({ $0.hasPrefix(".") }) {
            try fm.removeItem(at: legacyRoot)
        }
        return moved
    }

    public init(library: URL) { self.library = library }

    public static func photosIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Photos").isEmpty
    }

    /// Backups next to the library, plus any still inside it from older versions.
    public func list() -> [Entry] {
        let dirs = [root, legacyRoot].flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                  let m = try? Self.decoder.decode(Manifest.self, from: data) else { return nil }
            return Entry(url: dir, manifest: m)
        }.sorted { $0.manifest.created > $1.manifest.created }
    }

    /// Copies database/ into a new backup folder and verifies every file by checksum.
    @discardableResult
    public func create(sourceModelVersion: Int?, progress: (String) -> Void = { _ in }) throws -> Entry {
        let fm = FileManager.default
        guard !Self.photosIsRunning() else { throw Failure.photosRunning }
        let holders = Preflight.processesUsing(library: library)
        if !holders.isEmpty { throw Preflight.Problem.inUse(holders) }
        guard fm.fileExists(atPath: library.appendingPathComponent("database/Photos.sqlite").path) else { throw Failure.notALibrary }
        let relocated = try moveLegacyBackupsOut()
        if !relocated.isEmpty { progress("Moved \(relocated.count) older backup(s) out of the library to “\(root.lastPathComponent)”.") }

        let size = try Self.backedUpItems.reduce(Int64(0)) { $0 + (try Self.sizeOfTree(library.appendingPathComponent($1))) }
        let free = (try library.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? .max
        // Clones on APFS cost ~nothing, but require full space so a non-APFS copy can't fill the disk.
        guard free > size + 512 * 1_048_576 else { throw Failure.noSpace(needed: size, free: free) }

        let id = Self.idFormatter.string(from: Date()) + (sourceModelVersion.map { "-model\($0)" } ?? "")
        let dest = root.appendingPathComponent(id)
        let staging = root.appendingPathComponent(".incomplete-\(id)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            for item in Self.backedUpItems {
                progress("Copying \(item)/ (\(fmt(size)))…")
                try fm.copyItem(at: library.appendingPathComponent(item), to: staging.appendingPathComponent(item))
            }
            progress("Verifying backup…")
            var files: [String: String] = [:]
            var mismatched: [String] = []
            for item in Self.backedUpItems {
                for rel in try Self.files(in: staging.appendingPathComponent(item)) {
                    let path = item + "/" + rel
                    let copied = try Self.sha256(staging.appendingPathComponent(path))
                    if try Self.sha256(library.appendingPathComponent(path)) != copied { mismatched.append(path) }
                    files[path] = copied
                }
            }
            guard mismatched.isEmpty else { throw Failure.verifyFailed(mismatched) }

            let manifest = Manifest(id: id, created: Date(), sourceModelVersion: sourceModelVersion,
                                    items: Self.backedUpItems, files: files, totalBytes: size)
            try Self.encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
            try fm.moveItem(at: staging, to: dest)   // only complete, verified backups get a real name
            progress("Backup \(id) created and verified (\(files.count) files).")
            return Entry(url: dest, manifest: manifest)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Moves library items (relative paths) into `<backup>/moved/` and records them.
    @discardableResult
    public func moveIntoBackup(_ entry: Entry, items: [String]) throws -> [String] {
        let fm = FileManager.default
        var manifest = entry.manifest
        var moved = manifest.moved ?? []
        for item in items where fm.fileExists(atPath: library.appendingPathComponent(item).path) {
            let dest = entry.url.appendingPathComponent("moved").appendingPathComponent(item)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: library.appendingPathComponent(item), to: dest)
            moved.append(item)
            manifest.moved = moved
            try Self.encoder.encode(manifest).write(to: entry.url.appendingPathComponent("manifest.json"))
        }
        return moved
    }

    /// Checks a backup's files against its manifest.
    public func verify(_ entry: Entry) throws -> [String] {
        try entry.manifest.files.compactMap { rel, hash in
            let url = entry.url.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else { return rel }
            return try Self.sha256(url) == hash ? nil : rel
        }.sorted()
    }

    /// Puts a backup back. The current database/ is kept in the backup folder as
    /// `replaced-<date>/` so the restore itself can be undone.
    public func restore(_ entry: Entry, progress: (String) -> Void = { _ in }) throws {
        let fm = FileManager.default
        guard !Self.photosIsRunning() else { throw Failure.photosRunning }
        let holders = Preflight.processesUsing(library: library)
        if !holders.isEmpty { throw Preflight.Problem.inUse(holders) }
        progress("Verifying backup \(entry.manifest.id)…")
        let bad = try verify(entry)
        guard bad.isEmpty else { throw Failure.verifyFailed(bad) }

        let replaced = entry.url.appendingPathComponent("replaced-" + Self.idFormatter.string(from: Date()))
        try fm.createDirectory(at: replaced, withIntermediateDirectories: true)
        for item in entry.manifest.items {
            let live = library.appendingPathComponent(item)
            if fm.fileExists(atPath: live.path) {
                progress("Moving current \(item)/ aside…")
                try fm.moveItem(at: live, to: replaced.appendingPathComponent(item))
            }
            progress("Restoring \(item)/…")
            try fm.copyItem(at: entry.url.appendingPathComponent(item), to: live)
        }
        for item in entry.manifest.moved ?? [] {
            let live = library.appendingPathComponent(item)
            if fm.fileExists(atPath: live.path) {
                let aside = replaced.appendingPathComponent(item)
                try fm.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: live, to: aside)
            }
            progress("Restoring \(item)…")
            try fm.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: entry.url.appendingPathComponent("moved").appendingPathComponent(item), to: live)
        }
        progress("Restored backup \(entry.manifest.id). What it replaced is kept in \(replaced.lastPathComponent)/.")
    }

    // MARK: - Helpers

    static func files(in dir: URL) throws -> [String] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw Failure.missing(dir.path)
        }
        let base = dir.standardizedFileURL.path + "/"
        return e.compactMap { item in
            guard let u = item as? URL, (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            return String(u.standardizedFileURL.path.dropFirst(base.count))
        }
    }

    static func sizeOfTree(_ dir: URL) throws -> Int64 {
        try files(in: dir).reduce(Int64(0)) { sum, rel in
            let size = try dir.appendingPathComponent(rel).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return sum + Int64(size)
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { handle.readData(ofLength: 8 * 1_048_576) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

func fmt(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
