import Foundation

/// Makes a downgrade template from a library that is NOT empty, by copying it
/// without media and deleting all content rows from the copy. The result keeps
/// what the converter takes from a template (schema, Core Data metadata,
/// built-in albums, lookup tables) and nothing else.
///
/// A real empty library created by the older Photos is always preferable; this
/// exists for versions you can't run (e.g. from osxphotos' test libraries).
public enum TemplateMaker {
    /// Copied as empty folders; their contents are media or version caches.
    static let skippedItems: Set<String> = [
        "originals", "resources/derivatives", "resources/renders", "resources/journals", "resources/cpl",
        "database/search", "database/Photos.sqlite.lock", "Masters", "Thumbnails", "Previews",
        // Analysis/caches describe the source library's photos; Photos rebuilds them.
        "private/com.apple.photoanalysisd", "private/com.apple.mediaanalysisd", "private/com.apple.photolibraryd",
        "resources/caches", "internal",
    ]

    /// The files Photos keeps in database/ (search/ and the lock are skipped).
    static let databaseItems: Set<String> = [
        "Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm", "DataModelVersion.plist",
        "metaSchema.db", "photos.db", "protection", ".Photos_SUPPORT", "search",
    ]

    public static func make(from library: URL, to output: URL, progress: (String) -> Void = { _ in }) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: output.path])
        }
        progress("Copying library structure without photos…")
        try copyTree(from: library, to: output, relative: "")

        progress("Removing all content from the database…")
        let path = output.appendingPathComponent("database/Photos.sqlite").path
        try emptyDatabase(at: path, output: output, progress: progress)
        // Single self-contained file: templates may ship read-only inside the app.
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: path + suffix) }
    }

    private static func emptyDatabase(at path: String, output: URL, progress: (String) -> Void) throws {
        let db = try SQLiteDB(path: path, mode: .readWrite)
        _ = try db.query("PRAGMA wal_checkpoint(TRUNCATE)")
        let schema = try SchemaSnapshot(db: db)

        try db.execute("BEGIN")
        let triggers = try db.query("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND sql IS NOT NULL").compactMap { $0["sql"]?.text }
        for row in try db.query("SELECT name FROM sqlite_master WHERE type = 'trigger'") {
            try db.execute("DROP TRIGGER \(q(row["name"]!.text!))")
        }
        let keep = Downgrader.templateOwnedTables.union(["ZGENERICALBUM"])
        for table in schema.tables.values where !keep.contains(table.name) {
            if table.name.hasPrefix("Z_RT_") && table.name != "Z_RT_Asset_boundedByRect" { continue }   // R-tree shadow tables
            try db.execute("DELETE FROM \(q(table.name))")
        }
        // Built-in albums stay; user albums, folders, smart albums and import sessions go.
        let userKinds = Downgrader.userAlbumKinds.map(String.init).joined(separator: ",")
        try db.execute("DELETE FROM ZGENERICALBUM WHERE ZKIND IN (\(userKinds))")
        let albumCols = schema.tables["ZGENERICALBUM"]?.columnNames ?? []
        let cleared = albumCols.filter { $0.hasSuffix("KEYASSET") || $0.range(of: "^Z\\d+_.*KEYASSET$", options: .regularExpression) != nil }
        for c in cleared { try db.execute("UPDATE ZGENERICALBUM SET \(q(c)) = NULL") }
        for c in albumCols where c.hasPrefix("ZCACHED") && c.hasSuffix("COUNT") { try db.execute("UPDATE ZGENERICALBUM SET \(q(c)) = 0") }
        // Album-list memberships of the remaining built-in albums are kept.
        if let gaEnt = schema.entities["GenericAlbum"], let listEnt = schema.entities["AlbumList"],
           let join = schema.tables["Z_\(gaEnt)ALBUMLISTS"], join.columnNames.contains("Z_\(gaEnt)ALBUMS") {
            _ = listEnt
            try db.execute("DELETE FROM \(q(join.name)) WHERE Z_\(gaEnt)ALBUMS NOT IN (SELECT Z_PK FROM ZGENERICALBUM)")
        }
        // Templates may be shared: drop anything that identifies the Mac they came from.
        for table in ["ZMIGRATIONHISTORY", "ZGLOBALKEYVALUE"] {
            for c in schema.tables[table]?.columnNames ?? []
                where c.range(of: "DEVICE|HARDWARE|HOSTNAME|SERIAL|MACHINE", options: .regularExpression) != nil {
                try db.execute("UPDATE \(q(table)) SET \(q(c)) = NULL")
            }
        }
        for sql in triggers { try db.execute(sql) }
        try db.execute("COMMIT")
        try db.execute("VACUUM")
        _ = try db.query("PRAGMA wal_checkpoint(TRUNCATE)")
        let assets = try PhotoLibrary(url: output).summarize(db, schema: SchemaSnapshot(db: db), checkFiles: false).assetCount ?? -1
        progress("Template written to \(output.lastPathComponent) (\(assets) photos left).")
    }

    private static func copyTree(from src: URL, to dst: URL, relative: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: src.path) {
            let rel = relative.isEmpty ? name : relative + "/" + name
            let s = src.appendingPathComponent(name), d = dst.appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: s.path, isDirectory: &isDir)
            // In database/, only Photos' own files: never stray copies such as
            // Dropbox "conflicted copy" databases, which may hold real content.
            if relative == "database", !databaseItems.contains(name) { continue }
            if skippedItems.contains(rel) {
                if isDir.boolValue { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
            } else if isDir.boolValue {
                try copyTree(from: s, to: d, relative: rel)
            } else {
                try fm.copyItem(at: s, to: d)
            }
        }
    }
}
