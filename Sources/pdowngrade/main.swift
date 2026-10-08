import Foundation
import PhotosDowngradeCore

let usage = """
usage:
  pdowngrade inspect <library.photoslibrary>
  pdowngrade plan <library.photoslibrary> [--model <photos.momd|.mom> | --template <older.photoslibrary>]
  pdowngrade plan-models <source.mom[d]> <target.mom[d]>    (test without a library)
  pdowngrade downgrade <library.photoslibrary> [--to <version> | --template <older.photoslibrary>]
                                                             rebuild the database IN PLACE for an older Photos
                                                             [--allow-missing-originals] [--close-apps]
                                                             [--copy: downgrade a copy, e.g. of the System Photo Library];
                                                             default: this Mac's macOS
  pdowngrade check <library.photoslibrary>                   safety checks only (in use, space, originals)
  pdowngrade close <library.photoslibrary>                   quit Photos and whatever has the library open
  pdowngrade versions                                        list built-in target versions
  pdowngrade make-template <library.photoslibrary> <out.photoslibrary>
                                                             empty template from a library of the target version
  pdowngrade backup <library.photoslibrary>                  back up database/ next to the library
  pdowngrade backups <library.photoslibrary>                 list and verify backups
  pdowngrade restore <library.photoslibrary> <backup-id>     put a backup back

Without --model, the target is this Mac's own Photos model.
"""

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pdowngrade")

func targetModel(_ args: [String]) throws -> TargetModel {
    if let i = args.firstIndex(of: "--model"), i + 1 < args.count {
        let url = URL(fileURLWithPath: args[i + 1])
        return try TargetModel(name: url.lastPathComponent, url: url)
    }
    return try TargetModel.system()
}

func printMetadata(_ schema: SchemaSnapshot) {
    for key in schema.metadata.keys.sorted() where key != "NSStoreModelVersionHashes" {
        print("  \(key): \(schema.metadata[key]!)")
    }
}

