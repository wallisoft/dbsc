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
#   --replace-range <path> <s> <e> <file>  Atomically replace a block of lines
#   --replace-block <path> <s> <old_file> <new_file>  Like replace-range, but
#                                  "end" is derived from old_file's line count,
#                                  and the DB is verified against it first
#   --find-brace <path> <s>        Preview the block from <s> to its matching
#                                  closing brace, without changing anything
#   --replace-brace <path> <s> <new_file>  Replace <s> through its matching
#                                  closing brace in one shot (naive counting —
#                                  no awareness of strings/comments)
#   --line <path> <n>             Print a single line's content
#   --show <path>                  Show current version (lines)
#   --list <path>                  List versions
#   --grep <path> <pattern>       Search one file
#   --grep-all <pattern>          Search every active file in the project
#   --rollback <path> <version>   Rollback to a previous version
#   --help                         Show usage
#
# Options:
#   --project <name>   Scope files to a project (default: basename of cwd)
#   --db <file>         SQLite DB file (default: ~/.dbsc/dbsc.db)
#   --deploy-dir <dir>  Where --deploy writes files (default: cwd)
#   --json              Output --show/--list/--grep/--grep-all/--line as JSON

set -e

DBSC_DIR="${DBSC_DIR:-$HOME/.dbsc}"
DB_FILE="${DBSC_DB:-$DBSC_DIR/dbsc.db}"
DEPLOY_DIR="${DBSC_DEPLOY_DIR:-$(pwd)}"
PROJECT="${DBSC_PROJECT:-$(basename "$(pwd)")}"

command -v sqlite3 >/dev/null 2>&1 || { echo "ERROR: sqlite3 not found. Install it (apt install sqlite3)."; exit 1; }

# Parse arguments
ACTION=""
SHOW_HELP=0
JSON_MODE=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --init) ACTION="init"; shift ;;
        --deploy) ACTION="deploy"; PATH_ARG="$2"; shift 2 ;;
        --deploy-all) ACTION="deploy_all"; shift ;;
        --update) ACTION="update"; FILE_ARG="$2"; shift 2 ;;
        --insert-line) ACTION="insert_line"; PATH_ARG="$2"; LINE_NUM="$3"; CONTENT_ARG="$4"; shift 4 ;;
        --delete-line) ACTION="delete_line"; PATH_ARG="$2"; LINE_NUM="$3"; shift 3 ;;
        --replace-line) ACTION="replace_line"; PATH_ARG="$2"; LINE_NUM="$3"; CONTENT_ARG="$4"; shift 4 ;;
        --replace-range) ACTION="replace_range"; PATH_ARG="$2"; START_ARG="$3"; END_ARG="$4"; RANGE_FILE_ARG="$5"; shift 5 ;;
        --replace-block) ACTION="replace_block"; PATH_ARG="$2"; START_ARG="$3"; OLD_FILE_ARG="$4"; RANGE_FILE_ARG="$5"; shift 5 ;;
        --find-brace) ACTION="find_brace"; PATH_ARG="$2"; LINE_NUM="$3"; shift 3 ;;
        --replace-brace) ACTION="replace_brace"; PATH_ARG="$2"; LINE_NUM="$3"; RANGE_FILE_ARG="$4"; shift 4 ;;
        --line) ACTION="line"; PATH_ARG="$2"; LINE_NUM="$3"; shift 3 ;;
        --show) ACTION="show"; PATH_ARG="$2"; shift 2 ;;
        --list) ACTION="list"; PATH_ARG="$2"; shift 2 ;;
        --grep) ACTION="grep"; PATH_ARG="$2"; PATTERN_ARG="$3"; shift 3 ;;
        --grep-all) ACTION="grep_all"; PATTERN_ARG="$2"; shift 2 ;;
        --rollback) ACTION="rollback"; PATH_ARG="$2"; VERSION_ARG="$3"; shift 3 ;;
        --project) PROJECT="$2"; shift 2 ;;
        --db) DB_FILE="$2"; shift 2 ;;
        --deploy-dir) DEPLOY_DIR="$2"; shift 2 ;;
        --json) JSON_MODE=1; shift ;;
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
  dbsc.sh --replace-range <path> <start> <end> <file>  # Atomically replace a block of lines
  dbsc.sh --replace-block <path> <start> <old_file> <new_file>  # Same, but end is automatic —
                                                  # derived from old_file's line count, and
                                                  # verified against the DB before replacing
  dbsc.sh --find-brace <path> <start>            # Preview block from <start> to its matching }
  dbsc.sh --replace-brace <path> <start> <file>  # Replace <start> through its matching } in one shot
  dbsc.sh --line <path> <num>                    # Print a single line's content
  dbsc.sh --show <path>                          # Show current version (numbered)
  dbsc.sh --list <path>                          # List versions
  dbsc.sh --grep <path> <pattern>                # Search one file (grep -E), prints path:line:content
  dbsc.sh --grep-all <pattern>                   # Search every active file in the project
  dbsc.sh --rollback <path> <version>            # Rollback to a previous version

