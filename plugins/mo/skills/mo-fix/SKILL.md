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

**Medium-fix proposal template — Decision Voice** (see
`../_shared/decision-voice.md`):

```
[One-sentence user-visible symptom — what the user actually experiences]

我倾向 <one-sentence fix phrased as user outcome>, 理由是 <why>.

如果你更想 <one-sentence alternative, also as user outcome>, 说一声.

(Touches <N> files · 风险: <one line, e.g. "同一组件的两个其他用法
不受影响" / "会顺带改动 onboarding 路径">)
```

Do **not** lead the ask with "Root cause / Affected files / Fix plan /
Size" bullets — those are internal reasoning. The user-facing ask is
one short stanza: symptom → recommendation → alternative → one-line
risk. If the user wants the file list or implementation detail, they
will ask; offer it in a follow-up turn, not in the ask itself.

If the choice is genuinely single-path (no credible alternative),
skip the "如果你更想 …" line and just state the symptom, the fix, and
the risk, then proceed to Step 3 unless the user objects.

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

### Step 5 — Commit and the review loop

Commit as `fix(<scope>): description`. Valid scopes come from
`mo-config.json → commitScopes`.

**Default reviewer:** `ce-code-review mode:headless
base:origin/${BASE_DEFAULT}`. It dispatches persona subagents in
parallel (correctness / testing / maintainability / security / perf /
reliability / contract / migrations / stack-specific), returns a
structured finding envelope, and can auto-apply `safe_auto` fixes.
Subagent contexts are isolated, so the cost to the main conversation
is bounded to the merged envelope.

**Cross-model gate (opt-in):** `mo-codex review-code --base
origin/${BASE_DEFAULT} [--plan <plan>] [--prior-findings
.mo-codex-prior.md]` runs Codex/GPT as an independent second opinion.
**Do not default to mo-codex** — see
`feedback_mo_codex_slow.md` in per-project memory: it is slow and
frequently blocks in practice. Use it only when the change warrants a
cross-model sanity check (security, migration, contract-breaking
changes) or when the user explicitly asks. For plan-level review,
`mo-codex review-plan` stays the right tool — ce has no equivalent.

Follow-up protocol (applies to whichever reviewer ran):

0. **Pre-digest before escalating.** Do not forward the raw finding
   list to the user. For each finding, decide what you would do if
   the user delegated to you: apply silently (uncontroversial
   corrections), reject silently (items you disagree with, noted in
   the conversation), or **escalate** (only findings where the
   user's preference genuinely changes the fix). Escalations follow
   `../_shared/decision-voice.md` — lead with "我倾向 X, 理由是 Y",
   one question at a time, frame as user outcome not mechanism.

1. **P0 and P1 findings are blocking** (ce-code-review severity) or
   **P1 and P2 are blocking** (mo-codex severity — the scales are
   offset by one). Do not open a PR, do not push, do not declare the
   fix done while any blocking finding is open. Lower-severity items
   are the user's call.
2. For each blocking finding, produce an **independent follow-up
   commit** with the message shape
   `fix(<scope>): address review — <one-line summary>`. One commit per
   logical finding cluster; do not amend the primary fix commit so
   the review trail stays legible in `git log`.
3. After each follow-up commit or batch, **re-run the same reviewer**
   once. For mo-codex, pass `--since <last-reviewed-sha>` and
   `--prior-findings .mo-codex-prior.md` so it doesn't re-litigate
   round-1 findings. The loop exits when the reviewer returns zero
   blocking items, or the user explicitly waives a specific finding
   (record the waiver rationale in the conversation).
4. If a finding triggers a 2a mechanical trigger (e.g. "the real fix
   is in the design-system file we imported from"), stop the review
   loop and escalate to `/mo-plan` — do not silently grow the bug-fix
   PR into a refactor.

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