func run() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { print(usage); exit(64) }
    let command = args.removeFirst()

    switch command {
    case "inspect":
        guard let path = args.first else { print(usage); exit(64) }
        let lib = PhotoLibrary(url: URL(fileURLWithPath: path))
        let db = try lib.open()
        let schema = try SchemaSnapshot(db: db)
        let s = lib.summarize(db, schema: schema)
        print("Library: \(lib.url.path)")
        print(PhotoLibrary.describe(s))
        print("Tables: \(s.tableCount), entities: \(s.entityCount)")
        print("Store metadata:")
        printMetadata(schema)

    case "plan":
        guard let path = args.first else { print(usage); exit(64) }
        let lib = PhotoLibrary(url: URL(fileURLWithPath: path))
        let source = try SchemaSnapshot(db: lib.open())
        if let i = args.firstIndex(of: "--template"), i + 1 < args.count {
            let tpl = PhotoLibrary(url: URL(fileURLWithPath: args[i + 1]))
            print("Target: template \(tpl.url.lastPathComponent)")
            print(SchemaDiff(source: source, target: try SchemaSnapshot(db: tpl.open())).report())
        } else {
            let target = try targetModel(args)
            let (dst, _) = try target.emptyStoreSchema(scratchDir: scratch)
            print("Target: \(target.name)")
            print(SchemaDiff(source: source, target: dst).report())
        }

    case "plan-models":
        guard args.count >= 2 else { print(usage); exit(64) }
        let src = try TargetModel(name: "source", url: URL(fileURLWithPath: args[0])).emptyStoreSchema(scratchDir: scratch).schema
        let dst = try TargetModel(name: "target", url: URL(fileURLWithPath: args[1])).emptyStoreSchema(scratchDir: scratch).schema
        print(SchemaDiff(source: src, target: dst).report(limit: 40))

    case "downgrade":
        guard let path = args.first else { print(usage); exit(64) }
        let catalog = TemplateCatalog(searchPaths: TemplateCatalog.defaultSearchPaths())
        let template: URL, targetName: String
        if let i = args.firstIndex(of: "--template"), i + 1 < args.count {
            template = URL(fileURLWithPath: args[i + 1])
            targetName = template.deletingPathExtension().lastPathComponent
        } else if let i = args.firstIndex(of: "--to"), i + 1 < args.count {
            guard let e = catalog.entry(named: args[i + 1]) else {
                print("Unknown version “\(args[i + 1])”. Run “pdowngrade versions”."); exit(64)
            }
            (template, targetName) = (e.url, e.name)
        } else if let e = catalog.forThisMac {
            print("Target: \(e.name) (this Mac)")
            (template, targetName) = (e.url, e.name)
        } else {
            print("No built-in template for \(TemplateCatalog.runningDescription). Use --to or --template."); exit(64)
        }
        var library = URL(fileURLWithPath: path)
        let closeApps = args.contains("--close-apps")
        if args.contains("--copy") {
            if closeApps { Preflight.closeEverything(holding: library) { print($0) } }
            library = try Preflight.makeCopy(of: library, for: targetName) { print($0) }
        }
        let report = try Downgrader(library: library, template: template,
                                    allowMissingOriginals: args.contains("--allow-missing-originals"),
                                    closeApps: closeApps).run { print($0) }
        print("\n" + report.summary)

    case "check":
        guard let path = args.first else { print(usage); exit(64) }
        let p = Preflight(library: URL(fileURLWithPath: path), forDowngrade: true)
        print("Database: \(ByteCountFormatter.string(fromByteCount: p.databaseBytes, countStyle: .file)), "
              + "downgrade needs \(ByteCountFormatter.string(fromByteCount: p.neededBytes, countStyle: .file)), "
              + "free \(ByteCountFormatter.string(fromByteCount: p.freeBytes, countStyle: .file))")
        print("iCloud sync state present: \(p.hasCloudSyncState ? "yes" : "no")")
        for problem in p.problems { print((problem.isBlocking ? "BLOCK: " : "WARN:  ") + (problem.errorDescription ?? "")) }
        p.cloudNotes.forEach { print("iCloud: " + $0) }
        if p.problems.isEmpty { print("OK: ready to downgrade") }

    case "close":
        guard let path = args.first else { print(usage); exit(64) }
        let remaining = Preflight.closeEverything(holding: URL(fileURLWithPath: path)) { print($0) }
        print(remaining.isEmpty ? "Nothing has the library open now."
              : "Still open in: \(remaining.joined(separator: ", ")). This is the System Photo Library; use downgrade --copy.")

    case "versions":
        let catalog = TemplateCatalog(searchPaths: TemplateCatalog.defaultSearchPaths())
        print("This Mac: \(TemplateCatalog.runningDescription)")
        for e in catalog.entries.sorted(by: { $0.order > $1.order }) {
            let key = e.url.deletingPathExtension().lastPathComponent.lowercased()
            print("  --to \(key.padding(toLength: 9, withPad: " ", startingAt: 0))  \(e.name), database \(e.modelVersion.map(String.init) ?? "?")"
                  + (e.derived ? "  (derived template)" : "") + (e.macOSMajor == TemplateCatalog.runningMajor ? "  ← this Mac" : ""))
        }
        if catalog.entries.isEmpty { print("No templates found (looked in Templates/ next to the executable and the app bundle).") }

    case "make-template":
        guard args.count >= 2 else { print(usage); exit(64) }
        try TemplateMaker.make(from: URL(fileURLWithPath: args[0]), to: URL(fileURLWithPath: args[1])) { print($0) }

    case "backup":
        guard let path = args.first else { print(usage); exit(64) }
        let lib = PhotoLibrary(url: URL(fileURLWithPath: path))
        let schema = try SchemaSnapshot(db: lib.open())
        try LibraryBackup(library: lib.url).create(
            sourceModelVersion: (schema.metadata["PLModelVersion"] as? NSNumber)?.intValue) { print($0) }

    case "backups":
        guard let path = args.first else { print(usage); exit(64) }
        let backup = LibraryBackup(library: URL(fileURLWithPath: path))
        let entries = backup.list()
        if entries.isEmpty { print("No backups in \(backup.root.path)") }
        for e in entries {
            let bad = try backup.verify(e)
            print("\(e.manifest.id)  \(e.manifest.files.count) files  " + (bad.isEmpty ? "verified OK" : "DAMAGED: \(bad.count) files"))
        }

    case "restore":
        guard args.count >= 2 else { print(usage); exit(64) }
        let backup = LibraryBackup(library: URL(fileURLWithPath: args[0]))
        guard let entry = backup.list().first(where: { $0.manifest.id == args[1] }) else {
            print("No backup named \(args[1])"); exit(1)
        }
        try backup.restore(entry) { print($0) }

    default:
        print(usage); exit(64)
    }
}

do { try run() } catch { FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!); exit(1) }
