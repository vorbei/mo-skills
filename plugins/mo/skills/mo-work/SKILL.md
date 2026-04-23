---
name: mo-work
description: "Execute implementation plan following the project's TDD rules. Strict red-green TDD with evidence, resume from checkpoint, follows plan units, optionally checks frontend design docs and mobile viewport. Use when asked to 'implement', 'start work', 'mo-work', or after mo-plan is ready."
argument-hint: "[plan file path or feature description]"
---

# Mo Work

> **Reference, not replacement.** This skill is a *project overlay* on `ce:work`.

## Config

Load `mo-config.json` (first match wins):

```bash
for p in "${CLAUDE_PROJECT_DIR:-}/.claude/mo-config.json" \
         "$PWD/.claude/mo-config.json" \
         "$HOME/.claude/mo-config.json"; do
  [[ -f "$p" ]] && { MO_CONFIG="$p"; break; }
done

PLAN_STORE=$(jq -r '.planStore // empty' "${MO_CONFIG:-/dev/null}")
HARNESS_DIR=$(jq -r '.harnessDir // empty' "${MO_CONFIG:-/dev/null}")
TEST_CMD=$(jq -r '.commands.test // "pnpm test"' "${MO_CONFIG:-/dev/null}")
TYPECHECK_CMD=$(jq -r '.commands.typecheck // "pnpm typecheck"' "${MO_CONFIG:-/dev/null}")
ARCH_CMD=$(jq -r '.commands.archLint // ""' "${MO_CONFIG:-/dev/null}")
BASE_DEFAULT=$(jq -r '.base.default // "main"' "${MO_CONFIG:-/dev/null}")
FRONTEND_ENABLED=$(jq -r '.frontend.enabled // false' "${MO_CONFIG:-/dev/null}")
MOBILE_WIDTH=$(jq -r '.frontend.mobileWidth // 375' "${MO_CONFIG:-/dev/null}")
CONTAINER_CHECK=$(jq -r '.frontend.containerCheckCommand // empty' "${MO_CONFIG:-/dev/null}")
CONTAINER_GLOB=$(jq -r '.frontend.containerGlob // empty' "${MO_CONFIG:-/dev/null}")
# Design doc paths, newline-separated
DESIGN_DOCS=$(jq -r '.frontend.designDocs[]? // empty' "${MO_CONFIG:-/dev/null}")
# Commit scopes, space-separated for listing in commit-format section
COMMIT_SCOPES=$(jq -r '.commitScopes[]? // empty' "${MO_CONFIG:-/dev/null}" | tr '\n' ' ')
```

**Language policy:** plans, code, evidence blocks, commit messages →
`language.artifacts`. Conversational replies during implementation →
`language.conversation`.

## Input

<input_document> #$ARGUMENTS </input_document>

If empty, search `$PLAN_STORE` for the most recent active plan and confirm
with the user.

## Project overlays

### Before starting

Read **authority files first** from `$HARNESS_DIR` (or the plugin's
`templates/harness/` if `harnessDir` is unset), in this order:

1. `protocols.md` — action boundaries. Any unit that crosses a boundary
   must surface the confirmation in the conversation, not silently proceed.
2. `DECISIONS.md` — settled architecture decisions. If implementation
   suggests deviating from an active decision, stop and surface it; do not
   silently work around the decision.
3. `plan-quality-gate.md` §2.3, `tdd-and-simplify.md` §3,
   and `frontend.md` §7 (last one only if `frontend.enabled`).

If the plan carries `issue: <prefix>-NNN` and an issue tracker is
configured, call it — failures do not block.

### Branch check

Confirm the correct worktree and feature branch. Resume rule: every
previously completed (`- [x]`) unit must still be present in
`git diff <base>...HEAD` — if one has been lost, stop and alert the user.

### TDD evidence (hard requirement)

Feature-bearing units must produce a TDD evidence block in the
conversation. Red and green are **two independent executions** — the same
run shown twice does not count.

````
### TDD Evidence: Unit <N> — <goal>

**Red (before impl):**
```
$ <TEST_CMD> -- <test file> 2>&1 | tail -10
<paste real FAIL output>
```

**Green (after impl):**
```
$ <TEST_CMD> -- <test file> 2>&1 | tail -10
<paste real PASS output>
```

**Typecheck + Arch:** `$ <TYPECHECK_CMD> && <ARCH_CMD>` → OK
````

Pure-config, pure-style, and scaffolding units may skip TDD but must
state `Skipping TDD: <reason>`.

### Frontend units (only when `frontend.enabled`)

For every frontend unit:

1. Read every path in `$DESIGN_DOCS` before implementing.
2. Verify at `${MOBILE_WIDTH}px` width after implementing.
3. Follow `frontend.md` §7.

### /simplify unit

When the loop reaches the `/simplify` unit, run
`<TEST_CMD> && <ARCH_CMD>` both before and after — both must be fully
green. If `/simplify` is in the plan and was skipped, run it now before
review.

### Review

After the loop reaches `/simplify`, run `mo-codex review-code` against
`origin/${BASE_DEFAULT}`. The `mo-codex` skill grades severity per the
project's own decision / protocol docs; high-severity findings route to
`/mo-fix`, lower severity is the user's call.

### Commit conventions

Commit autonomously once a logical unit is complete and all tests are
green. Format: `<type>(<scope>): description`. Stage only the relevant
files.

Valid scopes (from `mo-config.json → commitScopes`): `${COMMIT_SCOPES:-any}`.

### Container/view separation (frontend, only when configured)

When the change touches files matching `$CONTAINER_GLOB`, run
`$CONTAINER_CHECK` before committing. If any container has lost its view
import, move the JSX back into the view file before proceeding.

### PR creation

Ask the user whether to create a PR — do not create one automatically.
After the PR exists, display `Base: X ← Head: Y` and the URL.

### Escalation voice — Decision Voice

Any time `/mo-work` pauses to ask the user — scope expansion beyond
the plan, merge conflict resolution, failing test that needs a
judgment call, subagent diff divergence, PR creation confirm, design
docs flag an unresolved UX choice — follow
`../_shared/decision-voice.md`. Lead with your recommendation, frame
options as user outcomes (not "change `absolute` to `fixed`"), ≤1
blocking question with ≤2 options. For codex review findings relayed
from `mo-codex review-code`, apply the pre-digest rule from
`/mo-fix` Step 5.0. Routine commit-level choices (commit message,
which file to stage first) are *not* Decision Voice — just proceed.

## What's next

| Situation | Skill |
|-----------|-------|
| `mo-codex review-code` found a bug / PR has review notes | `/mo-fix` (if installed) |
| Frontend implementation done | Project's design-lint skill |
| Ready to ship | Project's ship workflow |

## Self-revision hook

See `self-revision.md`. Drift dimensions specific to this skill:

- **TDD evidence format** — lock in any reformat the user demands more than once.
- **Frontend prerequisite read list** — when a UI regression traces back to
  "I didn't read X first", reinforce or expand the trigger.
- **`/simplify` timing in resume mode** — if `/simplify` keeps getting
  skipped after `- [x]` checkpoints, clarify the branch logic.
