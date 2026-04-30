---
name: mo-swarm
description: "Batch-orchestrate N independent issues through debug → summary → plan → implement → review → fix-review → PR. Tiles N tmux+codex workers in visible Terminal windows on a portrait display (headless fallback if absent), runs a web kanban dashboard on http://127.0.0.1:8866 backed by a single state.json, enforces a summary checkpoint (HARD STOP — user reviews before any code), runs dual-pipeline review (opencode + Claude correctness), and lands N PRs against a single base branch. Use when the user hands a batch of >=3 independent issues, a Linear cycle URL, or 'fix all my open bugs'. Triggers on 'swarm', 'batch fix', 'N issues', '一组 issue', '批量修', '并行修', '所有这些 bug'."
argument-hint: "[issue keys, comma-separated] | [Linear cycle URL] | ['all my open bugs']"
---

# Mo Swarm

> **Project overlay on the [batch orchestration protocol](../../../../../../Maxgent/maxgent-worktree/webapp/harness/multi-agent.md#96-batch-issue-ingestion-n-issues--n-prs).**
> The dispatch prompts live in
> [`harness/batch-orchestration-templates.md`](../../../../../../Maxgent/maxgent-worktree/webapp/harness/batch-orchestration-templates.md).
> The action boundaries are in
> [`harness/protocols.md`](../../../../../../Maxgent/maxgent-worktree/webapp/harness/protocols.md).
> The visualization layer (tiled Terminal panes + web kanban) is documented in
> [`harness/swarm-dashboard.md`](../../../../../../Maxgent/maxgent-worktree/webapp/harness/swarm-dashboard.md).
> This skill is the orchestrator's loop — it does not redefine the protocol.

## When to use

- ≥3 independent issues in a single ask (Linear cycle, regression sweep, locale audit)
- Issues are file-disjoint enough that workers won't conflict
- The user wants parallel progress, not strict serial pacing

When NOT to use:
- Single bug fix → use `/mo-fix` or `/mo-plan` + `/mo-work` directly
- Issues that share files → serialize via `/mo-fix` chain instead
- The user explicitly asked for serial pacing → respect it

## Config

Load `mo-config.json` like other mo-* skills:

```bash
for p in "${CLAUDE_PROJECT_DIR:-}/.claude/mo-config.json" \
         "$PWD/.claude/mo-config.json" \
         "$HOME/.claude/mo-config.json"; do
  [[ -f "$p" ]] && { MO_CONFIG="$p"; break; }
done

PLAN_STORE=$(jq -r '.planStore // empty' "${MO_CONFIG:-/dev/null}")
HARNESS_DIR=$(jq -r '.harnessDir // empty' "${MO_CONFIG:-/dev/null}")
WORKTREE_BASE=$(jq -r '.worktrees.base // empty' "${MO_CONFIG:-/dev/null}")
ISSUE_PREFIX=$(jq -r '.issueTracker.prefix // "MAX"' "${MO_CONFIG:-/dev/null}")
LINEAR_API_KEY="${LINEAR_API_KEY:-$(grep ^LINEAR_API_KEY ~/.claude/.env | cut -d= -f2-)}"
```

If `MO_CONFIG` is missing or `LINEAR_API_KEY` is empty, ask the user to fix
before proceeding. Do not silently fall back to defaults.

## Inputs

```
<argument> #$ARGUMENTS
```

Resolve `$ARGUMENTS` to a list of issue keys:
- Comma-separated keys (`MAX-633,MAX-631,MAX-560,...`) → use directly
- Linear cycle URL → query GraphQL for `cycle(id:...).issues.nodes[].identifier`
- `"all my open bugs"` / similar → query `issues(filter: { assignee: { isMe: { eq: true } }, state: { type: { neq: \"completed\" } }, labels: { name: { eq: \"Bug\" } } })`

If empty: ask "Which issues? Paste keys, a Linear cycle URL, or describe the
filter (e.g. 'my open bugs')."

## Phase 0 — Pre-flight (HARD GATE — fail loud, don't spawn)

Before creating any worktree:

1. **Pick base branch.** Prefer `release/<latest-date>` if it exists and
   passes step 3; fall back to `dev` only if release is unavailable. Reason:
   `dev` may carry in-progress refactors that break `pnpm install` or
   `agent-server` startup; release is shipped-stable.
2. **Fetch issue contexts** via Linear GraphQL. Build a map
   `{ ${ISSUE_KEY}: { title, description, labels, priority, url, assignee } }`.
3. **Verify base builds clean** in a scratch worktree:
   ```bash
   git worktree add /tmp/swarm-preflight ${BASE} && cd /tmp/swarm-preflight
   pnpm install --frozen-lockfile
   cd client/webapp && pnpm typecheck && pnpm test src/test-setup.ts
   # Optional: deploy-cli local dev if backend swarm
   ```
   If `pnpm install` or smoke-test fails, **report concrete failures and
   stop**. Do not spawn N workers against a broken base — every one will
   hit the same wall.
4. **Classify verification strategy per issue** (see
   [`multi-agent.md` §9.7](../../../../../../Maxgent/maxgent-worktree/webapp/harness/multi-agent.md#97-verification-strategy-classifier)).
   Mark each issue as `local-UI` / `local-logic` / `deploy-only`. Tell the
   user upfront which need post-deploy validation so they don't expect
   in-session smoke for those.
5. **Init state file + launch dashboard.** Single source of truth for
   every phase change. See [`harness/swarm-dashboard.md`](../../../../../../Maxgent/maxgent-worktree/webapp/harness/swarm-dashboard.md).
   ```bash
   SCRIPTS=/Users/cheng/Maxgent/maxgent-worktree/webapp/harness/swarm-scripts
   RUN_ID=$(date +%Y-%m-%d-%H%M)
   RUN_DIR="/Users/cheng/Maxgent/maxgent-worktree/swarm-runs/${RUN_ID}"
   "$SCRIPTS/state.sh" init "$RUN_DIR" --base "$BASE" --worktree-base "$WORKTREE_BASE"
   for KEY in "${KEYS[@]}"; do
     "$SCRIPTS/state.sh" register "$RUN_DIR" "$KEY" \
       title="${TITLES[$KEY]}" url="${URLS[$KEY]}" \
       verification="${VERIFICATION[$KEY]}"
   done
   "$SCRIPTS/assign-ports.sh" "$RUN_DIR"
   "$SCRIPTS/dashboard.sh" start "$RUN_DIR"   # opens http://127.0.0.1:8866
   ```
   The dashboard becomes the user's at-a-glance view across all phases.
   Every state mutation later in the swarm goes through `state.sh` — never
   edit `state.json` by hand.

Output a one-paragraph pre-flight report to the user before phase 1, plus
the dashboard URL.

## Phase 1 — Spawn (SERIAL worktree creation, tile or headless launch)

For each issue `${KEY}`:

```bash
# Slug from issue title — lowercase, dashed, ≤40 chars
SLUG=$(echo "$TITLE" | sed 's/[^a-zA-Z0-9 ]//g' | tr ' ' '-' | tr A-Z a-z | head -c 40)
DIR="${WORKTREE_BASE}/fix-${KEY}-${SLUG}"
BRANCH="fix/${KEY}-${SLUG}"

# SERIAL — git worktree add holds .git/config lock; parallel adds collide
git worktree add "$DIR" -b "$BRANCH" "$BASE"

# Record worktree + branch in state so the dashboard can show them
"$SCRIPTS/state.sh" set "$RUN_DIR" "$KEY" worktree "$DIR"
"$SCRIPTS/state.sh" set "$RUN_DIR" "$KEY" branch "$BRANCH"

# Write the worker's context file
mkdir -p "$DIR/docs/plans"
# ... write ${KEY}-context.md with Linear-fetched fields ...
"$SCRIPTS/state.sh" set "$RUN_DIR" "$KEY" artifacts.context "fix-${KEY}-${SLUG}/docs/plans/${KEY}-context.md"
```

Once all worktrees are created, launch sessions with **one call**:

```bash
"$SCRIPTS/tile-terminals.sh" "$RUN_DIR"
```

This:
- detects the portrait NSScreen and **re-calibrates** Terminal.app's
  y-offset (it changes with display arrangement; never reuse a stale value)
- tiles the first 9 issues in visible Terminal windows running
  `tmux new-session -As swarm-<key> codex`
- falls back to headless `tmux new-session -d` for issues 10+ or when no
  portrait display is present
- writes `tmuxSession` and `terminalWindowId` back into state.json so the
  dashboard's "⌨ window" / "tmux ↗" buttons can target each worker

The worker's context file (`${KEY}-context.md`) is the worker's source
of truth — workers should never query Linear themselves.

## Phase 2 — Dispatch debug-first

For each session, send the
[`debug-first` template](../../../../../../Maxgent/maxgent-worktree/webapp/harness/batch-orchestration-templates.md#1-debug-first)
verbatim, with `${ISSUE_KEY}` filled in. Use `tmux send-keys -l --` for
literal paste, then sleep 0.3, then send `Enter`.

```bash
tmux send-keys -t "$SESSION" -l -- "$DEBUG_FIRST_PROMPT"
sleep 0.3
tmux send-keys -t "$SESSION" Enter
"$SCRIPTS/state.sh" advance "$RUN_DIR" "$KEY" --to debug
```

**Pre-send safety check** (per [`HARNESS.md` §1.2](../../../../../../Maxgent/maxgent-worktree/webapp/harness/HARNESS.md)):
detect pane state. `Enter to select` menu → send Escape first; `❯` idle
→ safe; thinking >5min → interrupt and re-send simpler.

## Phase 3 — Wait for debug.md, then dispatch summary-only

Poll each worktree for `docs/plans/${KEY}-debug.md`. When present:

```bash
"$SCRIPTS/state.sh" set "$RUN_DIR" "$KEY" artifacts.debug "fix-${KEY}-${SLUG}/docs/plans/${KEY}-debug.md"
```

Then send the
[`summary-only` template](../../../../../../Maxgent/maxgent-worktree/webapp/harness/batch-orchestration-templates.md#2-summary-only).
This forces a HARD STOP — worker writes `${KEY}-summary.md` and idles.

When the summary lands, advance phase so the card moves into the
**Awaiting** lane (yellow highlight on the dashboard):

```bash
"$SCRIPTS/state.sh" set "$RUN_DIR" "$KEY" artifacts.summary "fix-${KEY}-${SLUG}/docs/plans/${KEY}-summary.md"
"$SCRIPTS/state.sh" advance "$RUN_DIR" "$KEY" --to awaiting-summary-confirm
```

## Phase 4 — HARD STOP, present summaries to user (the load-bearing checkpoint)

**This is non-negotiable. See
[`protocols.md` Stop and confirm](../../../../../../Maxgent/maxgent-worktree/webapp/harness/protocols.md#stop-and-confirm--visible-to-others-or-hard-to-reverse).**

When all `${KEY}-summary.md` files exist, present them to the user as a
consolidated review:

```
| Bug    | Root cause             | Fix direction          | Confidence | Verification |
|--------|------------------------|------------------------|------------|--------------|
| MAX-X  | ...file:line...        | ...                    | High       | local-UI     |
| MAX-Y  | ...partial — needs Z…  | ...                    | Medium     | deploy-only  |
| ...
```

Then ask: "Review the summaries above. For each bug, approve / override
scope / reject. I'll wait."

**Do NOT auto-advance even if every issue is High confidence + clean
plan.** The user may redirect scope (e.g., "MAX-631: just hide the button
on mobile — don't add a renderer") or close one as won't-fix. This is the
single most valuable user touchpoint in the swarm; skipping it has
re-litigation cost ~10× the pause cost.

## Phase 5 — Per-issue plan + implement (after user approves each)

For each approved issue:

```bash
"$SCRIPTS/state.sh" advance "$RUN_DIR" "$KEY" --to plan
```

Send the [`plan-after-summary` template](../../../../../../Maxgent/maxgent-worktree/webapp/harness/batch-orchestration-templates.md#3-plan-after-summary-approval).
If user gave a scope override, fill it into `${OPTIONAL_USER_OVERRIDES}`.

Wait for `${KEY}-plan.md`. Record artifact, advance, then send
[`implement` template](../../../../../../Maxgent/maxgent-worktree/webapp/harness/batch-orchestration-templates.md#4-implement):

```bash
"$SCRIPTS/state.sh" set "$RUN_DIR" "$KEY" artifacts.plan "fix-${KEY}-${SLUG}/docs/plans/${KEY}-plan.md"
"$SCRIPTS/state.sh" advance "$RUN_DIR" "$KEY" --to implement
```

Worker writes code following TDD with paste-it-RED → paste-it-GREEN
evidence.

User-rejected issues:

```bash
"$SCRIPTS/state.sh" advance "$RUN_DIR" "$KEY" --to rejected
tmux kill-session -t "swarm-${KEY,,}" 2>/dev/null || true
git worktree remove "$DIR" --force
```

## Phase 6 — Parallel review (dual-pipeline)

When all approved workers report triple-gate green and idle:

```bash
"$SCRIPTS/state.sh" advance "$RUN_DIR" "$KEY" --to review
```

Then dispatch **both reviewers in parallel** for every PR:

```bash
# Background: opencode (one per worktree)
opencode run --dir "$DIR" --dangerously-skip-permissions "$REVIEW_PROMPT" \
  > /tmp/swarm-reviews/${KEY}-opencode.md 2>&1 &

# Foreground: Claude correctness (Agent tool, send all in single message
# with multiple tool_use blocks for true parallelism)
Agent({
  subagent_type: "compound-engineering:ce-correctness-reviewer",
  prompt: REVIEW_PROMPT,  // template 5 from batch-orchestration-templates.md
})
```

Reason for dual: opencode catches diff-mechanical issues, Claude catches
plan-vs-implementation gaps + locale-quality + cross-cutting memory rules.
Single-pipeline missed real CRITICAL findings on 3 of 7 PRs in the
2026-04-29 batch.

Send the [`review` template](../../../../../../Maxgent/maxgent-worktree/webapp/harness/batch-orchestration-templates.md#5-review)
verbatim to both — the prompt itself enumerates every dimension to check.

## Phase 7 — Merge findings, dispatch fix-review

For each PR:

1. Merge findings from both reviewers (dedupe by file:line, keep more
   specific citation when overlap).
2. Apply auto-decision threshold per
   [`multi-agent.md` §9.6](../../../../../../Maxgent/maxgent-worktree/webapp/harness/multi-agent.md#96-batch-issue-ingestion-n-issues--n-prs):
   - **Ship + High** + 0 critical → advance to phase 8
   - **Ship + Medium** + 0 critical → one-line ping, advance after ack
   - **Fix** + ≥1 should-fix → send
     [`fix-review` template](../../../../../../Maxgent/maxgent-worktree/webapp/harness/batch-orchestration-templates.md#6-fix-review),
     re-run review (max 2 rounds before pinging user)
   - **Block** + ≥1 critical → escalate to user with concrete decision ask

3. Reviewers MUST cite file:line. If a finding doesn't, kick it back as
   "needs file:line" instead of forwarding to fix-review (vague feedback
   wastes worker rounds).

State transitions for this phase:

```bash
# Reviewer findings filed:
"$SCRIPTS/state.sh" set "$RUN_DIR" "$KEY" artifacts.review "fix-${KEY}-${SLUG}/docs/plans/${KEY}-review.md"

# Auto-decision result:
case "$decision" in
  ship)        "$SCRIPTS/state.sh" advance "$RUN_DIR" "$KEY" --to pr ;;
  fix)         "$SCRIPTS/state.sh" advance "$RUN_DIR" "$KEY" --to fix-review ;;
  block)       "$SCRIPTS/state.sh" advance "$RUN_DIR" "$KEY" --to awaiting-review-confirm ;;
esac
```

## Phase 8 — Branch handoff to PR (orchestrator runs git, not the worker)

Per [`batch-orchestration-templates.md` "Branch handoff to PR"](../../../../../../Maxgent/maxgent-worktree/webapp/harness/batch-orchestration-templates.md#branch-handoff-to-pr-orchestrator-runs-this-not-the-worker):

```bash
cd "$DIR"
git stash push -u -m "wip ${KEY}"
git fetch origin "$BASE"
git reset --hard "origin/$BASE"   # base may have moved during the swarm
git stash pop                      # auto-merge if no conflicts
cd client/webapp && pnpm install --frozen-lockfile
pnpm typecheck && pnpm test <focused>  # CATCH stale code shapes from sibling merges
git add <explicit files>           # never `git add -A`
git commit -m "..."
git push -u origin "$BRANCH"
gh pr create --base "$BASE" --title "..." --body "..."
```

**Pre-commit hook gotcha** (memory rule): if a hook auto-modifies a file
and the auto-fix conflicts with staged changes, it silently rolls back
("Stashed changes conflicted with hook auto-fixes... Rolling back fixes...").
Diagnosis: re-run `git commit` and grep stdout for `Failed`. Fix: stage
the auto-fix output, retry. Never `--no-verify`.

**PR creation requires explicit user confirmation** per
[`protocols.md` Hard rules](../../../../../../Maxgent/maxgent-worktree/webapp/harness/protocols.md#hard-rules--never-no-override-without-explicit-user-instruction).
After all PRs are ready, present a one-line summary per PR ("MAX-X: 2 files
/ 88+/8- / High confidence / OK to open?") and wait for batch approval
("ship them all" / "ship 1, 3, 5 / hold the others").

After PR is created and CI is running, record it in state:

```bash
"$SCRIPTS/state.sh" pr "$RUN_DIR" "$KEY" --url "$PR_URL" --number "$PR_NUMBER"
"$SCRIPTS/state.sh" smoke "$RUN_DIR" "$KEY" --result "${SMOKE_RESULT:-pending}"
"$SCRIPTS/state.sh" advance "$RUN_DIR" "$KEY" --to pr
```

Cards now show on the **🚀 PR Open** lane with the PR number as a clickable
link.

## Phase 9 — Cleanup

After all PRs are open and CI is green-or-pending:

- For each merged PR:
  ```bash
  "$SCRIPTS/state.sh" advance "$RUN_DIR" "$KEY" --to done
  tmux kill-session -t "swarm-${KEY,,}" 2>/dev/null || true
  git worktree remove "$DIR" && git branch -D "$BRANCH"   # or /mo-clean
  ```
- For closed-without-merge: same cleanup, advance to `rejected`.
- For open PRs: leave the worktree in place for review-fix iterations.
- **Don't kill the dashboard server** — leave it running so the user can
  reload the page later to check CI / merge state. Stop manually with:
  ```bash
  "$SCRIPTS/dashboard.sh" stop "$RUN_DIR"
  ```
  (Or leave it; `swarm-runs/<runId>/` is a permanent record.)

## Reference cards

| Topic | File |
|---|---|
| Dispatch templates (debug-first / summary-only / plan / implement / review / fix-review) | [`batch-orchestration-templates.md`](../../../../../../Maxgent/maxgent-worktree/webapp/harness/batch-orchestration-templates.md) |
| Action boundaries (stop-and-confirm + hard rules) | [`protocols.md`](../../../../../../Maxgent/maxgent-worktree/webapp/harness/protocols.md) |
| Auto-decision thresholds + verification classifier + rotation worktree | [`multi-agent.md` §9.6–9.8](../../../../../../Maxgent/maxgent-worktree/webapp/harness/multi-agent.md#96-batch-issue-ingestion-n-issues--n-prs) |
| Plan structure / Quality Gate | [`plan-quality-gate.md`](../../../../../../Maxgent/maxgent-worktree/webapp/harness/plan-quality-gate.md) |
| TDD evidence rules | [`tdd-and-simplify.md`](../../../../../../Maxgent/maxgent-worktree/webapp/harness/tdd-and-simplify.md) |
| Visualization layer (state schema, kanban, calibration) | [`swarm-dashboard.md`](../../../../../../Maxgent/maxgent-worktree/webapp/harness/swarm-dashboard.md) |
| Scripts: `state.sh` / `tile-terminals.sh` / `dashboard.sh` / `assign-ports.sh` | [`swarm-scripts/`](../../../../../../Maxgent/maxgent-worktree/webapp/harness/swarm-scripts/) |

## Anti-patterns (observed in 2026-04-29 batch)

1. **Spawning N workers before pre-flight catches a broken base.** Every
   worker hits the same `pnpm install` / `agent-server` failure; rebuild
   pre-flight before retrying.
2. **Skipping the summary checkpoint** because "the plan looks fine" or
   "auto-decision says High". The summary is for SCOPE redirection, not
   correctness validation. User had a 10× scope cut on MAX-631 here.
3. **Letting workers `git stash → reset → pop` rebase against a moving
   base without re-running tests.** A sibling PR merging while you rebase
   introduces stale code shapes that pass local but fail CI (MAX-623's
   `buildApiError` format mismatch was caught only at CI).
4. **Single-pipeline review.** opencode alone or Claude alone misses ~30%
   of CRITICAL findings. Dual-pipeline non-negotiable.
5. **25+ user check-ins on small decisions** ("继续 / 测一下 / 下一个").
   Use auto-decision thresholds at review checkpoints; only ping for
   summary checkpoint and Block findings.
6. **Cross-CLI prompt with `/mo-*` references.** Codex / opencode see
   `/mo-debug` as literal text and report "Unrecognized command". Use
   templates from `batch-orchestration-templates.md` which are inlined.
7. **`tmux send-keys` without pane-state check.** If the session is in a
   menu or thinking, the keystrokes go to the wrong context. See HARNESS
   §1.2 pane-state table.
8. **Editing `state.json` by hand.** Always go through `state.sh advance` /
   `state.sh set` — they update `state.md` atomically and bump
   `lastUpdate` so the dashboard's polling diff fires. Hand edits leave
   the kanban stale.
9. **Re-using a stale `yOffset`.** Terminal.app's portrait quirk depends
   on display arrangement. `tile-terminals.sh` re-calibrates every run.
   Don't shortcut by reading `state.calibration.yOffset` from a previous
   run.

## Output

End the swarm with a status table:

```
| Issue   | PR        | Base     | Status            | Verification |
|---------|-----------|----------|-------------------|--------------|
| MAX-X   | #1234     | release/ | Open, CI green    | local OK     |
| MAX-Y   | #1235     | release/ | Open, CI pending  | post-deploy  |
| MAX-Z   | (closed)  | -        | User declined     | -            |
```

Plus a one-paragraph "what to do next" — typically "wait for CI on the
N open PRs, then merge in your preferred order. Z (deploy-only validations)
require post-deploy smoke per the verification classifier."

Always include the dashboard URL in the final summary so the user can
keep tabs on CI / merge state without opening new tools:
`http://127.0.0.1:8866/` (running while the swarm is active).
