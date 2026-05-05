#!/usr/bin/env bash
# install.sh — copy the dual-build skill and agents into ~/.claude/
# Use this if you're not installing via the Claude Code plugin system.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_AGENTS="${HOME}/.claude/agents"
DEST_SKILL="${HOME}/.claude/skills/dual-build"

mkdir -p "$DEST_AGENTS" "$DEST_SKILL"

cp -v "$SCRIPT_DIR/agents/claude-builder.md"   "$DEST_AGENTS/"
cp -v "$SCRIPT_DIR/agents/codex-builder.md"    "$DEST_AGENTS/"
cp -v "$SCRIPT_DIR/agents/claude-reviewer.md"  "$DEST_AGENTS/"
cp -v "$SCRIPT_DIR/agents/codex-reviewer.md"   "$DEST_AGENTS/"
cp -v "$SCRIPT_DIR/skills/dual-build/SKILL.md" "$DEST_SKILL/"

cat <<EOF

Installed dual-build into ~/.claude/.
  agents: $DEST_AGENTS
  skill:  $DEST_SKILL

Restart Claude Code if /dual-build doesn't appear immediately.
Verify the Codex plugin is authenticated by running /codex:setup.
EOF
