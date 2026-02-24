package ipc

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

// HistoryClient abstracts IPC client and SQLite fallback behind the same interface.
// All TUI and CLI commands use this interface.
type HistoryClient interface {
	List(limit, offset int) ([]Entry, error)
	Pins() ([]Entry, error)
	Last() (*Entry, error)
	Pin(entryID string) error
	Unpin(entryID string) error
	Delete(entryID string) error
	Transform(entryID, transform string) (string, error)
	Clear() (int, error)
	Close()
}

// Ensure *Client satisfies HistoryClient.
var _ HistoryClient = (*Client)(nil)

// ─── FallbackClient ──────────────────────────────────────────────────────────

// FallbackClient reads directly from history.db when the daemon is offline.
// Write operations return a descriptive error.
type FallbackClient struct {
	db *sql.DB
}

// NewFallbackClient opens history.db in read-only mode.
func NewFallbackClient() (HistoryClient, error) {
	home, _ := os.UserHomeDir()
	path := filepath.Join(home, "Library", "Application Support", "Clipster", "history.db")
	db, err := sql.Open("sqlite", fmt.Sprintf("file:%s?mode=ro", path))
	if err != nil {
		return nil, fmt.Errorf("open history.db: %w", err)
	}
	return &FallbackClient{db: db}, nil
}

func (f *FallbackClient) Close() { f.db.Close() }

func (f *FallbackClient) List(limit, offset int) ([]Entry, error) {
	rows, err := f.db.Query(`
		SELECT id, content_type, content, COALESCE(preview,''), 
		       COALESCE(source_bundle,''), COALESCE(source_name,''),
		       source_confidence, created_at, is_pinned
		FROM entries ORDER BY created_at DESC LIMIT ? OFFSET ?`, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanEntries(rows)
}

func (f *FallbackClient) Pins() ([]Entry, error) {
	rows, err := f.db.Query(`
		SELECT id, content_type, content, COALESCE(preview,''),
		       COALESCE(source_bundle,''), COALESCE(source_name,''),
		       source_confidence, created_at, is_pinned
		FROM entries WHERE is_pinned=1 ORDER BY created_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanEntries(rows)
}

func (f *FallbackClient) Last() (*Entry, error) {
	row := f.db.QueryRow(`
		SELECT id, content_type, content, COALESCE(preview,''),
		       COALESCE(source_bundle,''), COALESCE(source_name,''),
		       source_confidence, created_at, is_pinned
		FROM entries ORDER BY created_at DESC LIMIT 1`)
	var e Entry
	var pinned int
	if err := row.Scan(&e.ID, &e.ContentType, &e.Content, &e.Preview,
		&e.SourceBundle, &e.SourceName, &e.SourceConfidence, &e.CreatedAt, &pinned); err != nil {
		return nil, err
	}
	e.IsPinned = pinned != 0
	return &e, nil
}

func (f *FallbackClient) Pin(string) error    { return errDaemonRequired("pin") }
func (f *FallbackClient) Unpin(string) error  { return errDaemonRequired("unpin") }
func (f *FallbackClient) Delete(string) error { return errDaemonRequired("delete") }
func (f *FallbackClient) Transform(string, string) (string, error) {
	return "", errDaemonRequired("transform")
}
func (f *FallbackClient) Clear() (int, error) { return 0, errDaemonRequired("clear") }

func errDaemonRequired(op string) error {
	return fmt.Errorf("%s requires daemon — run: clipster daemon start", op)
}

func scanEntries(rows *sql.Rows) ([]Entry, error) {
	var out []Entry
	for rows.Next() {
		var e Entry
		var pinned int
		if err := rows.Scan(&e.ID, &e.ContentType, &e.Content, &e.Preview,
			&e.SourceBundle, &e.SourceName, &e.SourceConfidence, &e.CreatedAt, &pinned); err != nil {
			return nil, err
		}
		e.IsPinned = pinned != 0
		out = append(out, e)
	}
	return out, rows.Err()
}
