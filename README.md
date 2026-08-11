# treedock

**Paper-plate git worktrees** — cheap, disposable checkouts with shared deps (pnpm-friendly) and matched Docker Compose lifecycle.

Git worktrees share objects (good). Fat `node_modules` copies and orphaned compose stacks (bad) are why people say “worktrees must die.” Treedock is the missing teardown half: **one plate = one task**, spin up in seconds, toss when done.

Version: **0.4.3**

## Install

### As a Grok / Claude skill

Copy or clone into your skills directory:

```bash
git clone https://github.com/sng-asyncfunc/treedock.git ~/.grok/skills/treedock
# or: ~/.claude/skills/treedock
```

### CLI alias

```bash
# ~/.zshrc
alias td='bash ~/.grok/skills/treedock/scripts/treedock.sh'
```

## Quick start

```bash
cd /path/to/your/repo

td up feat/auth              # worktree + install + compose (if present)
td up feat/billing           # second plate for parallel agent
td up --pr 482               # PR plate
td up spike/x --no-docker    # no compose

cd .worktrees/feat-auth      # do work / point an agent here
# commit + push…

cd "$(git rev-parse --show-toplevel)"
td down feat-auth            # compose down → remove worktree (safe)
td list
td prune                     # local orphans (report)
td prune --merged            # plan plates with merged/closed PRs
td prune --merged --yes      # reap them (never deletes branches)
```

## What it does

| Verb | Meaning |
|------|---------|
| `up` | Create `.worktrees/<slug>`, install deps, optional `docker compose up` with project `td-<repo>-<slug>` |
| `down` | Fail-closed teardown: dirty preflight **before** compose stop; then worktree remove; optional branch delete |
| `list` / `status` | Inventory and health |
| `prune` | Unregistered dirs + stale meta |
| `prune --merged` | Via `gh` / `glab`: report/reap plates whose PR/MR is merged or closed |

### Safety (load-bearing)

- **External meta** at `.worktrees/.meta/<slug>.meta` (survives `rm -rf` of the plate dir)
- **Dirty non-force `down`** refuses without stopping containers (no half-toss)
- **`compose_used=1` before** `docker compose up` (mid-kill recoverable)
- **Ghost recovery** for missing plate dirs
- **Branch delete** is opt-in; unmerged keeps meta for `down <slug> --force-delete-branch`
- Plates always hang off the **primary** checkout (no nesting under linked worktrees)

## Mental model (parallel agents)

One plate per Claude Code / agent tab:

```text
td up feat/a   → agent A cwd: .worktrees/feat-a
td up feat/b   → agent B cwd: .worktrees/feat-b
# …ship PRs…
td prune --merged --yes   # weekly janitor for merged/closed
```

Prefer **pnpm** (global virtual store) so plates stay thin — see `references/pnpm-worktrees.md`.

## Layout

```text
SKILL.md                 # agent skill contract
scripts/treedock.sh      # CLI
scripts/verify-lifecycle.sh
references/pnpm-worktrees.md
```

## Requirements

- `git`, `bash`, **`python3`** (used by `prune --merged` PR JSON parsing)
- Optional: `pnpm` / `bun` / `yarn` / `npm`, `docker` + Compose v2
- Optional for `prune --merged`: authenticated `gh` (GitHub) or `glab` (GitLab)
  matching your `origin` host

## Related

- Isolation-only worktrees (no plate lifecycle): harness tools / compound-engineering `ce-worktree`
- PR auto-clean inspiration: [git-gtr](https://github.com/coderabbitai/git-worktree-runner) / [OutThisLife worktree notes](https://gist.github.com/OutThisLife/69e87de53bb37ff85387cb120632f255)

## License

MIT
