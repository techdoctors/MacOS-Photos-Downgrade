import AppKit
import Foundation

/// Checks run before anything touches a library, plus the tools to fix the
/// common ones: closing whatever has the library open, or working on a copy.
public struct Preflight {
    public enum Problem: LocalizedError {
        case photosRunning
        case inUse([String])
        /// Still open after closing everything: macOS reopens the System Photo Library.
        case systemLibrary([String])
        case noSpace(needed: Int64, free: Int64)
        case missingOriginals(Int)

        public var errorDescription: String? {
            switch self {
            case .photosRunning:
                return "Photos is open."
            case let .inUse(processes):
                return "The library is open in: \(processes.joined(separator: ", "))."
            case let .systemLibrary(processes):
                return "This is the System Photo Library. macOS reopens it right away (\(processes.joined(separator: ", "))), so it can't be changed in place. Downgrade a copy of it instead."
            case let .noSpace(needed, free):
                return "Not enough free space next to the library: need \(fmt(needed)), have \(fmt(free))."
            case let .missingOriginals(n):
                return "\(n) original \(n == 1 ? "photo/video is" : "photos/videos are") not on this Mac (iCloud “Optimize Mac Storage”). Download them first (Photos › Settings › iCloud › Download Originals to this Mac), or downgrade anyway and keep previews only for those items."
            }
        }

        /// Problems that can't be overridden.
        public var isBlocking: Bool {
            if case .missingOriginals = self { return false }
            return true
        }

        /// Fixed by closing apps and processes.
        public var isClosable: Bool {
            switch self {
            case .photosRunning, .inUse: return true
            default: return false
            }
        }
    }

    public struct Holder: Hashable {
        public let pid: pid_t
        public let name: String
    }

    public let library: URL
    public var problems: [Problem] = []
    public var summary: PhotoLibrary.Summary?
    public var databaseBytes: Int64 = 0
    public var neededBytes: Int64 = 0
    public var freeBytes: Int64 = 0
    /// Library still carries iCloud Photos sync state (resources/cpl).
    public var hasCloudSyncState = false

    public var blocking: [Problem] { problems.filter(\.isBlocking) }
    public var warnings: [Problem] { problems.filter { !$0.isBlocking } }
    /// Every blocking problem is fixed by `closeEverything`.
    public var onlyNeedsClosing: Bool { !blocking.isEmpty && blocking.allSatisfy(\.isClosable) }

    /// Apps and processes to close, for the confirmation dialog.
    public var holderNames: [String] {
        var names = Self.holders(of: library).map(\.name)
        if LibraryBackup.photosIsRunning() { names.insert("Photos", at: 0) }
        return Array(NSOrderedSet(array: names)) as? [String] ?? names
    }

    /// - Parameter forDowngrade: also checks space for a rebuild and missing originals.
    public init(library: URL, forDowngrade: Bool) {
        self.library = library
        if LibraryBackup.photosIsRunning() { problems.append(.photosRunning) }
        let holders = Self.holders(of: library).map(\.name)
        if !holders.isEmpty { problems.append(.inUse(Array(Set(holders)).sorted())) }

        let db = library.appendingPathComponent("database")
        databaseBytes = (try? LibraryBackup.sizeOfTree(db)) ?? 0
        // Backup + working copy of the source + the new database, plus headroom.
        neededBytes = databaseBytes * (forDowngrade ? 3 : 1) + 512 * 1_048_576
        freeBytes = Self.freeSpace(near: library)
        if freeBytes < neededBytes { problems.append(.noSpace(needed: neededBytes, free: freeBytes)) }

        let cpl = library.appendingPathComponent("resources/cpl")
        hasCloudSyncState = ((try? LibraryBackup.sizeOfTree(cpl)) ?? 0) > 0

        guard forDowngrade else { return }
        let lib = PhotoLibrary(url: library)
        if let handle = try? lib.open(), let schema = try? SchemaSnapshot(db: handle) {
            summary = lib.summarize(handle, schema: schema)
            if let missing = summary?.missingOriginals.count, missing > 0 { problems.append(.missingOriginals(missing)) }
        }
    }

    /// iCloud guidance for libraries that have been synced with iCloud Photos.
    public var cloudNotes: [String] {
        guard let ids = summary?.cloudIDCount, ids > 0 else { return [] }
        return [
            "\(ids) items have iCloud Photos IDs. They are kept: if this library is ever turned on for iCloud Photos, Photos uses them to match photos already in iCloud instead of uploading duplicates.",
            "iCloud sync state was moved into the backup, so Photos treats the library like one restored from a backup: turning on iCloud Photos starts a full merge, not a continuation.",
            "For iCloud Photos on the older Mac, the cleanest route is a NEW empty System Photo Library that downloads from iCloud; use this library as a local library.",
        ]
    }

