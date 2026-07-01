#!/bin/bash
# dbsc.sh – Line-based Database Source Control (SQLite backend)
# Stores files as lines in dbsc_lines for surgical, escape-safe updates.
# Own DB, auto-created on first run: ~/.dbsc/dbsc.db (override with --db / DBSC_DB)
# Multiple projects/frameworks share one DB, scoped by "project" (default: cwd basename).
#
# Commands:
#   --init                       Create tables (also runs automatically on first use)
#   --deploy <path>               Reconstruct <path> from DB lines to DEPLOY_DIR
#   --deploy-all                  Reconstruct all active files for current project
#   --update <file>                Insert/update a file (split into lines, new version)
#   --insert-line <path> <n> <c>  Insert a line (shifts later lines)
#   --delete-line <path> <n>      Delete a line (shifts later lines)
#   --replace-line <path> <n> <c> Replace a line
#   --show <path>                  Show current version (lines)
#   --list <path>                  List versions
#   --rollback <path> <version>   Rollback to a previous version
#   --help                         Show usage
#
# Options:
#   --project <name>   Scope files to a project (default: basename of cwd)
#   --db <file>         SQLite DB file (default: ~/.dbsc/dbsc.db)
#   --deploy-dir <dir>  Where --deploy writes files (default: cwd)

set -e

DBSC_DIR="${DBSC_DIR:-$HOME/.dbsc}"
DB_FILE="${DBSC_DB:-$DBSC_DIR/dbsc.db}"
DEPLOY_DIR="${DBSC_DEPLOY_DIR:-$(pwd)}"
PROJECT="${DBSC_PROJECT:-$(basename "$(pwd)")}"

command -v sqlite3 >/dev/null 2>&1 || { echo "ERROR: sqlite3 not found. Install it (apt install sqlite3)."; exit 1; }

# Parse arguments
ACTION=""
SHOW_HELP=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --init) ACTION="init"; shift ;;
        --deploy) ACTION="deploy"; PATH_ARG="$2"; shift 2 ;;
        --deploy-all) ACTION="deploy_all"; shift ;;
        --update) ACTION="update"; FILE_ARG="$2"; shift 2 ;;
        --insert-line) ACTION="insert_line"; PATH_ARG="$2"; LINE_NUM="$3"; CONTENT_ARG="$4"; shift 4 ;;
        --delete-line) ACTION="delete_line"; PATH_ARG="$2"; LINE_NUM="$3"; shift 3 ;;
        --replace-line) ACTION="replace_line"; PATH_ARG="$2"; LINE_NUM="$3"; CONTENT_ARG="$4"; shift 4 ;;
        --show) ACTION="show"; PATH_ARG="$2"; shift 2 ;;
        --list) ACTION="list"; PATH_ARG="$2"; shift 2 ;;
        --rollback) ACTION="rollback"; PATH_ARG="$2"; VERSION_ARG="$3"; shift 3 ;;
        --project) PROJECT="$2"; shift 2 ;;
        --db) DB_FILE="$2"; shift 2 ;;
        --deploy-dir) DEPLOY_DIR="$2"; shift 2 ;;
        --help|-h) SHOW_HELP=1; shift ;;
        *) echo "Unknown option: $1"; SHOW_HELP=1; shift ;;
    esac
done

if [ $SHOW_HELP -eq 1 ]; then
    cat <<EOF
dbsc.sh – Line-based Database Source Control (SQLite)

Usage:
  dbsc.sh --update <file>                        # Insert/update file (new version)
  dbsc.sh --deploy <path>                        # Reconstruct <path> to DEPLOY_DIR
  dbsc.sh --deploy-all                           # Reconstruct all active files
  dbsc.sh --insert-line <path> <num> <content>   # Insert a line (shift)
  dbsc.sh --delete-line <path> <num>             # Delete a line (shift)
  dbsc.sh --replace-line <path> <num> <content>  # Replace a line
  dbsc.sh --show <path>                          # Show current version (numbered)
  dbsc.sh --list <path>                          # List versions
  dbsc.sh --rollback <path> <version>            # Rollback to a previous version

Options:
  --project <name>    Scope (default: basename of cwd, i.e. "$PROJECT")
  --db <file>         SQLite file (default: ~/.dbsc/dbsc.db)
  --deploy-dir <dir>  Deploy directory (default: cwd)
  --help              Show this help

Env overrides: DBSC_DB, DBSC_DEPLOY_DIR, DBSC_PROJECT, DBSC_DIR

Examples:
  dbsc.sh --update cms_renderer.php
  dbsc.sh --deploy cms_renderer.php
  dbsc.sh --insert-line cms_renderer.php 181 '        error_log("DEBUG");'
  dbsc.sh --show cms_renderer.php | grep DEBUG
  dbsc.sh --rollback cms_renderer.php 1
  dbsc.sh --project tinyhost --show checkout.php
