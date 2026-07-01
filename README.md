# dbsc.sh

**Line-based Database Source Control.** A tiny, dependency-light alternative to
git for surgical, single-line edits to source files — designed to be safe for
both humans and AI agents to drive.

Every file is stored as individual rows (one per line) in a local SQLite
database (`~/.dbsc/dbsc.db` by default). That gives you:

- **Surgical edits** — insert, replace, or delete a single line by number,
  without ever generating a diff, a patch, or a full file rewrite.
- **No escaping hell** — content is passed through batch SQL files rather
  than inline shell commands, and SQLite string literals only need `'`
  doubled (no backslash rules to fight). Verified round-trip safe with
  quotes, backslashes, tabs, and blank lines.
- **Full version history** — every `--update` or line edit creates a new
  version; nothing is ever destructively overwritten. Roll back any file to
  any prior version instantly.
- **Zero setup** — the DB and its schema are created automatically on first
  use. No server, no daemon, just a single `.db` file.
- **Multi-project by design** — one DB can safely track files across many
  unrelated projects/frameworks, scoped by a `--project` name (defaults to
  the current directory).

## Why this exists

Built for workflows where an AI coding agent (or a human, late at night) is
making small, targeted edits to live source files — a debug line here, a
config tweak there — and a full git commit/diff cycle is overkill, but you
still want every change tracked and trivially reversible. Line-addressable
storage means an agent can say "insert this at line 181" without needing to
reconstruct or reproduce surrounding context, which is where most
shell/SQL-escaping bugs come from in agentic edit loops.

## Install

```bash
git clone https://github.com/<you>/dbsc.git
chmod +x dbsc/dbsc.sh
sudo ln -s "$(pwd)/dbsc/dbsc.sh" /usr/local/bin/dbsc.sh
```

Or just run `./install.sh` from inside the cloned repo.

Requires `bash` and `sqlite3` (`apt install sqlite3` / `brew install sqlite3`).
Nothing else.

## Quick start

```bash
# Track a file (creates version 1)
dbsc.sh --update myscript.php

# Show it back, numbered
dbsc.sh --show myscript.php

# Surgical single-line edit
dbsc.sh --insert-line myscript.php 42 '        error_log("here");'
dbsc.sh --replace-line myscript.php 10 '$debug = true;'
dbsc.sh --delete-line myscript.php 42

# Write the current version out to disk
dbsc.sh --deploy myscript.php --deploy-dir /var/www/html

# See every version, and roll back
dbsc.sh --list myscript.php
dbsc.sh --rollback myscript.php 2

# Find a line without piping through grep and getting an off-by-one
# from a header line — output is path:line:content, ready to paste
# straight into --replace-line
dbsc.sh --grep myscript.php 'TODO'
dbsc.sh --grep-all 'error_log'

# Swap a whole block (e.g. a function body) atomically in one transaction —
# new content can be a different number of lines, the tail renumbers itself
dbsc.sh --replace-range myscript.php 40 55 new_block.php

# Same idea, but you don't need to count the end line yourself — give the
# block you expect to find there, its line count becomes the end line, and
# it's verified against the DB first (aborts cleanly if the file has moved
# since you last looked, instead of replacing the wrong lines)
dbsc.sh --replace-block myscript.php 40 old_block.php new_block.php

# Structured output for scripting/agents — same data, no text-parsing required
dbsc.sh --show myscript.php --json
dbsc.sh --grep-all 'TODO' --json
```

## Multi-project usage

```bash
dbsc.sh --project siteA --update checkout.php
dbsc.sh --project siteB --update checkout.php   # no collision — separate scope
dbsc.sh --project siteA --show checkout.php
```

By default `--project` is inferred from the basename of your current
directory, so running inside each project's folder usually needs no flag at
all.

## Command reference

| Command | Description |
|---|---|
| `--update <file>` | Insert/update a file (new version, split into lines) |
| `--deploy <path>` | Reconstruct `<path>` from the DB to `--deploy-dir` |
| `--deploy-all` | Reconstruct every active file for the current project |
| `--insert-line <path> <n> <content>` | Insert a line, shifting the rest down |
| `--delete-line <path> <n>` | Delete a line, shifting the rest up |
| `--replace-line <path> <n> <content>` | Replace a single line in place |
| `--replace-range <path> <start> <end> <file>` | Atomically replace a block of lines with new content (any line count) |
| `--replace-block <path> <start> <old_file> <new_file>` | Same, but `end` is automatic — derived from `old_file`'s line count, and the DB is verified against it before replacing |
| `--line <path> <n>` | Print a single line's content |
| `--show <path>` | Print the current version, numbered |
| `--list <path>` | List all stored versions |
| `--grep <path> <pattern>` | Search one file (`grep -E`), prints `path:line:content` |
| `--grep-all <pattern>` | Search every active file in the current project |
| `--rollback <path> <version>` | Reactivate an old version and deploy it |
| `--init` | Create the DB/schema (also runs automatically on first use) |

### Options

| Flag | Default |
|---|---|
| `--project <name>` | basename of current directory |
| `--db <file>` | `~/.dbsc/dbsc.db` |
| `--deploy-dir <dir>` | current directory |
| `--json` | off — add to `--show`/`--list`/`--grep`/`--grep-all`/`--line` for structured output |

Environment overrides: `DBSC_DB`, `DBSC_DEPLOY_DIR`, `DBSC_PROJECT`, `DBSC_DIR`.

## How it works

Two tables, one SQLite file:

- `dbsc_sources` — one row per `(project, path, version)`, with an `active`
  flag marking the current version.
- `dbsc_lines` — one row per line, `(file_id, line_order, content)`.

Line-shift operations (`--insert-line` / `--delete-line`) use a
negate-then-restore pattern to avoid `UNIQUE` constraint collisions, since
SQLite doesn't guarantee row processing order within a multi-row `UPDATE`.

## License

MIT — see [LICENSE](LICENSE).
