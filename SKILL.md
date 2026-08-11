---
name: treedock
version: 0.4.3
description: >
  Paper-plate git worktrees: cheap, fast, disposable checkouts with shared deps
  (pnpm global virtual store) and matched Docker Compose lifecycle. Use when the
  user says "treedock", "/treedock", "paper plate worktree", "disposable worktree",
  "spin up a worktree", "teardown worktree", "worktree + docker", or wants
  setup/teardown scripts so worktrees don't pile into a 20GB ceramic-plate sink.
  Contrasts with bare isolation (ce-worktree): treedock owns the full plate —
  create, install, compose up, then toss.
---

# Treedock — paper-plate worktrees

Worktrees that pile up with fat `node_modules` and orphaned compose stacks are
**ceramic plates**. Treedock makes **paper plates**: spin up in seconds, toss
when done.

Origin: the "worktrees must die" pile-up problem (repeated `node_modules`) is
mostly a package-manager + lifecycle issue, not a git issue. Git worktrees
already share objects; pnpm can share the store; Docker needs a matching
teardown. This skill wires those three into one plate.

## Philosophy (do not violate)

1. **One plate = one task.** Branch + worktree path + compose project name share one slug.
2. **Setup and teardown are twins.** Never leave compose running after the worktree is gone.
3. **Prefer links over copies.** pnpm (global virtual store) > bun > yarn > npm. npm copies; treat it as last resort and warn about disk.
4. **Toss by default.** Finished work: commit/push first if needed, then `down`. Leftovers are cheap only when deps are linked; still prune.
5. **Same trust boundary.** One writable pnpm store for mutually untrusted agents is unsafe — assume shared-trust agents only.

## When to use

| Use treedock | Don't use treedock |
|---|---|
| Parallel agent / feature work | Already isolated and only need code edits |
| Need deps + optional docker per branch | Pure git isolation with no install/compose |
| Cleaning ceramic-plate sink (stale worktrees) | Single long-lived main checkout |

For harness-native isolation without the plate lifecycle, prefer the platform
worktree tool or `ce-worktree`. Use treedock when the user wants the **full
paper-plate lifecycle**.

## Verbs

| Verb | Meaning |
|---|---|
| `up` | Create worktree, install deps, optional compose up |
| `down` | Compose down + remove worktree (+ optional branch delete) |
| `list` | Show plates (path, branch, compose project, status) |
| `prune` | Remove stale / gone worktrees and orphaned compose projects |
| `status` | One plate's health (git + node_modules + compose) |

Run the bundled CLI when available; otherwise follow the manual steps below.

```bash
# From skill root or via absolute path
bash ~/.grok/skills/treedock/scripts/treedock.sh up <slug-or-branch> [--base main] [--no-docker] [--pr N]
bash ~/.grok/skills/treedock/scripts/treedock.sh down <slug-or-branch> [--delete-branch] [--force-delete-branch] [--force]
bash ~/.grok/skills/treedock/scripts/treedock.sh list
bash ~/.grok/skills/treedock/scripts/treedock.sh prune [--yes] [--force]
bash ~/.grok/skills/treedock/scripts/treedock.sh prune --merged [--yes] [--force]
bash ~/.grok/skills/treedock/scripts/treedock.sh status <slug-or-branch>
```

Plates always hang off the **primary** worktree (first entry in `git worktree
list`), never under a nested linked checkout. Run from any worktree of the repo.

---

## `up` — spin a plate

### 0. Preconditions

- Inside a git repo (not required to already be a worktree).
- Prefer **not** nesting worktrees: create plates under the primary checkout's
  `.worktrees/`, never under a linked worktree path.
- Ensure `.worktrees/` is gitignored (trailing slash). If missing, append
  `.worktrees/` to root `.gitignore`.
- Register plate meta at `.worktrees/.meta/<slug>.meta` (outside the plate so
  recovery survives a failed compose down). Optionally also write `.treedock`
  inside the plate, ignored via `info/exclude`.

### 1. Naming

- Slug: branch with `/` → `-` (e.g. `feat/auth` → `feat-auth`). Reject `..`.
- Path: `.worktrees/<slug>` under the **primary** worktree root.
- Compose project: `td-<repo>-<slug>` — dots → hyphens; `[a-z0-9_-]` only; if
  longer than 63 chars, truncate and append a short hash for uniqueness.

### 2. Create worktree

```bash
git fetch origin <base> 2>/dev/null || true

# New branch from base
git worktree add -b <branch> .worktrees/<slug> origin/<base>   # or local <base>

# Existing branch
git worktree add .worktrees/<slug> <branch>

# PR (local branch so commits aren't orphaned)
git fetch origin pull/<N>/head:pr-<N>
git worktree add .worktrees/pr-<N> pr-<N>
```

If the branch is already checked out elsewhere: report that path; do not force
a second worktree on the same branch. Offer work-in-place or a detached plate
only if the user insists.

### 3. Dependencies (links, not copies)

Detect lockfile / config in the new worktree:

| Signal | Install |
|---|---|
| `pnpm-lock.yaml` or `packageManager: pnpm@…` | `pnpm install` |
| `bun.lock` / `bun.lockb` | `bun install` |
| `yarn.lock` | `yarn install` |
| `package-lock.json` only | `npm ci` or `npm install` + **warn** (copies) |
| no JS lockfile | skip install; note non-JS or empty |

