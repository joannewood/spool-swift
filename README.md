# Spool

A native macOS rewrite of [SPOOL](https://github.com/joannewood/spool) — a local,
searchable library for your 3D printing files (`.stl`, `.3mf`, `.step`/`.stp`, `.svg`,
`.scad`, `.gcode`, `.obj`). Spool watches your folders, hashes and thumbnails every
recognized file, and gives you a live-updating, searchable library — as one ordinary
Mac app, no Docker, no Postgres, no background daemon to keep running.

If you've used the original Python/FastAPI/Docker version, this is the same idea,
rebuilt from scratch as a single-process SwiftUI app. See [below](#how-this-relates-to-the-original-spool)
for how the two relate.

## Get it

Grab the latest signed, notarized build from **[Releases](https://github.com/joannewood/spool-swift/releases)**
— download `Spool.dmg`, open it, and drag Spool into Applications. It's notarized by
Apple, so it opens normally on first launch, no right-click/"Open Anyway" dance needed.

Requires **macOS 14 (Sonoma) or later**.

## What it does

- **Watches your folders** — a drop folder, an existing library folder (read-only,
  never modified), and Downloads (new files auto-relocated into your drop folder) are
  indexed automatically as files arrive, plus a periodic rescan catches anything a live
  filesystem event missed.
- **Real preview thumbnails** — STL/3MF/OBJ are rendered natively (SceneKit); STEP is
  tessellated through a bundled OpenCASCADE-based converter; a mesh-safety check skips
  pathological files (oversized meshes, exploding 3MF component trees) rather than
  risking a crash.
- **Search and browse** — search-as-you-type across filenames, tags, and print
  metadata (material, printer, slicer, your own notes), filter by extension, sort,
  grid or list view. Hyphens, underscores, and spaces are treated as equivalent, so
  "cake stand" finds `cake_stand.stl`.
- **Tags, nestable projects, print metadata** — organize files by hand, or let Spool
  auto-suggest a project for files that share a folder.
- **Relationships** — link a STEP file to the STL exported from it, or a part to its
  next revision, with auto-suggested `duplicate_of`/`new_version_of`/`derived_from`
  detection based on content hash and filename patterns.
- **Archive review** — a `.zip` containing a recognized model file is surfaced for you
  to confirm or dismiss before anything is extracted. `.7z`/`.rar` support is optional
  and opt-in (Settings → General → Archives) since macOS has no native reader for
  either format.
- **Duplicate cleanup** — byte-identical files are grouped for review, with bulk
  select/delete (via the Trash, not a hard delete).
- **Printed tracker** — mark a file as printed, rate it, and leave yourself notes.
- **A menu bar item** that keeps watching/ingesting in the background even with the
  main window closed, with a live "N files pending" glance.

## Known gaps

- **Quick Look (spacebar preview)** isn't wired up yet.
- `.7z`/`.rar` support requires you to have `unar` or `7z` installed yourself (e.g. via
  Homebrew) and located once in Settings — see the in-app prompt in Admin → Archives.

## Feedback

Found a bug, or something that doesn't match the original app's behavior? Please
[open an issue](https://github.com/joannewood/spool-swift/issues).

## For developers

See [`CLAUDE.md`](CLAUDE.md) for the architecture (SwiftPM packages + a SwiftUI app
target), build/test commands, and the project's own build-log-style notes on
non-obvious decisions.

## How this relates to the original SPOOL

[joannewood/spool](https://github.com/joannewood/spool) is the original app — a
Python/FastAPI/Postgres/Docker stack that still runs great and is the more
battle-tested of the two. This repo is a from-scratch native rewrite targeting full
feature parity, trading Docker/Postgres/a background daemon for a single ordinary
Mac app. Both are actively maintained; pick whichever fits how you want to run it.
