---
name: mo-work
description: "Execute implementation plan following the project's TDD rules. Strict red-green TDD with evidence, resume from checkpoint, follows plan units, optionally checks frontend design docs and mobile viewport. Use when asked to 'implement', 'start work', 'mo-work', or after mo-plan is ready."
argument-hint: "[plan file path or feature description]"
---

# Mo Work

## Default flow

`/mo-work` is execution-after-plan: a plan exists at `docs/plans/<slug>.md`,
and this skill drives implementation → review → PR. For non-trivial plans
(≥3 Units), prefer dispatching to codex `/goal` mode rather than implementing
in Claude:

```bash
TASK="MAX-NNN-cdx"
T=$(pool-task.sh acquire-for --wait $TASK codex)
cat > /tmp/goal-prompt.txt <<EOF
/goal 实现 {plan-file-path}. Each Unit 内部 TDD（红→绿→commit）。每个 Unit 完成跑 pnpm typecheck && pnpm test && pnpm lint:arch，全绿才进下一个 Unit. 完成后输出 git log + diff stat 概要.
EOF
pool-task.sh send "$T" /tmp/goal-prompt.txt
pool-task.sh wait "$T" --timeout 3600   # /goal can run a long time
# Don't `done` yet — keep the pane bound to MAX-NNN-cdx so /mo-fix can reuse it.
```

For small plans (1-2 Units, mechanical edits), implement directly in Claude with inline TDD evidence — `/goal` overhead isn't worth it.

Why codex `/goal` for big plans: autonomous goal-driven mode — reads plan, executes U1→U2→U3 sequentially without pausing for "should I continue?" approval loops. The plan IS the contract.

After codex finishes, verify exit gate (whether or not the project has
`docs/ship-workflow.md` — these gates apply universally):
- N commits on branch (one per Unit)
- Triple gate green at HEAD
- `git status -sb` clean
- Branch still based on the plan's base SHA (no auto-rebase before review)

Skip dispatch and implement directly in Claude if:
- Plan doesn't exist (run `/mo-plan` first, or it's a one-line typo fix)
- Single trivial change (just edit + commit)

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

