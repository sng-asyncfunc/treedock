# treedock

**Workspace lifecycle for coding agents** — one command up (branch + deps + services), one command provably down.

Version **0.5.0**. Install for agents; **`SKILL.md` is the contract** (auto-loaded by agent hosts).

## Install

```bash
git clone https://github.com/sng-asyncfunc/treedock.git ~/.grok/skills/treedock
# or: ~/.claude/skills/treedock  |  ~/.codex/skills/treedock
```

Agents invoke the script by absolute path (never a shell alias):

```bash
bash ~/.grok/skills/treedock/scripts/treedock.sh up feat/task --json
bash ~/.grok/skills/treedock/scripts/treedock.sh down feat-task --json
```

## Verbs

| Verb | Intent |
|------|--------|
| `up <branch>` / `up --pr N` | Create plate (worktree + frozen install + optional compose) |
| `list` / `status <slug>` | Inventory / health (`status` supports ghost meta) |
| `down <slug>` | Fail-closed teardown |
| `prune` | Local orphans / stale meta |
| `prune --finished` | Reap **merged or closed** PR/MR plates (gh/glab) |
| `prune --merged` | Reap **merged only** |

Useful flags: `--json`, `--no-docker`, `--no-install`, `--update-gitignore`,  
`--discard-dirty`, `--allow-orphan-compose`, `--force` (both), `--yes`.

## Safety

- External meta `.worktrees/.meta/<slug>.meta` (ghost recovery)
- Dirty non-force `down` refuses **before** stopping compose
- `compose_used=1` before `docker compose up`
- Default ignore via `.git/info/exclude` (not tracked `.gitignore`)
- Lockfile → frozen/immutable install by default
- Prune never deletes git branches; leftovers → `.worktrees/.reaped.log`
- Nonzero exit when prune action skips/fails

## Requirements

- `git`, `bash`, **`python3`**
- Optional: package managers, Docker Compose v2, authenticated `gh` / `glab`

## License

MIT
