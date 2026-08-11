#!/usr/bin/env bash
# treedock — paper-plate git worktrees (create / install / compose / toss)
# Lifecycle invariant: fail closed on compose errors.
# Non-force down: dirty preflight BEFORE compose teardown (no half-toss).
# Once teardown is committed: compose down → worktree remove → branch delete → drop meta.
# Meta is kept until branch-delete succeeds so --force-delete-branch remains retryable.
set -euo pipefail

VERSION="0.4.2"

# Absolute path to this script (for re-entry: prune --merged → down).
TREEDOCK_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

die() { echo "treedock: $*" >&2; exit 1; }
info() { echo "treedock: $*" >&2; }

need_git() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
}

# Primary (main) worktree root — never nest plates under a linked worktree.
main_worktree_root() {
  local first
  first="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)"
  if [[ -n "$first" ]]; then
    (cd "$first" && pwd -P)
    return
  fi
  git rev-parse --show-toplevel
}

# Current checkout root (may be a linked worktree)
current_toplevel() {
  git rev-parse --show-toplevel
}

realpath_p() {
  local p="$1"
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd -P)
  elif [[ -e "$p" ]]; then
    (cd "$(dirname "$p")" && echo "$(pwd -P)/$(basename "$p")")
  else
    # parent may exist
    local parent base
    parent="$(dirname "$p")"
    base="$(basename "$p")"
    if [[ -d "$parent" ]]; then
      echo "$(cd "$parent" && pwd -P)/$base"
    else
      echo "$p"
    fi
  fi
}

repo_name() {
  basename "$(main_worktree_root)" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# Reject path-ish input before transforms can hide ".." .
assert_safe_name() {
  local raw="$1" seg
  case "$raw" in
    ''|'.'|'..') die "invalid name: '$raw'" ;;
  esac
  # split on / and \ — reject . and .. segments
  local IFS='\/'
  # shellcheck disable=SC2206
  local parts=($raw)
  for seg in "${parts[@]}"; do
    if [[ "$seg" == "." || "$seg" == ".." ]]; then
      die "path traversal / relative segments not allowed: '$raw'"
    fi
  done
}

slugify() {
  local raw="$1" s
  assert_safe_name "$raw"
  # spaces and other junk → hyphen; keep dots for readability (compose_project strips them)
  s="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's|[[:space:]]+|-|g; s|/|-|g; s/[^a-z0-9._-]+/-/g; s/-+/-/g; s/^\.+//; s/\.+$//; s/^-+//; s/-+$//')"
  if [[ -z "$s" || "$s" == "." || "$s" == ".." ]]; then
    die "invalid slug from '$raw' (got '$s')"
  fi
  case "$s" in
    *..*) die "invalid slug contains '..': $s" ;;
  esac
  printf '%s\n' "$s"
}

# Git branch names must pass check-ref-format. Call before worktree add.
validate_branch_name() {
  local branch="$1"
  if [[ "$branch" == *" "* ]]; then
    die "invalid git branch name: '$branch' (spaces not allowed — use hyphens)"
  fi
  if ! git check-ref-format "refs/heads/${branch}" 2>/dev/null; then
    die "invalid git branch name: '$branch' (see git check-ref-format; no spaces or '..')"
  fi
}

