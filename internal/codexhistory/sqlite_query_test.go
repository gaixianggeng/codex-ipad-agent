package codexhistory

import (
	"database/sql"
	"encoding/json"
	"path/filepath"
	"testing"
)

func TestQuerySQLiteJSONReadsDatabaseWithoutExternalCLI(t *testing.T) {
	databasePath := filepath.Join(t.TempDir(), "state.sqlite")
	database, err := sql.Open("sqlite", databasePath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`
		create table threads (
			id text primary key,
			title text not null,
			updated_at_ms integer not null
		);
		insert into threads values ('thread-1', 'Windows path', 42);
	`); err != nil {
		database.Close()
		t.Fatal(err)
	}
	if err := database.Close(); err != nil {
		t.Fatal(err)
	}

	output, err := querySQLiteJSON(
		databasePath,
		"select id, title, updated_at_ms from threads",
	)
	if err != nil {
		t.Fatal(err)
	}

	var rows []struct {
		ID          string `json:"id"`
		Title       string `json:"title"`
		UpdatedAtMS int64  `json:"updated_at_ms"`
	}
	if err := json.Unmarshal(output, &rows); err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 ||
		rows[0].ID != "thread-1" ||
		rows[0].Title != "Windows path" ||
		rows[0].UpdatedAtMS != 42 {
		t.Fatalf("unexpected rows: %#v", rows)
	}
}

func TestSQLiteReadOnlyDSNDoesNotCreateMissingDatabase(t *testing.T) {
	databasePath := filepath.Join(t.TempDir(), "missing.sqlite")
	if _, err := querySQLiteJSON(databasePath, "select 1"); err == nil {
		t.Fatal("missing database must not be created")
	}
	if _, err := statFileFunc(databasePath); err == nil {
		t.Fatal("read-only query unexpectedly created the database")
	}
}
