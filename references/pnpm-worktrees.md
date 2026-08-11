# pnpm + git worktrees (paper-plate density)

Source of truth for the store model: https://pnpm.io/git-worktrees

## Why ceramic plates happen

Git worktrees share objects — cheap. Each worktree still needs its own
`node_modules`. With npm (and default copy-heavy installs), that is hundreds of
MB to multi-GB **per plate**. Ten agents → ceramic sink.

## Global virtual store

Requires **pnpm ≥ 10.12** (older versions ignore or lack the flag — still ceramic).

In `pnpm-workspace.yaml` (repo root):

```yaml
packages:
  - 'packages/*'
enableGlobalVirtualStore: true
```

Effects:

- Package bytes live once in the content-addressable global store (`pnpm store path`).
- Each worktree `node_modules` is mostly **symlinks** into that store.
- First `pnpm install` warms the store; later plates are near-instant.
- Branches can still resolve different versions — trees are per-worktree; store is shared.

## Trust boundary

Do **not** share one writable store across mutually untrusted agents/users.
Treedock assumes same-trust local agents.

## Bare hub pattern (optional)

```sh
git clone --bare https://github.com/org/repo.git repo
cd repo
git worktree add ./main main
git worktree add ./feature-auth feat/auth
```

Treedock's default is simpler: linked worktrees under `.worktrees/` from a
normal checkout. Switch to bare hub when a monorepo is agent-dense full-time.

## pnpm helper scripts (upstream pattern)

pnpm's own monorepo uses:

- `pnpm worktree:new <branch|pr-number>`
- `shell/wt.sh` → `wt <branch|pr>`

Treedock generalizes that lifecycle + Docker project naming.

## Cleanup

```sh
git worktree remove ./feature-auth
# or
treedock down feature-auth
```

Leftover plates are cheap only when deps are linked. Still prune compose stacks.
