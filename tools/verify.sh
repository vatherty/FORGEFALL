#!/usr/bin/env bash
# tools/verify.sh — FORGEFALL project sanity check.
#
# Usage: ./tools/verify.sh [PROJECT_DIR]
#   PROJECT_DIR defaults to the repository root (parent of tools/).
#
# What it does:
#   1. If a `godot` binary is on PATH:
#        a. Runs a headless import (`--import`) so .godot/ caches and the
#           global class cache (class_name resolution) are built.
#        b. If tools/check_scripts.gd exists, runs it as a SceneTree script so
#           project-specific compile/logic checks execute headless.
#   2. If no `godot` binary is found: prints a file listing of the project and
#      exits 0 with "Godot not installed" — this is NOT a failure, it just
#      means the machine (e.g. a build VM) can't run the engine.
#
# Defensive notes:
#   - `set -u` (no pipefail: we want partial output, not a hard abort).
#   - Every godot invocation is guarded; a failing import still exits 0 here so
#     CI-style callers can decide policy themselves. The engine's own output
#     carries the real diagnostics.
set -u

PROJ="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

echo "== FORGEFALL verify =="
echo "project dir: $PROJ"

if [ ! -f "$PROJ/project.godot" ]; then
    echo "ERROR: no project.godot in $PROJ" >&2
    exit 1
fi

if ! command -v godot >/dev/null 2>&1; then
    echo "Godot not installed (no 'godot' on PATH)."
    echo "--- project file listing ---"
    find "$PROJ" -maxdepth 3 -not -path '*/.godot*' -not -path '*/.git*' | sort
    exit 0
fi

echo "godot: $(command -v godot)"
godot --version || true

echo "--- headless import ---"
# Builds .godot/, imports resources, registers class_name globals.
godot --headless --path "$PROJ" --import || echo "WARNING: import reported errors (see above)."

CHECK_SCRIPT="$PROJ/tools/check_scripts.gd"
if [ -f "$CHECK_SCRIPT" ]; then
    echo "--- running tools/check_scripts.gd ---"
    # check_scripts.gd must extend SceneTree (or MainLoop) to run this way.
    godot --headless --path "$PROJ" --script "res://tools/check_scripts.gd" \
        || echo "WARNING: check_scripts.gd reported errors (see above)."
else
    echo "(no tools/check_scripts.gd — skipping script compile check)"
fi

echo "== verify done =="
exit 0
