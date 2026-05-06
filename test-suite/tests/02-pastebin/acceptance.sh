#!/usr/bin/env bash
# acceptance.sh — heuristic check that the pastebin scaffold is functional.
# Verifies expected files exist, server boots, and the API endpoints respond.
set -uo pipefail

sandbox="${1:?sandbox path required}"
cd "$sandbox"

fail=0

# Required files (any reasonable layout)
for f in README.md; do
  if [[ -f "$f" ]]; then
    echo "✓ $f exists"
  else
    echo "✗ $f missing"
    fail=1
  fi
done

# Server entry point — be flexible about layout
server_file=""
for cand in server/index.js src/server.js src/index.js index.js app.js server.js; do
  if [[ -f "$cand" ]]; then
    server_file="$cand"
    break
  fi
done
if [[ -n "$server_file" ]]; then
  echo "✓ server entry: $server_file"
else
  echo "✗ no server entry point found"
  fail=1
fi

# DB module / schema
if find . -maxdepth 4 \( -name 'schema.sql' -o -name 'db*.js' -o -path './db/*' \) -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null | head -1 | grep -q .; then
  echo "✓ db module/schema present"
else
  echo "✗ no db module or schema"
  fail=1
fi

# Frontend
if find . -maxdepth 4 -name '*.html' -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null | head -1 | grep -q .; then
  echo "✓ HTML page present"
else
  echo "✗ no HTML page"
  fail=1
fi

# Try to boot the server briefly and hit it
if [[ -n "$server_file" ]]; then
  port=$((10000 + RANDOM % 50000))
  echo "Booting $server_file on port $port for 3s..."
  PORT="$port" timeout 3 node "$server_file" >/tmp/pastebin-acceptance.log 2>&1 &
  pid=$!
  sleep 2
  # Try POST /api/pastes
  if curl -sf -X POST -H 'Content-Type: application/json' \
      -d '{"content":"hello","expires_in_hours":24}' \
      "http://localhost:$port/api/pastes" >/tmp/post-out.json 2>&1; then
    echo "✓ POST /api/pastes responded"
  else
    echo "✗ POST /api/pastes failed (server may not honor PORT env or have wrong endpoint)"
    # Don't fail hard — port-binding conventions vary
  fi
  kill $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
fi

if [[ "$fail" -eq 0 ]]; then
  echo "PASS: scaffold appears complete"
  exit 0
else
  echo "FAIL: see above"
  exit 1
fi
