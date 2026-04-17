#!/usr/bin/env bash
set -euo pipefail

WEFT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_DIR="${WEFT_UPSTREAM_DIR:-/Users/zarretkieran/weft-upstream}"
LOCAL_BRANCH="${WEFT_LOCAL_BRANCH:-main}"
UPSTREAM_BRANCH="${WEFT_UPSTREAM_BRANCH:-main}"
UPSTREAM_MIRROR_BRANCH="${WEFT_UPSTREAM_MIRROR_BRANCH:-upstream-main}"
SNAPSHOT_PREFIX="${WEFT_SNAPSHOT_PREFIX:-chore(sync): snapshot local changes before upstream merge}"

log() {
  printf '[weft-sync] %s\n' "$*"
}

die() {
  printf '[weft-sync] ERROR: %s\n' "$*" >&2
  exit 1
}

require_git_repo() {
  local dir="$1"
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "Not a git repository: $dir"
}

ensure_no_in_progress_git_operation() {
  local dir="$1"
  local git_dir
  git_dir="$(git -C "$dir" rev-parse --git-dir)"

  [[ -f "$git_dir/MERGE_HEAD" ]] && die "Merge already in progress in $dir. Resolve it before running reconciliation."
  [[ -d "$git_dir/rebase-merge" ]] && die "Rebase already in progress in $dir. Resolve it before running reconciliation."
  [[ -d "$git_dir/rebase-apply" ]] && die "Rebase already in progress in $dir. Resolve it before running reconciliation."
  [[ -f "$git_dir/CHERRY_PICK_HEAD" ]] && die "Cherry-pick already in progress in $dir. Resolve it before running reconciliation."
  return 0
}

is_junk_path() {
  local path="$1"
  case "$path" in
    .DS_Store|*/.DS_Store|.codex_staging/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

stage_snapshot_candidates() {
  local dir="$1"
  local added_any=0
  local path

  git -C "$dir" add -u

  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if is_junk_path "$path"; then
      continue
    fi
    git -C "$dir" add -- "$path"
    added_any=1
  done < <(git -C "$dir" ls-files --others --exclude-standard)

  if git -C "$dir" diff --cached --quiet; then
    return 1
  fi

  if [[ "$added_any" -eq 1 ]]; then
    log "Included untracked files in the snapshot commit."
  fi
  return 0
}

snapshot_local_changes_if_needed() {
  local dir="$1"

  if [[ -z "$(git -C "$dir" status --short)" ]]; then
    log "Working tree is already clean."
    return 0
  fi

  if ! stage_snapshot_candidates "$dir"; then
    log "Working tree has only untracked junk or ignored files. No snapshot commit created."
    return 0
  fi

  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  git -C "$dir" commit -m "$SNAPSHOT_PREFIX ($timestamp)"
  log "Created snapshot commit for local changes."
}

update_upstream_mirror() {
  require_git_repo "$UPSTREAM_DIR"
  ensure_no_in_progress_git_operation "$UPSTREAM_DIR"
  log "Updating clean upstream mirror in $UPSTREAM_DIR"
  git -C "$UPSTREAM_DIR" checkout "$UPSTREAM_MIRROR_BRANCH" >/dev/null 2>&1
  git -C "$UPSTREAM_DIR" fetch origin --prune
  git -C "$UPSTREAM_DIR" pull --ff-only origin "$UPSTREAM_BRANCH"
}

prepare_local_main() {
  require_git_repo "$WEFT_DIR"
  ensure_no_in_progress_git_operation "$WEFT_DIR"
  log "Preparing local canonical checkout in $WEFT_DIR"
  git -C "$WEFT_DIR" config rerere.enabled true
  git -C "$WEFT_DIR" checkout "$LOCAL_BRANCH" >/dev/null 2>&1
  snapshot_local_changes_if_needed "$WEFT_DIR"
  git -C "$WEFT_DIR" fetch personal --prune
  git -C "$WEFT_DIR" fetch origin --prune
  reconcile_personal_main
}

reconcile_personal_main() {
  local personal_head
  personal_head="$(git -C "$WEFT_DIR" rev-parse "personal/$LOCAL_BRANCH")"

  if git -C "$WEFT_DIR" merge-base --is-ancestor "$personal_head" HEAD; then
    log "Local main already contains personal/$LOCAL_BRANCH."
    return 0
  fi

  if git -C "$WEFT_DIR" merge-base --is-ancestor HEAD "$personal_head"; then
    log "Fast-forwarding local main from personal/$LOCAL_BRANCH."
    git -C "$WEFT_DIR" merge --ff-only "$personal_head"
    return 0
  fi

  log "Local main and personal/$LOCAL_BRANCH diverged. Merging personal/$LOCAL_BRANCH into local main."
  if git -C "$WEFT_DIR" merge --no-ff --no-edit "$personal_head"; then
    log "personal/$LOCAL_BRANCH merge completed cleanly."
    return 0
  fi

  log "Merge with personal/$LOCAL_BRANCH reported conflicts. Resolve them in $WEFT_DIR, then run:"
  log "  git -C $WEFT_DIR merge --continue"
  log "  git -C $WEFT_DIR push personal $LOCAL_BRANCH"
  exit 2
}

merge_upstream_into_local_main() {
  local origin_head
  origin_head="$(git -C "$WEFT_DIR" rev-parse "origin/$UPSTREAM_BRANCH")"

  if git -C "$WEFT_DIR" merge-base --is-ancestor "$origin_head" HEAD; then
    log "Local main already contains origin/$UPSTREAM_BRANCH."
    return 0
  fi

  log "Merging origin/$UPSTREAM_BRANCH into $LOCAL_BRANCH"
  if git -C "$WEFT_DIR" merge --no-ff --no-edit "$origin_head"; then
    log "Upstream merge completed cleanly."
    return 0
  fi

  log "Merge reported conflicts. Resolve them in $WEFT_DIR, then run:"
  log "  git -C $WEFT_DIR merge --continue"
  log "  git -C $WEFT_DIR push personal $LOCAL_BRANCH"
  exit 2
}

push_local_main() {
  log "Pushing $LOCAL_BRANCH to personal/$LOCAL_BRANCH"
  if git -C "$WEFT_DIR" push personal "$LOCAL_BRANCH"; then
    return 0
  fi

  die "Push to personal/$LOCAL_BRANCH failed. Fetch personal, inspect divergence, and rerun reconciliation."
}

main() {
  update_upstream_mirror
  prepare_local_main
  merge_upstream_into_local_main
  push_local_main
  log "Reconciliation complete. Local canonical checkout and personal/main are up to date."
}

main "$@"