After `/simplify`, run review **as two parallel pool agents**, then
optionally a third Claude-subagent pass for high-stakes diffs. Single-agent
review misses too much; the policy is codex + opencode in parallel, merge
findings, route P0/P1 to `/mo-fix`. See [`/mo-plan` § Pool protocol](../mo-plan/SKILL.md#pool-protocol-canonical--referenced-by-other-mo--skills)
for the acquire / send / wait / done helpers.

```bash
WORKTREE="<absolute-worktree-path>"
cd "$WORKTREE" && git fetch origin "${BASE_DEFAULT}"

# Two reviewers in parallel — distinct task names so the dispatcher gives
# each kind its own pane and we can wait on them independently.
Tc=$(pool-task.sh acquire-for --wait MAX-NNN-cdx codex)
To=$(pool-task.sh acquire-for --wait MAX-NNN-opc opencode)

OUT_C=$(mktemp -t mo-work-review-codex-XXXXXX.md)
OUT_O=$(mktemp -t mo-work-review-opencode-XXXXXX.md)

# Same prompt body, distinct OUT files.
make_prompt() {
  local OUT="$1"
  cat <<PROMPT_EOF
Working directory: $WORKTREE
Use your shell tool with that absolute cwd. Run
  git diff origin/${BASE_DEFAULT}...HEAD
and do a pre-PR code review end to end.

Output format:
- Numbered findings. For each: file:line → concern → suggestion.
- Tag each [P0] (blocks landing) / [P1] (should fix before merge) / [P2] (nice-to-have).
- Final line, exactly: VERDICT: BLOCK | CHANGES REQUESTED | NITS | LGTM

When done, write your COMPLETE output (findings + VERDICT) to:
  $OUT
Then reply with EXACTLY one line: DONE $OUT
PROMPT_EOF
}
P_C=$(mktemp -t prompt-cdx-XXXXXX.txt); make_prompt "$OUT_C" > "$P_C"
P_O=$(mktemp -t prompt-opc-XXXXXX.txt); make_prompt "$OUT_O" > "$P_O"
pool-task.sh send "$Tc" "$P_C" && rm "$P_C"
pool-task.sh send "$To" "$P_O" && rm "$P_O"

# Wait both. They run concurrently — total wall time = max(codex, opencode),
# not sum. wait blocks per-pane; do them sequentially or background them.
pool-task.sh wait "$Tc" --timeout 900 &
pool-task.sh wait "$To" --timeout 900 &
wait
[[ -s "$OUT_C" ]] || tmux capture-pane -t "$Tc" -p -S -300 > "$OUT_C"
[[ -s "$OUT_O" ]] || tmux capture-pane -t "$To" -p -S -300 > "$OUT_O"
pool-task.sh done "$Tc"
pool-task.sh done "$To"

# Merge: both flag = high-confidence fix; one flag + valid = judge by P-tag;
# conflicting verdicts → adjudicate by plan + project conventions.
REVIEW_CODEX=$(cat "$OUT_C")
REVIEW_OPENCODE=$(cat "$OUT_O")
```

**Optional third pass — Claude subagent.** For high-stakes diffs (auth,
payments, migrations, public APIs, anything you'd hesitate to land at 5pm
Friday), follow the parallel pool review with `ce-code-review mode:report-only base:origin/${BASE_DEFAULT}`
as a Claude-subagent third pass. It reads the diff into its own context and
produces its own findings list, which you merge into the same P0/P1/P2
buckets. Skip for mechanical / low-risk diffs to save tokens.

P0/P1 findings (from any of the three) route to `/mo-fix`; P2 / NITS are
the user's call.

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

**Rebase onto base before asking.** Per the memory rule "Rebase onto
base before every PR", every PR path goes through:

```bash
cd "<worktree>"
git fetch origin "${BASE_DEFAULT}"
git rebase origin/"${BASE_DEFAULT}"          # or stash → reset --hard → pop if uncommitted
pnpm typecheck && pnpm test <focused> && pnpm lint:arch   # re-run AFTER rebase
```

If rebase produces conflicts: resolve, re-run the triple gate, do not
`--no-verify`. If the post-rebase test run reveals shape drift from a
sibling merge (e.g. an API helper changed shape on `dev`), treat it
as a new finding and route to `/mo-fix` — do not paper over.

Then ask the user whether to create a PR — do not create one
automatically. After the PR exists, display `Base: X ← Head: Y` and the
URL.

### Escalation voice — Decision Voice

Any time `/mo-work` pauses to ask the user — scope expansion beyond
the plan, merge conflict resolution, failing test that needs a
judgment call, subagent diff divergence, PR creation confirm, design
docs flag an unresolved UX choice — follow
`../../references/decision-voice.md`. Lead with your recommendation, frame
options as user outcomes (not "change `absolute` to `fixed`"), ≤1
blocking question with ≤2 options. For findings relayed from the
parallel pool review (codex + opencode), pre-digest before escalating:
apply uncontroversial fixes silently, surface only the subset where
reviewers diverge or where the user's preference genuinely shifts the
diff. See `/mo-fix` § review-fix follow-up for the pre-digest pattern.
Routine commit-level choices (commit message, which file to stage
first) are *not* Decision Voice — just proceed.

## What's next

| Situation | Skill |
|-----------|-------|
| Codex review found a bug / PR has review notes | `/mo-fix` (if installed) |
| Frontend implementation done | Project's design-lint skill |
| Ready to ship | Project's ship workflow |

## Self-revision hook

See `self-revision.md`. Drift dimensions specific to this skill:

- **TDD evidence format** — lock in any reformat the user demands more than once.
- **Frontend prerequisite read list** — when a UI regression traces back to
  "I didn't read X first", reinforce or expand the trigger.
- **`/simplify` timing in resume mode** — if `/simplify` keeps getting
  skipped after `- [x]` checkpoints, clarify the branch logic.
