import Compression
import CoreData
import Foundation

/// Every Core Data SQLite store caches the exact model it was created with in
/// `Z_MODELCACHE` (a raw-deflate compressed keyed archive). Reading it gives
/// the precise schema of *that* library's Photos version, with no need for the
/// framework from that macOS release.
public enum ModelCache {
    public static func load(from db: SQLiteDB) throws -> NSManagedObjectModel {
        guard let blob = try db.query("SELECT Z_CONTENT FROM Z_MODELCACHE LIMIT 1").first?["Z_CONTENT"]?.blob else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Database has no Z_MODELCACHE"])
        }
        if let model = unarchive(blob) { return model }
        for capacity in [16, 64, 256].map({ $0 * 1_048_576 }) {
            var out = Data(count: capacity)
            let n = out.withUnsafeMutableBytes { o in
                blob.withUnsafeBytes { i in
                    compression_decode_buffer(o.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              i.bindMemory(to: UInt8.self).baseAddress!, blob.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0, n < capacity, let model = unarchive(out.prefix(n)) { return model }
        }
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Could not decode Z_MODELCACHE"])
    }

    private static func unarchive(_ data: Data) -> NSManagedObjectModel? {
        if let m = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSManagedObjectModel.self, from: data) { return m }
        return (try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data)) as? NSManagedObjectModel
    }
}

extension NSEntityDescription {
    var rootEntity: NSEntityDescription {
        var e = self
        while let s = e.superentity { e = s }
        return e
    }
}
