import AppKit
import PhotosDowngradeCore
import SwiftUI

// AppKit entry point (not SwiftUI's App protocol) so the app runs on macOS 10.15.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Photos Downgrade"
        window.contentView = NSHostingView(rootView: ContentView(model: model).frame(minWidth: 700, minHeight: 560))
        window.center()
        window.setFrameAutosaveName("Main")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
appMenuItem.submenu = NSMenu()
appMenuItem.submenu?.addItem(withTitle: "Quit Photos Downgrade", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let editItem = NSMenuItem()
mainMenu.addItem(editItem)
editItem.submenu = NSMenu(title: "Edit")
editItem.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editItem.submenu?.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
app.mainMenu = mainMenu
app.run()

/// Open-panel filter that enables only items `accept` returns true for, while
/// still letting the user navigate into ordinary folders. Matching by name
/// instead of content types matters on older macOS, where the `.photoslibrary`
/// type may not resolve and every library shows greyed out.
final class PanelFilter: NSObject, NSOpenSavePanelDelegate {
    let accept: (URL) -> Bool
    init(accept: @escaping (URL) -> Bool) { self.accept = accept }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if accept(url) { return true }
        var isDir: ObjCBool = false
        let isFolder = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        return isFolder && !NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard accept(url) else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [
                NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” isn't the right kind of item."])
        }
    }
}

final class AppModel: ObservableObject {
    static let customTag = "custom"

    let catalog = TemplateCatalog(searchPaths: TemplateCatalog.defaultSearchPaths())
    @Published var libraryURL: URL?
    @Published var libraryVersion: Int?
    /// Picker tag: a built-in template's path, or `customTag`.
    @Published var targetTag = ""
    @Published var customTemplate: (url: URL, version: Int?)?
    @Published var output = ""
    @Published var busy = false
    @Published var backups: [LibraryBackup.Entry] = []

    init() { targetTag = catalog.forThisMac?.url.path ?? "" }

    // MARK: Target

    var targets: [TemplateCatalog.Entry] { catalog.entries.sorted { $0.order > $1.order } }

    func label(for entry: TemplateCatalog.Entry) -> String {
        entry.name + (entry.macOSMajor == TemplateCatalog.runningMajor ? "  (this Mac)" : "")
    }

    var targetURL: URL? {
        targetTag == Self.customTag ? customTemplate?.url : catalog.entries.first { $0.url.path == targetTag }?.url
    }

    var targetVersion: Int? {
        targetTag == Self.customTag ? customTemplate?.version : catalog.entries.first { $0.url.path == targetTag }?.modelVersion
    }

    var targetName: String {
        if targetTag == Self.customTag, let c = customTemplate { return c.url.deletingPathExtension().lastPathComponent }
        return catalog.entries.first { $0.url.path == targetTag }?.name ?? "—"
    }

    /// Picker binding: choosing "Other template library…" opens a panel.
    var targetBinding: Binding<String> {
        Binding(get: { self.targetTag }, set: { tag in
            if tag == Self.customTag { self.chooseCustomTemplate() } else { self.targetTag = tag }
        })
    }

    var compatibility: String? {
        guard let lib = libraryVersion, let target = targetVersion else { return nil }
        if lib <= target { return "✅ This library already opens on \(targetName). Nothing to downgrade." }
        return "This library was last used by \(TemplateCatalog.macOSName(forModelVersion: lib)). It needs a downgrade to open on \(targetName)."
    }

    var canDowngrade: Bool {
        guard libraryURL != nil, targetURL != nil, !busy else { return false }
        if let lib = libraryVersion, let target = targetVersion { return lib > target }
        return true
    }

