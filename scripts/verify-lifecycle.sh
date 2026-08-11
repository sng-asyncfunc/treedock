#!/usr/bin/env bash
# Durable lifecycle checks against the real treedock.sh entry point.
# Usage: verify-lifecycle.sh [scratch-dir-for-logs]
set -euo pipefail

TD="$(cd "$(dirname "$0")" && pwd)/treedock.sh"
SCRATCH="${1:-$(mktemp -d)}"
mkdir -p "$SCRATCH"
SANDBOX="$SCRATCH/verify-sandbox"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
cd "$SANDBOX"

git init -b main >/dev/null
git config user.email verify@treedock.test
git config user.name treedock-verify
cat > compose.yaml <<'EOF'
services:
  web:
    image: nginx:alpine
EOF
echo root > README.md
echo '.worktrees/' > .gitignore
git add -A && git commit -m init >/dev/null

bash -n "$TD"
VER="$("$TD" -v)"
echo "version=$VER" >"$SCRATCH/version.txt"

# 1) Dirty refuse must not stop containers
"$TD" up dirty/plate >/dev/null 2>&1
PROJ=$(sed -n 's/^compose_project=//p' .worktrees/.meta/dirty-plate.meta)
echo dirty > .worktrees/dirty-plate/UNTRACKED.txt
set +e
OUT=$("$TD" down dirty-plate 2>&1)
EC=$?
set -e
N=$(docker compose -p "$PROJ" ps -q | wc -l | tr -d ' ')
{
  echo "$OUT"
  echo "exit=$EC container_count=$N"
} | tee "$SCRATCH/dirty-down.log"
[[ $EC -ne 0 && -d .worktrees/dirty-plate && "$N" -gt 0 ]]

# 2) Force path
"$TD" down dirty-plate --force --delete-branch --force-delete-branch >/dev/null 2>&1
N=$(docker compose -p "$PROJ" ps -q 2>/dev/null | wc -l | tr -d ' ')
echo "force_containers=$N" | tee "$SCRATCH/dirty-force.log"
[[ ! -d .worktrees/dirty-plate && "$N" == "0" ]]

# 3) Branch retry
"$TD" up unmerged/br --no-docker >/dev/null 2>&1
(cd .worktrees/unmerged-br && echo x >> README.md && git add README.md && git commit -m wip >/dev/null)
set +e
"$TD" down unmerged-br --delete-branch >/dev/null 2>&1
EC=$?
set -e
[[ $EC -ne 0 && -f .worktrees/.meta/unmerged-br.meta ]]
BR=$(sed -n 's/^branch=//p' .worktrees/.meta/unmerged-br.meta)
git show-ref --verify --quiet "refs/heads/$BR"
"$TD" down unmerged-br --force-delete-branch >/dev/null 2>&1
[[ ! -f .worktrees/.meta/unmerged-br.meta ]]
! git show-ref --verify --quiet "refs/heads/unmerged/br"
echo "branch_retry_ok branch=$BR" | tee "$SCRATCH/branch-delete.log"

# 4) Ghost keep meta without docker
"$TD" up ghost/a >/dev/null 2>&1
rm -rf .worktrees/ghost-a
set +e
PATH="/usr/bin:/bin" "$TD" down ghost-a >/dev/null 2>&1
EC=$?
set -e
[[ $EC -ne 0 && -f .worktrees/.meta/ghost-a.meta ]]
PATH="/usr/bin:/bin" "$TD" down ghost-a --force --force-delete-branch >/dev/null 2>&1 || true
echo "ghost_ok" | tee "$SCRATCH/ghost.log"

echo "ALL_VERIFY_OK version=$VER" | tee "$SCRATCH/dogfood-summary.txt"
echo "logs under $SCRATCH"
