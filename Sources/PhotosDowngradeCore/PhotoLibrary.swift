import Foundation

/// Read-only view of a .photoslibrary bundle.
public struct PhotoLibrary {
    public let url: URL
    public var databaseURL: URL { url.appendingPathComponent("database/Photos.sqlite") }

    public init(url: URL) { self.url = url }

    /// Default location of the System Photo Library.
    public static let defaultLibraryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Photos Library.photoslibrary")

    /// Returns the enclosing `.photoslibrary` for a URL (the bundle itself or
    /// anything inside it, e.g. its `database` folder), or nil.
    public static func resolve(_ url: URL) -> URL? {
        var u = url.standardizedFileURL
        while u.path != "/" {
            if u.pathExtension.lowercased() == "photoslibrary" { return u }
            u.deleteLastPathComponent()
        }
        return nil
    }

    /// Opens the database without modifying the library. If Photos left changes in
    /// the write-ahead log (-wal), an immutable open would not see them, so a scratch
    /// copy is opened instead and the log merged there.
    public func open() throws -> SQLiteDB {
        let fm = FileManager.default
        let wal = databaseURL.path + "-wal"
        let walSize = (try? fm.attributesOfItem(atPath: wal)[.size] as? Int64) ?? 0
        guard walSize > 0 else { return try SQLiteDB(path: databaseURL.path, mode: .immutable) }
        let scratch = fm.temporaryDirectory.appendingPathComponent("pdowngrade-read-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: databaseURL.path + suffix) {
            try fm.copyItem(atPath: databaseURL.path + suffix, toPath: scratch.appendingPathComponent("Photos.sqlite" + suffix).path)
        }
        let db = try SQLiteDB(path: scratch.appendingPathComponent("Photos.sqlite").path, mode: .readWrite)
        _ = try db.query("PRAGMA wal_checkpoint(TRUNCATE)")
        return db
    }

    public struct Summary {
        public var modelVersion: Int?
        public var entityCount: Int
        public var tableCount: Int
        public var assetCount: Int64?
        /// In "Recently Deleted".
        public var trashedCount: Int64?
        /// "Referenced" files that live outside the library (not copied into it).
        public var referencedCount: Int64?
        /// Assets whose original file was looked for inside the library.
        public var originalsChecked = 0
        /// Assets whose original file is not in the library bundle (checked on disk,
        /// not trusted from database flags). Excludes trashed and referenced items.
        public var missingOriginals: [String] = []
        /// Assets carrying an iCloud Photos identifier. This is history, not status:
        /// IDs remain after iCloud is turned off and arrive with photos from iCloud devices.
        public var cloudIDCount: Int64?
    }

    public func summarize(_ db: SQLiteDB, schema: SchemaSnapshot, checkFiles: Bool = true) -> Summary {
        // macOS 10.15–12 used ZGENERICASSET; 13+ uses ZASSET.
        let assetTable = schema.tables["ZASSET"] != nil ? "ZASSET" : "ZGENERICASSET"
        let cols = schema.tables[assetTable]?.columnNames ?? []

        var s = Summary(modelVersion: (schema.metadata["PLModelVersion"] as? NSNumber)?.intValue,
                        entityCount: schema.entities.count,
                        tableCount: schema.tables.count)
        s.assetCount = try? db.scalarInt("SELECT COUNT(*) FROM \(assetTable)")
        if cols.contains("ZTRASHEDSTATE") {
            s.trashedCount = try? db.scalarInt("SELECT COUNT(*) FROM \(assetTable) WHERE ZTRASHEDSTATE = 1")
        }
        // ZSAVEDASSETTYPE 10 = referenced file (same rule osxphotos uses).
        if cols.contains("ZSAVEDASSETTYPE") {
            s.referencedCount = try? db.scalarInt("SELECT COUNT(*) FROM \(assetTable) WHERE ZSAVEDASSETTYPE = 10")
        }
        if cols.contains("ZCLOUDASSETGUID") {
            s.cloudIDCount = try? db.scalarInt("SELECT COUNT(*) FROM \(assetTable) WHERE ZCLOUDASSETGUID IS NOT NULL")
        }

        guard checkFiles, cols.isSuperset(of: ["ZDIRECTORY", "ZFILENAME"]) else { return s }
        var filters: [String] = []
        if cols.contains("ZTRASHEDSTATE") { filters.append("COALESCE(ZTRASHEDSTATE, 0) != 1") }
        if cols.contains("ZSAVEDASSETTYPE") { filters.append("COALESCE(ZSAVEDASSETTYPE, 0) != 10") }
        let sql = "SELECT ZDIRECTORY, ZFILENAME FROM \(assetTable)"
            + (filters.isEmpty ? "" : " WHERE " + filters.joined(separator: " AND "))
        // macOS 10.15+ stores originals in originals/<dir>/<file>; older libraries used Masters/.
        let roots = ["originals", "Masters"].map { url.appendingPathComponent($0) }
        let fm = FileManager.default
        for row in (try? db.query(sql)) ?? [] {
            guard let dir = row["ZDIRECTORY"]?.text, let file = row["ZFILENAME"]?.text else { continue }
            s.originalsChecked += 1
            let found = roots.contains { fm.fileExists(atPath: $0.appendingPathComponent(dir).appendingPathComponent(file).path) }
            if !found { s.missingOriginals.append("\(dir)/\(file)") }
        }
        return s
    }

    /// Human-readable summary shared by the CLI and the app.
    public static func describe(_ s: Summary) -> String {
        func n(_ v: Int64?) -> String { v.map(String.init) ?? "?" }
        var lines = [
            "Library database version (PLModelVersion): \(s.modelVersion.map(String.init) ?? "unknown")",
            "Photos & videos: \(n(s.assetCount))   in Recently Deleted: \(n(s.trashedCount))   referenced (outside library): \(n(s.referencedCount))",
        ]
        if s.originalsChecked > 0 {
            lines.append(s.missingOriginals.isEmpty
                ? "Original files: all \(s.originalsChecked) present on disk ✅"
                : "Original files: \(s.missingOriginals.count) of \(s.originalsChecked) NOT found on disk, e.g. "
                  + s.missingOriginals.prefix(3).joined(separator: ", "))
        }
        if let ids = s.cloudIDCount, ids > 0 {
            lines.append("iCloud IDs on \(ids) items: history only (synced at some point or came from an iCloud device). Doesn't mean this library is connected to iCloud now.")
        }
        return lines.joined(separator: "\n")
    }
}
