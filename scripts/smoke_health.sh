#!/usr/bin/env bash
set -euo pipefail

HOST="${NODE_AGENT_HOST:-127.0.0.1}"
PORT="${NODE_AGENT_PORT:-8085}"
URL="http://${HOST}:${PORT}/health"

response="$(curl -fsS "$URL")"
printf '%s\n' "$response" | jq -e '.success == true and .status == "ready"' >/dev/null

printf 'health: ready\n'
printf 'ipv6_egress: '
printf '%s\n' "$response" | jq -c '.ipv6Egress // .ipv6 // {}'
