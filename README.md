# Photos Downgrade

A macOS app that converts an Apple Photos library (`.photoslibrary`) so an
**older** version of Photos can open it, for example a library last used on
macOS Sequoia or later, opened on Ventura or Monterey.

Apple does not support downgrading Photos libraries. This tool is unofficial
and not affiliated with Apple. It backs up before changing anything and can
restore exactly, but keep your own backup of any library you care about.

## Download and install

1. Go to the [**Releases**](https://github.com/techdoctors/photos-downgrade/releases/latest) page and download
   **Photos-Downgrade-1.0.zip** (under *Assets*).
2. Double-click the zip to unpack it, then drag **Photos Downgrade** into your
   **Applications** folder.
3. Open it. The first time, macOS says it can't check the app for malicious
   software, because it isn't signed with a paid Apple developer certificate:
   - **macOS 15 Sequoia or later:** click **Done**, open **System Settings ›
     Privacy & Security**, scroll down and click **Open Anyway** next to
     “Photos Downgrade”, then confirm.
   - **macOS 14 Sonoma or earlier:** right-click (or Control-click) the app,
     choose **Open**, then click **Open** again.
4. Give it **Full Disk Access** so it can read Photos libraries:
   **System Settings › Privacy & Security › Full Disk Access** (on macOS 12 and
   earlier: System Preferences › Security & Privacy › Privacy), click **+**,
   choose **Photos Downgrade** in Applications, and turn it on. Quit and reopen
   the app.

Works on macOS 10.15 Catalina and later, on Intel and Apple Silicon Macs.

## Using the app

1. **Library**: choose the library (or drag it onto the window).
2. **Make it open on**: preset to the macOS this Mac runs. Pick another
   version if the library will be used on a different Mac.
3. **Analyze** (optional, read-only): shows what the older Photos has no
   place for.
4. **Downgrade…**: closes whatever has the library open (after asking), backs
   up the database next to the library, rebuilds it for the chosen version,
   checks it with Core Data, and swaps it in. Photos and videos are never
   moved or copied.

Then open the library with Photos on that Mac. **Restore…** puts any backup
back exactly.


## How it works

A Photos library is mostly a Core Data store (`database/Photos.sqlite`) whose
schema changes with nearly every macOS release, and older Photos refuses a
store whose model version (`PLModelVersion`) is newer than its own.

The downgrade is a **schema-level rebuild**, not a Core Data migration:

1. **Template.** An empty library made by the target Photos supplies the
   exact schema, Core Data metadata, cached model and built-in albums.
   Templates for each supported macOS ship inside the app.
2. **Models.** Each store caches its exact Core Data model in
   `Z_MODELCACHE`; decoding both gives the source and target models.
3. **Copy.** Rows are copied with `INSERT … SELECT` through `ATTACH`:
   entity numbers (`Z_ENT`, `Z<n>_` columns, join-table names) are remapped
   by entity name; renamed relationships are found by their unchanged
   inverse; built-in albums are matched by kind; album key assets, file-type
   codes (compact UTI → lookup tables) and Catalina's `GenericAsset`
   hierarchy are converted; Core Data triggers, the location R-tree and
   `Z_PRIMARYKEY` are restored.
4. **Validate.** The new store is opened read-only with the target model and
   every entity is fetched before the library is touched.
5. **Install.** The database is swapped in; the newer version's journals,
   caches and iCloud sync state are moved into the backup. Photos rebuilds
   search and analysis on first open.

## Build

```bash
./scripts/make-app.sh   # universal app, CLI and release zip in build/ (VERSION=1.0)
```

Requires the Xcode command line tools. The command-line tool:

```bash
build/pdowngrade versions                                         # targets, and this Mac
build/pdowngrade inspect <library>
build/pdowngrade check <library>                                  # safety checks only
build/pdowngrade plan <library> --template <older template>
build/pdowngrade downgrade <library> [--to ventura] [--close-apps] # default: this Mac
build/pdowngrade downgrade <System Photo Library> --to ventura --copy --close-apps
build/pdowngrade close <library>                                  # quit whatever has it open
build/pdowngrade backup | backups | restore <library> [backup-id]
build/pdowngrade make-template <library> <out.photoslibrary>
```

## Supported targets

Templates ship inside the app (`Resources/Templates`).

| Target | Database version | Template |
|---|---|---|
| Catalina 10.15 | 13703 | derived* |
| Big Sur 11 | 14208 | derived* |
| Monterey 12 | 15502 | from a real empty library |
| Ventura 13 | 16502 | from a real empty library |
| Sequoia 15 | 18600 | derived from a test library |

Mojave and earlier use a different (pre-Core Data) database and are not supported.

\* Derived with `pdowngrade make-template` from the test libraries of
[osxphotos](https://github.com/RhetTbull/osxphotos) (MIT license), because no
Mac running those versions was available. A real empty library created on
that version is preferable when one can be made.

## Safety checks

Before a backup, restore or downgrade the app refuses to continue if:

- Photos or anything else has the library's database open (`lsof`). The app
  asks once, then closes them itself: apps are asked to quit normally,
  background processes get SIGTERM, and anything still running after 15 s is
  forced. Background processes restart on demand.
- If the library is reopened right away, it is the System Photo Library
  (macOS keeps it open). It can't be changed in place, so the app offers to
  downgrade a copy, `<Name> (macOS Ventura 13).photoslibrary`, next to it;
  on APFS the copy is an instant clone that takes no extra space.
- There isn't room for three copies of the database (backup, working copy,
  rebuilt database).
- Originals exist only in iCloud ("Optimize Mac Storage"), unless confirmed
  (`--allow-missing-originals`): those items keep previews only.

Each downgrade writes `report.txt` (or `report-FAILED.txt`) into its backup folder.

### iCloud Photos

Only the database changes, but iCloud sync is driven by the database, so
reconnecting is not a no-op. The downgrade keeps every item's iCloud IDs (so a
later iCloud merge matches photos instead of uploading duplicates) and moves the
iCloud sync state (`resources/cpl`) into the backup, so Photos treats the library
like one restored from a backup and does a full merge if iCloud Photos is turned
on. Newer data that the older Photos drops stays in iCloud. For iCloud on the
older Mac, a new empty System Photo Library that downloads from iCloud is the
cleanest route; use the downgraded library as a local library.

## Status

Tested: a 55,000-item library from macOS Sequoia (and later) converted for
Ventura and opened. Sequoia → Monterey, Big Sur and Catalina pass Core Data
validation against those versions' own models but have not yet been opened
on those systems.

Known limitations:

- Mojave and earlier use a different database and are not supported.
- No Sonoma template yet. Templates come from one point release of each
  macOS; the target Mac should have the latest updates for its version.
- Edits made with features the older Photos doesn't have may show as the
  unedited original there.
- Album cached counts and some derived fields are not recalculated.

## Credits

Catalina and Big Sur templates are derived from test libraries in
[osxphotos](https://github.com/RhetTbull/osxphotos) by Rhet Turnbull (MIT
license; see `THIRD_PARTY_NOTICES.md`).

## License

MIT, see `LICENSE`.
