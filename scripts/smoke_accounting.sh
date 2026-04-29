#!/usr/bin/env bash
set -euo pipefail

AGENT_URL="${1:-http://127.0.0.1:8085}"
API_KEY_HEADER=()
if [ -n "${NODE_AGENT_API_KEY:-}" ]; then
  API_KEY_HEADER=(-H "X-API-KEY: ${NODE_AGENT_API_KEY}")
fi

echo "1. GET /describe — verifying supports.accounting == true"
curl -fsS "${API_KEY_HEADER[@]}" "$AGENT_URL/describe" | jq -e '.supports.accounting == true' >/dev/null
echo "   OK"

echo "2. GET /accounting?ports= without ports → 400"
code=$(curl -s -o /dev/null -w '%{http_code}' "${API_KEY_HEADER[@]}" "$AGENT_URL/accounting?ports=")
[ "$code" = "400" ] || { echo "expected 400, got $code"; exit 1; }
echo "   OK"

echo "3. GET /accounting?ports=99999 (non-existent port) → 200 with empty map"
body=$(curl -fsS "${API_KEY_HEADER[@]}" "$AGENT_URL/accounting?ports=99999")
echo "$body" | jq -e '.success == true and (.counters | length == 0)' >/dev/null
echo "   OK"

echo "4. POST /accounts/99999/disable (non-existent port) → 404"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${API_KEY_HEADER[@]}" "$AGENT_URL/accounts/99999/disable")
[ "$code" = "404" ] || { echo "expected 404, got $code"; exit 1; }
echo "   OK"

echo "5. POST /accounts/99999/enable (non-existent port) → 404"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${API_KEY_HEADER[@]}" "$AGENT_URL/accounts/99999/enable")
[ "$code" = "404" ] || { echo "expected 404, got $code"; exit 1; }
echo "   OK"

echo ""
echo "All smoke checks passed."
