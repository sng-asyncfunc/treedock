---
name: treedock
version: 0.5.0
description: >
  Manage disposable, task-scoped git worktrees for parallel agents: create branch
  or GitHub PR plates, install dependencies, start isolated Docker Compose projects,
  inspect status, fail-closed teardown and ghost recovery, prune finished GitHub/GitLab
  review plates. Use when an agent needs a temporary checkout with managed dep/container
  lifecycle; invoke the bundled scripts/treedock.sh — never raw git worktree remove or
  unscoped docker compose down. Triggers: treedock, disposable worktree, plate, agent
  isolation, parallel agents, prune merged plates, worktree + docker.
---

# treedock — agent workspace lifecycle

**One command up (branch + deps + services), one command provably down.**

This skill is a **contract for coding agents**. Humans install it; agents execute it.
Do not improvise git worktree / compose teardown outside this script.

**Script (always absolute path):**

```bash
TREEDOCK="$(dirname "$SKILL_DIR")/treedock/scripts/treedock.sh"
# if skill root is known:
bash "${TREEDOCK_ROOT:-$HOME/.grok/skills/treedock}/scripts/treedock.sh" <verb> ...
```

Prefer resolving the skill install path for the current harness (`~/.grok/skills/treedock`,
`~/.claude/skills/treedock`, `~/.codex/skills/treedock`, or repo-local `.grok/skills/treedock`).
**Never depend on a `td` shell alias.**

Prefer machine-readable output: pass **`--json`** on any verb (JSON object on stdout;
diagnostics on stderr).

---

## Hard rules (do not violate)

1. Invoke the **bundled** `scripts/treedock.sh` by absolute path — not ad-hoc git/docker.
2. **One plate = one task = one agent.** Never share a live plate across concurrent agents.
3. After `up`, parse **`slug`** and **`path`** from output (or `--json`); use those values only.
4. Set **cwd explicitly** to `path` for every tool call / subagent — do not assume `cd` persists.
5. Work only inside the plate. Run **`down` from the primary checkout** (or any non-plate dir).
6. Inspect git status / preserve required work **before** `down`.
7. Never `rm -rf` a plate, never edit `.worktrees/.meta/` by hand, never unscoped `docker compose down`.
8. **`--force` / `--discard-dirty` / `--allow-orphan-compose` / branch-delete flags** require
   explicit authorization for the exact data loss — not generic “retry harder.”
9. **`prune` report-only first**; `--yes` only after reviewing the plan.
10. Failed `up` leaves a recoverable plate — `status`/`down` it; do not blind-retry `up`.
11. Preserve recovery metadata on compose/worktree failure; retry through treedock.
12. Shared pnpm store ⇒ **same trust boundary**. Untrusted code: no shared store / no plate.

---

## When to invoke vs refuse

| Invoke | Refuse / use something else |
|--------|-----------------------------|
| Task needs own branch + install and/or compose | Read-only exploration |
| Fan-out N agents on one repo | Already in an isolated plate for this task |
| PR review must run (`up --pr N`) | Not a git repo |
| Cleanup finished review plates | Code-only isolation with no deps/compose → harness worktree / ce-worktree |
| Ghost recovery after vanished plate dir | Sandboxing untrusted multi-tenant code |

---

## Verbs

| Verb | Agent intent |
|------|----------------|
| `up <branch\|slug>` | Create plate: worktree + install + optional compose |
| `up --pr N` | GitHub PR review plate; meta stores `pr=N` for janitor |
| `list` | Inventory plates |
| `status <slug>` | Health (supports ghost meta when dir missing) |
| `down <slug>` | Fail-closed teardown |
| `prune` | Local orphans / stale meta |
| `prune --finished` | Plan/reap **merged or closed** PR/MR plates |
| `prune --merged` | Plan/reap **merged only** |

Common flags:

- `up`: `--base <ref>`, `--no-docker`, `--no-install`, `--update-gitignore`, `--json`
- `down`: `--delete-branch`, `--force-delete-branch`, `--discard-dirty`, `--allow-orphan-compose`, `--force` (both discards), `--json`
- `prune`: `--yes`, `--discard-dirty`, `--allow-orphan-compose`, `--force`, `--json`

---

## Create a plate

