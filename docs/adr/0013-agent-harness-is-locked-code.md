# 13. The agent harness is locked like code

Status: accepted, 2026-11-18. Built.

## Context

Coding agents execute configuration from the repository they open. Claude Code runs project hooks in `.claude/settings.json` without asking, even in a folder that was never trusted, under `claude -p`, or when only a parent folder is trusted ([docs](https://code.claude.com/docs/en/permissions), "What runs before you trust a folder"). In a trusted folder it hot-reloads changed hooks. GTIG (Nov 2026) reports a suspected DPRK cluster that pivoted into internal repositories and edited `.claude/settings.json`, so every developer who next started Claude Code downloaded a backdoor. This repository has such a file (a `SessionStart` hook), plus `AGENTS.md` and `CLAUDE.md`, and nothing reviewed changes to them as code.

## Decision

- `harness.lock` holds the sha256 of every file under `.claude/`, plus `.mcp.json`, `AGENTS.md` and `CLAUDE.md`. `dagger call check` (`Harness`) fails on any changed, new or missing file until `python3 tools/harness/harness.py lock` is run and the lock committed in the same PR. The failure lists every hook and MCP command the harness would run.
- The lock is over content, so a hook that calls a script covers the script.
- `devbox.json` is not locked, because Renovate bumps its packages. Instead the check rejects `shell.init_hook`, the one devbox field that runs on `devbox shell` unasked.

## Alternatives considered

- **CODEOWNERS on the harness paths.** Rejected for now. Branch protection, which is what makes a code-owner review required, is not available for this private repository on its current plan (the API returns 403). On top of that, agent sessions open PRs as the same account that owns the repo. CODEOWNERS would only request a review from the author. Revisit if the repo becomes public or the plan changes.
- **An allow-list of hook commands.** The content lock is stricter: it also catches an allowed command whose script changed.

## Consequences

- Any harness edit shows up in review as a `harness.lock` diff next to the change. This is a visibility control, not an enforcement one: without branch protection, CI is advisory, and someone with push rights can push past it.
- `bd` can rewrite the managed block in `AGENTS.md`/`CLAUDE.md`. That turns the check red until someone relocks, which is intended: an automated rewrite of agent instructions is exactly the change this exists to surface.
- This protects the repository's content. It does not protect a developer who clones a fork or an unrelated repo; that needs a client-side control (the managed setting `allowManagedHooksOnly`, or a per-clone pin of the harness files).