    func chooseCustomTemplate() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Template Library"
        panel.message = "Select an EMPTY library created by the Photos version you need (hold Option while opening Photos › Create New…)."
        panel.prompt = "Choose Template"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        let filter = PanelFilter { PhotoLibrary.resolve($0) == $0 }
        panel.delegate = filter
        guard panel.runModal() == .OK, let url = panel.url, let lib = PhotoLibrary.resolve(url) else { return }
        if lib == libraryURL { output = "The template must be a different library."; return }
        let version = (try? SchemaSnapshot(db: PhotoLibrary(url: lib).open()).metadata["PLModelVersion"] as? NSNumber)?.intValue
        customTemplate = (lib, version)
        targetTag = Self.customTag
    }

    // MARK: Library

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Photos Library"
        panel.message = "Select a .photoslibrary (usually in your Pictures folder). Analyzing only reads it."
        panel.prompt = "Choose Library"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true   // a library is a folder (package) on disk
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = PhotoLibrary.defaultLibraryURL.deletingLastPathComponent()
        let filter = PanelFilter { PhotoLibrary.resolve($0) == $0 }
        panel.delegate = filter
        if panel.runModal() == .OK, let url = panel.url { setLibrary(url) }
    }

    func useSystemLibrary() { setLibrary(PhotoLibrary.defaultLibraryURL) }

    func setLibrary(_ url: URL) {
        guard let lib = PhotoLibrary.resolve(url) else {
            output = "“\(url.lastPathComponent)” is not a Photos library (.photoslibrary)."
            return
        }
        libraryURL = lib
        libraryVersion = nil
        refreshBackups()
        output = "Library selected. Click “Analyze” to see what a downgrade involves."
        DispatchQueue.global(qos: .userInitiated).async {
            let version = (try? SchemaSnapshot(db: PhotoLibrary(url: lib).open()).metadata["PLModelVersion"] as? NSNumber)?.intValue
            DispatchQueue.main.async {
                guard self.libraryURL == lib else { return }
                self.libraryVersion = version
                if version == nil { self.output = Self.accessHelp }
            }
        }
    }

    func refreshBackups() {
        backups = libraryURL.map { LibraryBackup(library: $0).list() } ?? []
    }

    // MARK: Jobs

    /// Runs file work off the main thread, streaming progress lines into the output.
    private func runJob(_ title: String, refreshAfter: Bool = true, completion: (() -> Void)? = nil,
                        _ work: @escaping (@escaping (String) -> Void) throws -> Void) {
        busy = true
        output = title
        DispatchQueue.global(qos: .userInitiated).async {
            let log: (String) -> Void = { line in DispatchQueue.main.async { self.output += "\n" + line } }
            var succeeded = true
            do { try work(log) } catch { succeeded = false; log(Self.describe(error)) }
            DispatchQueue.main.async {
                self.busy = false
                if succeeded { completion?() }
                guard refreshAfter else { return }
                self.refreshBackups()
                if let lib = self.libraryURL { self.setLibraryVersionQuietly(lib) }
            }
        }
    }

    private func setLibraryVersionQuietly(_ lib: URL) {
        libraryVersion = (try? SchemaSnapshot(db: PhotoLibrary(url: lib).open()).metadata["PLModelVersion"] as? NSNumber)?.intValue
    }

    func plan() {
        guard let libraryURL else { return }
        let targetURL = targetURL, targetName = targetName
        runJob("Analyzing…") { log in
            let lib = PhotoLibrary(url: libraryURL)
            let db = try lib.open()
            let source = try SchemaSnapshot(db: db)
            let s = lib.summarize(db, schema: source)
            guard let targetURL else { log("Choose which macOS the library will be used on."); return }
            let preflight = Preflight(library: libraryURL, forDowngrade: false)
            let checks = preflight.problems.map { "⚠️ " + ($0.errorDescription ?? "") }
                + [preflight.hasCloudSyncState ? "This library has iCloud Photos sync state (it is or was synced with iCloud)." : nil].compactMap { $0 }
                + ["Space: \(ByteCountFormatter.string(fromByteCount: preflight.databaseBytes * 3, countStyle: .file)) needed for a downgrade, \(ByteCountFormatter.string(fromByteCount: preflight.freeBytes, countStyle: .file)) free."]
            let target = try SchemaSnapshot(db: PhotoLibrary(url: targetURL).open())
            let diff = SchemaDiff(source: source, target: target)
            let tv = (target.metadata["PLModelVersion"] as? NSNumber)?.intValue
            let verdict: String
            if let sv = s.modelVersion, let tv, sv <= tv {
                verdict = "✅ Already compatible with \(targetName). Nothing to downgrade."
            } else if diff.hasBlockers {
                verdict = "⛔️ Blockers found: a downgrade needs extra fill rules (see BLOCK lines)."
            } else {
                verdict = "🟡 Downgrade possible. LOSS lines are newer data \(targetName) has no place for (Photos rebuilds most of it)."
            }
            log("""
                Library: \(libraryURL.path)
                Last used by: \(TemplateCatalog.macOSName(forModelVersion: s.modelVersion))
                \(PhotoLibrary.describe(s))
                Target: \(targetName) (database version \(tv.map(String.init) ?? "?"))
                \(checks.joined(separator: "\n"))

                \(verdict)

                \(diff.report())
                """)
        }
    }

    // MARK: Closing apps that have the library open

    /// Makes sure nothing has the library open, asking once before closing apps.
    /// If macOS reopens it right away (System Photo Library), `onSystemLibrary`
    /// is called instead of `then`.
    private func ensureClosed(_ lib: URL, onSystemLibrary: (([String]) -> Void)?, then: @escaping () -> Void) {
        busy = true
        output = "Checking whether anything has the library open…"
        DispatchQueue.global(qos: .userInitiated).async {
            var names = Preflight.processesUsing(library: lib)
            if LibraryBackup.photosIsRunning() { names = ["Photos"] + names.filter { $0 != "Photos" } }
            DispatchQueue.main.async {
                self.busy = false
                guard !names.isEmpty else { then(); return }
                let alert = NSAlert()
                alert.messageText = "Close apps that are using the library?"
                alert.informativeText = """
                    Photos Downgrade needs the library to itself. It will close:
                    \(names.joined(separator: ", "))

                    Apps are asked to quit normally so nothing is lost. Background processes restart by themselves when needed.
                    """
                alert.addButton(withTitle: "Close and Continue")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { self.output = "Cancelled. Nothing was changed."; return }
                self.busy = true
                self.output = "Closing apps…"
                DispatchQueue.global(qos: .userInitiated).async {
                    let remaining = Preflight.closeEverything(holding: lib) { line in
                        DispatchQueue.main.async { self.output += "\n" + line }
                    }
                    DispatchQueue.main.async {
                        self.busy = false
                        if remaining.isEmpty { then(); return }
                        if let onSystemLibrary { onSystemLibrary(remaining); return }
                        self.showError("The library is still in use",
                                       Preflight.Problem.systemLibrary(remaining).errorDescription ?? "")
                    }
                }
            }
        }
    }

    private func showError(_ title: String, _ text: String) {
        output = title + "\n\n" + text
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .critical
        alert.runModal()
    }

    // MARK: Downgrade

    func downgrade() {
        guard let libraryURL, targetURL != nil else { return }
        ensureClosed(libraryURL, onSystemLibrary: { remaining in self.offerCopy(of: libraryURL, remaining: remaining) }) {
            self.checkAndConfirm(libraryURL)
        }
    }

    /// The System Photo Library can't be changed in place: offer to downgrade a copy.
    private func offerCopy(of libraryURL: URL, remaining: [String]) {
        let name = targetName
        let copyName = libraryURL.deletingPathExtension().lastPathComponent + " (\(name))"
        let clones = (try? libraryURL.deletingLastPathComponent().resourceValues(forKeys: [.volumeSupportsFileCloningKey])
            .volumeSupportsFileCloning) ?? false
        let alert = NSAlert()
        alert.messageText = "This is your System Photo Library"
        alert.informativeText = """
            macOS opens it again right away (\(remaining.joined(separator: ", "))), so it can't be changed in place.

            Photos Downgrade can make a copy next to it named “\(copyName)” and downgrade the copy. Your current library stays exactly as it is.

            \(clones ? "On this drive the copy is instant and takes no extra space." : "This drive can't make instant copies, so the copy needs as much free space as the library and may take a while.")
            """
        alert.addButton(withTitle: "Make a Copy and Downgrade It")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { output = "Cancelled. Nothing was changed."; return }
        var copy: URL?
        runJob("Copying the library…", refreshAfter: false, completion: {
            guard let copy else { return }
            self.setLibrary(copy)
            self.checkAndConfirm(copy)
        }) { log in
            // Quiet the library for the moment of copying, so the copy is consistent.
            Preflight.closeEverything(holding: libraryURL, progress: log)
            copy = try Preflight.makeCopy(of: libraryURL, for: name, progress: log)
        }
    }

    /// Final checks, then the confirmation dialog, then the downgrade.
    private func checkAndConfirm(_ libraryURL: URL) {
        guard let templateURL = targetURL else { return }
        let name = targetName
        busy = true
        output = "Checking the library…"
        DispatchQueue.global(qos: .userInitiated).async {
            let preflight = Preflight(library: libraryURL, forDowngrade: true)
            DispatchQueue.main.async {
                self.busy = false
                self.confirmDowngrade(libraryURL: libraryURL, templateURL: templateURL, name: name, preflight: preflight)
            }
        }
    }

    private func confirmDowngrade(libraryURL: URL, templateURL: URL, name: String, preflight: Preflight) {
        let libraryName = libraryURL.deletingPathExtension().lastPathComponent
        // Open again already: something keeps reopening it.
        if preflight.onlyNeedsClosing {
            offerCopy(of: libraryURL, remaining: preflight.holderNames)
            return
        }
        if let problem = preflight.blocking.first {
            showError("“\(libraryName)” can't be downgraded", problem.errorDescription ?? "")
            return
        }

        var details = """
            The library's database is backed up next to the library, then rebuilt for \(name). Photos and videos are not moved or copied. Data \(name) has no place for is left out. You can undo with Restore.
            """
        if !preflight.cloudNotes.isEmpty {
            details += "\n\niCloud Photos: this library has been synced with iCloud. iCloud IDs are kept so a future iCloud merge can match photos instead of duplicating them. For iCloud on the older Mac, a new empty System Photo Library is the cleanest choice."
        }
        let missing = preflight.warnings.first
        if let missing { details += "\n\n⚠️ " + (missing.errorDescription ?? "") }

        let alert = NSAlert()
        alert.messageText = "Downgrade “\(libraryName)” for \(name)?"
        alert.informativeText = details
        alert.alertStyle = .warning
        alert.addButton(withTitle: missing == nil ? "Downgrade" : "Downgrade Anyway")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { output = "Cancelled. Nothing was changed."; return }

        runJob("Downgrading for \(name)…") { log in
            let report = try Downgrader(library: libraryURL, template: templateURL,
                                        allowMissingOriginals: missing != nil, closeApps: true).run(progress: log)
            let backupFolder = LibraryBackup(library: libraryURL).root.lastPathComponent
            log("\n" + report.summary + "\n\nA copy of this report is in “\(backupFolder)/\(report.backupID)/report.txt”.\nNext: open the library with Photos on \(name).")
        }
    }

    // MARK: Backups

    func backUp() {
        guard let libraryURL else { return }
        ensureClosed(libraryURL, onSystemLibrary: nil) {
            self.runJob("Backing up the library database (photos are not copied)…") { log in
                let version = try (SchemaSnapshot(db: PhotoLibrary(url: libraryURL).open()).metadata["PLModelVersion"] as? NSNumber)?.intValue
                try LibraryBackup(library: libraryURL).create(sourceModelVersion: version, progress: log)
                log("✅ Done. Backups are in “\(LibraryBackup(library: libraryURL).root.lastPathComponent)”, next to the library.")
            }
        }
    }

    func restore(_ entry: LibraryBackup.Entry) {
        guard let libraryURL else { return }
        let alert = NSAlert()
        alert.messageText = "Restore backup \(entry.manifest.id)?"
        alert.informativeText = "The library's current database is replaced by this backup. The current one is kept in the backup folder, so this can be undone."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ensureClosed(libraryURL, onSystemLibrary: nil) {
            self.runJob("Restoring \(entry.manifest.id)…") { log in
                try LibraryBackup(library: libraryURL).restore(entry, progress: log)
                log("✅ Done. You can open the library in Photos again.")
            }
        }
    }

    func verify(_ entry: LibraryBackup.Entry) {
        guard let libraryURL else { return }
        runJob("Verifying \(entry.manifest.id)…") { log in
            let bad = try LibraryBackup(library: libraryURL).verify(entry)
            log(bad.isEmpty ? "✅ All \(entry.manifest.files.count) files match their checksums."
                            : "❌ \(bad.count) files are damaged or missing: " + bad.prefix(5).joined(separator: ", "))
        }
    }

    static func describe(_ error: Error) -> String {
        let text = "\(error)"
        if text.contains("authorization denied") || text.contains("not permitted") { return accessHelp + "\n\n(\(text))" }
        return "❌ \(error.localizedDescription)"
    }

    static let accessHelp = """
        macOS blocked access to the library.

        Give Photos Downgrade Full Disk Access:
          • macOS 13+: System Settings › Privacy & Security › Full Disk Access
          • macOS 10.15–12: System Preferences › Security & Privacy › Privacy › Full Disk Access
        Click +, add Photos Downgrade.app, then quit and reopen this app.
        """
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: Text("1  Library")) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button("Choose Library…", action: model.chooseLibrary)
                        Button("System Photo Library", action: model.useSystemLibrary)
                        Text(model.libraryURL?.path ?? "None. Choose one, or drag a library onto this window.")
                            .foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                    if let v = model.libraryVersion {
                        Text("Last used by \(TemplateCatalog.macOSName(forModelVersion: v)) (database version \(v))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }.padding(4)
            }
            GroupBox(label: Text("2  Make it open on")) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: model.targetBinding) {
                        ForEach(model.targets, id: \.url.path) { entry in
                            Text(model.label(for: entry)).tag(entry.url.path)
                        }
                        if let c = model.customTemplate {
                            Text("Template: \(c.url.deletingPathExtension().lastPathComponent)").tag(AppModel.customTag)
                        } else {
                            Text("Other template library…").tag(AppModel.customTag)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360)
                    Text(model.catalog.forThisMac != nil
                         ? "This Mac runs \(TemplateCatalog.runningDescription). Choose another version if the library will be used on a different Mac."
                         : "This Mac runs \(TemplateCatalog.runningDescription), which has no built-in template. Choose the macOS the library will be used on.")
                        .font(.caption).foregroundColor(.secondary)
                    if let c = model.compatibility { Text(c).font(.caption) }
                }.padding(4)
            }
            GroupBox(label: Text("Backups (stored next to the library)")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Back Up Database Now", action: model.backUp)
                            .disabled(model.libraryURL == nil || model.busy)
                        Text("Copies only the database, not the photos.").font(.caption).foregroundColor(.secondary)
                        Spacer()
                    }
                    ForEach(model.backups, id: \.manifest.id) { entry in
                        HStack {
                            Text(entry.manifest.id).font(.system(.body, design: .monospaced))
                            Text("\(entry.manifest.files.count) files").foregroundColor(.secondary)
                            Spacer()
                            Button("Verify") { model.verify(entry) }.disabled(model.busy)
                            Button("Restore…") { model.restore(entry) }.disabled(model.busy)
                        }
                    }
                }.padding(4)
            }
            HStack {
                Button("3  Analyze (dry run)", action: model.plan)
                    .disabled(model.libraryURL == nil || model.busy)
                Button("4  Downgrade…", action: model.downgrade)
                    .disabled(!model.canDowngrade)
                Spacer()
                Text(model.busy ? "Working…" : "Analyze changes nothing. Downgrade backs up first.")
                    .font(.caption).foregroundColor(.secondary)
            }
            ScrollView {
                SelectableText(text: model.output.isEmpty ? Self.help : model.output)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(NSColor.textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(dropTargeted ? Color.accentColor : .clear, lineWidth: 3))
        }
        .padding()
        .onDrop(of: ["public.file-url"], isTargeted: $dropTargeted) { providers in
            providers.first?.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { model.setLibrary(url) }
            }
            return true
        }
    }

    static let help = """
    How it works

    1. Library: the .photoslibrary an older Photos must open. Quit Photos first.

    2. Make it open on: preset to the macOS this Mac runs. If the library
       will be used on another Mac, pick that Mac's macOS instead. The
       older Mac should have the latest updates for its macOS version.

    3. Analyze: read-only. Shows what the older version has no place for
       (LOSS) and what it gets fresh (INFO).

    4. Downgrade: works IN PLACE, photos and videos stay where they are.
         • backs up the database into “<Library name> (Downgrade
           Backups)” next to the library, verified by checksum
         • rebuilds the database for the chosen macOS and checks it
           with Core Data before touching the library
         • moves the newer version's caches/journals into the backup
       Then open the library with Photos on that Mac. Photos rebuilds
       search and analysis in the background.

    Restore… puts a backup back exactly (the replaced files are kept).
    Keep the backup folder next to the library. If you move the library,
    move its “(Downgrade Backups)” folder with it.

    Needs Full Disk Access (System Settings › Privacy & Security).
    """
}

/// Monospaced, selectable text (SwiftUI's textSelection needs macOS 12).
struct SelectableText: View {
    let text: String
    var body: AnyView {
        let label = Text(text).font(.system(.body, design: .monospaced))
        if #available(macOS 12.0, *) { return AnyView(label.textSelection(.enabled)) }
        return AnyView(label)
    }
}
