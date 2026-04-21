---
name: mo-fix
description: "Bug fix and PR review fix workflow with TDD-first approach. Writes failing test first, mechanical triggers for systemic issues, container/view regression check, multi-round review loop support. Use when asked to 'fix a bug', 'mo-fix', 'debug this', 'fix review comments', 'handle PR feedback', or when a test failure needs investigation."
argument-hint: "[bug description, error message, issue number, or PR number for review fixes]"
---

# Mo Fix

> **Reference, not replacement.** This skill is a *project overlay* on the
> `ce:work` execution approach for fix-shaped work. Each section either
> (a) adds a project-specific constraint ce:work does not have, (b) overrides
> a ce:work default with a one-line justification, or (c) keeps a concept
> locally because ce:work does not own it. If a section grows beyond that
> contract, hoist it into ce:work.

## Config

Load `mo-config.json` (first match wins):

```bash
for p in "${CLAUDE_PROJECT_DIR:-}/.claude/mo-config.json" \
         "$PWD/.claude/mo-config.json" \
         "$HOME/.claude/mo-config.json"; do
  [[ -f "$p" ]] && { MO_CONFIG="$p"; break; }
done

TEST_CMD=$(jq -r '.commands.test // "pnpm test"' "${MO_CONFIG:-/dev/null}")
TYPECHECK_CMD=$(jq -r '.commands.typecheck // "pnpm typecheck"' "${MO_CONFIG:-/dev/null}")
ARCH_CMD=$(jq -r '.commands.archLint // ""' "${MO_CONFIG:-/dev/null}")
HARNESS_DIR=$(jq -r '.harnessDir // empty' "${MO_CONFIG:-/dev/null}")
ISSUE_PREFIX=$(jq -r '.issueTracker.prefix // empty' "${MO_CONFIG:-/dev/null}")
FRONTEND_ENABLED=$(jq -r '.frontend.enabled // false' "${MO_CONFIG:-/dev/null}")
MOBILE_WIDTH=$(jq -r '.frontend.mobileWidth // 375' "${MO_CONFIG:-/dev/null}")
CONTAINER_CHECK=$(jq -r '.frontend.containerCheckCommand // empty' "${MO_CONFIG:-/dev/null}")
CONTAINER_GLOB=$(jq -r '.frontend.containerGlob // empty' "${MO_CONFIG:-/dev/null}")
# Design doc paths, newline-separated
DESIGN_DOCS=$(jq -r '.frontend.designDocs[]? // empty' "${MO_CONFIG:-/dev/null}")
BASE_DEFAULT=$(jq -r '.base.default // "main"' "${MO_CONFIG:-/dev/null}")
LANG_CONV=$(jq -r '.language.conversation // "English"' "${MO_CONFIG:-/dev/null}")
LANG_ART=$(jq -r '.language.artifacts // "English"' "${MO_CONFIG:-/dev/null}")
```

**Language policy:** test names, code, evidence blocks, commit messages →
`$LANG_ART`. Conversational replies during the fix → `$LANG_CONV`.

## Input

<bug_description> #$ARGUMENTS </bug_description>

If empty, ask: "Describe the bug, error, issue number, or PR number."

## Mode routing

| Input | Mode |
|-------|------|
| bug description / error text / `${ISSUE_PREFIX}-NNN` | **Bug Fix** → Step 1 |
| PR number / `#NNN` / "review comments" | **Review Fix** → Step R1 |

## Prerequisites

Read **authority files first** from `$HARNESS_DIR` (or the project's
equivalent), in order:

1. `protocols.md` — action boundaries. Bug fixes that touch DBs, external
   APIs, or shared resources must respect the stop-and-confirm list.
2. `DECISIONS.md` — settled architecture. If the bug exists *because* an
   active decision was violated, the fix is "follow the decision", not
   "work around it".
3. `tdd-and-simplify.md` §3 (TDD evidence rules).

For frontend bugs with `frontend.enabled = true`, also read every path
listed in `$DESIGN_DOCS` and `$HARNESS_DIR/frontend.md`.

If the input matches `${ISSUE_PREFIX}-\d+` and an issue-tracker integration
is configured, fetch the issue — failures do not block.

---

## Bug Fix Mode

### Step 1 — Reproduce and red-light

Read the relevant code, error, or issue, and locate the layer
(`lib` / `api` / `stores` / `hooks` / `components`, or the project's
equivalent). Write a precise failing test: the test name describes the
bug behavior, not the fix; the input is the triggering condition; the
assertion is the expected correct behavior. Run `<TEST_CMD>` and confirm
FAIL, then post the red-light evidence (`tail -10`).

Key rule: if you cannot produce a failing test, your understanding of
the bug is incomplete — return to Step 1, do not jump ahead to a fix.

### Step 2 — Mechanical triggers and scale assessment

#### 2a. If any trigger fires, stop and recommend `/mo-plan`

| Trigger | Why |
|---------|-----|
| Input contains "overall / entire / unified / systemic / design system / token / refactor" | Refactor is not a bug |
| Root cause is in a design-system file (tokens, theme, base CSS) | Design-system level |
| Needs a new semantic token or CSS variable | Design-system level |
| Needs to change a DB schema, API contract, or response shape | Contract-level |
| Needs to add a metadata / flag / provenance field | Triggers Provenance check — must go through mo-plan |
| Affects 3+ files with no single test that can pinpoint it | Scope too large |
| The same pattern appears in 3+ places | Should be a refactor |
| The fix breaks existing tests | Behavioral contract change |
| Adds a new production abstraction or reusable module that changes ownership boundaries, is used by multiple call sites, or cannot be fully pinned by one failing regression test | Refactor / design work hiding inside a bug fix |

