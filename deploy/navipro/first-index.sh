#!/usr/bin/env bash
# Builds the default corpus (W1 28 source + docs) once, on CPU, then lets the
# services start. Run by bcatlas-firstindex.service as user bcatlas. Safe to
# re-run: `ccc index` resumes from its own tracking state.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
ROOT=/opt/bcatlas/bc-code-atlas
MARKER=/var/lib/bcatlas/indexed

echo "==> $(date -Is) semantic index (hours on CPU)"
cd "$ROOT/data"
# The AL chunker must be importable by the indexer; same overlay the search server uses.
uv run --project "$ROOT/tools/cocoindex-code" --with-editable "$ROOT/chunker" ccc index

echo "==> $(date -Is) structural graph"
"$ROOT/scripts/rebuild-default-graph.sh"

date -Is > "$MARKER"
echo "==> $(date -Is) first index complete"
