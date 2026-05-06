#!/usr/bin/env bash
# Greenfield scaffold: empty Node + Express + better-sqlite3 + marked project,
# nothing implemented. The /dual-build (or baseline) run must build the whole
# pastebin app from this starting point.
set -euo pipefail

sandbox="${1:?sandbox path required}"
rm -rf "$sandbox"
mkdir -p "$sandbox"
cd "$sandbox"

git init -q -b main
git config user.email "test@example.com"
git config user.name "test"

npm init -y -q >/dev/null
npm pkg set type=module >/dev/null
npm i --silent express better-sqlite3 marked >/dev/null 2>&1 || npm i express better-sqlite3 marked

git add .
git commit -qm "initial scaffold: deps installed, no src yet"

echo "Scaffolded empty pastebin project at $sandbox"
