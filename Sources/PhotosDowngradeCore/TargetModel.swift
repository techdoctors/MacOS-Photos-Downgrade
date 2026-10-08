import CoreData
import Foundation

/// A Photos Core Data model the downgraded library must match.
///
/// The model of the Mac the tool runs on is always available from
/// PhotoLibraryServices.framework. Models for other macOS releases come from
/// "model packs" (a folder containing photos.momd extracted from that release).
public struct TargetModel {
    public static let systemModelURL = URL(fileURLWithPath:
        "/System/Library/PrivateFrameworks/PhotoLibraryServices.framework/Versions/A/Resources/photos.momd")

    public let name: String
    public let url: URL
    public let model: NSManagedObjectModel

    public init(name: String, url: URL) throws {
        guard let model = NSManagedObjectModel(contentsOf: url) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        self.name = name
        self.url = url
        self.model = model
    }

    /// Accepts a .momd, a .mom, or a model-pack folder containing photos.momd.
    public static func resolve(_ url: URL) -> URL? {
        if ["momd", "mom"].contains(url.pathExtension.lowercased()) { return url }
        let inner = url.appendingPathComponent("photos.momd")
        return FileManager.default.fileExists(atPath: inner.path) ? inner : nil
    }

    public static func system() throws -> TargetModel {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return try TargetModel(name: "This Mac (macOS \(v.majorVersion).\(v.minorVersion))", url: systemModelURL)
    }

    /// Lets Core Data create an empty store from this model and returns its
    /// actual SQLite schema. Deriving table/column names ourselves would mean
    /// re-implementing Core Data's naming rules; this way they are exact.
    public func emptyStoreSchema(scratchDir: URL) throws -> (schema: SchemaSnapshot, storeURL: URL) {
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        let storeURL = scratchDir.appendingPathComponent("target-\(UUID().uuidString).sqlite")
        let psc = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try psc.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL,
                                               options: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]])
        try psc.remove(store)
        let schema = try SchemaSnapshot(db: SQLiteDB(path: storeURL.path, mode: .readOnly))
        return (schema, storeURL)
    }
}