**pnpm paper-plate upgrade (when package is JS and pnpm is in use):**

If `pnpm-workspace.yaml` exists and lacks `enableGlobalVirtualStore: true`,
recommend adding it (or add when the user wants monorepo-agent density). First
install fills the global store; later plates are near-instant symlinks.
See `references/pnpm-worktrees.md`.

Do not enable a shared store across untrusted agents.

### 4. Docker Compose (optional)

Skip with `--no-docker`, or when no `compose.yaml` / `compose.yml` /
`docker-compose.yml` / `docker-compose.yaml` exists in the worktree root
(or documented compose path).

```bash
export COMPOSE_PROJECT_NAME="td-<repo>-<slug>"
docker compose -p "$COMPOSE_PROJECT_NAME" -f <compose-file> up -d
```

Record project + path in `.worktrees/.meta/<slug>.meta` early (after worktree
create). Set **`compose_used=1` before** `docker compose up` so a mid-start kill
still tears down on the next `down`.

### 5. Report

Return:

- worktree path
- branch
- install tool used (one clean word: `pnpm` / `bun` / `yarn` / `npm` / `none`)
- compose: project + file, or **`none`** when skipped
- next command hint: `cd .worktrees/<slug>`

---

## `down` — toss the plate

Order on the **non-`--force`** path (no half-toss):

1. Resolve path via meta, else `.worktrees/<slug>`, else `git worktree list`.
2. **Dirty preflight** (plate still has uncommitted changes): **stop immediately**.
   Compose is **not** torn down. Commit/stash, or pass `--force`.
3. If `compose_used=1`:
   ```bash
   docker compose -p "td-<repo>-<slug>" down --remove-orphans
   ```
   If docker is missing or compose down fails: **stop**. Keep the worktree and
   meta. Only `--force` may orphan the stack.
4. Leave the worktree directory (`cd` to primary root).
5. `git worktree remove .worktrees/<slug>`  
   (Already clean on non-force; `--force` may discard dirty.)
6. Rewrite meta with **empty path** and `compose_used=0` (branch name preserved).
7. Optional `--delete-branch`: `git branch -d` only (merged). Unmerged → **stop**,
   meta kept. Retry: `treedock down <slug> --force-delete-branch` (does not need
   the plate dir). Never force-delete remote without ask.
8. Delete `.worktrees/.meta/<slug>.meta` only after branch intent finishes.
9. `git worktree prune` if remove left stale admin files.

**Ghost plates** (dir already gone, meta left): same compose fail-closed rule;
branch-only retries still work via meta.

**`--force` path:** may tear down compose even when dirty, then force-remove the
tree; still keeps meta until branch-delete succeeds if branch flags are set.

Never delete the user's primary checkout. Never `docker compose down` without
the plate's project name (would hit another stack).

---

## `list` / `status` / `prune`

**list**

```bash
git worktree list
# For each plate: branch, compose project from meta, running container count
```

**status \<slug\>**

- path exists + branch
- `node_modules` present?
- compose project / used flag / running containers
- dump meta file

**prune**

- `git worktree prune`
- Unregistered dirs / stale meta: report only unless **`--yes`**
- If `compose_used=1`, teardown must succeed before delete; otherwise keep
  recovery data. **`--force`** with `--yes` orphans when teardown fails
- Never silently delete registered plates

**prune --merged** (GitHub `gh` / GitLab `glab`)

- Enumerate **treedock meta plates only** (not arbitrary worktrees)
- Classification: if meta has `pr=N` (from `up --pr N`), query that PR/MR by
  number (`gh pr view N` / `glab mr view N`); else match by head **branch** name
- States: open / merged / closed / none / error (any open keeps; else newest;
  unverified → error; `--yes` exits non-zero on error/dirty/down-fail)
- Report-only by default; **`--yes`** reaps finished (merged **or** closed)
  plates via normal `down` (dirty skip unless `--force`; **never** deletes branches)
- After reap, leftover local branches are listed and logged to
  `.worktrees/.reaped.log` (squash merges often leave branches behind)
- Fail closed if provider/auth/query fails for a plate

---

## Agent checklist (copy into handoffs)

```
[ ] .worktrees/ gitignored
[ ] worktree created at .worktrees/<slug> on branch <branch>
[ ] deps installed with link-friendly PM (pnpm preferred)
[ ] COMPOSE_PROJECT_NAME=td-<repo>-<slug> (if docker)
[ ] work done / committed / pushed as needed
[ ] treedock down <slug>  → compose down + worktree remove
```

## Anti-patterns

- Creating worktrees without a teardown plan
- `npm install` in every plate and wondering why disk dies
- `docker compose up` with default project name (directory name collisions)
- Removing the worktree while containers still run
- Nesting worktree-from-worktree when a plate from main was requested
- Sharing one pnpm store with untrusted multi-tenant agents

## Related

- Isolation-only (no plate lifecycle): harness worktree tool / `ce-worktree`
- Deep pnpm notes: `references/pnpm-worktrees.md`
- CLI implementation: `scripts/treedock.sh`
