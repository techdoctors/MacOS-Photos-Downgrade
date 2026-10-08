import CoreData
import Foundation

/// Rewrites a library's database IN PLACE into the format of an older Photos,
/// using an empty "template" library created by that older Photos.
///
/// The template supplies everything version-specific: the exact schema,
/// Core Data metadata (PLModelVersion, model hashes, cached model), migration
/// history and the built-in albums. The library supplies the content: assets,
/// resources, user albums and folders, keywords, people, faces, memories...
///
/// Photo and video files are never touched. Before anything changes, the
/// database is backed up next to the library (see `LibraryBackup`), and the
/// newer version's caches and journals are moved into that backup.
public final class Downgrader {
    public struct Report {
        public var backupID = ""
        public var sourceVersion: Int?
        public var targetVersion: Int?
        public var rowsCopied: [String: Int] = [:]
        public var droppedTables: [String] = []
        public var notes: [String] = []

        public var summary: String {
            var lines = ["Database version \(sourceVersion.map(String.init) ?? "?") → \(targetVersion.map(String.init) ?? "?")",
                         "Backup: \(backupID)"]
            let important = ["ZASSET", "ZGENERICASSET", "ZINTERNALRESOURCE", "ZGENERICALBUM", "ZKEYWORD", "ZPERSON", "ZDETECTEDFACE", "ZMOMENT", "ZMEMORY"]
            lines.append("Copied: " + important.compactMap { t in rowsCopied[t].map { "\(t.dropFirst().lowercased()) \($0)" } }.joined(separator: ", "))
            if !droppedTables.isEmpty { lines.append("Not supported by the older version (dropped): " + droppedTables.sorted().joined(separator: ", ")) }
            lines += notes.map { "• " + $0 }
            return lines.joined(separator: "\n")
        }
    }

    public enum Failure: LocalizedError {
        case notNewer(source: Int?, target: Int?), validation(String), templateNotEmpty(Int64)
        public var errorDescription: String? {
            switch self {
            case let .notNewer(s, t):
                return "The library (version \(s.map(String.init) ?? "?")) is not newer than the template (version \(t.map(String.init) ?? "?")). Nothing to downgrade."
            case let .validation(msg): return "The rebuilt database failed validation, so the library was NOT changed: \(msg)"
            case let .templateNotEmpty(n):
                return "The template library contains \(n) photos. Use an EMPTY library created by the older Photos (hold Option while opening Photos › Create New…)."
            }
        }
    }

    /// Kept from the template, never copied from the library.
    static let templateOwnedTables: Set<String> = [
        "Z_PRIMARYKEY", "Z_METADATA", "Z_MODELCACHE", "ZGLOBALKEYVALUE", "ZMIGRATIONHISTORY", "ZALBUMLIST",
        // Lookup tables (Big Sur and older); rows are added on demand by DatabaseRebuild.
        "ZUNIFORMTYPEIDENTIFIER", "ZCODEC",
    ]
    /// Core Data persistent-history tables: version-specific, emptied.
    static let historyTables: Set<String> = ["ACHANGE", "ATRANSACTION", "ATRANSACTIONSTRING"]
    /// Library items that belong to the newer version. They're moved into the backup;
    /// those the template has are replaced with the template's fresh copy.
    public static let versionSpecificItems = [
        "resources/journals", "resources/cpl", "internal",
        "private/com.apple.photolibraryd", "private/com.apple.photoanalysisd", "private/com.apple.mediaanalysisd",
    ]
    /// GenericAlbum kinds that are user content (always copied as new albums).
    static let userAlbumKinds: Set<Int64> = [2, 1505, 1506, 1507, 1508, 1509, 1510, 4000]

    let library: URL
    let template: URL
    /// Downgrade even if some originals exist only in iCloud (they stay previews).
    let allowMissingOriginals: Bool
    /// Quit Photos and anything else holding the library open, when needed.
    let closeApps: Bool
    let fm = FileManager.default

    public init(library: URL, template: URL, allowMissingOriginals: Bool = false, closeApps: Bool = false) {
        self.library = library
        self.template = template
        self.allowMissingOriginals = allowMissingOriginals
        self.closeApps = closeApps
    }