EOF
    exit 0
fi

# --- Helpers ---

# Escape a value for a single-quoted SQLite string literal (only ' needs doubling)
sql_escape() {
    printf '%s' "${1//\'/\'\'}"
}

ensure_db() {
    mkdir -p "$(dirname "$DB_FILE")"
    sqlite3 "$DB_FILE" "
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS dbsc_sources (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project TEXT NOT NULL,
            path TEXT NOT NULL,
            version INTEGER NOT NULL,
            active INTEGER NOT NULL DEFAULT 1,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(project, path, version)
        );
        CREATE INDEX IF NOT EXISTS idx_dbsc_active ON dbsc_sources(project, path, active);
        CREATE TABLE IF NOT EXISTS dbsc_lines (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id INTEGER NOT NULL,
            line_order INTEGER NOT NULL,
            content TEXT NOT NULL,
            UNIQUE(file_id, line_order),
            FOREIGN KEY (file_id) REFERENCES dbsc_sources(id) ON DELETE CASCADE
        );
    "
}

get_file_id() {
    local path="$1"
    sqlite3 -batch "$DB_FILE" "
        SELECT id FROM dbsc_sources
        WHERE project='$(sql_escape "$PROJECT")' AND path='$(sql_escape "$path")' AND active=1
        LIMIT 1;
    "
}

get_next_version() {
    local path="$1"
    sqlite3 -batch "$DB_FILE" "
        SELECT COALESCE(MAX(version), 0) + 1
        FROM dbsc_sources
        WHERE project='$(sql_escape "$PROJECT")' AND path='$(sql_escape "$path")';
    "
}

ensure_file_id() {
    local fid=$(get_file_id "$1")
    if [ -z "$fid" ]; then
        echo "ERROR: File '$1' not found in project '$PROJECT'." >&2
        exit 1
    fi
    echo "$fid"
}

# --- Init ---

init() {
    echo "🔧 Initialising SQLite DB at $DB_FILE ..."
    ensure_db
    echo "✅ Tables ready."
}

# --- Deploy ---

deploy_file() {
    local path="$1"
    local fid=$(get_file_id "$path")
    if [ -z "$fid" ]; then
        echo "ERROR: File '$path' not found in project '$PROJECT'." >&2
        return 1
    fi
    local target="$DEPLOY_DIR/$path"
    mkdir -p "$(dirname "$target")"
    sqlite3 -batch -noheader -list "$DB_FILE" "
        SELECT content FROM dbsc_lines WHERE file_id=$fid ORDER BY line_order;
    " > "$target"
    echo "  ✅ $target"
}

