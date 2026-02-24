// Package db provides read-only SQLite access for fallback mode.
// PRD §7.5 — when clipsterd is not running, clipster reads directly from the DB.
// This is explicitly READ-ONLY. No writes ever happen here.
package db

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite" // pure-Go driver, no CGO
)

// DBPath returns ~/Library/Application Support/Clipster/history.db.
func DBPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "Clipster", "history.db")
}

// Entry mirrors the IPC Entry type for fallback reads.
type Entry struct {
	ID               string
	ContentType      string
	Content          string
	Preview          sql.NullString
	SourceBundle     sql.NullString
	SourceName       sql.NullString
	SourceConfidence string
	CreatedAt        int64
	IsPinned         bool
}

// Reader provides read-only access to the Clipster SQLite database.
type Reader struct {
	db *sql.DB
}

// Open opens the database in read-only mode. Returns an error if the DB doesn't exist.
func Open() (*Reader, error) {
	path := DBPath()
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil, fmt.Errorf("database not found at %s — has clipsterd ever run?", path)
	}
	// Open with immutable=1 for strict read-only access (no WAL writer needed)
	dsn := fmt.Sprintf("file:%s?mode=ro&_journal_mode=WAL", path)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	db.SetMaxOpenConns(1)
	return &Reader{db: db}, nil
}

// Close closes the database.
func (r *Reader) Close() {
	r.db.Close()
}

// List returns history entries, newest first.
func (r *Reader) List(limit, offset int) ([]Entry, error) {
	rows, err := r.db.Query(`
		SELECT id, content_type, content, preview,
		       source_bundle, source_name, source_confidence,
		       created_at, is_pinned
		FROM entries
		ORDER BY created_at DESC
		LIMIT ? OFFSET ?
	`, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("query: %w", err)
	}
	defer rows.Close()
	return scanEntries(rows)
}

// Pins returns all pinned entries, newest first.
func (r *Reader) Pins() ([]Entry, error) {
	rows, err := r.db.Query(`
		SELECT id, content_type, content, preview,
		       source_bundle, source_name, source_confidence,
		       created_at, is_pinned
		FROM entries
		WHERE is_pinned = 1
		ORDER BY created_at DESC
	`)
	if err != nil {
		return nil, fmt.Errorf("query pins: %w", err)
	}
	defer rows.Close()
	return scanEntries(rows)
}

// Latest returns the most recent entry, or nil if history is empty.
func (r *Reader) Latest() (*Entry, error) {
	entries, err := r.List(1, 0)
	if err != nil {
		return nil, err
	}
	if len(entries) == 0 {
		return nil, nil
	}
	return &entries[0], nil
}

func scanEntries(rows *sql.Rows) ([]Entry, error) {
	var entries []Entry
	for rows.Next() {
		var e Entry
		var isPinnedInt int
		if err := rows.Scan(
			&e.ID, &e.ContentType, &e.Content, &e.Preview,
			&e.SourceBundle, &e.SourceName, &e.SourceConfidence,
			&e.CreatedAt, &isPinnedInt,
		); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		e.IsPinned = isPinnedInt != 0
		entries = append(entries, e)
	}
	return entries, rows.Err()
}
