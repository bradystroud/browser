/// Ordered, additive schema migrations, applied via SQLite's own
/// `PRAGMA user_version` as the version marker. `migrations[i]` upgrades
/// from version `i` to `i + 1` -- to add a schema change, append a new
/// closure rather than editing an existing one, so a partially-migrated
/// database from an older build always has a well-defined path forward.
enum Migrations {
    static let migrations: [(SQLiteConnection) throws -> Void] = [
        { db in
            try db.execute("""
            CREATE TABLE history_urls (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL DEFAULT '',
                visit_count INTEGER NOT NULL DEFAULT 0,
                last_visit_time INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX idx_history_urls_last_visit ON history_urls(last_visit_time);

            CREATE TABLE history_visits (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url_id INTEGER NOT NULL REFERENCES history_urls(id) ON DELETE CASCADE,
                visit_time INTEGER NOT NULL
            );
            CREATE INDEX idx_history_visits_url_id ON history_visits(url_id);
            CREATE INDEX idx_history_visits_time ON history_visits(visit_time);

            CREATE TABLE bookmark_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                parent_id INTEGER REFERENCES bookmark_items(id) ON DELETE CASCADE,
                kind TEXT NOT NULL CHECK(kind IN ('folder', 'bookmark')),
                title TEXT NOT NULL,
                url TEXT,
                position INTEGER NOT NULL,
                created_at INTEGER NOT NULL
            );
            CREATE INDEX idx_bookmark_items_parent ON bookmark_items(parent_id, position);

            CREATE TABLE downloads (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL,
                suggested_name TEXT NOT NULL,
                destination_path TEXT NOT NULL,
                state TEXT NOT NULL CHECK(
                    state IN ('pending', 'inProgress', 'completed', 'cancelled', 'failed', 'interrupted')
                ),
                received_bytes INTEGER NOT NULL DEFAULT 0,
                total_bytes INTEGER NOT NULL DEFAULT -1,
                started_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                completed_at INTEGER
            );
            CREATE INDEX idx_downloads_started ON downloads(started_at);
            """)
        },
        { db in
            // Reading list (browser-56p). `article_html` is Readability's
            // extracted markup, stored inline rather than as a file beside
            // the database so that deleting an item cannot leave an orphaned
            // article behind, and so clearing the list is one statement.
            try db.execute("""
            CREATE TABLE reading_list_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL DEFAULT '',
                byline TEXT NOT NULL DEFAULT '',
                excerpt TEXT NOT NULL DEFAULT '',
                article_html TEXT,
                added_at INTEGER NOT NULL,
                is_read INTEGER NOT NULL DEFAULT 0,
                read_at INTEGER
            );
            CREATE INDEX idx_reading_list_added ON reading_list_items(added_at);
            """)
        }
    ]

    /// Applies every migration between the connection's current
    /// `user_version` and `migrations.count`, each in its own transaction so
    /// a failure partway through a multi-statement migration doesn't leave
    /// the schema half-upgraded with a version bump already recorded.
    static func run(on db: SQLiteConnection) throws {
        var version = Int(db.userVersion)
        while version < migrations.count {
            let migration = migrations[version]
            let nextVersion = Int32(version + 1)
            try db.withTransaction {
                try migration(db)
                // Bumped inside the same transaction as the schema change
                // itself, so a crash between the two can never leave the
                // version marker ahead of the schema it claims to describe.
                try db.setUserVersion(nextVersion)
            }
            version += 1
        }
    }
}