    public func run(progress: @escaping (String) -> Void = { _ in }) throws -> Report {
        var log: [String] = []
        let progress: (String) -> Void = { line in log.append(line); progress(line) }
        var report = Report()

        // 0. Safety checks: not in use, enough space, originals present.
        progress("Checking the library…")
        if closeApps {
            let remaining = Preflight.closeEverything(holding: library, progress: progress)
            if !remaining.isEmpty { throw Preflight.Problem.systemLibrary(remaining) }
        }
        let preflight = Preflight(library: library, forDowngrade: true)
        if let problem = preflight.blocking.first { throw problem }
        if !allowMissingOriginals, let problem = preflight.warnings.first { throw problem }
        report.notes += preflight.cloudNotes
        if case let .missingOriginals(n)? = preflight.warnings.first {
            report.notes.append("\(n) originals were only in iCloud; those items keep their previews only.")
        }

        // 1. Versions.
        let srcMeta = try SchemaSnapshot(db: PhotoLibrary(url: library).open()).metadata
        let tplDB = try PhotoLibrary(url: template).open()
        let tplMeta = try SchemaSnapshot(db: tplDB).metadata
        // Anything in the template would end up in the downgraded library.
        let tplAssets = (try? tplDB.scalarInt("SELECT COUNT(*) FROM ZASSET"))
            ?? (try? tplDB.scalarInt("SELECT COUNT(*) FROM ZGENERICASSET")) ?? 0
        guard tplAssets == 0 else { throw Failure.templateNotEmpty(tplAssets ?? 0) }
        report.sourceVersion = (srcMeta["PLModelVersion"] as? NSNumber)?.intValue
        report.targetVersion = (tplMeta["PLModelVersion"] as? NSNumber)?.intValue
        if let s = report.sourceVersion, let t = report.targetVersion, s <= t {
            throw Failure.notNewer(source: s, target: t)
        }

        // 2. Verified backup next to the library.
        let backups = LibraryBackup(library: library)
        let backup = try backups.create(sourceModelVersion: report.sourceVersion, progress: progress)
        report.backupID = backup.manifest.id

        // From here on, a report file is written into the backup folder either way.
        do {
            report = try rebuildAndInstall(backup: backup, backups: backups, report: report, progress: progress)
        } catch {
            log.append("❌ \(error.localizedDescription)")
            try? log.joined(separator: "\n").write(to: backup.url.appendingPathComponent("report-FAILED.txt"),
                                                   atomically: true, encoding: .utf8)
            throw error
        }
        try? (log.joined(separator: "\n") + "\n\n" + report.summary)
            .write(to: backup.url.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        return report
    }

    private func rebuildAndInstall(backup: LibraryBackup.Entry, backups: LibraryBackup, report: Report,
                                   progress: @escaping (String) -> Void) throws -> Report {
        var report = report

        // 3. Build the new database in a work folder next to the backups.
        let work = backups.root.appendingPathComponent(".work-\(backup.manifest.id)")
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work.appendingPathComponent("source"), withIntermediateDirectories: true)
        try fm.createDirectory(at: work.appendingPathComponent("new"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let srcPath = try copyDatabase(from: backup.url.appendingPathComponent("database"), to: work.appendingPathComponent("source"))
        let srcCheck = try SQLiteDB(path: srcPath, mode: .readOnly).query("PRAGMA quick_check").first?.values.first?.text ?? "?"
        guard srcCheck == "ok" else { throw Failure.validation("the library's own database is damaged (\(srcCheck)). Try Photos' Repair Library first.") }
        let newPath = try copyDatabase(from: template.appendingPathComponent("database"), to: work.appendingPathComponent("new"))

        progress("Rebuilding the database in the older format…")
        let dstModel: NSManagedObjectModel
        do {
            let db = try SQLiteDB(path: newPath, mode: .readWrite)
            let srcDB = try SQLiteDB(path: srcPath, mode: .readWrite)
            let srcModel = try ModelCache.load(from: srcDB)
            dstModel = try ModelCache.load(from: db)
            let rebuild = DatabaseRebuild(db: db, srcPath: srcPath, srcDB: srcDB, srcModel: srcModel,
                                          dstModel: dstModel, report: report)
            try rebuild.run()
            report = rebuild.report
        }

        // 4. Validate with Core Data against the older Photos' own model.
        progress("Validating the rebuilt database with Core Data…")
        try validate(storePath: newPath, model: dstModel)

        // 5. Swap into the library. Everything replaced is in the backup.
        // Re-check: something may have opened the library during the rebuild.
        var holders = Preflight.processesUsing(library: library)
        if (!holders.isEmpty || LibraryBackup.photosIsRunning()) && closeApps {
            holders = Preflight.closeEverything(holding: library, progress: progress)
        }
        if !holders.isEmpty { throw Preflight.Problem.inUse(holders) }
        if LibraryBackup.photosIsRunning() { throw Preflight.Problem.photosRunning }
        progress("Installing the rebuilt database…")
        let liveDB = library.appendingPathComponent("database")
        // All of these are in the verified backup copy of database/.
        for name in ["Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm", "Photos.sqlite.lock", "search"] {
            let live = liveDB.appendingPathComponent(name)
            if fm.fileExists(atPath: live.path) { try fm.removeItem(at: live) }
        }
        try fm.moveItem(at: URL(fileURLWithPath: newPath), to: liveDB.appendingPathComponent("Photos.sqlite"))

        progress("Moving the newer version's caches and journals into the backup…")
        let moved = try backups.moveIntoBackup(backup, items: Self.versionSpecificItems)
        for item in moved {
            let fromTemplate = template.appendingPathComponent(item)
            // Journals are not replaced: the template's describe an empty library.
            guard item != "resources/journals", fm.fileExists(atPath: fromTemplate.path) else { continue }
            try fm.copyItem(at: fromTemplate, to: library.appendingPathComponent(item))
        }
        report.notes.append("Moved into backup: " + moved.joined(separator: ", "))
        report.notes.append("Photos will rebuild its search index, journals and analysis the first time the older version opens the library.")
        progress("✅ Done.")
        return report
    }

    /// Copies Photos.sqlite (+ WAL) and folds the WAL into the main file.
    private func copyDatabase(from dir: URL, to dest: URL) throws -> String {
        for suffix in ["", "-wal", "-shm"] {
            let src = dir.appendingPathComponent("Photos.sqlite" + suffix)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: dest.appendingPathComponent("Photos.sqlite" + suffix)) }
        }
        let path = dest.appendingPathComponent("Photos.sqlite").path
        let db = try SQLiteDB(path: path, mode: .readWrite)
        _ = try db.query("PRAGMA wal_checkpoint(TRUNCATE)")
        return path
    }

