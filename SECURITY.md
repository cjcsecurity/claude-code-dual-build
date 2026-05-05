# Security policy

## Reporting a vulnerability

If you find a security issue in this project, please report it through GitHub's private vulnerability reporting:

https://github.com/cjcsecurity/claude-code-dual-build/security/advisories/new

Do not open a public issue for security concerns. I aim to acknowledge reports within 72 hours.

## Scope

This project is a set of Markdown skill and agent definitions for Claude Code. Relevant security concerns include:

- **Prompt injection vectors** in skill or agent definitions that an attacker could exploit when the skill is loaded into a Claude Code session
- **Instructions that could leak sensitive data**, exfiltrate credentials, or escape the intended sandbox
- **Documentation that misleads users** into running unsafe commands (e.g., a `curl | bash` pattern, an `rm -rf` example with a working path)
- **Worktree isolation gaps** — if the skill's instructions could cause an agent to escape the assigned worktree and modify the main repo without the user's confirmation

The project does not run code itself; it instructs Claude Code and Codex. Vulnerabilities in those tools are out of scope here — please report them upstream:

- Claude Code: https://github.com/anthropics/claude-code/issues (security: see https://www.anthropic.com/responsible-disclosure-policy)
- Codex (OpenAI): https://github.com/openai/codex-plugin-cc

## Supported versions

Only the latest commit on `main` is supported.

## Hardening assumptions made by this project

- The user has reviewed the agent and skill markdown before installing.
- The user understands that these agents will dispatch real builds (file writes, commits) when invoked, and that the orchestrator will pause for confirmation before parallel build dispatch.
- The Codex MCP plugin is installed and authenticated; the agents in this project assume `mcp__codex__codex` is available.

If any of those assumptions could be violated by something a downstream user copy-pastes, please report it.
