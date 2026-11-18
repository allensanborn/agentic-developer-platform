"""Verify or relock harness.lock: the sha256 of every file a coding agent executes from this repo.

    python3 tools/harness/harness.py verify   # exit 1 if any harness file differs from harness.lock
    python3 tools/harness/harness.py lock     # rewrite harness.lock from the working tree

Why (ADR 0013): GTIG (Nov 2026) saw attackers edit .claude/settings.json in internal repos so
Claude Code fetched a backdoor at startup, and Claude Code runs project hooks without asking
(code.claude.com/docs/en/permissions, "What runs before you trust a folder"). A harness change
must therefore be a visible, deliberate diff: it fails `dagger call check` until harness.lock is
relocked in the same PR, and the failure prints every command the harness would run.

The lock is over file content, so a hook pointing at a script covers the script too. devbox.json
is not locked (Renovate bumps it); instead it may not declare shell.init_hook, the one devbox
field that runs on `devbox shell` without being asked. Standard library only.
"""

import hashlib
import json
import sys
from pathlib import Path

LOCK = "harness.lock"
PATTERNS = [".claude/**/*", ".mcp.json", "AGENTS.md", "CLAUDE.md"]


def harness_files(root: Path) -> list[str]:
    found = {p for pattern in PATTERNS for p in root.glob(pattern) if p.is_file()}
    return sorted(str(p.relative_to(root)) for p in found)


def digests(root: Path) -> dict[str, str]:
    return {f: hashlib.sha256((root / f).read_bytes()).hexdigest() for f in harness_files(root)}


def commands(root: Path) -> list[str]:
    """Every command the harness runs: settings hooks and MCP servers."""
    out = []
    settings = root / ".claude/settings.json"
    if settings.is_file():
        for event, groups in json.loads(settings.read_text()).get("hooks", {}).items():
            for group in groups:
                for hook in group.get("hooks", []):
                    out.append(f"hook {event}: {hook.get('command', hook)}")
    mcp = root / ".mcp.json"
    if mcp.is_file():
        for name, server in json.loads(mcp.read_text()).get("mcpServers", {}).items():
            out.append(f"mcp {name}: {server.get('command', server.get('url', ''))} {' '.join(server.get('args', []))}".rstrip())
    return out


def verify(root: Path) -> int:
    errors = []
    devbox = root / "devbox.json"
    if devbox.is_file() and json.loads(devbox.read_text()).get("shell", {}).get("init_hook"):
        errors.append("devbox.json declares shell.init_hook, which runs on every `devbox shell`")
    lock_path = root / LOCK
    locked = json.loads(lock_path.read_text()) if lock_path.is_file() else {}
    have = digests(root)
    for f in sorted(set(locked) | set(have)):
        if f not in have:
            errors.append(f"{f}: in {LOCK} but missing")
        elif f not in locked:
            errors.append(f"{f}: new harness file, not in {LOCK}")
        elif locked[f] != have[f]:
            errors.append(f"{f}: changed since {LOCK}")
    if not errors:
        print(f"Harness lock OK: {len(have)} files")
        return 0
    print(f"Harness lock FAILED: {len(errors)} error(s)")
    for e in errors:
        print(f"  - {e}")
    print("Commands this harness would run:")
    for c in commands(root):
        print(f"  {c}")
    print(f"If the change is intended: python3 tools/harness/harness.py lock, and commit {LOCK}.")
    return 1


def lock(root: Path) -> int:
    (root / LOCK).write_text(json.dumps(digests(root), indent=2) + "\n")
    print(f"Wrote {LOCK}: {len(harness_files(root))} files")
    return 0


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    if action not in ("verify", "lock"):
        sys.exit(__doc__)
    sys.exit({"verify": verify, "lock": lock}[action](Path.cwd()))