```bash
bash "$TREEDOCK" up feat/task-slug --json
# or: bash "$TREEDOCK" up --pr 123 --json
```

On success, capture at least: `ok`, `slug`, `path`, `branch`, `install`, `compose`, `meta`.

**Partial failure:** plate and `.worktrees/.meta/<slug>.meta` may already exist.
Run `status` / `down` — do **not** re-run `up` (path exists).

**Install policy:** when a lockfile is present, install is **frozen/immutable** by default
(does not rewrite locks).

**Ignore policy:** `.worktrees/` is registered in **`.git/info/exclude`** by default
(no tracked `.gitignore` dirt). Pass `--update-gitignore` only if authorized to dirty main.

---

## Hand off / multi-agent protocol

Handoff payload **must** include:

| Field | Meaning |
|-------|---------|
| `slug` | Plate identity |
| `path` | Absolute worktree path |
| `branch` | Git branch |
| `compose` | Project name or `none` |
| `owner` | Which agent tears down |
| `dirty` | clean \| dirty \| unknown |

- **Resume:** `status <slug>` first; on mismatch with handoff → stop and report.
- **Lock:** `branch already checked out at <path>` is authoritative — rebranch or coordinate.
- **Janitor agent:** may run `prune --finished` (report) then authorized `--yes`; skips dirty plates; never deletes branches.

---

## Safe teardown

```bash
# from primary checkout (or non-plate cwd)
bash "$TREEDOCK" down <slug> --json
```

Order (non-destructive path):

1. Dirty preflight → refuse **without** stopping compose  
2. Compose down if `compose_used=1` (fail closed)  
3. Remove worktree  
4. Keep meta until optional branch-delete finishes  
5. Drop meta  

Ghost dir (`rm -rf` plate): still `down <slug>` — meta recovers compose/branch.

---

## Pruning

```bash
bash "$TREEDOCK" prune --json                    # local orphans (report)
bash "$TREEDOCK" prune --yes --json              # act on orphans
bash "$TREEDOCK" prune --finished --json         # finished reviews (report)
bash "$TREEDOCK" prune --finished --yes --json   # reap finished reviews
bash "$TREEDOCK" prune --merged --yes --json     # merged only
```

- Report first; `--yes` is destructive for plates only (**not** branches).  
- Leftover branches after reap → listed + `.worktrees/.reaped.log`.  
- Nonzero exit when acting if dirty skip / unverified PR / teardown failure / skip.

---

## Failure → action

| Signal | Agent action |
|--------|----------------|
| `plate already exists` | `status` / work there or `down` then recreate |
| `branch already checked out at X` | Use path X or new branch name |
| `plate is dirty` (down) | Commit/stash or authorized `--discard-dirty` |
| `compose … failed` / docker missing | Fix docker or authorized `--allow-orphan-compose` |
| `branch … not fully merged` | `down <slug> --force-delete-branch` if authorized |
| `prune --merged` unverified / error | Report; do not `--force` to “make green” |
| nonzero `up` after partial create | `down <slug>` cleanup or resume — not second `up` |

---

## Result reporting

After each verb, report to the orchestrator: operation, repo root, slug, path, branch,
install manager, compose project/`none`, `ok`, recovery needed, follow-up.

---

## Agent anti-patterns

- Assuming `td` alias or persistent shell cwd  
- Guessing `.worktrees/<branch>` instead of returned slug  
- Blind re-`up` after failed install/compose  
- Using `--force` as generic retry  
- Manual `git worktree remove` / `rm -rf` / unscoped compose down  
- Sharing one pnpm store across untrusted agents  
- Treating `prune --finished` as “merged only” (use `--merged` for that)  
- Expecting prune to delete local branches  

---

## Meta registry (read-only for agents)

`.worktrees/.meta/<slug>.meta` fields include: `slug`, `branch`, `path`, `compose_project`,
`compose_file`, `compose_used`, `install`, `pr`, `created_at`.  
**Agents must not hand-edit these files.**

---

## Related

- Code-only isolation without deps/compose: harness worktree tool / `ce-worktree`
- CLI implementation: `scripts/treedock.sh`
- Lifecycle smoke: `scripts/verify-lifecycle.sh`
- pnpm density notes: `references/pnpm-worktrees.md`
