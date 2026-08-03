import GRDB

/// A project auto-created by `ProjectSuggestionService`'s folder-based heuristic
/// (`sourceFolderPath` non-nil) that has lost its last `project_files` row — via an
/// explicit removal, or via deleting the file itself cascading one away — is dead
/// weight: nothing links to it, and nothing will ever re-suggest it back (a new file
/// discovered later in that same folder just recreates an equivalent row, no
/// suggestion is lost by removing the empty shell). A manually-created project
/// (`sourceFolderPath` nil) is deliberately never auto-deleted this way, even if
/// empty — the user made it on purpose and might want it waiting for files.
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
            """, arguments: [projectId, projectId])
    }
}