    static func freeSpace(near url: URL) -> Int64 {
        (try? url.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? .max
    }

    // MARK: - Closing whatever has the library open

    /// Never terminated, even if they show up as holding the library.
    static let protectedProcesses: Set<String> = [
        "launchd", "loginwindow", "WindowServer", "Finder", "Dock", "SystemUIServer", "kernel_task", "PhotosDowngrade",
    ]

    /// Quits Photos and every process holding the library's database open.
    /// Apps are asked to quit normally first (so they can save), background
    /// processes get SIGTERM; anything still running after `timeout` is forced.
    /// Returns the processes holding the library afterwards (empty = success).
    @discardableResult
    public static func closeEverything(holding library: URL, timeout: TimeInterval = 15,
                                       progress: (String) -> Void = { _ in }) -> [String] {
        var targets: [pid_t: String] = [:]
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Photos") {
            targets[app.processIdentifier] = "Photos"
        }
        for h in holders(of: library) where !protectedProcesses.contains(h.name) { targets[h.pid] = h.name }
        guard !targets.isEmpty else { return [] }

        progress("Closing: " + Set(targets.values).sorted().joined(separator: ", ") + "…")
        for (pid, _) in targets {
            if let app = NSRunningApplication(processIdentifier: pid) { app.terminate() } else { kill(pid, SIGTERM) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, targets.keys.contains(where: isAlive) { Thread.sleep(forTimeInterval: 0.5) }
        for pid in targets.keys where isAlive(pid) {
            progress("Force-quitting \(targets[pid]!)…")
            if let app = NSRunningApplication(processIdentifier: pid) { app.forceTerminate() } else { kill(pid, SIGKILL) }
        }
        // Give launchd-managed services a moment; if they reopen the library, it's the System Photo Library.
        Thread.sleep(forTimeInterval: 2)
        return Array(Set(holders(of: library).map(\.name))).sorted()
    }

    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    // MARK: - Working on a copy

    /// Copies the library next to itself, named for the target macOS. On APFS the
    /// copy is a clone: instant, and it takes no extra space until files change.
    public static func makeCopy(of library: URL, for targetName: String, progress: (String) -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        let base = library.deletingPathExtension().lastPathComponent + " (\(targetName))"
        var dest = library.deletingLastPathComponent().appendingPathComponent(base + ".photoslibrary")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = library.deletingLastPathComponent().appendingPathComponent("\(base) \(n).photoslibrary")
            n += 1
        }
        let clones = (try? library.deletingLastPathComponent().resourceValues(forKeys: [.volumeSupportsFileCloningKey])
            .volumeSupportsFileCloning) ?? false
        if !clones {
            let size = try LibraryBackup.sizeOfTree(library)
            let free = freeSpace(near: library)
            guard free > size + 1_073_741_824 else { throw Problem.noSpace(needed: size, free: free) }
        }
        progress(clones ? "Making a copy of the library (instant on this drive)…"
                        : "Copying the whole library (this drive can't make instant copies; this may take a while)…")
        try fm.copyItem(at: library, to: dest)   // clonefile() on APFS
        // Never carry backups or a lock from the original into the copy.
        try? fm.removeItem(at: dest.appendingPathComponent(LibraryBackup.legacyFolderName))
        try? fm.removeItem(at: dest.appendingPathComponent("database/Photos.sqlite.lock"))
        progress("Copy created: \(dest.lastPathComponent)")
        return dest
    }

    // MARK: - Who has the library open

    /// Processes (other than this one) holding the library's database files open.
    public static func holders(of library: URL) -> [Holder] {
        let db = library.appendingPathComponent("database")
        let files = ["Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm"].map { db.appendingPathComponent($0).path }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-F", "pc", "--"] + files
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()

        let me = ProcessInfo.processInfo.processIdentifier
        var result: [Holder] = []
        var pid: pid_t = 0
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") { pid = pid_t(line.dropFirst()) ?? 0 }
            if line.hasPrefix("c"), pid != me, pid > 0 { result.append(Holder(pid: pid, name: String(line.dropFirst()))) }
        }
        return Array(Set(result))
    }

    /// Names only (kept for callers that just report).
    public static func processesUsing(library: URL) -> [String] {
        Array(Set(holders(of: library).map(\.name))).sorted()
    }
}
