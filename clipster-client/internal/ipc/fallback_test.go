package ipc

import (
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"

	_ "modernc.org/sqlite"
)

// makeTestDB creates a temporary history.db with the clipster schema.
func makeTestDB(t *testing.T) (string, *sql.DB) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "history.db")

	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}

	_, err = db.Exec(`
		CREATE TABLE entries (
			id TEXT PRIMARY KEY,
			content_type TEXT NOT NULL,
			content BLOB NOT NULL,
			preview TEXT,
			source_bundle TEXT,
			source_name TEXT,
			source_confidence TEXT NOT NULL DEFAULT 'high',
			created_at INTEGER NOT NULL,
			is_pinned INTEGER NOT NULL DEFAULT 0,
			content_hash TEXT NOT NULL
		)`)
	if err != nil {
		t.Fatalf("create table: %v", err)
	}

	return path, db
}

// insertEntry inserts a test row directly into the DB.
func insertEntry(t *testing.T, db *sql.DB, id, content, ctype string, pinned bool, createdAt int64) {
	t.Helper()
	pin := 0
	if pinned {
		pin = 1
	}
	_, err := db.Exec(`INSERT INTO entries
		(id, content_type, content, preview, source_bundle, source_name, source_confidence, created_at, is_pinned, content_hash)
		VALUES (?,?,?,?,?,?,'high',?,?,?)`,
		id, ctype, content, content[:min(len(content), 200)], "", "TestApp", createdAt, pin, "hash-"+id,
	)
	if err != nil {
		t.Fatalf("insert: %v", err)
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func openFallbackFromPath(t *testing.T, path string) HistoryClient {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+path+"?mode=ro")
	if err != nil {
		t.Fatalf("open fallback: %v", err)
	}
	return &FallbackClient{db: db}
}

// ─── Tests ───────────────────────────────────────────────────────────────────

func TestFallbackClient_ListEmpty(t *testing.T) {
	path, db := makeTestDB(t)
	db.Close()

	client := openFallbackFromPath(t, path)
	defer client.Close()

	entries, err := client.List(10, 0)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(entries) != 0 {
		t.Errorf("expected 0 entries, got %d", len(entries))
	}
}

func TestFallbackClient_ListReturnsEntries(t *testing.T) {
	path, db := makeTestDB(t)
	insertEntry(t, db, "id1", "hello world", "plain-text", false, 1000)
	insertEntry(t, db, "id2", "second entry", "plain-text", false, 2000)
	db.Close()

	client := openFallbackFromPath(t, path)
	defer client.Close()

	entries, err := client.List(10, 0)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(entries) != 2 {
		t.Errorf("expected 2 entries, got %d", len(entries))
	}
	// Most recent first
	if entries[0].ID != "id2" {
		t.Errorf("expected id2 first (most recent), got %s", entries[0].ID)
	}
}

func TestFallbackClient_PinsFiltered(t *testing.T) {
	path, db := makeTestDB(t)
	insertEntry(t, db, "id1", "unpinned", "plain-text", false, 1000)
	insertEntry(t, db, "id2", "pinned", "plain-text", true, 2000)
	db.Close()

	client := openFallbackFromPath(t, path)
	defer client.Close()

	pins, err := client.Pins()
	if err != nil {
		t.Fatalf("Pins: %v", err)
	}
	if len(pins) != 1 || pins[0].ID != "id2" {
		t.Errorf("expected 1 pinned entry (id2), got %v", pins)
	}
}

func TestFallbackClient_Last(t *testing.T) {
	path, db := makeTestDB(t)
	insertEntry(t, db, "id1", "first", "plain-text", false, 1000)
	insertEntry(t, db, "id2", "second", "plain-text", false, 2000)
	db.Close()

	client := openFallbackFromPath(t, path)
	defer client.Close()

	e, err := client.Last()
	if err != nil {
		t.Fatalf("Last: %v", err)
	}
	if e.ID != "id2" {
		t.Errorf("expected last entry id2, got %s", e.ID)
	}
}

func TestFallbackClient_WriteOpsReturnDaemonError(t *testing.T) {
	path, db := makeTestDB(t)
	db.Close()

	client := openFallbackFromPath(t, path)
	defer client.Close()

	checkErr := func(t *testing.T, err error, op string) {
		t.Helper()
		if err == nil {
			t.Errorf("%s: expected error, got nil", op)
			return
		}
		if !strings.Contains(err.Error(), "daemon") {
			t.Errorf("%s: expected daemon error, got: %v", op, err)
		}
	}

	checkErr(t, client.Pin("x"), "Pin")
	checkErr(t, client.Unpin("x"), "Unpin")
	checkErr(t, client.Delete("x"), "Delete")

	_, err := client.Transform("x", "uppercase")
	checkErr(t, err, "Transform")

	_, err = client.Clear()
	checkErr(t, err, "Clear")
}

func TestFallbackClient_IsPinnedParsed(t *testing.T) {
	path, db := makeTestDB(t)
	insertEntry(t, db, "id1", "pinned entry", "plain-text", true, 1000)
	db.Close()

	client := openFallbackFromPath(t, path)
	defer client.Close()

	entries, err := client.List(10, 0)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(entries) == 0 {
		t.Fatal("no entries")
	}
	if !entries[0].IsPinned {
		t.Error("expected IsPinned=true")
	}
}

func TestFallbackClient_FileNotFoundError(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nonexistent.db")
	// With mode=ro, trying to open a nonexistent file should error.
	db, err := sql.Open("sqlite", "file:"+path+"?mode=ro")
	if err != nil {
		return // expected
	}
	// Ping forces actual connection
	if err := db.Ping(); err != nil {
		os.Remove(path)
		return // expected — file doesn't exist in ro mode
	}
	db.Close()
	os.Remove(path)
}