# Compose project names: [a-z0-9][a-z0-9_-]* only, max 63 chars.
# Replace dots; if truncated, append short hash of full intent for uniqueness.
compose_project() {
  local slug="$1"
  local raw hash base max=63
  raw="td-$(repo_name)-$(echo "$slug" | tr '.' '-' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//')"
  if [[ ${#raw} -le $max ]]; then
    echo "$raw"
    return
  fi
  hash="$(printf '%s' "$raw" | shasum -a 256 2>/dev/null | cut -c1-8 || printf '%s' "$raw" | cksum | awk '{print $1}')"
  base="$(echo "$raw" | cut -c1-$((max - 9)))"
  echo "${base}-${hash}"
}

meta_dir() {
  echo "$(main_worktree_root)/.worktrees/.meta"
}

meta_path() {
  local slug="$1"
  echo "$(meta_dir)/${slug}.meta"
}

plates_dir() {
  echo "$(main_worktree_root)/.worktrees"
}

ensure_worktrees_gitignore() {
  local root="$1"
  (
    cd "$root" || exit 1
    if git check-ignore -q .worktrees/ 2>/dev/null; then
      return 0
    fi
    if [[ -f .gitignore ]] && grep -qxF '.worktrees/' .gitignore 2>/dev/null; then
      return 0
    fi
    info "adding .worktrees/ to .gitignore"
    { echo; echo '# treedock paper plates'; echo '.worktrees/'; } >> .gitignore
  )
}

# Ignore in-plate marker so worktree stays clean for git worktree remove.
ensure_plate_exclude() {
  local root="$1"
  local exclude
  exclude="$(git -C "$root" rev-parse --git-path info/exclude)"
  mkdir -p "$(dirname "$exclude")"
  if ! grep -qxF '.treedock' "$exclude" 2>/dev/null; then
    { echo; echo '# treedock plate marker'; echo '.treedock'; } >> "$exclude"
  fi
}

find_compose_file() {
  local dir="$1"
  local f
  for f in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
    if [[ -f "$dir/$f" ]]; then
      echo "$dir/$f"
      return 0
    fi
  done
  return 1
}

detect_install() {
  local dir="$1"
  local pm_field=""
  if [[ -f "$dir/package.json" ]] && command -v python3 >/dev/null 2>&1; then
    pm_field="$(python3 -c "
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  print((d.get('packageManager') or '').split('@')[0])
except Exception:
  print('')
" "$dir/package.json" 2>/dev/null || true)"
  fi
  case "$pm_field" in
    pnpm|yarn|npm|bun) echo "$pm_field"; return ;;
  esac
  if [[ -f "$dir/pnpm-lock.yaml" ]] || [[ -f "$dir/pnpm-workspace.yaml" ]]; then
    echo pnpm
  elif [[ -f "$dir/bun.lockb" ]] || [[ -f "$dir/bun.lock" ]]; then
    echo bun
  elif [[ -f "$dir/yarn.lock" ]]; then
    echo yarn
  elif [[ -f "$dir/package-lock.json" ]]; then
    echo npm
  elif [[ -f "$dir/package.json" ]]; then
    if command -v pnpm >/dev/null 2>&1; then
      echo pnpm
    elif command -v bun >/dev/null 2>&1; then
      echo bun
    else
      echo npm
    fi
  else
    echo none
  fi
}

run_install() {
  local dir="$1"
  local pm
  pm="$(detect_install "$dir")"
  case "$pm" in
    pnpm)
      command -v pnpm >/dev/null 2>&1 || die "pnpm not on PATH"
      info "install: pnpm (prefer enableGlobalVirtualStore for multi-plate density)"
      (cd "$dir" && pnpm install) >&2
      ;;
    bun)
      command -v bun >/dev/null 2>&1 || die "bun not on PATH"
      info "install: bun"
      (cd "$dir" && bun install) >&2
      ;;
    yarn)
      command -v yarn >/dev/null 2>&1 || die "yarn not on PATH"
      info "install: yarn"
      (cd "$dir" && yarn install) >&2
      ;;
    npm)
      info "install: npm (warning: copies node_modules — ceramic plate risk)"
      (cd "$dir" && { [[ -f package-lock.json ]] && npm ci || npm install; }) >&2
      ;;
    none)
      info "install: skipped (no JS package manifest/lockfile)"
      ;;
  esac
  # ONLY the pm name on stdout (install logs went to stderr)
  printf '%s\n' "$pm"
}

write_meta() {
  local slug="$1" branch="$2" project="$3" path="$4" compose_file="${5:-}" compose_used="${6:-0}" pm="${7:-none}"
  mkdir -p "$(meta_dir)"
  cat >"$(meta_path "$slug")" <<EOF
# treedock plate registry (outside the worktree — survives failed compose down)
slug=$slug
branch=$branch
compose_project=$project
compose_file=$compose_file
compose_used=$compose_used
path=$path
install=$pm
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  # Optional human-visible marker inside plate (gitignored via info/exclude)
  if [[ -d "$path" ]]; then
    cat >"$path/.treedock" <<EOF
# treedock plate marker (also registered at $(meta_path "$slug"))
slug=$slug
branch=$branch
compose_project=$project
compose_file=$compose_file
compose_used=$compose_used
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  fi
}

read_meta_field() {
  local slug="$1" field="$2"
  local mp
  mp="$(meta_path "$slug")"
  if [[ -f "$mp" ]]; then
    sed -n "s/^${field}=//p" "$mp" | head -1
    return 0
  fi
  return 1
}

read_marker_field() {
  # legacy in-tree marker fallback
  local dir="$1" field="$2"
  [[ -f "$dir/.treedock" ]] || return 1
  sed -n "s/^${field}=//p" "$dir/.treedock" | head -1
}

delete_meta() {
  local slug="$1"
  rm -f "$(meta_path "$slug")"
}

default_base() {
  if [[ -n "${TREEDOCK_BASE:-}" ]]; then
    echo "$TREEDOCK_BASE"
    return
  fi
  local root
  root="$(main_worktree_root)"
  if git -C "$root" show-ref --verify --quiet refs/remotes/origin/main; then
    echo "origin/main"
  elif git -C "$root" show-ref --verify --quiet refs/heads/main; then
    echo "main"
  elif git -C "$root" show-ref --verify --quiet refs/remotes/origin/master; then
    echo "origin/master"
  elif git -C "$root" show-ref --verify --quiet refs/heads/master; then
    echo "master"
  else
    git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
      || git -C "$root" rev-parse --abbrev-ref HEAD
  fi
}

registered_worktree_paths() {
  git worktree list --porcelain | sed -n 's/^worktree //p' | while read -r p; do
    realpath_p "$p"
  done
}

