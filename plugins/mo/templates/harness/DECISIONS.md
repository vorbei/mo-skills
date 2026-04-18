# Architecture Decisions

> Settled decisions. Do not re-litigate without new evidence. Each entry:
> what, why, alternatives considered, status, when it triggers.
>
> **This file is a template.** Copy it into your project's `harness/` dir (or
> wherever `harnessDir` in `mo-config.json` points), then replace these
> examples with real decisions your team has made. `mo-plan` and `mo-work`
> read from this file before every run.

## Example: layered architecture

- **Decision:** One-way dependency between layers (e.g. `lib → api → stores → hooks → components → routes`); enforced by a static arch-lint.
- **Why:** Random cross-layer imports are the #1 source of refactor regressions; a static gate is cheaper than convention.
- **Alternatives considered:** Convention-only (drifts), feature-folder slicing (breaks shared primitives).
- **Status:** Active.
- **Triggers:** Any new file under the affected source tree. Any "just import it, it's fine" suggestion.

## Example: test layering

- **Decision:** No component render tests. Extract pure logic into unit-testable modules instead.
- **Why:** Render tests couple to implementation and break on every UI-library upgrade, producing false confidence.
- **Alternatives considered:** Snapshot tests (noisy), visual regression (heavy infra), E2E only (slower feedback).
- **Status:** Active.
- **Triggers:** "Let me add a test for this component" — instead, find the pure logic, lift it, test it.

## Example: plan files never committed

- **Decision:** Plan files (from `/mo-plan` etc.) live at a single absolute path that is gitignored. Every worktree shares the same path.
- **Why:** Plans are local thinking artifacts. Committing them pollutes the repo's docs tree and triggers review rejections.
- **Alternatives considered:** Per-worktree `plans/` (drifts and gets lost on cleanup), commit and prune (manual overhead).
- **Status:** Active.
- **Triggers:** Any planning skill output. Any "let me check this plan into the repo for review" instinct.

## Example: PR review uses a single tool

- **Decision:** All pre-merge code review goes through one path (e.g. `mo-codex review-code --base origin/<default>`). Replaces ad-hoc review flows.
- **Why:** A single reproducible path matches what the remote will diff; ad-hoc flows use stale local refs.
- **Status:** Active.

---

Add project-specific decisions below. Each should answer: **what, why, what was considered instead, is it still active, and when it triggers**.