deploy_all() {
    echo "📦 Deploying all active '$PROJECT' files to $DEPLOY_DIR ..."
    local paths=$(sqlite3 -batch -noheader -list "$DB_FILE" "
        SELECT path FROM dbsc_sources WHERE project='$(sql_escape "$PROJECT")' AND active=1;
    ")
    while IFS= read -r p; do
        [ -n "$p" ] && deploy_file "$p"
    done <<< "$paths"
    echo "✅ Deployment complete."
}

# --- Update (insert new version from file) ---
# Lines are split IN BASH and written to a batch SQL file (not passed via -e),
# so no line content ever has to survive a round trip through the shell's
# own argument parsing. Only ' needs doubling for SQLite.

update_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "ERROR: File not found: $file"
        exit 1
    fi
    local path=$(basename "$file")
    local pe=$(sql_escape "$PROJECT")
    local path_e=$(sql_escape "$path")
    local version=$(get_next_version "$path")
    [ -z "$version" ] && version=1

    echo "📥 Inserting version $version of $path (project: $PROJECT) ..."

    sqlite3 "$DB_FILE" "
        UPDATE dbsc_sources SET active=0 WHERE project='$pe' AND path='$path_e';
        INSERT INTO dbsc_sources (project, path, version, active) VALUES ('$pe', '$path_e', $version, 1);
    "
    local file_id=$(sqlite3 -batch "$DB_FILE" "
        SELECT id FROM dbsc_sources WHERE project='$pe' AND path='$path_e' AND version=$version;
    ")

    local batch
    batch=$(mktemp)
    {
        echo "BEGIN;"
        local line_num=0
        while IFS= read -r line || [ -n "$line" ]; do
            line_num=$((line_num + 1))
            printf "INSERT INTO dbsc_lines (file_id, line_order, content) VALUES (%s, %s, '%s');\n" \
                "$file_id" "$line_num" "$(sql_escape "$line")"
        done < "$file"
        echo "COMMIT;"
    } > "$batch"

    sqlite3 "$DB_FILE" < "$batch"
    rm -f "$batch"

    echo "✅ Version $version inserted ($line_num lines)."
}

# --- Surgical line operations ---

insert_line() {
    local path="$1" line_num="$2" content="$3"
    local fid=$(ensure_file_id "$path")
    echo "📝 Inserting line $line_num in $path ..."
    # SQLite doesn't guarantee row order within a multi-row UPDATE, so shifting
    # line_order upward in place can collide (e.g. line 7 bumped to 8 before
    # line 6 is bumped to 7). Negate first so shifted rows can never collide
    # with not-yet-shifted ones, then restore to the final positive value.
    sqlite3 "$DB_FILE" "
        BEGIN;
        UPDATE dbsc_lines SET line_order = -line_order
        WHERE file_id = $fid AND line_order >= $line_num;
        UPDATE dbsc_lines SET line_order = -line_order + 1
        WHERE file_id = $fid AND line_order < 0;
        INSERT INTO dbsc_lines (file_id, line_order, content)
        VALUES ($fid, $line_num, '$(sql_escape "$content")');
        COMMIT;
    "
    echo "✅ Line inserted."
}

delete_line() {
    local path="$1" line_num="$2"
    local fid=$(ensure_file_id "$path")
    echo "🗑️  Deleting line $line_num from $path ..."
    # Same negate-then-restore trick as insert_line, to avoid UNIQUE collisions
    # while shifting the tail of the file down by one.
    sqlite3 "$DB_FILE" "
        BEGIN;
        DELETE FROM dbsc_lines WHERE file_id = $fid AND line_order = $line_num;
        UPDATE dbsc_lines SET line_order = -line_order
        WHERE file_id = $fid AND line_order > $line_num;
        UPDATE dbsc_lines SET line_order = -line_order - 1
        WHERE file_id = $fid AND line_order < 0;
        COMMIT;
    "
    echo "✅ Line deleted."
}

replace_line() {
    local path="$1" line_num="$2" content="$3"
    local fid=$(ensure_file_id "$path")
    echo "✏️  Replacing line $line_num in $path ..."
    sqlite3 "$DB_FILE" "
        UPDATE dbsc_lines
        SET content = '$(sql_escape "$content")'
        WHERE file_id = $fid AND line_order = $line_num;
    "
    echo "✅ Line replaced."
}

show_file() {
    local path="$1"
    local fid=$(ensure_file_id "$path")
    local ver=$(sqlite3 -batch "$DB_FILE" "SELECT version FROM dbsc_sources WHERE id=$fid;")
    echo "📄 $path (project: $PROJECT, version $ver)"
    sqlite3 -batch -noheader -separator '  ' "$DB_FILE" "
        SELECT line_order, content FROM dbsc_lines
        WHERE file_id = $fid
        ORDER BY line_order;
    "
}

list_versions() {
    local path="$1"
    echo "📋 Versions for $path (project: $PROJECT):"
    sqlite3 -batch -header -column "$DB_FILE" "
        SELECT id, version, active, created_at
        FROM dbsc_sources
        WHERE project='$(sql_escape "$PROJECT")' AND path='$(sql_escape "$path")'
        ORDER BY version DESC;
    "
}

rollback() {
    local path="$1" version="$2"
    local pe=$(sql_escape "$PROJECT") path_e=$(sql_escape "$path")
    echo "⏪ Rolling back $path to version $version (project: $PROJECT) ..."
    sqlite3 "$DB_FILE" "
        UPDATE dbsc_sources SET active=0 WHERE project='$pe' AND path='$path_e' AND active=1;
        UPDATE dbsc_sources SET active=1 WHERE project='$pe' AND path='$path_e' AND version=$version;
    "
    echo "✅ Rollback complete."
    deploy_file "$path"
}

# --- Main ---

[ "$ACTION" = "init" ] || ensure_db

case $ACTION in
    init) init ;;
    deploy) deploy_file "$PATH_ARG" ;;
    deploy_all) deploy_all ;;
    update) update_file "$FILE_ARG" ;;
    insert_line) insert_line "$PATH_ARG" "$LINE_NUM" "$CONTENT_ARG" ;;
    delete_line) delete_line "$PATH_ARG" "$LINE_NUM" ;;
    replace_line) replace_line "$PATH_ARG" "$LINE_NUM" "$CONTENT_ARG" ;;
    show) show_file "$PATH_ARG" ;;
    list) list_versions "$PATH_ARG" ;;
    rollback) rollback "$PATH_ARG" "$VERSION_ARG" ;;
    *) echo "No action specified. Use --help."; exit 1 ;;
esac
