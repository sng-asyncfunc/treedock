# treedock

**One plate. One task. One agent. Provably down.**

Parallel coding agents need their own checkout, deps, and services — then a teardown you can trust. treedock is the workspace lifecycle skill that makes that path mechanical: one command up, one command fail-closed down.

Version **0.5.0**. Humans install it. Agents execute it. **`SKILL.md` is the contract** (auto-loaded by agent hosts).

---

## The problem agents hit

You fan out agents on one repo. Without a lifecycle:

- **They collide** on a single working tree (branch locks, dirty files, half-applied edits)
- **They leave mess** — orphan worktrees, stale compose projects, meta nobody owns
- **Teardown is improvised** — `rm -rf`, unscoped `docker compose down`, guessed paths

That’s not isolation. That’s a sink full of ceramic plates.

**Temporary work should be disposable.** Not “clean it later if you remember.”

---

## What treedock does

A **plate** is a task-scoped git worktree with optional frozen dependency install and Docker Compose — registered in external meta so recovery and prune stay reliable.

| You want | treedock does |
|----------|----------------|
| Isolated parallel work | `up` creates branch + worktree + install + compose |
| A path the agent can trust | Returns `slug` + absolute `path` (prefer `--json`) |
| Teardown that doesn’t half-finish | `down` is fail-closed (dirty refuse before compose stop) |
| Cleanup after reviews | `prune --finished` / `--merged` reaps closed PR plates |
| Ghost recovery | Meta lives outside the plate: `.worktrees/.meta/<slug>.meta` |

**Not** a human-first CLI with aliases and vibes. Not bare `git worktree` with no install/compose/teardown policy. Agents call the bundled script by **absolute path**.

---

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

---

## Plan (agent path)

1. **Install** the skill into the host’s skills directory  
2. **`up`** a plate for this task (`--json`; capture `slug` + `path`)  
3. **Work only in `path`** — one plate = one task = one agent  
4. **`down`** from the primary checkout when the task is done  

Orchestrators: hand off `slug`, `path`, `branch`, `compose`, `owner`. Janitors: `prune` report-first, then authorized `--yes`.

Full contract, hard rules, and failure tables → **[SKILL.md](./SKILL.md)**.

---

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

---

## Safety (why down is trustworthy)

- External meta `.worktrees/.meta/<slug>.meta` (ghost recovery after vanished dirs)
- Dirty non-force `down` refuses **before** stopping compose
- `compose_used=1` recorded before `docker compose up`
- Default ignore via `.git/info/exclude` (not tracked `.gitignore`)
- Lockfile → frozen/immutable install by default
- Prune never deletes git branches; leftovers → `.worktrees/.reaped.log`
- Nonzero exit when prune action skips/fails

---

## Success looks like

- N agents, N plates, zero shared-checkout fights  
- Disk and compose state match what meta says  
- Finished PR review plates reaped without hunting directories by hand  
- Orchestrator reports: operation, slug, path, `ok` — not “maybe cleaned up”

---

## Requirements

- `git`, `bash`, **`python3`**
- Optional: package managers, Docker Compose v2, authenticated `gh` / `glab`

## Related

- Agent contract: [SKILL.md](./SKILL.md)
- CLI: `scripts/treedock.sh`
- Lifecycle smoke: `scripts/verify-lifecycle.sh`
- pnpm density notes: `references/pnpm-worktrees.md`
- Code-only isolation (no deps/compose lifecycle): harness worktree / `ce-worktree`

## License

MIT
