import Foundation

/// Template libraries shipped with the app, one per macOS release, and
/// detection of which one matches the Mac the app runs on.
public struct TemplateCatalog {
    public struct Entry: Hashable {
        public let macOSMajor: Int        // 10 for Catalina is stored as 1015
        public let name: String           // "macOS Ventura 13"
        public let url: URL
        public let modelVersion: Int?
        /// Built from a library that once had content (not a fresh empty one).
        public let derived: Bool
        /// Release order (10.15 sorts before 11).
        public var order: Int { macOSMajor == 1015 ? 10 : macOSMajor }
    }

    /// Folder name (without .photoslibrary) -> macOS release.
    static let known: [(folder: String, major: Int, name: String)] = [
        ("Catalina", 1015, "macOS Catalina 10.15"),
        ("BigSur", 11, "macOS Big Sur 11"),
        ("Monterey", 12, "macOS Monterey 12"),
        ("Ventura", 13, "macOS Ventura 13"),
        ("Sonoma", 14, "macOS Sonoma 14"),
        ("Sequoia", 15, "macOS Sequoia 15"),
    ]
    static let derivedFolders: Set<String> = ["Catalina", "BigSur", "Sequoia"]

    public let entries: [Entry]

    /// Loads templates from the first existing `Templates` folder in `searchPaths`.
    public init(searchPaths: [URL]) {
        let fm = FileManager.default
        guard let dir = searchPaths.first(where: { fm.fileExists(atPath: $0.path) }) else { entries = []; return }
        entries = Self.known.compactMap { item in
            let url = dir.appendingPathComponent(item.folder + ".photoslibrary")
            guard fm.fileExists(atPath: url.appendingPathComponent("database/Photos.sqlite").path) else { return nil }
            let version = (try? SchemaSnapshot(db: PhotoLibrary(url: url).open()).metadata["PLModelVersion"] as? NSNumber)?.intValue
            return Entry(macOSMajor: item.major, name: item.name, url: url, modelVersion: version,
                         derived: Self.derivedFolders.contains(item.folder))
        }
    }

    /// Default search locations: inside the app bundle, then next to the executable.
    public static func defaultSearchPaths() -> [URL] {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        return [Bundle.main.resourceURL?.appendingPathComponent("Templates"),
                exe.appendingPathComponent("Templates"),
                exe.appendingPathComponent("../Resources/Templates").standardizedFileURL,
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Templates")]
            .compactMap { $0 }
    }

    /// macOS release key of this Mac: 1015 for 10.15, otherwise the major version.
    public static var runningMajor: Int {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion == 10 ? 1000 + v.minorVersion : v.majorVersion
    }

    public static var runningDescription: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let name = known.first { $0.major == runningMajor }?.name.components(separatedBy: " ").dropLast().joined(separator: " ")
        return "\(name ?? "macOS") \(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "")"
    }

    public var forThisMac: Entry? { entries.first { $0.macOSMajor == Self.runningMajor } }

    public func entry(named key: String) -> Entry? {
        let k = key.lowercased().replacingOccurrences(of: " ", with: "")
        return entries.first { e in
            e.url.deletingPathExtension().lastPathComponent.lowercased() == k || String(e.macOSMajor) == k
                || (k == "10.15" && e.macOSMajor == 1015)
        }
    }

    /// Which macOS release wrote a library, from its database version.
    public static func macOSName(forModelVersion v: Int?) -> String {
        guard let v else { return "unknown macOS" }
        switch v / 1000 {
        case 13: return "macOS Catalina 10.15"
        case 14: return "macOS Big Sur 11"
        case 15: return "macOS Monterey 12"
        case 16: return "macOS Ventura 13"
        case 17: return "macOS Sonoma 14"
        case 18: return "macOS Sequoia 15"
        case 19...: return "a macOS newer than Sequoia"
        default: return "macOS Mojave or earlier"
        }
    }
}