#### 2b. No trigger — assess normally

| Signal | Judgment | Action |
|--------|----------|--------|
| Single file with a clear logic error or boundary miss | Small fix | Go directly to Step 3 |
| Multiple files, or the same pattern in fewer than 3 places | Medium fix | Use the template below to discuss with the user, then Step 3 on approval |

**Medium-fix proposal template:**

```
Bug analysis:
- Root cause: [one sentence]
- Affected files: [list]
- Fix plan: 1. ... 2. ... 3. ...
- Risk: [does this touch adjacent features?]
- Size: [file count + line count]

Proceed?
```

### Step 3 — Fix and green-light

Make the minimal fix — no incidental refactors. Run `<TEST_CMD>` and
confirm both the new test and existing ones pass. Run
`<TYPECHECK_CMD> && <ARCH_CMD>`. Post the green-light evidence. For
frontend bugs with `frontend.enabled = true`, verify at
`${MOBILE_WIDTH}px` width after the fix.

### Step 4 — Regression check

#### 4a. Container/view separation hard check (only when configured)

If `$CONTAINER_CHECK` is set and the change touches files matching
`$CONTAINER_GLOB`, run:

```bash
<CONTAINER_CHECK>
```

If any container has lost its view import, move the JSX back into the
view file before proceeding.

#### 4b. Other regression checks

Run `git diff --stat` to confirm no unrelated drift. Confirm
`<ARCH_CMD>` still passes. If a store was touched, run the store-scoped
test suite (project convention).

### Step 5 — Commit and the Codex review loop

Commit as `fix(<scope>): description`. Valid scopes come from
`mo-config.json → commitScopes`.

Then run **`mo-codex review-code --base origin/${BASE_DEFAULT}`**. The
`mo-codex` skill prompt grades severity (P1 / P2 / NITS). The
follow-up protocol is mandatory, not optional:

1. **P1 and P2 findings are blocking.** Do not open a PR, do not push,
   do not declare the fix done while any P1 or P2 is open. NITS are
   the user's call.
2. For each blocking finding, produce an **independent follow-up
   commit** with the message shape
   `fix(<scope>): address review — <one-line summary>`. One commit per
   logical finding cluster; do not amend the primary fix commit so
   the review trail stays legible in `git log`.
3. After each follow-up commit or batch, **re-run
   `mo-codex review-code`** once. The loop only exits when Codex
   returns zero P1 / P2, or the user explicitly waives a specific
   finding (record the waiver rationale in the conversation).
4. If a Codex finding triggers a 2a mechanical trigger (e.g.
   "the real fix is in the design-system file we imported from"),
   stop the review loop and escalate to `/mo-plan` — do not silently
   grow the bug-fix PR into a refactor.

Ask the user whether to create a PR only after the loop has exited
cleanly. Never create one automatically.

---

## Review Fix Mode (multi-round)

### Step R1 — Pull the full PR state

Fetch the full PR state and recent comments via `gh` (status checks,
review decision, comment threads, head/base refs, mergeability).
Classify comments by freshness against the most recent `address review`
commit:

- Later than that commit = new and must be handled
- Earlier and unresolved = pending
- `resolved=true` = skip

Classify by type:

| Type | Action |
|------|--------|
| Bug (logic / race / data loss) | TDD red → green |
| Architecture (layering, coupling) | Check 2a triggers; may escalate to mo-plan |
| Test coverage | Add tests |
| Style (naming, comments) | Edit directly |
| CI failing | Locate via logs, run Bug Fix flow |

### Step R2 — Fix each comment

Bug and architecture comments walk the full Steps 1–4. Test coverage
means writing the missing tests. Style means editing directly. CI
failures are traced back through the failing job's logs.

Commit each comment independently:
`fix(<scope>): address review — [summary]`. Multi-round passes get a
`round N` tag.

Do not expand scope. Record adjacent issues for later, do not fix them
in this round.

### Step R3 — Loop and stop conditions

After each round, re-pull PR state (checks, review decision, comments).
Stop conditions — all must hold simultaneously: CI fully green, no
unresolved threads, and user confirmation. If any condition fails,
return to R1.

### Step R4 — Verify and push

Run `<TYPECHECK_CMD> && <TEST_CMD> && <ARCH_CMD>`. Run the Step 4a
container/view check if configured. Post the round summary:

```
Review Fix Summary (Round <N>)
| # | Comment | Type | Status | File | Commit |
|---|---------|------|--------|------|--------|
| 1 | xxx     | Bug  | ✅     | a.ts | abc123 |

CI: ✅ green / ❌ <job> failing
Review: ✅ APPROVED / ⏳ REVIEW_REQUIRED / ❌ CHANGES_REQUESTED
```

Ask the user whether to push — do not push automatically.

## What's next

| Situation | Skill |
|-----------|-------|
| 2a trigger → systemic problem | `/mo-plan` |
| Frontend fix, want lint | Project's design-lint skill |
| Fix complete, ready to ship | Project's ship workflow |
| Review round complete, ready to merge | Project's ship workflow |

## Self-revision hook

See `self-revision.md` for triggers and conservative principles. Drift
dimensions specific to this skill:

- **Bug Fix vs Review Fix routing** when input is ambiguous (PR #
  mentioned alongside an issue token, "fix this PR comment about the
  bug we shipped", etc.) — refine the trigger table at the top.
- **Mechanical trigger list** — when the same bug pattern recurs
  without a mechanical-trigger entry, add it.
- **Container/view regression check timing** — if regressions slip past
  the pre-commit check, move it earlier in the loop.
