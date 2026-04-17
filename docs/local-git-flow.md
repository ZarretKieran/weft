# Local Git Flow

This setup has two distinct roles. Keep them separate.

## Roles

- `/Users/zarretkieran/weft`
  - Active local development checkout.
  - Canonical local Weft installation.
  - Local customizations and reconciled upstream changes both land on `main`.
  - `main` tracks `personal/main`.
- `/Users/zarretkieran/weft-upstream`
  - Clean upstream mirror.
  - Tracks `origin/main` on branch `upstream-main`.
  - Safe place for automated `fetch` and `pull --ff-only`.

## Remotes

- `origin` = canonical upstream (`WeaveMindAI/weft`)
- `personal` = personal fork (`ZarretKieran/weft`)

## Branch Responsibilities

- `origin/main`
  - Canonical upstream history. Read from it. Do not push to it.
- `personal/main`
  - Your durable integration branch.
  - Keep it current with the merged result of local Weft work plus upstream `origin/main`.
- `main`
  - Active branch in `/Users/zarretkieran/weft`.
  - Local Weft changes land here first.
  - This branch should match `personal/main` after every successful sync run.
- `upstream-main`
  - Branch used only inside `/Users/zarretkieran/weft-upstream`.
  - Mirrors upstream `origin/main`.

## Rules

- Do local Weft development in `/Users/zarretkieran/weft` on `main`.
- Never point local `main` back at `origin/main`.
- Only fast-forward update `/Users/zarretkieran/weft-upstream`.
- Keep `/Users/zarretkieran/weft/main` aligned with `personal/main`.
- Integrate upstream changes by merging `origin/main` into local `main`.
- If that merge conflicts, the cron agent should resolve the conflict in `/Users/zarretkieran/weft`, verify the result, and then complete the merge.
- After a successful integration pass, push `main` to `personal/main`.
- Do not push local changes to `origin/main`.
- Never run database reset, cleanup, or project-deleting commands as part of git sync.

## Standard Local Work

Make Weft changes directly in `/Users/zarretkieran/weft` on `main`:

```bash
git -C /Users/zarretkieran/weft checkout main
git -C /Users/zarretkieran/weft commit -am "Describe the local Weft change"
git -C /Users/zarretkieran/weft push personal main
```

If you created new files, add them first:

```bash
git -C /Users/zarretkieran/weft add path/to/new-file
git -C /Users/zarretkieran/weft commit -m "Describe the local Weft change"
git -C /Users/zarretkieran/weft push personal main
```

## Standard Reconciliation Loop

The deterministic fast path is:

```bash
./scripts/reconcile-local-main.sh
```

What it does:

1. Updates `/Users/zarretkieran/weft-upstream` with `fetch` plus `pull --ff-only`.
2. Checks out `/Users/zarretkieran/weft/main`.
3. Fast-forwards local `main` from `personal/main`.
4. Creates an automatic snapshot commit if there are unstaged or uncommitted local source changes.
5. Merges `origin/main` into local `main`.
6. Pushes the merged result to `personal/main`.

If the merge conflicts, the script stops and leaves the repository in the conflict state for an agent or human to resolve. The resolution still happens in `/Users/zarretkieran/weft` on `main`.

## Automation Policy

The weekly Codex automation should follow this exact flow:

1. Run `/Users/zarretkieran/weft/scripts/reconcile-local-main.sh`.
2. If the script completes cleanly, stop.
3. If the script stops on a merge conflict, resolve that conflict directly in `/Users/zarretkieran/weft` on `main`.
4. Run focused verification for the files involved.
5. Complete the merge and push `main` to `personal/main`.
6. Leave `/Users/zarretkieran/weft` checked out on the merged `main` result so the local Weft installation is the current reconciled state.
7. Use a PR-style fallback only if the agent cannot safely land a direct merge after inspection and verification.

The automation must treat `docs/local-git-flow.md` as the local policy file for future runs.
