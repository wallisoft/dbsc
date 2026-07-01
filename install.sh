#!/bin/bash
# install.sh - symlink dbsc.sh onto PATH via /usr/local/bin
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$DIR/dbsc.sh"
LINK="/usr/local/bin/dbsc.sh"

if [ ! -f "$TARGET" ]; then
    echo "ERROR: dbsc.sh not found in $DIR"
    exit 1
fi

chmod +x "$TARGET"

if [ -w "$(dirname "$LINK")" ]; then
    ln -sf "$TARGET" "$LINK"
else
    echo "Need sudo to link into /usr/local/bin ..."
    sudo ln -sf "$TARGET" "$LINK"
fi

echo "✅ Linked $LINK -> $TARGET"
command -v sqlite3 >/dev/null 2>&1 || echo "⚠️  sqlite3 not found — install it (apt install sqlite3 / brew install sqlite3)"
echo "Try: dbsc.sh --help"
