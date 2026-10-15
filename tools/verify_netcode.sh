#!/bin/bash
# verify_netcode.sh — run the Goal 4 Worker A headless netcode checks.
# Starts the host process in the background, then the client process;
# both must print zero FAILs. Usage: tools/verify_netcode.sh
set -u
cd "$(dirname "$0")/.." || exit 1
GODOT="${GODOT:-$HOME/tools/godot-4.7.2/Godot_v4.7.2-stable_linux.x86_64}"
HOST_LOG="$(mktemp)"
CLIENT_LOG="$(mktemp)"
trap 'rm -f "$HOST_LOG" "$CLIENT_LOG"' EXIT
"$GODOT" --headless --path . --script res://tools/verify_netcode.gd -- --net-mode=host > "$HOST_LOG" 2>&1 &
HOST_PID=$!
# Give the host a moment to bind the server port before the client dials.
sleep 1
"$GODOT" --headless --path . --script res://tools/verify_netcode.gd -- --net-mode=client > "$CLIENT_LOG" 2>&1
CLIENT_RC=$?
wait "$HOST_PID"
HOST_RC=$?
cat "$HOST_LOG" "$CLIENT_LOG"
echo "verify_netcode: host exit=$HOST_RC client exit=$CLIENT_RC"
if [ "$HOST_RC" -eq 0 ] && [ "$CLIENT_RC" -eq 0 ]; then
	echo "verify_netcode: ALL CHECKS PASSED"
	exit 0
else
	echo "verify_netcode: FAILURES PRESENT"
	exit 1
fi