    /// Opens the store exactly as Core Data would (no migration allowed) and reads
    /// every non-transformable attribute of every entity.
    func validate(storePath: String, model: NSManagedObjectModel) throws {
        let psc = NSPersistentStoreCoordinator(managedObjectModel: model)
        do {
            try psc.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: URL(fileURLWithPath: storePath),
                                       options: [NSReadOnlyPersistentStoreOption: true,
                                                 NSMigratePersistentStoresAutomaticallyOption: false,
                                                 NSInferMappingModelAutomaticallyOption: false])
        } catch {
            throw Failure.validation("Core Data refused the store: \(error.localizedDescription)")
        }
        let ctx = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        ctx.persistentStoreCoordinator = psc
        var problem: String?
        ctx.performAndWait {
            for entity in model.entities where !entity.isAbstract {
                let request = NSFetchRequest<NSDictionary>(entityName: entity.name!)
                request.resultType = .dictionaryResultType
                request.includesSubentities = false
                let attributes = entity.attributesByName.values.filter {
                    $0.attributeType != .transformableAttributeType && !$0.isTransient
                }
                request.propertiesToFetch = attributes
                do {
                    if attributes.isEmpty { _ = try ctx.count(for: request) } else { _ = try ctx.fetch(request) }
                } catch {
                    problem = "\(entity.name!): \(error.localizedDescription)"
                    return
                }
            }
        }
        if let problem { throw Failure.validation(problem) }
    }
}

// MARK: - SQL-level rebuild

final class DatabaseRebuild {
    let db: SQLiteDB
    let srcPath: String
    let srcDB: SQLiteDB
    let srcModel: NSManagedObjectModel
    let dstModel: NSManagedObjectModel
    var report: Downgrader.Report

    init(db: SQLiteDB, srcPath: String, srcDB: SQLiteDB, srcModel: NSManagedObjectModel, dstModel: NSManagedObjectModel,
         report: Downgrader.Report) {
        self.db = db
        self.srcPath = srcPath
        self.srcDB = srcDB
        self.srcModel = srcModel
        self.dstModel = dstModel
        self.report = report
    }