Options:
  --project <name>    Scope (default: basename of cwd, i.e. "$PROJECT")
  --db <file>         SQLite file (default: ~/.dbsc/dbsc.db)
  --deploy-dir <dir>  Deploy directory (default: cwd)
  --json              Output --show/--list/--grep/--grep-all/--line as JSON
  --help              Show this help

Env overrides: DBSC_DB, DBSC_DEPLOY_DIR, DBSC_PROJECT, DBSC_DIR

Examples:
  dbsc.sh --update cms_renderer.php
  dbsc.sh --deploy cms_renderer.php
  dbsc.sh --insert-line cms_renderer.php 181 '        error_log("DEBUG");'
  dbsc.sh --show cms_renderer.php | grep DEBUG
  dbsc.sh --grep cms_renderer.php DEBUG
  dbsc.sh --grep-all TODO
  dbsc.sh --replace-range cms_renderer.php 40 55 new_block.php
  dbsc.sh --replace-block cms_renderer.php 40 old_block.php new_block.php
  dbsc.sh --find-brace cms_renderer.php 40
  dbsc.sh --replace-brace cms_renderer.php 40 new_function_body.php
  dbsc.sh --line cms_renderer.php 42
  dbsc.sh --show cms_renderer.php --json
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

# Escape a value for a JSON string (bash-only, no external deps)
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
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

    # Skip creating a new version if content is identical to the active one
    local active_fid=$(get_file_id "$path")
    if [ -n "$active_fid" ]; then
        local existing_content new_content
        existing_content=$(sqlite3 -batch -noheader -list "$DB_FILE" "
            SELECT content FROM dbsc_lines WHERE file_id=$active_fid ORDER BY line_order;
        " | md5sum)
        new_content=$(md5sum < "$file")
        if [ "$existing_content" = "$new_content" ]; then
            echo "⏭️  No change to $path (project: $PROJECT) — active version unchanged, skipping."
            return 0
        fi
    fi

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

# Atomically replace lines [start, end] with the contents of a file. New content
# can be a different number of lines than the range being replaced — the tail
# of the file is shifted by the resulting delta (positive, negative, or zero)
# using the same negate-then-restore trick as insert_line/delete_line.
replace_range() {
    local path="$1" start="$2" end="$3" file="$4"
    if [ ! -f "$file" ]; then
        echo "ERROR: File not found: $file"
        exit 1
    fi
    if ! [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || [ "$start" -gt "$end" ]; then
        echo "ERROR: invalid range $start-$end"
        exit 1
    fi
    local fid=$(ensure_file_id "$path")
    local old_count=$((end - start + 1))

    local new_count=0
    local inserts=""
    while IFS= read -r line || [ -n "$line" ]; do
        new_count=$((new_count + 1))
        local ln=$((start + new_count - 1))
        inserts+="INSERT INTO dbsc_lines (file_id, line_order, content) VALUES ($fid, $ln, '$(sql_escape "$line")');
"
    done < "$file"
    local delta=$((new_count - old_count))

    local batch
    batch=$(mktemp)
    {
        echo "BEGIN;"
        echo "DELETE FROM dbsc_lines WHERE file_id=$fid AND line_order BETWEEN $start AND $end;"
        echo "UPDATE dbsc_lines SET line_order = -line_order WHERE file_id=$fid AND line_order > $end;"
        echo "UPDATE dbsc_lines SET line_order = -line_order + ($delta) WHERE file_id=$fid AND line_order < 0;"
        printf '%s' "$inserts"
        echo "COMMIT;"
    } > "$batch"

    sqlite3 "$DB_FILE" < "$batch"
    rm -f "$batch"
    echo "✅ Replaced lines $start-$end ($old_count line(s)) with $new_count new line(s) in $path (net shift: $delta)."
}

# Like replace_range, but "end" is automatic: give the block of content you
# expect to find starting at `start`, and its line count determines where it
# ends. The DB is checked against that expected content first — if the file
# has moved under you since you last looked, this aborts instead of
# silently replacing the wrong lines.
replace_block() {
    local path="$1" start="$2" old_file="$3" new_file="$4"
    if [ ! -f "$old_file" ]; then echo "ERROR: File not found: $old_file"; exit 1; fi
    if [ ! -f "$new_file" ]; then echo "ERROR: File not found: $new_file"; exit 1; fi
    if ! [[ "$start" =~ ^[0-9]+$ ]]; then echo "ERROR: invalid start line $start"; exit 1; fi
    local fid=$(ensure_file_id "$path")

    local old_count=0
    while IFS= read -r line || [ -n "$line" ]; do old_count=$((old_count + 1)); done < "$old_file"
    local end=$((start + old_count - 1))

    local expected actual
    expected=$(cat "$old_file")
    actual=$(sqlite3 -batch -noheader -list "$DB_FILE" "
        SELECT content FROM dbsc_lines
        WHERE file_id=$fid AND line_order BETWEEN $start AND $end
        ORDER BY line_order;
    ")
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: content at lines $start-$end doesn't match what you expected — the file may have changed since you last looked. Aborting without making changes." >&2
        echo "--- expected (from $old_file) ---" >&2
        printf '%s\n' "$expected" >&2
        echo "--- actual (DB, lines $start-$end) ---" >&2
        printf '%s\n' "$actual" >&2
        exit 1
    fi

    replace_range "$path" "$start" "$end" "$new_file"
}

# Find the line where brace depth returns to zero, scanning from `start`.
# Naive character counting — does not understand strings or comments, so a
# literal { or } inside a quoted string or a // comment will throw it off.
# Prints nothing (empty) if no match is found before end of file.
find_matching_brace() {
    local fid="$1" start="$2"
    sqlite3 -batch -noheader -list "$DB_FILE" "
        SELECT content FROM dbsc_lines WHERE file_id=$fid AND line_order >= $start ORDER BY line_order;
    " | awk -v start="$start" '
        {
            n = length($0)
            for (i = 1; i <= n; i++) {
                c = substr($0, i, 1)
                if (c == "{") { depth++; opened = 1 }
                else if (c == "}") { depth-- }
            }
            if (opened && depth == 0) {
                print start + NR - 1
                exit
            }
        }
    '
}

# Read-only preview: show the block from `start` to its matching closing
# brace, without changing anything. Use this to sanity-check before
# --replace-brace, given the naive-matching caveat above.
show_brace() {
    local path="$1" start="$2"
    local fid=$(ensure_file_id "$path")
    local end=$(find_matching_brace "$fid" "$start")
    if [ -z "$end" ]; then
        echo "ERROR: no matching closing brace found starting from line $start in $path." >&2
        exit 1
    fi
    if [ "$JSON_MODE" -eq 1 ]; then
        local lines_json=$(sqlite3 -json -batch "$DB_FILE" "
            SELECT line_order AS line, content FROM dbsc_lines
            WHERE file_id=$fid AND line_order BETWEEN $start AND $end ORDER BY line_order;
        ")
        printf '{"path":"%s","start":%s,"end":%s,"lines":%s}\n' "$(json_escape "$path")" "$start" "$end" "$lines_json"
    else
        echo "🔎 $path lines $start-$end (matching brace)"
        sqlite3 -batch -noheader -separator '  ' "$DB_FILE" "
            SELECT line_order, content FROM dbsc_lines
            WHERE file_id=$fid AND line_order BETWEEN $start AND $end
            ORDER BY line_order;
        "
    fi
}

# Replace the block from `start` to its matching closing brace in one shot.
replace_brace() {
    local path="$1" start="$2" new_file="$3"
    if [ ! -f "$new_file" ]; then echo "ERROR: File not found: $new_file"; exit 1; fi
    if ! [[ "$start" =~ ^[0-9]+$ ]]; then echo "ERROR: invalid start line $start"; exit 1; fi
    local fid=$(ensure_file_id "$path")
    local end=$(find_matching_brace "$fid" "$start")
    if [ -z "$end" ]; then
        echo "ERROR: no matching closing brace found starting from line $start in $path." >&2
        echo "Note: brace matching is naive — it doesn't understand strings or comments containing { or }. Try --find-brace first to check." >&2
        exit 1
    fi
    echo "🔎 Found matching brace: lines $start-$end"
    replace_range "$path" "$start" "$end" "$new_file"
}

line_at() {
    local path="$1" n="$2"
    local fid=$(ensure_file_id "$path")
    local content=$(sqlite3 -batch -noheader -list "$DB_FILE" "
        SELECT content FROM dbsc_lines WHERE file_id=$fid AND line_order=$n;
    ")
    if [ "$JSON_MODE" -eq 1 ]; then
        printf '{"path":"%s","line":%s,"content":"%s"}\n' "$(json_escape "$path")" "$n" "$(json_escape "$content")"
    else
        printf '%s\n' "$content"
    fi
}

show_file() {
    local path="$1"
    local fid=$(ensure_file_id "$path")
    local ver=$(sqlite3 -batch "$DB_FILE" "SELECT version FROM dbsc_sources WHERE id=$fid;")
    if [ "$JSON_MODE" -eq 1 ]; then
        local lines_json=$(sqlite3 -json -batch "$DB_FILE" "
            SELECT line_order AS line, content FROM dbsc_lines
            WHERE file_id = $fid ORDER BY line_order;
        ")
        printf '{"path":"%s","project":"%s","version":%s,"lines":%s}\n' \
            "$(json_escape "$path")" "$(json_escape "$PROJECT")" "$ver" "$lines_json"
    else
        echo "📄 $path (project: $PROJECT, version $ver)"
        sqlite3 -batch -noheader -separator '  ' "$DB_FILE" "
            SELECT line_order, content FROM dbsc_lines
            WHERE file_id = $fid
            ORDER BY line_order;
        "
    fi
}

list_versions() {
    local path="$1"
    if [ "$JSON_MODE" -eq 1 ]; then
        sqlite3 -json -batch "$DB_FILE" "
            SELECT id, version, active, created_at
            FROM dbsc_sources
            WHERE project='$(sql_escape "$PROJECT")' AND path='$(sql_escape "$path")'
            ORDER BY version DESC;
        "
    else
        echo "📋 Versions for $path (project: $PROJECT):"
        sqlite3 -batch -header -column "$DB_FILE" "
            SELECT id, version, active, created_at
            FROM dbsc_sources
            WHERE project='$(sql_escape "$PROJECT")' AND path='$(sql_escape "$path")'
            ORDER BY version DESC;
        "
    fi
}

_grep_file_raw() {
    local path="$1" pattern="$2"
    local fid=$(get_file_id "$path")
    [ -z "$fid" ] && return 0
    # Unit separator (0x1F) between fields — won't collide with real source content.
    sqlite3 -batch -noheader "$DB_FILE" "
        SELECT line_order || char(31) || content FROM dbsc_lines
        WHERE file_id = $fid ORDER BY line_order;
    " | while IFS=$'\x1f' read -r lineno content; do
        if printf '%s' "$content" | grep -qE -- "$pattern"; then
            if [ "$JSON_MODE" -eq 1 ]; then
                printf '{"path":"%s","line":%s,"content":"%s"}\n' \
                    "$(json_escape "$path")" "$lineno" "$(json_escape "$content")"
            else
                printf '%s:%s:%s\n' "$path" "$lineno" "$content"
            fi
        fi
    done
}

grep_file() {
    local path="$1" pattern="$2"
    ensure_file_id "$path" >/dev/null
    if [ "$JSON_MODE" -eq 1 ]; then
        local matches=$(_grep_file_raw "$path" "$pattern")
        if [ -z "$matches" ]; then echo "[]"; else echo "[$(printf '%s' "$matches" | paste -sd, -)]"; fi
    else
        _grep_file_raw "$path" "$pattern"
    fi
}

grep_all() {
    local pattern="$1"
    local paths=$(sqlite3 -batch -noheader -list "$DB_FILE" "
        SELECT path FROM dbsc_sources WHERE project='$(sql_escape "$PROJECT")' AND active=1;
    ")
    if [ "$JSON_MODE" -eq 1 ]; then
        local all=""
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            local m=$(_grep_file_raw "$p" "$pattern")
            [ -n "$m" ] && all="${all:+$all$'\n'}$m"
        done <<< "$paths"
        if [ -z "$all" ]; then echo "[]"; else echo "[$(printf '%s' "$all" | paste -sd, -)]"; fi
    else
        while IFS= read -r p; do
            [ -n "$p" ] && _grep_file_raw "$p" "$pattern"
        done <<< "$paths"
    fi
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
    replace_range) replace_range "$PATH_ARG" "$START_ARG" "$END_ARG" "$RANGE_FILE_ARG" ;;
    replace_block) replace_block "$PATH_ARG" "$START_ARG" "$OLD_FILE_ARG" "$RANGE_FILE_ARG" ;;
    find_brace) show_brace "$PATH_ARG" "$LINE_NUM" ;;
    replace_brace) replace_brace "$PATH_ARG" "$LINE_NUM" "$RANGE_FILE_ARG" ;;
    line) line_at "$PATH_ARG" "$LINE_NUM" ;;
    show) show_file "$PATH_ARG" ;;
    list) list_versions "$PATH_ARG" ;;
    grep) grep_file "$PATH_ARG" "$PATTERN_ARG" ;;
    grep_all) grep_all "$PATTERN_ARG" ;;
    rollback) rollback "$PATH_ARG" "$VERSION_ARG" ;;
    *) echo "No action specified. Use --help."; exit 1 ;;
esac
