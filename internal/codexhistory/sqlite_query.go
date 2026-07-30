package codexhistory

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/url"
	"path/filepath"
	"runtime"
	"strings"

	_ "modernc.org/sqlite"
)

// querySQLiteJSON preserves the small JSON boundary previously provided by
// `sqlite3 -json`, while keeping SQLite access inside agentd on every host OS.
func querySQLiteJSON(databasePath string, query string) ([]byte, error) {
	dsn, err := sqliteReadOnlyDSN(databasePath)
	if err != nil {
		return nil, err
	}

	database, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite database: %w", err)
	}
	database.SetMaxOpenConns(1)
	defer database.Close()

	rows, err := database.Query(query)
	if err != nil {
		return nil, fmt.Errorf("query sqlite database: %w", err)
	}
	defer rows.Close()

	columns, err := rows.Columns()
	if err != nil {
		return nil, fmt.Errorf("read sqlite columns: %w", err)
	}

	result := make([]map[string]any, 0)
	for rows.Next() {
		values := make([]any, len(columns))
		destinations := make([]any, len(columns))
		for index := range values {
			destinations[index] = &values[index]
		}
		if err := rows.Scan(destinations...); err != nil {
			return nil, fmt.Errorf("scan sqlite row: %w", err)
		}

		item := make(map[string]any, len(columns))
		for index, column := range columns {
			value := values[index]
			if bytes, ok := value.([]byte); ok {
				value = string(bytes)
			}
			item[column] = value
		}
		result = append(result, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate sqlite rows: %w", err)
	}

	output, err := json.Marshal(result)
	if err != nil {
		return nil, fmt.Errorf("encode sqlite rows: %w", err)
	}
	return output, nil
}

func sqliteReadOnlyDSN(databasePath string) (string, error) {
	absolutePath, err := filepath.Abs(databasePath)
	if err != nil {
		return "", fmt.Errorf("resolve sqlite database path: %w", err)
	}

	slashPath := filepath.ToSlash(absolutePath)
	if runtime.GOOS == "windows" && !strings.HasPrefix(slashPath, "/") {
		slashPath = "/" + slashPath
	}
	location := url.URL{
		Scheme: "file",
		Path:   slashPath,
	}
	parameters := location.Query()
	parameters.Set("mode", "ro")
	location.RawQuery = parameters.Encode()
	return location.String(), nil
}
