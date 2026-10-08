import Foundation

/// Dry-run comparison of a source library schema against a target model's schema.
///
/// Core Data embeds entity numbers (Z_ENT) in many-to-many join table and column
/// names, e.g. `Z_28ASSETS` / `Z_3ASSETS`. Those numbers differ between model
/// versions, so names are normalised to `Z_{EntityName}ASSETS` before comparing.
public struct SchemaDiff {
    public enum Severity: Int, Comparable {
        case info, dataLoss, blocker
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Item {
        public let severity: Severity
        public let table: String
        public let column: String?
        public let note: String
    }

    public var items: [Item] = []
    /// Normalised table name -> (source table, target table).
    public var tableMapping: [String: (source: String, target: String)] = [:]
    /// Entity name -> (source Z_ENT, target Z_ENT) for entities present in both.
    public var entityMapping: [String: (source: Int, target: Int)] = [:]

    public var hasBlockers: Bool { items.contains { $0.severity == .blocker } }

    public init(source: SchemaSnapshot, target: SchemaSnapshot) {
        let srcNorm = Self.normalizer(entities: source.entities)
        let dstNorm = Self.normalizer(entities: target.entities)

        for (name, dst) in target.entities {
            if let src = source.entities[name] { entityMapping[name] = (src, dst) }
        }
        for name in Set(source.entities.keys).subtracting(target.entities.keys).sorted() {
            items.append(Item(severity: .dataLoss, table: "Z_PRIMARYKEY", column: nil,
                              note: "Entity \(name) does not exist in target model; its objects are dropped"))
        }

        let srcTables = Dictionary(source.tables.values.map { (srcNorm($0.name), $0) }, uniquingKeysWith: { a, _ in a })
        let dstTables = Dictionary(target.tables.values.map { (dstNorm($0.name), $0) }, uniquingKeysWith: { a, _ in a })

        for key in Set(srcTables.keys).union(dstTables.keys).sorted() {
            switch (srcTables[key], dstTables[key]) {
            case let (s?, nil):
                items.append(Item(severity: .dataLoss, table: s.name, column: nil,
                                  note: "Table not in target model; contents dropped"))
            case let (nil, d?):
                items.append(Item(severity: .info, table: d.name, column: nil,
                                  note: "New (empty) table in target model"))
            case let (s?, d?):
                tableMapping[key] = (s.name, d.name)
                let sCols = Dictionary(s.columns.map { (srcNorm($0.name), $0) }, uniquingKeysWith: { a, _ in a })
                let dCols = Dictionary(d.columns.map { (dstNorm($0.name), $0) }, uniquingKeysWith: { a, _ in a })
                for c in Set(sCols.keys).subtracting(dCols.keys).sorted() {
                    items.append(Item(severity: .dataLoss, table: d.name, column: sCols[c]!.name,
                                      note: "Column not in target; values dropped"))
                }
                for c in Set(dCols.keys).subtracting(sCols.keys).sorted() {
                    let col = dCols[c]!
                    let blocking = col.notNull && !col.hasDefault && !col.primaryKey
                    items.append(Item(severity: blocking ? .blocker : .info, table: d.name, column: col.name,
                                      note: blocking ? "Target column is NOT NULL with no default; needs a fill rule"
                                                     : "New column in target; filled with NULL"))
                }
            default: break
            }
        }
    }

    /// Replaces `Z_<n>`, `Z_FOK_<n>` and `Z<n>_` entity-number prefixes with `{Name}`.
    /// Entities that were folded into another between versions. Catalina keeps
    /// assets in a `GenericAsset` hierarchy; Big Sur and later use `Asset`.
    static let entityAliases = ["GenericAsset": "Asset"]

    static func normalizer(entities: [String: Int]) -> (String) -> String {
        let byNumber = Dictionary(entities.map { ($0.value, entityAliases[$0.key] ?? $0.key) }, uniquingKeysWith: { a, _ in a })
        let regex = try! NSRegularExpression(pattern: "^Z(_FOK_|_)?(\\d+)(?=[A-Z_])")
        return { name in
            let ns = name as NSString
            guard let m = regex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
                  let n = Int(ns.substring(with: m.range(at: 2))), let entity = byNumber[n] else { return name }
            let prefix = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
            return "Z\(prefix){\(entity)}" + ns.substring(from: m.range.upperBound)
        }
    }

    public func report(limit: Int = .max) -> String {
        var out: [String] = []
        let counts = Dictionary(grouping: items, by: \.severity).mapValues(\.count)
        out.append("Entities mapped: \(entityMapping.count), tables mapped: \(tableMapping.count)")
        out.append("Blockers: \(counts[.blocker] ?? 0), data loss: \(counts[.dataLoss] ?? 0), info: \(counts[.info] ?? 0)")
        for item in items.sorted(by: { ($0.severity, $0.table) > ($1.severity, $1.table) }).prefix(limit) {
            let tag = ["INFO", "LOSS", "BLOCK"][item.severity.rawValue]
            out.append("  [\(tag)] \(item.table)\(item.column.map { ".\($0)" } ?? ""): \(item.note)")
        }
        return out.joined(separator: "\n")
    }
}
