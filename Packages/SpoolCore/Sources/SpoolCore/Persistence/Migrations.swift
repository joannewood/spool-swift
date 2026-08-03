import GRDB

/// Full schema, translated from the source Postgres DDL (see the project plan for the
/// column-by-column mapping). Defined as one migration up front — even for tables later
/// milestones don't populate yet — so there's no migration churn as features land.
func registerMigrations(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v1_initial") { db in
        try db.execute(sql: """
            CREATE TABLE watched_roots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                host_path TEXT NOT NULL UNIQUE,
                label TEXT NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('library','drop_folder','downloads')),
                ingest_mode TEXT NOT NULL DEFAULT 'index_in_place'
                    CHECK (ingest_mode IN ('index_in_place','relocate_to_dropfolder')),
                active INTEGER NOT NULL DEFAULT 1,
                last_scanned_at TEXT,
                bookmark_data BLOB NOT NULL
            );

            CREATE TABLE files (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                watched_root_id INTEGER NOT NULL REFERENCES watched_roots(id) ON DELETE CASCADE,
                path TEXT NOT NULL UNIQUE,
                filename TEXT NOT NULL,
                ext TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                content_hash TEXT,
                bbox_x REAL,
                bbox_y REAL,
                bbox_z REAL,
                volume_mm3 REAL,
                tri_count INTEGER,
                is_manifold INTEGER,
                units TEXT,
                thumbnail_path TEXT,
                render_status TEXT NOT NULL DEFAULT 'pending'
                    CHECK (render_status IN ('pending','rendering','done','failed','unsupported')),
                status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','missing')),
                first_seen_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                mtime TEXT,
                display_name TEXT,
                filename_normalized TEXT NOT NULL DEFAULT '',
                display_name_normalized TEXT
            );
            CREATE INDEX idx_files_content_hash ON files(content_hash);
            CREATE INDEX idx_files_watched_root_id ON files(watched_root_id);
            CREATE INDEX idx_files_status ON files(status);
            CREATE INDEX idx_files_filename_normalized ON files(filename_normalized);
            CREATE INDEX idx_files_display_name_normalized ON files(display_name_normalized);

            -- Keep filename_normalized/display_name_normalized in sync so search can
            -- treat hyphens/underscores/spaces as equivalent without renormalizing at
            -- query time. `UPDATE OF` scopes each trigger so the trigger's own write
            -- (to different columns) can't recursively refire it.
            CREATE TRIGGER trg_files_normalize_insert AFTER INSERT ON files BEGIN
                UPDATE files
                SET filename_normalized = normalize(NEW.filename),
                    display_name_normalized = CASE WHEN NEW.display_name IS NULL THEN NULL
                                                    ELSE normalize(NEW.display_name) END
                WHERE id = NEW.id;
            END;
            CREATE TRIGGER trg_files_normalize_update AFTER UPDATE OF filename, display_name ON files BEGIN
                UPDATE files
                SET filename_normalized = normalize(NEW.filename),
                    display_name_normalized = CASE WHEN NEW.display_name IS NULL THEN NULL
                                                    ELSE normalize(NEW.display_name) END
                WHERE id = NEW.id;
            END;

            CREATE TABLE tags (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                name_normalized TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX idx_tags_name_normalized ON tags(name_normalized);
            CREATE TRIGGER trg_tags_normalize_insert AFTER INSERT ON tags BEGIN
                UPDATE tags SET name_normalized = normalize(NEW.name) WHERE id = NEW.id;
            END;
            CREATE TRIGGER trg_tags_normalize_update AFTER UPDATE OF name ON tags BEGIN
                UPDATE tags SET name_normalized = normalize(NEW.name) WHERE id = NEW.id;
            END;

            CREATE TABLE file_tags (
                file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                PRIMARY KEY (file_id, tag_id)
            );

            CREATE TABLE projects (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                name_normalized TEXT NOT NULL DEFAULT '',
                description TEXT,
                parent_project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
                created_at TEXT NOT NULL,
                source_folder_path TEXT UNIQUE
            );
            CREATE INDEX idx_projects_name_normalized ON projects(name_normalized);
            CREATE INDEX idx_projects_parent ON projects(parent_project_id);
            CREATE TRIGGER trg_projects_normalize_insert AFTER INSERT ON projects BEGIN
                UPDATE projects SET name_normalized = normalize(NEW.name) WHERE id = NEW.id;
            END;
            CREATE TRIGGER trg_projects_normalize_update AFTER UPDATE OF name ON projects BEGIN
                UPDATE projects SET name_normalized = normalize(NEW.name) WHERE id = NEW.id;
            END;

            CREATE TABLE project_files (
                project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                status TEXT NOT NULL DEFAULT 'confirmed'
                    CHECK (status IN ('suggested','confirmed','rejected')),
                PRIMARY KEY (project_id, file_id)
            );

            CREATE TABLE print_metadata (
                file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                material TEXT,
                printer_profile TEXT,
                slicer TEXT,
                settings_json TEXT,
                notes TEXT,
                source TEXT NOT NULL DEFAULT 'manual'
                    CHECK (source IN ('manual','auto_extracted_3mf','auto_extracted_gcode'))
            );

            CREATE TABLE relationships (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                from_file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                to_file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                type TEXT NOT NULL CHECK (type IN ('derived_from','new_version_of','variant_of','duplicate_of')),
                status TEXT NOT NULL DEFAULT 'suggested' CHECK (status IN ('suggested','confirmed','rejected')),
                confidence REAL,
                created_at TEXT NOT NULL,
                CHECK (from_file_id != to_file_id)
            );
            CREATE UNIQUE INDEX idx_relationships_from_to_type ON relationships(from_file_id, to_file_id, type);

            CREATE TABLE jobs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_id INTEGER REFERENCES files(id) ON DELETE CASCADE,
                zip_file_id INTEGER REFERENCES zip_files(id) ON DELETE CASCADE,
                job_type TEXT NOT NULL CHECK (job_type IN ('ingest','render','render_step','rescan','extract_zip')),
                status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','done','failed')),
                error TEXT,
                created_at TEXT NOT NULL,
                completed_at TEXT
            );
            CREATE INDEX idx_jobs_status_type ON jobs(status, job_type);

            CREATE TABLE zip_files (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                watched_root_id INTEGER NOT NULL REFERENCES watched_roots(id) ON DELETE CASCADE,
                path TEXT NOT NULL,
                filename TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                status TEXT NOT NULL DEFAULT 'suggested'
                    CHECK (status IN ('suggested','confirmed','rejected','unsupported_format')),
                error TEXT,
                content_hash TEXT
            );
            CREATE UNIQUE INDEX idx_zip_files_path_hash ON zip_files(path, content_hash);

            CREATE TABLE sidecar_files (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                watched_root_id INTEGER NOT NULL REFERENCES watched_roots(id) ON DELETE CASCADE,
                path TEXT NOT NULL UNIQUE,
                filename TEXT NOT NULL,
                ext TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                first_seen_at TEXT NOT NULL,
                thumbnail_path TEXT,
                status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','missing'))
            );
            CREATE INDEX idx_sidecar_files_watched_root_id ON sidecar_files(watched_root_id);

            CREATE TABLE print_log (
                file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                printed INTEGER NOT NULL DEFAULT 0,
                rating INTEGER CHECK (rating IS NULL OR (rating BETWEEN 1 AND 5)),
                comments TEXT
            );

            CREATE TABLE app_settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                rescan_enabled INTEGER NOT NULL DEFAULT 1,
                rescan_interval_seconds INTEGER NOT NULL DEFAULT 300,
                updated_at TEXT NOT NULL,
                auto_accept_archives INTEGER NOT NULL DEFAULT 0
            );
            """)

        try db.execute(sql: """
            INSERT INTO app_settings (id, rescan_enabled, rescan_interval_seconds, updated_at, auto_accept_archives)
            VALUES (1, 1, 300, datetime('now'), 0);
            """)
    }

    // A render failure previously set render_status = 'failed' with no record of why —
    // the browse UI could show that a thumbnail failed but not what went wrong. A real
    // migration (not a v1_initial edit) so an already-set-up install's existing library
    // keeps its data rather than needing a fresh DB.
    migrator.registerMigration("v2_render_error") { db in
        try db.execute(sql: "ALTER TABLE files ADD COLUMN render_error TEXT")
    }

    // Project colors — a native-app addition, not in the source app. Lets a user flag
    // important projects with a Finder-label-style color; every project defaults to
    // blue, and only a project explicitly given a different color sorts to the top of
    // the sidebar/cards list (see ProjectService.allProjects/projectSummaries).
    migrator.registerMigration("v3_project_color") { db in
        try db.execute(sql: """
            ALTER TABLE projects ADD COLUMN color TEXT NOT NULL DEFAULT 'blue'
                CHECK (color IN ('blue','red','orange','yellow','green','purple','gray'))
            """)
    }

    // A security-scoped bookmark for an optional, user-located `unar`/`7z` binary.
    // `ArchiveToolLocator`'s fixed-path search (checking e.g. /opt/homebrew/bin/unar
    // directly) only ever worked in unsandboxed dev builds — confirmed live that under
    // the real shipped app's sandbox entitlements, `FileManager.isExecutableFile`
    // returns false for every such path even when the binary is genuinely installed,
    // silently defeating .7z/.rar support entirely. This bookmark, granted once via
    // NSOpenPanel in Settings, is the actual sandbox-compliant fix.
    migrator.registerMigration("v4_archive_tool_bookmark") { db in
        try db.execute(sql: "ALTER TABLE app_settings ADD COLUMN archive_tool_bookmark_data BLOB")
    }
}
