# Protocols — Action Boundaries

> What an Agent may do unsupervised, what must stop and confirm, and what is
> never allowed. Single source of truth for hooks and guardrails — if a rule
> lives elsewhere, link it here, do not re-define.
>
> **This file is a template.** Copy into your project's `harness/` dir and
> adapt the examples. `mo-plan` and `mo-work` read this file before every run
> so plan units that cross a boundary get surfaced.

## Free — proceed without asking

- Read any file in the worktree
- Run the configured test / typecheck / lint commands (`commands.*` in `mo-config.json`)
- Edit files inside the current worktree branch
- `git add` / `git commit` (commits are autonomous; gates run via pre-commit hooks)
- Create / update plan files at the configured `planStore` path

## Stop and confirm — visible-to-others or hard-to-reverse

- `git push` to any branch
- `gh pr create`, `gh pr merge`, `gh pr close`, `gh issue create`, any GitHub comment
- Slack / tracker writes
- Drop / truncate / delete in any database or shared resource
- Modifying CI / workflow files
- Removing or downgrading dependencies
- Uploading content to third-party renderers / pastebins (may be cached or indexed)
- Any change to shared cloud resources (S3, buckets, DNS, IAM, etc.)

## Hard rules — never, no override without explicit user instruction

- Edit source files in the repo's container root instead of a per-task worktree
- Check out the same branch in two worktrees simultaneously
- Hardcode config values — use the config file or environment
- Forward raw error messages to any externally-visible client (sanitize at the edge)
- Commit plan documents (they live under `planStore`, which must be gitignored)
- `git commit --no-verify` (use stash-dance if a hook modifies unrelated files)
- `git push --force` to protected branches (e.g. `main`, `dev`)
- `git rebase -i` / `git add -i` (interactive — not supported)
- Skip GPG signing (`--no-gpg-sign`)
- Create a PR without explicit user confirmation (commits are autonomous, PRs are not)

## Pre-action checks (lifecycle hooks)

### Before any `tmux send-keys` (Orchestrator mode)

| Pane state                   | Action                                        |
|------------------------------|-----------------------------------------------|
| `Enter to select` (menu)     | Send `Escape`, wait 2s, then send command     |
| Thinking >5 min              | Send `Escape` to interrupt, send simpler form |
| Idle prompt                  | Safe to send                                  |

### Before any external API call

- API keys live in the file referenced by `envFile` in `mo-config.json`.
- Source it with `set -a && source <envFile> && set +a`.
- Keys must never appear in source files, commits, or logs.

---

Add project-specific rules below. Prefer **link** over **duplicate** when a
rule is also defined in another document.
