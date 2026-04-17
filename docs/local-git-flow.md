# Local Git Flow

This checkout has two distinct roles. Keep them separate.

## Roles

- `/Users/zarretkieran/weft`
  - Active local development checkout.
  - Local customizations live on `local/minimax-support`.
  - Push this branch to `personal/local/minimax-support`.
  - Promote reviewed local changes into `personal/main` without pushing to `origin`.
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
  - Your fork's durable default branch.
  - Keep it current with the latest reviewed local customization state.
  - It may differ from upstream `main`.
- `local/minimax-support`
  - Active customization branch in the local checkout.
  - New local Weft changes land here first.
- `upstream-main`
  - Branch used only inside `/Users/zarretkieran/weft-upstream`.
  - Mirrors upstream `origin/main`.

## Rules

- Never do local development on `main`.
- Never auto-pull into `/Users/zarretkieran/weft`.
- Only fast-forward update `/Users/zarretkieran/weft-upstream`.
- Integrate upstream changes into `local/minimax-support` by cherry-picking commits from the clean mirror.
- If a cherry-pick conflicts, stop immediately and report the conflict. Do not resolve by force, reset, or skip silently.
- After a successful integration pass, push `local/minimax-support` to `personal`.
- After local work is reviewed and stable, fast-forward `personal/main` to the desired local commit. Do not push local changes to `origin/main`.
- Never run database reset, cleanup, or project-deleting commands as part of git sync.

## Standard Update Loop

From the clean mirror:

```bash
git -C /Users/zarretkieran/weft-upstream fetch origin --prune
git -C /Users/zarretkieran/weft-upstream pull --ff-only origin main
```

From the customized checkout:

```bash
git -C /Users/zarretkieran/weft checkout local/minimax-support
git -C /Users/zarretkieran/weft fetch origin --prune
git -C /Users/zarretkieran/weft log --oneline --reverse HEAD..origin/main
```

If the upstream commits look safe to carry over, cherry-pick them one by one:

```bash
git -C /Users/zarretkieran/weft cherry-pick <commit>
git -C /Users/zarretkieran/weft cherry-pick <next-commit>
git -C /Users/zarretkieran/weft push personal local/minimax-support
```

## Promotion To Personal Main

When local customization work is ready to become the new default state of your fork, promote it to `personal/main` only.

First make sure the working branch is up to date on the fork:

```bash
git -C /Users/zarretkieran/weft checkout local/minimax-support
git -C /Users/zarretkieran/weft push personal local/minimax-support
```

If `personal/main` is an ancestor of `local/minimax-support`, fast-forward the fork's main directly:

```bash
git -C /Users/zarretkieran/weft push personal local/minimax-support:main
```

If that push is rejected because the histories diverged, create a temporary local branch from `personal/main`, merge deliberately, and then push to `personal/main`. Do not involve `origin/main` in that process.

## Automation Policy

The weekly Codex automation should follow this exact flow:

1. Update `/Users/zarretkieran/weft-upstream` with `fetch` plus `pull --ff-only`.
2. Compare upstream commits not yet present on `local/minimax-support`.
3. Cherry-pick only clean, reviewable commits onto `local/minimax-support`.
4. Stop on conflict and open an inbox item with the failing commit hash and files involved.
5. Push successful integrations to `personal/local/minimax-support`.
6. Do not update `personal/main` automatically unless the automation prompt is explicitly expanded to do promotion as well.

The automation must treat `docs/local-git-flow.md` as the local policy file for future runs.
