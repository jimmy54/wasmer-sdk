#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ETS="$ROOT/harmony/wasmer/src/main/ets"
exports="$(mktemp)"
codes="$(mktemp)"
trap 'rm -f "$exports" "$codes"' EXIT

grep -hoE '^export (class|interface|type|const) [A-Za-z0-9_]+' \
  "$ETS/index.ets" "$ETS/errors.ets" | awk '{print $3}' | sort -u > "$exports"

awk '/^export type WasmerErrorCode =/ { in_codes = 1 }
  in_codes { print }
  in_codes && /;/ { exit }' "$ETS/errors.ets" \
  | grep -oE '"[A-Z0-9_]+"' | tr -d '"' | sort -u > "$codes"

status=0

missing_exports="$(comm -23 "$ROOT/tests/upstream-api.txt" "$exports")"
if [[ -n "$missing_exports" ]]; then
  echo "Missing upstream exports:" >&2
  echo "$missing_exports" >&2
  status=1
fi

missing_codes="$(comm -23 "$ROOT/tests/upstream-error-codes.txt" "$codes")"
if [[ -n "$missing_codes" ]]; then
  echo "Missing upstream error codes:" >&2
  echo "$missing_codes" >&2
  status=1
fi

if [[ "$status" -ne 0 ]]; then
  exit "$status"
fi

echo "API surface OK: $(wc -l < "$ROOT/tests/upstream-api.txt" | tr -d ' ') exports, $(wc -l < "$ROOT/tests/upstream-error-codes.txt" | tr -d ' ') error codes"
echo "Additional HarmonyOS exports:"
comm -13 "$ROOT/tests/upstream-api.txt" "$exports" | sed 's/^/  /'