cmd_up() {
  local target="" base="" no_docker=0 pr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base)
        [[ -n "${2:-}" ]] || die "--base requires a ref"
        base="$2"; shift 2
        ;;
      --no-docker) no_docker=1; shift ;;
      --pr)
        [[ -n "${2:-}" ]] || die "--pr requires a number"
        pr="$2"; shift 2
        ;;
      -h|--help)
        cat <<'EOF'
Usage: treedock up <branch-or-slug> [--base <ref>] [--no-docker]
       treedock up --pr <N> [--base <ref>] [--no-docker]
EOF
        return 0
        ;;
      *)
        if [[ -z "$target" && "$1" != --* ]]; then
          target="$1"; shift
        else
          die "unknown up flag: $1"
        fi
        ;;
    esac
  done

  need_git
  local root
  root="$(main_worktree_root)"
  cd "$root"

  if [[ -n "$pr" ]]; then
    target="pr-${pr}"
  fi
  [[ -n "$target" ]] || die "up requires a branch/slug or --pr N"

  local branch slug path project
  if [[ -n "$pr" ]]; then
    branch="pr-${pr}"
    slug="$(slugify "$branch")"
  else
    branch="$target"
    slug="$(slugify "$target")"
  fi
  validate_branch_name "$branch"
  path="$(plates_dir)/$slug"
  project="$(compose_project "$slug")"
  base="${base:-$(default_base)}"

  ensure_worktrees_gitignore "$root"
  ensure_plate_exclude "$root"
  mkdir -p "$(plates_dir)" "$(meta_dir)"

  if [[ -e "$path" ]]; then
    die "plate already exists: $path (treedock down $slug first, or cd there)"
  fi

  # Create worktree first, then write meta early so partial failures remain recoverable.
  if [[ -n "$pr" ]]; then
    info "fetching pull/${pr}/head → ${branch}"
    git fetch origin "pull/${pr}/head:${branch}"
    git worktree add "$path" "$branch" || die "git worktree add failed for PR $pr"
  elif git show-ref --verify --quiet "refs/heads/${branch}"; then
    # Refuse if already checked out in another worktree (clearer than raw git error)
    local existing
    existing="$(git worktree list --porcelain | awk -v b="refs/heads/${branch}" '
      /^worktree /{wt=$2}
      /^branch /{if ($2==b) print wt}
    ')"
    if [[ -n "$existing" ]]; then
      die "branch '${branch}' already checked out at ${existing}"
    fi
    info "attaching existing branch ${branch}"
    git worktree add "$path" "$branch" || die "git worktree add failed"
  else
    info "creating branch ${branch} from ${base}"
    if [[ "$base" == origin/* ]]; then
      git fetch origin "${base#origin/}" 2>/dev/null || true
    fi
    git worktree add -b "$branch" "$path" "$base" || die "git worktree add failed for branch '${branch}'"
  fi

  # Early meta (compose not up yet)
  write_meta "$slug" "$branch" "$project" "$path" "" "0" "none"

  local pm compose_file="" compose_used=0
  # Install — on failure leave plate + meta for user; do not auto-delete (agent may want the tree)
  if ! pm="$(run_install "$path")"; then
    info "install failed — plate left at $path (meta at $(meta_path "$slug"))"
    die "install failed"
  fi
  write_meta "$slug" "$branch" "$project" "$path" "" "0" "$pm"

  if [[ "$no_docker" -eq 0 ]]; then
    if compose_file="$(find_compose_file "$path")"; then
      if command -v docker >/dev/null 2>&1; then
        # Mark compose_used BEFORE up so a mid-start kill still tears down on later down.
        compose_used=1
        write_meta "$slug" "$branch" "$project" "$path" "$compose_file" "1" "$pm"
        info "compose up project=${project} file=${compose_file}"
        if ! (cd "$path" && COMPOSE_PROJECT_NAME="$project" docker compose -p "$project" -f "$compose_file" up -d); then
          info "compose up failed — plate kept; meta has compose_used=1 for treedock down"
          die "compose up failed (run: treedock down $slug)"
        fi
      else
        info "docker not on PATH — skipped compose"
        compose_file=""
      fi
    else
      info "no compose file — skipped docker"
      compose_file=""
    fi
  else
    info "docker disabled (--no-docker)"
    compose_file=""
  fi

  write_meta "$slug" "$branch" "$project" "$path" "${compose_file:-}" "$compose_used" "$pm"

  local compose_report="none"
  if [[ "$compose_used" -eq 1 ]]; then
    compose_report="${project} (${compose_file})"
  fi

  cat <<EOF
plate ready
  path:     $path
  branch:   $branch
  slug:     $slug
  install:  $pm
  compose:  $compose_report
  meta:     $(meta_path "$slug")

  cd $path
  # when done:
  treedock down $slug
EOF
}

cmd_down() {
  local target="" delete_branch=0 force=0 force_delete_branch=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete-branch) delete_branch=1; shift ;;
      --force-delete-branch) force_delete_branch=1; delete_branch=1; shift ;;
      --force) force=1; shift ;;
      -h|--help)
        echo "Usage: treedock down <slug-or-branch> [--delete-branch] [--force-delete-branch] [--force]"
        echo "  --force                discard dirty plate + allow compose orphan on teardown failure"
        echo "  --delete-branch        delete local branch if fully merged (-d only)"
        echo "  --force-delete-branch  force-delete unmerged local branch (-D); retryable if meta kept"
        return 0
        ;;
      *)
        if [[ -z "$target" && "$1" != --* ]]; then target="$1"; shift
        else die "unknown down flag: $1"; fi
        ;;
    esac
  done
  [[ -n "$target" ]] || die "down requires a slug or branch"

  need_git
  local root slug path project compose_file branch compose_used
  root="$(main_worktree_root)"
  cd "$root"
  slug="$(slugify "$target")"
  path="$(plates_dir)/$slug"

  # Resolve path from meta or worktree list
  local meta_path_field path_missing=0
  meta_path_field="$(read_meta_field "$slug" path || true)"
  if [[ -n "${meta_path_field:-}" ]]; then
    path="$meta_path_field"
  fi
  if [[ ! -d "$path" ]]; then
    local wt
    while IFS= read -r wt; do
      [[ -z "$wt" ]] && continue
      if [[ "$(basename "$wt")" == "$slug" ]]; then
        path="$wt"
        break
      fi
    done < <(git worktree list --porcelain | sed -n 's/^worktree //p')
  fi

  project="$(read_meta_field "$slug" compose_project || true)"
  compose_file="$(read_meta_field "$slug" compose_file || true)"
  branch="$(read_meta_field "$slug" branch || true)"
  compose_used="$(read_meta_field "$slug" compose_used || true)"

  if [[ ! -d "$path" ]]; then
    # Ghost plate: meta or git admin left after manual rm -rf
    local has_meta=0 has_git_reg=0
    [[ -f "$(meta_path "$slug")" ]] && has_meta=1
    while IFS= read -r wt; do
      [[ -z "$wt" ]] && continue
      if [[ "$(basename "$wt")" == "$slug" ]]; then
        has_git_reg=1
        break
      fi
    done < <(git worktree list --porcelain | sed -n 's/^worktree //p')

    if [[ "$has_meta" -eq 1 || "$has_git_reg" -eq 1 ]]; then
      info "plate directory missing — ghost recovery for $slug"
      project="${project:-$(compose_project "$slug")}"
      compose_used="${compose_used:-0}"
      branch="${branch:-}"

      # Fail closed when compose was used: tear down or require --force before dropping recovery.
      if [[ "$compose_used" == "1" ]]; then
        if ! compose_teardown "$project" "${compose_file:-}" "$force" ""; then
          die "ghost plate has compose_used=1 project=${project}. Meta kept at $(meta_path "$slug"). Fix docker/compose and retry, or pass --force to orphan"
        fi
        compose_used=0
      fi

      git worktree prune 2>/dev/null || true
      while IFS= read -r wt; do
        [[ -z "$wt" ]] && continue
        if [[ "$(basename "$wt")" == "$slug" ]]; then
          git worktree remove --force "$wt" 2>/dev/null || true
        fi
      done < <(git worktree list --porcelain | sed -n 's/^worktree //p')
      git worktree prune 2>/dev/null || true

      # Keep meta until branch intent finishes so retries still know the branch name.
      write_meta "$slug" "${branch:-}" "$project" "" "" "0" "none"

      if [[ "$delete_branch" -eq 1 ]]; then
        if ! try_delete_branch "${branch:-}" "$force_delete_branch"; then
          die "branch ${branch} not fully merged. Retry: treedock down ${slug} --force-delete-branch (meta kept; branch name preserved)"
        fi
      fi
      delete_meta "$slug"
      echo "plate tossed (ghost): $slug"
      return 0
    fi
    die "plate not found: $(plates_dir)/$slug (or meta path)"
  fi

  # fallbacks from in-tree marker
  project="${project:-$(read_marker_field "$path" compose_project || true)}"
  compose_file="${compose_file:-$(read_marker_field "$path" compose_file || true)}"
  branch="${branch:-$(read_marker_field "$path" branch || true)}"
  compose_used="${compose_used:-$(read_marker_field "$path" compose_used || true)}"
  project="${project:-$(compose_project "$slug")}"
  compose_used="${compose_used:-0}"

  if [[ -z "${compose_file:-}" ]]; then
    compose_file="$(find_compose_file "$path" || true)"
  fi
  if [[ -z "${branch:-}" ]]; then
    branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi

  # Leave plate if cwd is inside it
  local path_abs cwd_abs
  path_abs="$(realpath_p "$path")"
  cwd_abs="$(pwd -P)"
  case "${cwd_abs}/" in
    "${path_abs}/"*) cd "$root" ;;
  esac

  # Dirty preflight BEFORE compose teardown on non-force (avoid half-tossed plate).
  if [[ "$force" -eq 0 ]] && plate_is_dirty "$path"; then
    die "plate is dirty (uncommitted changes at $path). Commit/stash, or pass --force to discard worktree and tear down compose"
  fi

  # Compose teardown — only if this plate actually started compose (compose_used=1).
  # Fail closed unless --force. Do not infer from compose.yaml alone (--no-docker plates).
  if [[ "$compose_used" == "1" ]]; then
    if ! compose_teardown "$project" "${compose_file:-}" "$force" "$path"; then
      die "compose project ${project} still may be running. Fix docker/compose and retry, or pass --force to orphan the stack and remove the worktree"
    fi
    compose_used=0
  fi

  info "removing worktree $path"
  if [[ "$force" -eq 1 ]]; then
    git worktree remove --force "$path"
  else
    if ! git worktree remove "$path"; then
      die "git worktree remove failed (dirty plate?). Commit/stash, or pass --force to discard"
    fi
  fi
  git worktree prune 2>/dev/null || true

  # Persist recovery meta without path so branch-only retries still work.
  write_meta "$slug" "${branch:-}" "$project" "" "" "0" "none"

  if [[ "$delete_branch" -eq 1 ]]; then
    if ! try_delete_branch "${branch:-}" "$force_delete_branch"; then
      die "branch ${branch} not fully merged. Retry: treedock down ${slug} --force-delete-branch (meta kept; branch name preserved)"
    fi
  fi
  delete_meta "$slug"

  echo "plate tossed: $slug"
}

cmd_list() {
  need_git
  local root
  root="$(main_worktree_root)"
  printf "%-28s %-24s %-32s %s\n" "SLUG/PATH" "BRANCH" "COMPOSE" "STATE"
  local path branch
  path=""; branch=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        path="${line#worktree }"
        ;;
      branch\ *)
        branch="${line#branch refs/heads/}"
        ;;
      HEAD\ *|detached*)
        ;;
      "")
        if [[ -n "$path" ]]; then
          local slug project state rel compose_used
          slug="$(basename "$path")"
          if [[ "$(realpath_p "$path")" == "$(realpath_p "$root")" ]]; then
            slug="(main)"
            project="-"
            compose_used="0"
          else
            project="$(read_meta_field "$slug" compose_project 2>/dev/null || true)"
            compose_used="$(read_meta_field "$slug" compose_used 2>/dev/null || true)"
            if [[ -z "${compose_used:-}" ]]; then
              compose_used="$(read_marker_field "$path" compose_used 2>/dev/null || echo 0)"
            fi
            if [[ "${compose_used:-0}" != "1" ]]; then
              project="-"
            elif [[ -z "${project:-}" ]]; then
              project="$(compose_project "$slug")"
            fi
          fi
          project="${project:--}"
          state="ok"
          if [[ ! -d "$path" ]]; then state="missing"; fi
          if [[ "${compose_used:-0}" == "1" && "$project" != "-" ]] && command -v docker >/dev/null 2>&1; then
            local n
            n="$(docker compose -p "$project" ps -q 2>/dev/null | wc -l | tr -d ' ')"
            if [[ "${n:-0}" -gt 0 ]]; then state="compose:${n}"; fi
          fi
          rel="${path#$root/}"
          [[ "$rel" == "$path" ]] && rel="$path"
          printf "%-28s %-24s %-32s %s\n" "$rel" "${branch:-detached}" "$project" "$state"
        fi
        path=""; branch=""
        ;;
    esac
  done < <(git worktree list --porcelain; echo)
}

cmd_status() {
  local target="${1:-}"
  [[ -n "$target" ]] || die "status requires a slug"
  need_git
  local root slug path
  root="$(main_worktree_root)"
  slug="$(slugify "$target")"
  path="$(plates_dir)/$slug"
  local mp
  mp="$(read_meta_field "$slug" path || true)"
  [[ -n "${mp:-}" && -d "$mp" ]] && path="$mp"
  [[ -d "$path" ]] || die "plate not found: $path"

  echo "path:    $path"
  echo "branch:  $(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  local pm
  pm="$(detect_install "$path")"
  echo "install: $pm"
  if [[ -d "$path/node_modules" ]]; then
    echo "node_modules: present"
  else
    echo "node_modules: absent"
  fi
  local project compose_file compose_used
  project="$(read_meta_field "$slug" compose_project || compose_project "$slug")"
  compose_file="$(read_meta_field "$slug" compose_file || true)"
  compose_used="$(read_meta_field "$slug" compose_used || echo 0)"
  echo "compose_project: $project"
  echo "compose_used: $compose_used"
  if [[ -n "${compose_file:-}" ]]; then
    echo "compose_file: $compose_file"
  elif compose_file="$(find_compose_file "$path")"; then
    echo "compose_file: $compose_file"
  else
    echo "compose_file: (none)"
  fi
  if command -v docker >/dev/null 2>&1 && [[ "$project" != "-" ]]; then
    echo "containers:"
    docker compose -p "$project" ps 2>/dev/null || true
  fi
  if [[ -f "$(meta_path "$slug")" ]]; then
    echo "--- meta ---"
    cat "$(meta_path "$slug")"
  fi
}

# True if the plate has uncommitted tracked/untracked changes (git worktree remove would refuse).
plate_is_dirty() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  # porcelain empty ⇒ clean enough for worktree remove without --force
  [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null || true)" ]]
}

# Delete local branch; 0 success, 1 unmerged/missing policy fail. Announces; never silent -D.
try_delete_branch() {
  local branch="$1" force_delete="${2:-0}"
  [[ -n "$branch" && "$branch" != "HEAD" ]] || return 0
  git show-ref --verify --quiet "refs/heads/${branch}" || return 0
  if [[ "$force_delete" -eq 1 ]]; then
    info "force-deleting local branch ${branch}"
    git branch -D "$branch"
    return 0
  fi
  info "deleting local branch ${branch} (merged only; use --force-delete-branch for -D)"
  if git branch -d "$branch"; then
    return 0
  fi
  return 1
}

# Teardown a compose project fail-closed. Returns 0 if safe to discard meta/dir.
# Args: project, optional compose_file, force(0|1), cwd_for_-f (optional)
compose_teardown() {
  local project="$1" compose_file="${2:-}" force="${3:-0}" workdir="${4:-}"
  if ! command -v docker >/dev/null 2>&1; then
    if [[ "$force" -eq 1 ]]; then
      info "docker missing — --force: orphaning project ${project}"
      return 0
    fi
    info "docker unavailable; keeping recovery data for project ${project}"
    return 1
  fi
  info "compose down project=${project}"
  local down_ok=0
  if [[ -n "$compose_file" && -f "$compose_file" && -n "$workdir" && -d "$workdir" ]]; then
    if (cd "$workdir" && COMPOSE_PROJECT_NAME="$project" docker compose -p "$project" -f "$compose_file" down --remove-orphans); then
      down_ok=1
    fi
  fi
  if [[ "$down_ok" -eq 0 ]]; then
    if COMPOSE_PROJECT_NAME="$project" docker compose -p "$project" down --remove-orphans 2>/dev/null; then
      down_ok=1
    fi
  fi
  if [[ "$down_ok" -eq 1 ]]; then
    return 0
  fi
  if [[ "$force" -eq 1 ]]; then
    info "compose down failed — --force: orphaning project ${project}"
    return 0
  fi
  info "compose down failed for ${project}; recovery data kept"
  return 1
}

# Prefer gh for GitHub, glab for GitLab. Fail closed if neither is usable.
detect_pr_cli() {
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  case "$url" in
    *gitlab*)
      if command -v glab >/dev/null 2>&1; then
        echo glab
        return 0
      fi
      ;;
  esac
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    echo gh
    return 0
  fi
  if command -v glab >/dev/null 2>&1; then
    echo glab
    return 0
  fi
  return 1
}

# Print: <status> <detail...>
# status: merged|closed|open|none|error
# Uses newest PR by number; any OPEN wins over finished states.
pr_status_for_branch() {
  local branch="$1" cli="${2:-}"
  [[ -n "$branch" && "$branch" != "HEAD" ]] || { echo "error no-branch"; return 0; }
  if [[ -z "$cli" ]]; then
    cli="$(detect_pr_cli)" || { echo "error no-pr-cli"; return 0; }
  fi
  case "$cli" in
    gh)
      local json
      if ! json="$(gh pr list --head "$branch" --state all --limit 50 \
          --json number,state,url,title 2>/dev/null)"; then
        echo "error gh-query-failed"
        return 0
      fi
      python3 -c '
import json,sys
try:
  prs=json.load(sys.stdin)
except Exception:
  print("error bad-json"); sys.exit(0)
if not isinstance(prs, list):
  print("error bad-json-shape"); sys.exit(0)
if not prs:
  print("none no-pr"); sys.exit(0)
prs=sorted(prs, key=lambda p: int(p.get("number") or 0), reverse=True)
# Any open keeps the plate
opens=[p for p in prs if str(p.get("state","")).upper()=="OPEN"]
if opens:
  p=opens[0]; print("open #%s %s" % (p.get("number"), p.get("url") or "")); sys.exit(0)
# Newest PR wins among non-open
p=prs[0]
st=str(p.get("state","")).upper()
if st=="MERGED":
  print("merged #%s %s" % (p.get("number"), p.get("url") or "")); sys.exit(0)
if st=="CLOSED":
  print("closed #%s %s" % (p.get("number"), p.get("url") or "")); sys.exit(0)
print("error unknown-state-%s" % (st or "empty"))
' <<<"$json"
      ;;
    glab)
      local json
      if ! json="$(glab mr list --source-branch "$branch" -A -F json 2>/dev/null)"; then
        # older glab may use different flags
        if ! json="$(glab mr list --source-branch="$branch" --output json 2>/dev/null)"; then
          echo "error glab-query-failed"
          return 0
        fi
      fi
      python3 -c '
import json,sys
try:
  prs=json.load(sys.stdin)
except Exception:
  print("error bad-json"); sys.exit(0)
if isinstance(prs, dict):
  if "items" in prs and isinstance(prs.get("items"), list):
    prs=prs["items"]
  elif "merge_requests" in prs and isinstance(prs.get("merge_requests"), list):
    prs=prs["merge_requests"]
  else:
    print("error bad-json-shape"); sys.exit(0)
elif not isinstance(prs, list):
  print("error bad-json-shape"); sys.exit(0)
if not prs:
  print("none no-pr"); sys.exit(0)
def num(p):
  return int(p.get("iid") or p.get("number") or p.get("id") or 0)
prs=sorted(prs, key=num, reverse=True)
def st(p):
  return str(p.get("state") or p.get("State") or "").lower()
opens=[p for p in prs if st(p) in ("opened","open")]
if opens:
  p=opens[0]; print("open !%s %s" % (num(p), p.get("web_url") or p.get("url") or "")); sys.exit(0)
p=prs[0]
s=st(p)
if s=="merged":
  print("merged !%s %s" % (num(p), p.get("web_url") or p.get("url") or "")); sys.exit(0)
if s=="closed":
  print("closed !%s %s" % (num(p), p.get("web_url") or p.get("url") or "")); sys.exit(0)
print("error unknown-state-%s" % (s or "empty"))
' <<<"$json"
      ;;
    *)
      echo "error unknown-cli"
      ;;
  esac
}

# Reap plates whose PR/MR is merged or closed (not open). Report-only unless --yes.
# Reuses `down` invariants (dirty preflight, fail-closed compose). Never deletes branches.
cmd_prune_merged() {
  local yes="${1:-0}" force="${2:-0}"
  need_git
  local root cli
  root="$(main_worktree_root)"
  cd "$root"

  if ! cli="$(detect_pr_cli)"; then
    die "prune --merged requires authenticated gh (GitHub) or glab (GitLab) on PATH"
  fi
  info "PR provider: $cli"

  if [[ ! -d "$(meta_dir)" ]]; then
    echo "no treedock plates (no .worktrees/.meta)"
    return 0
  fi

  printf "%-22s %-28s %-10s %s\n" "SLUG" "BRANCH" "STATUS" "ACTION/DETAIL"
  local mf slug branch path status detail action
  local reaped=0 skipped=0 failed=0 planned=0
  local line st rest

  for mf in "$(meta_dir)"/*.meta; do
    [[ -f "$mf" ]] || continue
    slug="$(basename "$mf" .meta)"
    branch="$(sed -n 's/^branch=//p' "$mf" | head -1)"
    path="$(sed -n 's/^path=//p' "$mf" | head -1)"
    line="$(pr_status_for_branch "$branch" "$cli")"
    st="${line%% *}"
    rest="${line#* }"
    [[ "$rest" == "$line" ]] && rest=""

    case "$st" in
      merged|closed)
        if [[ "$yes" -ne 1 ]]; then
          action="would-reap (pass --yes)"
          planned=$((planned + 1))
          printf "%-22s %-28s %-10s %s\n" "$slug" "${branch:-?}" "$st" "$action $rest"
          continue
        fi
        # Act: never implicit branch delete; optional --force only for down
        local down_args=("$slug")
        if [[ "$force" -eq 1 ]]; then
          down_args+=(--force)
        fi
        if [[ -n "$path" && -d "$path" ]] && plate_is_dirty "$path" && [[ "$force" -eq 0 ]]; then
          action="skip-dirty"
          skipped=$((skipped + 1))
          failed=$((failed + 1))
          printf "%-22s %-28s %-10s %s\n" "$slug" "${branch:-?}" "$st" "$action $rest"
          continue
        fi
        if bash "$TREEDOCK_SELF" down "${down_args[@]}"; then
          action="reaped"
          reaped=$((reaped + 1))
        else
          action="down-failed"
          failed=$((failed + 1))
        fi
        printf "%-22s %-28s %-10s %s\n" "$slug" "${branch:-?}" "$st" "$action $rest"
        ;;
      open)
        printf "%-22s %-28s %-10s %s\n" "$slug" "${branch:-?}" "$st" "keep $rest"
        ;;
      none)
        printf "%-22s %-28s %-10s %s\n" "$slug" "${branch:-?}" "$st" "keep (no PR/MR)"
        ;;
      error|*)
        printf "%-22s %-28s %-10s %s\n" "$slug" "${branch:-?}" "${st:-error}" "keep (unverified) $rest"
        failed=$((failed + 1))
        ;;
    esac
  done

  if [[ "$yes" -ne 1 ]]; then
    echo "prune --merged plan: $planned candidate(s). Re-run with --yes to reap (no branch delete)."
    return 0
  fi
  echo "prune --merged done: reaped=$reaped skipped_or_failed=$failed"
  if [[ "$failed" -gt 0 ]]; then
    return 1
  fi
  return 0
}

cmd_prune() {
  local yes=0 force=0 merged=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) yes=1; shift ;;
      --force) force=1; shift ;;
      --merged) merged=1; shift ;;
      -h|--help)
        echo "Usage: treedock prune [--yes] [--force]"
        echo "       treedock prune --merged [--yes] [--force]"
        echo "  --yes     required to delete orphans / reap finished-PR plates"
        echo "  --force   allow orphaning compose stacks if teardown fails (with --yes)"
        echo "  --merged  report/reap plates whose GitHub/GitLab PR/MR is merged or closed"
        echo "            (gh/glab; skips dirty unless --force; never deletes branches)"
        return 0
        ;;
      *) die "unknown prune flag: $1" ;;
    esac
  done

  need_git
  local root
  root="$(main_worktree_root)"
  cd "$root"

  if [[ "$merged" -eq 1 ]]; then
    cmd_prune_merged "$yes" "$force"
    return $?
  fi

  info "git worktree prune"
  git worktree prune

  # Build set of registered absolute paths
  local reg_file
  reg_file="$(mktemp)"
  registered_worktree_paths >"$reg_file" || true
  local skipped=0

  if [[ -d "$(plates_dir)" ]]; then
    local d slug project cf d_abs registered mused
    for d in "$(plates_dir)"/*; do
      [[ -e "$d" ]] || continue
      [[ -d "$d" ]] || continue
      slug="$(basename "$d")"
      [[ "$slug" == ".meta" ]] && continue
      d_abs="$(realpath_p "$d")"
      registered=0
      if grep -Fxq "$d_abs" "$reg_file" 2>/dev/null; then
        registered=1
      fi
      if [[ "$registered" -eq 1 ]]; then
        continue
      fi
      # Unregistered directory
      project="$(read_meta_field "$slug" compose_project || compose_project "$slug")"
      cf="$(read_meta_field "$slug" compose_file || true)"
      mused="$(read_meta_field "$slug" compose_used || true)"
      if [[ -z "${cf:-}" ]]; then cf="$(find_compose_file "$d" || true)"; fi
      if [[ "$yes" -ne 1 ]]; then
        info "orphan (not registered): $d — pass --yes to compose-down + rm -rf"
        continue
      fi
      # Strict: only tear down compose when meta says compose_used=1 (not mere compose file)
      if [[ "${mused:-0}" == "1" ]]; then
        if ! compose_teardown "$project" "${cf:-}" "$force" "$d"; then
          info "skipping $d (compose teardown not confirmed; re-run with --yes --force to orphan)"
          skipped=$((skipped + 1))
          continue
        fi
      fi
      info "removing orphan directory $d"
      rm -rf "$d"
      delete_meta "$slug"
    done
  fi

  # Stale meta files whose plate path is gone
  if [[ -d "$(meta_dir)" ]]; then
    local mf mslug mpath mproj mused
    for mf in "$(meta_dir)"/*.meta; do
      [[ -f "$mf" ]] || continue
      mslug="$(basename "$mf" .meta)"
      mpath="$(sed -n 's/^path=//p' "$mf" | head -1)"
      if [[ -n "$mpath" && -d "$mpath" ]]; then
        continue
      fi
      # path missing
      mproj="$(sed -n 's/^compose_project=//p' "$mf" | head -1)"
      mused="$(sed -n 's/^compose_used=//p' "$mf" | head -1)"
      if [[ "$yes" -ne 1 ]]; then
        info "stale meta (plate gone): $mf — pass --yes to drop"
        continue
      fi
      if [[ "${mused:-0}" == "1" && -n "$mproj" ]]; then
        if ! compose_teardown "$mproj" "" "$force" ""; then
          info "skipping stale meta $mf (compose teardown not confirmed; re-run with --yes --force to orphan)"
          skipped=$((skipped + 1))
          continue
        fi
      fi
      info "removing stale meta $mf"
      rm -f "$mf"
    done
  fi

  rm -f "$reg_file"
  if [[ "$skipped" -gt 0 ]]; then
    echo "prune complete ($skipped item(s) kept — need --force to orphan)"
  else
    echo "prune complete"
  fi
}

usage() {
  cat <<EOF
treedock v${VERSION} — paper-plate git worktrees

Usage:
  treedock up <branch-or-slug> [--base <ref>] [--no-docker]
  treedock up --pr <N> [--base <ref>] [--no-docker]
  treedock down <slug-or-branch> [--delete-branch] [--force-delete-branch] [--force]
  treedock list
  treedock status <slug>
  treedock prune [--yes] [--force]
  treedock prune --merged [--yes] [--force]

Environment:
  TREEDOCK_BASE   default base ref for new branches (overrides auto main/master)

Safety:
  non-force down: dirty preflight before compose teardown (no half-toss)
  down fails closed if compose teardown fails (use --force to orphan)
  meta kept until branch-delete succeeds (retry: down <slug> --force-delete-branch)
  ghost down (dir gone) keeps meta if compose_used=1 until teardown or --force
  prune requires --yes to delete; --force to orphan stacks when teardown fails
  prune --merged: gh/glab PR status; skips dirty; never deletes branches
  compose_used=1 is recorded before docker compose up (mid-kill safe)
  --delete-branch uses git branch -d only; unmerged needs --force-delete-branch
EOF
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    up) cmd_up "$@" ;;
    down) cmd_down "$@" ;;
    list|ls) cmd_list "$@" ;;
    status) cmd_status "$@" ;;
    prune) cmd_prune "$@" ;;
    -h|--help|help|"") usage ;;
    -v|--version) echo "$VERSION" ;;
    *) die "unknown command: $cmd (try: up down list status prune)" ;;
  esac
}

main "$@"
