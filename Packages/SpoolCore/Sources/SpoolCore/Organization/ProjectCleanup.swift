import GRDB

/// A project auto-created by `ProjectSuggestionService`'s folder-based heuristic
/// (`sourceFolderPath` non-nil) that has lost its last `project_files` row — via an
/// explicit removal, or via deleting the file itself cascading one away — is dead
/// weight: nothing links to it, and nothing will ever re-suggest it back (a new file
/// discovered later in that same folder just recreates an equivalent row, no
/// suggestion is lost by removing the empty shell). A manually-created project
/// (`sourceFolderPath` nil) is deliberately never auto-deleted this way, even if
/// empty — the user made it on purpose and might want it waiting for files. A project
/// that still has a *child* project (of any kind) is also never deleted here even if
/// it has no files of its own — an auto-created umbrella/parent with zero direct
/// files but a real, non-empty sub-project is a legitimate shape (confirmed live: a
/// leftover test root's cascade-deleted files left exactly this shape behind, nested
/// under an equally-empty parent — without the children guard this would have deleted
/// the parent out from under a still-meaningful child, silently promoting it to the
/// top level via `parent_project_id`'s `ON DELETE SET NULL`).
///
/// Mirrors the source app's `_delete_project_if_empty_and_auto_created`, confirmed
/// live there to matter: 349 real orphaned empty projects had accumulated, mostly from
/// duplicate-file cleanup deleting the only file in a project auto-created for what
/// turned out to be a duplicate download's own folder.
enum ProjectCleanup {
    static func deleteIfEmptyAndAutoCreated(projectId: Int64, conn: Database) throws {
        try conn.execute(sql: """
            DELETE FROM projects
            WHERE id = ? AND source_folder_path IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM project_files WHERE project_id = ?)
              AND NOT EXISTS (SELECT 1 FROM projects AS child WHERE child.parent_project_id = ?)
            """, arguments: [projectId, projectId, projectId])
    }

    /// Sweeps *every* now-empty, childless, auto-created project, not just one named
    /// id — for a bulk removal (e.g. deleting a whole watched root, which cascades its
    /// files away at the SQLite FK level via `ON DELETE CASCADE` and so never runs
    /// through `FileService`/`ProjectService`'s per-file cleanup calls at all) that
    /// can't enumerate every project it might have emptied. Repeats the sweep until a
    /// fixed point so a chain of nested auto-created projects (parent -> child, both
    /// now empty) fully collapses bottom-up in one call: the first pass removes the
    /// childless leaf, which can make its former parent newly childless-and-empty too,
    /// caught by the next pass.
    static func sweepEmptyAutoCreated(conn: Database) throws {
        while true {
            try conn.execute(sql: """
                DELETE FROM projects
                WHERE source_folder_path IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM project_files WHERE project_files.project_id = projects.id)
                  AND NOT EXISTS (SELECT 1 FROM projects AS child WHERE child.parent_project_id = projects.id)
                """)
            if conn.changesCount == 0 { break }
        }
    }
}