    func run() throws {
        let src = try SchemaSnapshot(db: srcDB)
        let dst = try SchemaSnapshot(db: db)
        try db.execute("ATTACH DATABASE '\(srcPath.replacingOccurrences(of: "'", with: "''"))' AS src")
        try db.execute("PRAGMA foreign_keys = OFF")
        try db.execute("BEGIN")

        // Triggers call Core Data-only SQL functions; drop them during the copy.
        let triggers = try db.query("SELECT sql FROM main.sqlite_master WHERE type = 'trigger' AND sql IS NOT NULL")
            .compactMap { $0["sql"]?.text }
        for row in try db.query("SELECT name FROM main.sqlite_master WHERE type = 'trigger'") {
            try db.execute("DROP TRIGGER \(q(row["name"]!.text!))")
        }
        for t in Downgrader.historyTables where dst.tables[t] != nil { try db.execute("DELETE FROM main.\(q(t))") }

        let ctx = Context(src: src, dst: dst, srcModel: srcModel, dstModel: dstModel)
        try buildPKMaps(ctx)
        try buildLookupMaps(ctx)

        // Copy entity tables, then many-to-many join tables.
        let srcNorm = SchemaDiff.normalizer(entities: src.entities)
        let srcByNorm = Dictionary(src.tables.values.map { (srcNorm($0.name), $0) }, uniquingKeysWith: { a, _ in a })
        let dstNorm = SchemaDiff.normalizer(entities: dst.entities)
        var copiedSrcTables: Set<String> = []
        for table in dst.tables.values.sorted(by: { $0.name < $1.name }) {
            let name = table.name
            if Downgrader.templateOwnedTables.contains(name) || Downgrader.historyTables.contains(name) || name.hasPrefix("Z_RT_") { continue }
            guard let s = srcByNorm[dstNorm(name)] ?? ctx.srcTableHoldingEntities(of: name) else { continue }
            copiedSrcTables.insert(s.name)
            let n: Int
            if table.columnNames.contains("Z_ENT") {
                n = try copyEntityTable(dst: table, src: s, ctx)
            } else if name.hasPrefix("Z_") {
                n = try copyJoinTable(dst: table, src: s, ctx)
            } else { continue }
            report.rowsCopied[name] = n
        }
        for t in src.tables.keys where !copiedSrcTables.contains(t) {
            let skip = Downgrader.templateOwnedTables.contains(t) || Downgrader.historyTables.contains(t) || t.hasPrefix("Z_RT_")
            if !skip, (try srcDB.scalarInt("SELECT COUNT(*) FROM \(q(t))") ?? 0) > 0 { report.droppedTables.append(t) }
        }

        try applyKeyAssets(ctx)

        // Primary-key counters, spatial index, triggers.
        for (name, ent) in dst.entities where ent < 16000 {
            guard let root = dstModel.entitiesByName[name]?.rootEntity, let table = ctx.dstTable(root) else { continue }
            try db.execute("UPDATE main.Z_PRIMARYKEY SET Z_MAX = MAX(Z_MAX, IFNULL((SELECT MAX(Z_PK) FROM main.\(q(table))), 0)) WHERE Z_ENT = \(ent)")
        }
        if dst.tables["Z_RT_Asset_boundedByRect"] != nil, dst.tables["ZASSET"]?.columnNames.isSuperset(of: ["ZLATITUDE", "ZLONGITUDE"]) == true {
            try db.execute("DELETE FROM main.Z_RT_Asset_boundedByRect")
            try db.execute("INSERT INTO main.Z_RT_Asset_boundedByRect (Z_PK, ZLATITUDE_MIN, ZLATITUDE_MAX, ZLONGITUDE_MIN, ZLONGITUDE_MAX) SELECT Z_PK, ZLATITUDE, ZLATITUDE, ZLONGITUDE, ZLONGITUDE FROM main.ZASSET")
        }
        for sql in triggers { try db.execute(sql) }
        // A fresh store identity, so libraries made from the same template don't share one.
        try db.execute("UPDATE main.Z_METADATA SET Z_UUID = '\(UUID().uuidString)'")

        try db.execute("COMMIT")
        try db.execute("DETACH DATABASE src")
        let check = try db.query("PRAGMA integrity_check").first?.values.first?.text ?? "?"
        guard check == "ok" else { throw Downgrader.Failure.validation("integrity_check: \(check)") }
        _ = try db.query("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    // MARK: Mapping context

    final class Context {
        let src: SchemaSnapshot, dst: SchemaSnapshot
        let srcModel: NSManagedObjectModel, dstModel: NSManagedObjectModel
        /// Root tables whose primary keys are renumbered (temp table `pkmap_<TABLE>`).
        var remapped: Set<String> = []
        /// source Z_ENT -> target Z_ENT for entities present in both.
        let entMap: [Int: Int]
        let dstEntName: [Int: String]

        init(src: SchemaSnapshot, dst: SchemaSnapshot, srcModel: NSManagedObjectModel, dstModel: NSManagedObjectModel) {
            self.src = src; self.dst = dst; self.srcModel = srcModel; self.dstModel = dstModel
            var m: [Int: Int] = [:]
            for (name, s) in src.entities { if let d = dst.entities[name] { m[s] = d } }
            entMap = m
            dstEntName = Dictionary(dst.entities.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        }

        func dstTable(_ root: NSEntityDescription) -> String? {
            let t = "Z" + root.name!.uppercased()
            return dst.tables[t] != nil ? t : nil
        }

        /// Root table for a target entity number (used by join-table columns).
        func dstRootTable(forEnt n: Int) -> String? {
            guard let name = dstEntName[n], let e = dstModel.entitiesByName[name] else { return nil }
            return dstTable(e.rootEntity)
        }

        /// Source root table storing any of the entities the target keeps in `dstTable`
        /// (e.g. Catalina's ZGENERICASSET holds Asset, which newer versions keep in ZASSET).
        func srcTableHoldingEntities(of dstTable: String) -> TableInfo? {
            let names = dstModel.entities.filter { self.dstTable($0.rootEntity) == dstTable }.compactMap(\.name)
            for name in names {
                guard let e = srcModel.entitiesByName[name] else { continue }
                if let t = src.tables["Z" + e.rootEntity.name!.uppercased()] { return t }
            }
            return nil
        }

        /// Source root table for an entity named in the target model.
        func srcRootTable(forEntityNamed name: String) -> String? {
            let resolved = SchemaDiff.entityAliases[name] ?? name
            guard let e = srcModel.entitiesByName[resolved] ?? srcModel.entitiesByName[name] else { return nil }
            let t = "Z" + e.rootEntity.name!.uppercased()
            return src.tables[t] != nil ? t : nil
        }

        func entCase(_ expr: String) -> String {
            guard !entMap.isEmpty else { return "NULL" }
            return "CASE \(expr) " + entMap.map { "WHEN \($0.key) THEN \($0.value)" }.joined(separator: " ") + " ELSE NULL END"
        }
    }

    // MARK: Primary-key maps

    func buildPKMaps(_ ctx: Context) throws {
        // Built-in albums: match by kind. User albums/folders: new primary keys.
        if ctx.dst.tables["ZGENERICALBUM"] != nil, ctx.src.tables["ZGENERICALBUM"] != nil {
            try createMap("ZGENERICALBUM", ctx)
            let tpl = try db.query("SELECT Z_PK, ZKIND FROM main.ZGENERICALBUM")
            var tplByKind: [Int64: [Int64]] = [:]
            for r in tpl { if let k = r["ZKIND"]?.int, let pk = r["Z_PK"]?.int { tplByKind[k, default: []].append(pk) } }
            var next = (try db.scalarInt("SELECT IFNULL(MAX(Z_PK), 0) FROM main.ZGENERICALBUM") ?? 0) + 1
            var dropped = 0
            for r in try srcDB.query("SELECT Z_PK, ZKIND FROM ZGENERICALBUM ORDER BY Z_PK") {
                guard let pk = r["Z_PK"]?.int else { continue }
                let kind = r["ZKIND"]?.int ?? -1
                if Downgrader.userAlbumKinds.contains(kind) || tplByKind[kind] == nil && kind < 1500 {
                    try db.execute("INSERT INTO temp.pkmap_ZGENERICALBUM VALUES (\(pk), \(next), 1)")
                    next += 1
                } else if let match = tplByKind[kind], match.count == 1 {
                    try db.execute("INSERT INTO temp.pkmap_ZGENERICALBUM VALUES (\(pk), \(match[0]), 0)")
                } else {
                    dropped += 1   // built-in album the older version doesn't have
                }
            }
            if dropped > 0 { report.notes.append("\(dropped) built-in album(s) that the older Photos doesn't have were skipped.") }
        }
        // Album lists (template-owned): match by identifier.
        if let s = ctx.src.tables["ZALBUMLIST"], s.columnNames.contains("ZIDENTIFIER"),
           ctx.dst.tables["ZALBUMLIST"]?.columnNames.contains("ZIDENTIFIER") == true {
            try createMap("ZALBUMLIST", ctx)
            try db.execute("""
                INSERT INTO temp.pkmap_ZALBUMLIST SELECT s.Z_PK, d.Z_PK, 0 FROM src.ZALBUMLIST s
                JOIN main.ZALBUMLIST d ON d.ZIDENTIFIER = s.ZIDENTIFIER
                """)
        }
        // Any other table the template already has rows in: append after them.
        for (name, table) in ctx.dst.tables where table.columnNames.contains("Z_ENT") && !ctx.remapped.contains(name)
            && !Downgrader.templateOwnedTables.contains(name) && ctx.src.tables[name] != nil {
            let maxPK = try db.scalarInt("SELECT IFNULL(MAX(Z_PK), 0) FROM main.\(q(name))") ?? 0
            guard maxPK > 0 else { continue }
            try createMap(name, ctx)
            try db.execute("INSERT INTO temp.\(q("pkmap_" + name)) SELECT Z_PK, Z_PK + \(maxPK), 1 FROM src.\(q(name))")
        }
    }

    private func createMap(_ table: String, _ ctx: Context) throws {
        try db.execute("CREATE TEMP TABLE \(q("pkmap_" + table)) (s INTEGER PRIMARY KEY, d INTEGER, ins INTEGER)")
        ctx.remapped.insert(table)
    }

    /// Expression mapping a source primary key of `rootTable` to the target's.
    private func mapPK(_ expr: String, _ rootTable: String?, _ ctx: Context) -> String {
        guard let rootTable, ctx.remapped.contains(rootTable) else { return expr }
        return "(SELECT d FROM temp.\(q("pkmap_" + rootTable)) WHERE s = \(expr))"
    }

    // MARK: Entity tables

    func copyEntityTable(dst: TableInfo, src: TableInfo, _ ctx: Context) throws -> Int {
        let srcNorm = SchemaDiff.normalizer(entities: ctx.src.entities)
        let dstNorm = SchemaDiff.normalizer(entities: ctx.dst.entities)
        let srcCols = Dictionary(src.columns.map { (srcNorm($0.name), $0.name) }, uniquingKeysWith: { a, _ in a })

        // Entities stored in this table, in both models.
        let dstEntities = ctx.dstModel.entities.filter { ctx.dstTable($0.rootEntity) == dst.name }
        let srcEntitiesByName = ctx.srcModel.entitiesByName

        var targets: [String] = [], exprs: [String] = []
        for col in dst.columns {
            let c = col.name
            var expr: String?
            switch c {
            case "Z_PK": expr = mapPK("s.Z_PK", dst.name, ctx)
            case "Z_ENT": expr = ctx.entCase("s.Z_ENT")
            case "Z_OPT": expr = "s.Z_OPT"
            default:
                let relation = toOneRelationship(column: c, in: dstEntities)
                var srcCol = srcCols[dstNorm(c)]
                if srcCol == nil, let (entity, rel) = relation {
                    srcCol = renamedRelationshipColumn(entity: entity, rel: rel, srcEntities: srcEntitiesByName, srcTable: src)
                    if let srcCol { report.notes.append("Renamed link \(dst.name).\(c) ← \(srcCol)") }
                }
                if srcCol == nil, let custom = customRule(table: dst.name, column: c, src: src) {
                    expr = custom
                } else if srcCol == nil, let poly = entityColumnRule(column: c, dstEntities: dstEntities, src: src, ctx) {
                    expr = poly
                } else if let srcCol {
                    if c.range(of: "^Z\\d+_", options: .regularExpression) != nil {
                        expr = ctx.entCase("s.\(q(srcCol))")      // stores an entity number
                    } else if let (_, rel) = relation, let dest = rel.destinationEntity {
                        expr = mapPK("s.\(q(srcCol))", ctx.dstTable(dest.rootEntity), ctx)
                    } else {
                        expr = "s.\(q(srcCol))"
                    }
                } else {
                    expr = defaultLiteral(column: c, entities: dstEntities)
                }
            }
            if let expr { targets.append(q(c)); exprs.append(expr) }
        }

        var filter = ["s.Z_ENT IN (\(ctx.entMap.keys.map(String.init).joined(separator: ",")))"]
        if ctx.remapped.contains(dst.name) {
            filter.append("s.Z_PK IN (SELECT s FROM temp.\(q("pkmap_" + dst.name)) WHERE ins = 1)")
        }
        try db.execute("""
            INSERT INTO main.\(q(dst.name)) (\(targets.joined(separator: ", ")))
            SELECT \(exprs.joined(separator: ", ")) FROM src.\(q(src.name)) s WHERE \(filter.joined(separator: " AND "))
            """)
        return Int(try db.scalarInt("SELECT changes()") ?? 0)
    }

    /// The target to-one relationship stored in `column`, if any.
    private func toOneRelationship(column: String, in entities: [NSEntityDescription]) -> (NSEntityDescription, NSRelationshipDescription)? {
        for e in entities {
            for (name, rel) in e.relationshipsByName where !rel.isToMany && "Z" + name.uppercased() == column {
                return (e, rel)
            }
        }
        return nil
    }

    /// A relationship renamed between versions keeps its inverse; find the source
    /// relationship with the same destination and inverse name.
    private func renamedRelationshipColumn(entity: NSEntityDescription, rel: NSRelationshipDescription,
                                           srcEntities: [String: NSEntityDescription], srcTable: TableInfo) -> String? {
        let canonical = { (name: String?) in name.map { SchemaDiff.entityAliases[$0] ?? $0 } }
        guard let srcEntity = srcEntities[entity.name!], let inverse = rel.inverseRelationship?.name,
              let dest = canonical(rel.destinationEntity?.name) else { return nil }
        let candidates = srcEntity.relationshipsByName.values.filter {
            !$0.isToMany && canonical($0.destinationEntity?.name) == dest && $0.inverseRelationship?.name == inverse
        }
        guard candidates.count == 1, let name = candidates.first?.name else { return nil }
        let col = "Z" + name.uppercased()
        return srcTable.columnNames.contains(col) ? col : nil
    }

    /// `Z<n>_<REL>` columns store the entity number of the object a to-one
    /// relationship points at; Core Data adds them when the destination is part of
    /// an inheritance hierarchy (Catalina's GenericAsset/Asset). If the source has
    /// no such column, look the entity up from the referenced row.
    private func entityColumnRule(column: String, dstEntities: [NSEntityDescription], src: TableInfo, _ ctx: Context) -> String? {
        guard let r = column.range(of: "^Z\\d+_", options: .regularExpression) else { return nil }
        let relColumn = "Z" + column[r.upperBound...]
        guard let (entity, rel) = toOneRelationship(column: relColumn, in: dstEntities),
              let dest = rel.destinationEntity?.name, let destTable = ctx.srcRootTable(forEntityNamed: dest) else { return nil }
        var fk: String? = src.columnNames.contains(relColumn) ? relColumn : nil
        if fk == nil {
            fk = renamedRelationshipColumn(entity: entity, rel: rel, srcEntities: ctx.srcModel.entitiesByName, srcTable: src)
        }
        guard let fk else { return nil }
        return "CASE WHEN s.\(q(fk)) IS NULL THEN NULL ELSE "
            + ctx.entCase("(SELECT Z_ENT FROM src.\(q(destTable)) WHERE Z_PK = s.\(q(fk)))") + " END"
    }

    /// Big Sur and older keep file types and codecs in lookup tables; newer
    /// versions store a compact code on each resource. Build code -> row maps,
    /// adding lookup rows the template doesn't have yet.
    func buildLookupMaps(_ ctx: Context) throws {
        let resources = ctx.src.tables["ZINTERNALRESOURCE"]?.columnNames ?? []
        if ctx.dst.tables["ZUNIFORMTYPEIDENTIFIER"] != nil, resources.contains("ZCOMPACTUTI"),
           let ent = ctx.dst.entities["UniformTypeIdentifier"] {
            try db.execute("CREATE TEMP TABLE uti_map (s TEXT PRIMARY KEY, d INTEGER)")
            for row in try srcDB.query("SELECT DISTINCT ZCOMPACTUTI FROM ZINTERNALRESOURCE WHERE ZCOMPACTUTI IS NOT NULL") {
                guard let code = row["ZCOMPACTUTI"]?.text ?? row["ZCOMPACTUTI"]?.int.map(String.init) else { continue }
                let identifier = CompactUTI.identifier(for: code)
                let pk = try lookupRow(table: "ZUNIFORMTYPEIDENTIFIER", keyColumn: "ZIDENTIFIER", key: identifier, ent: ent,
                                       extra: CompactUTI.conformance(of: identifier))
                try db.execute("INSERT OR REPLACE INTO temp.uti_map VALUES (\(sqlLiteral(code)), \(pk))")
            }
        }
        if ctx.dst.tables["ZCODEC"] != nil, resources.contains("ZCODECFOURCHARCODENAME"),
           let ent = ctx.dst.entities["Codec"] {
            try db.execute("CREATE TEMP TABLE codec_map (s TEXT PRIMARY KEY, d INTEGER)")
            for row in try srcDB.query("SELECT DISTINCT ZCODECFOURCHARCODENAME FROM ZINTERNALRESOURCE WHERE ZCODECFOURCHARCODENAME IS NOT NULL") {
                guard let name = row["ZCODECFOURCHARCODENAME"]?.text else { continue }
                let pk = try lookupRow(table: "ZCODEC", keyColumn: "ZFOURCHARCODENAME", key: name, ent: ent, extra: [:])
                try db.execute("INSERT OR REPLACE INTO temp.codec_map VALUES (\(sqlLiteral(name)), \(pk))")
            }
        }
    }

    /// Primary key of the lookup row with `key`, inserting it if missing.
    private func lookupRow(table: String, keyColumn: String, key: String, ent: Int, extra: [String: Int]) throws -> Int64 {
        if let pk = try db.scalarInt("SELECT Z_PK FROM main.\(q(table)) WHERE \(q(keyColumn)) = \(sqlLiteral(key))") { return pk }
        let pk = (try db.scalarInt("SELECT IFNULL(MAX(Z_PK), 0) FROM main.\(q(table))") ?? 0) + 1
        let columns = try SchemaSnapshot.columns(of: table, in: db)
        let extras = extra.filter { columns.contains($0.key) }
        try db.execute("INSERT INTO main.\(q(table)) (Z_PK, Z_ENT, Z_OPT, \(q(keyColumn))\(extras.keys.map { ", " + q($0) }.joined())) "
            + "VALUES (\(pk), \(ent), 1, \(sqlLiteral(key))\(extras.values.map { ", \($0)" }.joined()))")
        return pk
    }

    /// Value conversions that can't be inferred from the models.
    private func customRule(table: String, column: String, src: TableInfo) -> String? {
        switch (table, column) {
        case ("ZASSET", "ZHASADJUSTMENTS") where src.columnNames.contains("ZADJUSTMENTSSTATE"),
             ("ZGENERICASSET", "ZHASADJUSTMENTS") where src.columnNames.contains("ZADJUSTMENTSSTATE"):
            return "CASE WHEN IFNULL(s.ZADJUSTMENTSSTATE, 0) > 0 THEN 1 ELSE 0 END"
        case ("ZINTERNALRESOURCE", "ZUNIFORMTYPEIDENTIFIER") where src.columnNames.contains("ZCOMPACTUTI"):
            return "(SELECT d FROM temp.uti_map WHERE s = s.ZCOMPACTUTI)"
        case ("ZINTERNALRESOURCE", "ZCODEC") where src.columnNames.contains("ZCODECFOURCHARCODENAME"):
            return "(SELECT d FROM temp.codec_map WHERE s = s.ZCODECFOURCHARCODENAME)"
        default:
            return nil
        }
    }

    /// The target model's default for a column the source doesn't have.
    private func defaultLiteral(column: String, entities: [NSEntityDescription]) -> String {
        for e in entities {
            for (name, attr) in e.attributesByName where "Z" + name.uppercased() == column {
                switch attr.defaultValue {
                case let n as NSNumber: return n.stringValue
                case let s as String: return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
                case let d as Date: return String(d.timeIntervalSinceReferenceDate)
                default: return "NULL"
                }
            }
        }
        return "NULL"
    }

    // MARK: Join tables

    func copyJoinTable(dst: TableInfo, src: TableInfo, _ ctx: Context) throws -> Int {
        let srcNorm = SchemaDiff.normalizer(entities: ctx.src.entities)
        let dstNorm = SchemaDiff.normalizer(entities: ctx.dst.entities)
        var srcCols = Dictionary(src.columns.map { (srcNorm($0.name), $0.name) }, uniquingKeysWith: { a, _ in a })
        // Core Data appends "1" to one side of some join tables, and which side can
        // change between versions. Pair leftovers by name without trailing digits.
        var unmatched = dst.columns.map(\.name).filter { srcCols[dstNorm($0)] == nil }
        let stripped: (String) -> String = { $0.replacingOccurrences(of: "\\d+$", with: "", options: .regularExpression) }
        let used = Set(dst.columns.map { dstNorm($0.name) })
        for c in unmatched {
            let leftovers = srcCols.filter { !used.contains($0.key) && stripped($0.key) == stripped(dstNorm(c)) }
            if leftovers.count == 1, let pair = leftovers.first {
                srcCols[dstNorm(c)] = pair.value
                srcCols.removeValue(forKey: pair.key)
            }
        }
        unmatched = dst.columns.map(\.name).filter { srcCols[dstNorm($0)] == nil }

        var targets: [String] = [], exprs: [String] = [], keys: [String] = []
        for c in dst.columns.map(\.name) {
            guard let s = srcCols[dstNorm(c)] else { continue }
            targets.append(q(c))
            if c.hasPrefix("Z_FOK_") {
                exprs.append("s.\(q(s))")
            } else if let m = c.range(of: "^Z_(\\d+)", options: .regularExpression), let n = Int(c[m].dropFirst(2)) {
                exprs.append(mapPK("s.\(q(s))", ctx.dstRootTable(forEnt: n), ctx))
                keys.append(q(c))
            } else {
                exprs.append("s.\(q(s))")
            }
        }
        guard !keys.isEmpty, unmatched.allSatisfy({ $0.hasPrefix("Z_FOK_") }) else {
            report.droppedTables.append(src.name)
            return 0
        }
        try db.execute("""
            INSERT OR IGNORE INTO main.\(q(dst.name)) (\(targets.joined(separator: ", ")))
            SELECT * FROM (SELECT \(zip(exprs, targets).map { "\($0) AS \($1)" }.joined(separator: ", ")) FROM src.\(q(src.name)) s)
            WHERE \(keys.map { "\($0) IS NOT NULL" }.joined(separator: " AND "))
            """)
        return Int(try db.scalarInt("SELECT changes()") ?? 0)
    }

    // MARK: Special cases

    /// Newer Photos keeps album cover photos as an ordered to-many `keyAssets`;
    /// older versions have to-one keyAsset / secondaryKeyAsset / tertiaryKeyAsset.
    func applyKeyAssets(_ ctx: Context) throws {
        guard let album = ctx.dst.tables["ZGENERICALBUM"], album.columnNames.contains("ZKEYASSET"),
              let srcAlbum = ctx.srcModel.entitiesByName["GenericAlbum"], let gaEnt = ctx.src.entities["GenericAlbum"],
              let assetEnt = ctx.src.entities["Asset"],
              let rel = srcAlbum.relationshipsByName["keyAssets"], rel.isToMany else { return }
        let join = ctx.src.tables.values.first { $0.name == "Z_\(gaEnt)KEYASSETS" }
        guard let join, let albumCol = join.columns.first(where: { $0.name.hasPrefix("Z_\(gaEnt)") })?.name,
              join.columnNames.contains("Z_\(assetEnt)KEYASSETS") else { return }
        let assetCol = "Z_\(assetEnt)KEYASSETS"
        let order = join.columnNames.contains("Z_FOK_\(assetCol)") ? "Z_FOK_\(assetCol)" : "rowid"
        for (offset, column) in ["ZKEYASSET", "ZSECONDARYKEYASSET", "ZTERTIARYKEYASSET"].enumerated()
            where album.columnNames.contains(column) {
            try db.execute("""
                UPDATE main.ZGENERICALBUM SET \(column) = (
                  SELECT j.\(q(assetCol)) FROM src.\(q(join.name)) j
                  WHERE j.\(q(albumCol)) = (SELECT s FROM temp.pkmap_ZGENERICALBUM WHERE d = main.ZGENERICALBUM.Z_PK AND ins = 1)
                  ORDER BY j.\(q(order)) LIMIT 1 OFFSET \(offset))
                WHERE Z_PK IN (SELECT d FROM temp.pkmap_ZGENERICALBUM WHERE ins = 1)
                """)
        }
        // Catalina also stores the referenced entity number (Z<n>_KEYASSET).
        for column in album.columnNames where column.range(of: "^Z\\d+_(|SECONDARY|TERTIARY)KEYASSET$", options: .regularExpression) != nil {
            let fk = "Z" + column[column.range(of: "_")!.upperBound...]
            guard album.columnNames.contains(fk), let ent = ctx.dst.entities["Asset"] else { continue }
            try db.execute("UPDATE main.ZGENERICALBUM SET \(q(column)) = CASE WHEN \(q(fk)) IS NULL THEN NULL ELSE \(ent) END "
                + "WHERE Z_PK IN (SELECT d FROM temp.pkmap_ZGENERICALBUM WHERE ins = 1)")
        }
        report.droppedTables.removeAll { $0 == join.name }
        report.rowsCopied[join.name] = Int(try srcDB.scalarInt("SELECT COUNT(*) FROM \(q(join.name))") ?? 0)
        report.notes.append("Album cover photos converted from \(join.name).")
    }
}

func sqlLiteral(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }

func q(_ identifier: String) -> String { "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
