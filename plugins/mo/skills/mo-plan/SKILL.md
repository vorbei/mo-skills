---
name: mo-plan
description: "Create implementation plan following the project's harness rules. Enforces efficiency rules by depth, Quality Gate checks with on-disk evidence, Provenance granularity check, and strict frontmatter/filename schema. Use when asked to 'plan this', 'make a plan', 'mo-plan', or before implementing a feature/fix."
argument-hint: "[feature description or requirements doc path]"
---

# Mo Plan

## Default flow — parallel codex + opencode plan dispatch

`/mo-plan` orchestrates two pool agents writing plans in parallel, then
synthesizes them. You do NOT write the plan yourself unless the pool is
unavailable (fallback below).

1. **Pre-flight** — verify env, SSO, cwd, presence of `docs/plans/_planning-guidelines.md`. If `docs/ship-workflow.md` exists, also walk its Phase 1 pre-flight; absence is fine — these gates apply universally.
2. **Dispatch parallel — two phases per agent.** Plan mode in both codex and opencode is genuinely **read-only** — it blocks the agent's file-write tool, which means the OUT-contract can't be honored while in plan mode. So the dispatch runs in two phases per agent:

   **Phase 1: discuss the plan in plan mode** (no file writes, agent stays in planning posture)
   **Phase 2: write the plan to OUT in build mode** (mode flipped off, agent's just transcribing what it already worked out)

   Order is load-bearing throughout: `new-session` → `plan-mode on` → `send phase-1` → `wait` → `plan-mode off` → `send phase-2` → `wait` → read OUT. Switching plan mode after sending is too late; opencode in particular will auto-explore on whatever input the welcome placeholder provides if it wakes up in build mode.

   ```bash
   Tc=$(pool-task.sh acquire-for --wait MAX-NNN-cdx codex)
   To=$(pool-task.sh acquire-for --wait MAX-NNN-opc opencode)
   pool-task.sh new-session "$Tc"   # /new + Enter ×2 (codex)
   pool-task.sh new-session "$To"   # Ctrl-X N (opencode)
   pool-task.sh plan-mode "$Tc"     # MUST happen before phase-1 send
   pool-task.sh plan-mode "$To"

   # Phase 1: discuss/think (plan mode, no file writes possible).
   # Same body for both agents; instruct each to end with READY-TO-WRITE so wait sees a settle.
   OUT_C=$(mktemp -t plan-codex-MAX-NNN-XXXXXX.md)
   OUT_O=$(mktemp -t plan-opencode-MAX-NNN-XXXXXX.md)
   PHASE1=$(mktemp -t plan-phase1-XXXXXX.txt)
   cat > "$PHASE1" <<EOF
   You are in plan mode (read-only). Read $LINEAR_URL and the planning
   guidelines at docs/plans/_planning-guidelines.md, then sketch the
   plan in this chat. Cover: Open Questions / Risks / Architecture
   direction / Edge Case coverage / Acceptance Scenarios / Unit list.
   Do NOT write any file. End your message with the literal line:
   READY-TO-WRITE
   EOF
   pool-task.sh send "$Tc" "$PHASE1"
   pool-task.sh send "$To" "$PHASE1"
   pool-task.sh wait "$Tc" --timeout 600 &
   pool-task.sh wait "$To" --timeout 600 &
   wait; rm "$PHASE1"

   # Phase 2: transcribe to OUT (plan mode OFF so file-write works).
   pool-task.sh plan-mode "$Tc" off
   pool-task.sh plan-mode "$To" off
   make_phase2() {
     local OUT="$1"
     cat <<EOF
   Now write the plan you just discussed to:
     $OUT
   Use the planning-guidelines structure verbatim. Then reply with
   exactly one line: DONE $OUT
   EOF
   }
   P_C=$(mktemp -t plan-phase2-cdx-XXXXXX.txt); make_phase2 "$OUT_C" > "$P_C"
   P_O=$(mktemp -t plan-phase2-opc-XXXXXX.txt); make_phase2 "$OUT_O" > "$P_O"
   pool-task.sh send "$Tc" "$P_C" && rm "$P_C"
   pool-task.sh send "$To" "$P_O" && rm "$P_O"
   pool-task.sh wait "$Tc" --timeout 300 &
   pool-task.sh wait "$To" --timeout 300 &
   wait
   [[ -s "$OUT_C" ]] || tmux capture-pane -t "$Tc" -p -S -300 > "$OUT_C"
   [[ -s "$OUT_O" ]] || tmux capture-pane -t "$To" -p -S -300 > "$OUT_O"
   ```

   Codex flips its model badge to "Plan mode"; opencode swaps its footer from "Build ·" to "Plan ·". The fresh-session step is mandatory — both TUIs auto-resume their last on-disk conversation, so a pane that "looks idle" on dashboard may already be inside someone else's chat.

   **Escape hatch**: if a pane goes off-script after send (auto-explores random files, answers a different question, "thinks" about something unrelated), the TUI is contaminated. Don't try to recover with another prompt — `pool-launch.sh respawn opencode` (or `respawn codex`) to wipe that entire tier, then re-acquire and re-dispatch.
3. **Synthesize** — read `$OUT_C` and `$OUT_O`; produce one canonical `{date}-{NNN}-{type}-MAX-NNN-{slug}-plan.md` taking codex's structure (Open Questions / Risks / Architecture direction) + opencode's specificity (Edge Case coverage / AS values).
4. **Walk Edge Case Checklist** explicitly — each row in `_planning-guidelines.md` § Edge Case Checklist must be addressed (✅ or N/A with reason).
5. **Codex plan review** (see § Codex plan review below) — independent review pass on the synthesized plan, gates `/mo-work` start.

Skip the parallel dispatch and write a single plan personally if:
- One-line typo fix (no plan needed at all — go straight to commit)
- Brainstorm/research (use `docs/brainstorms/` not `docs/plans/`)
- Pool unavailable (no warm pool, both kinds saturated past `--wait` timeout) — fall back to single-author `ce:plan` flow inline

> **Reference, not replacement.** This skill is a *project overlay* on `ce:plan`.
> Each section either (a) adds a project-specific constraint ce:plan does not
> have, (b) overrides a ce:plan default with a one-line justification, or
> (c) keeps a concept locally because ce:plan does not own it.

## Config

Load `mo-config.json` (first match wins):

```bash
for p in "${CLAUDE_PROJECT_DIR:-}/.claude/mo-config.json" \
         "$PWD/.claude/mo-config.json" \
         "$HOME/.claude/mo-config.json"; do
  [[ -f "$p" ]] && { MO_CONFIG="$p"; break; }
done

# Required
PLAN_STORE=$(jq -r '.planStore // empty' "${MO_CONFIG:-/dev/null}")
# Optional — fall back to the plugin's templates/harness/ if absent
HARNESS_DIR=$(jq -r '.harnessDir // empty' "${MO_CONFIG:-/dev/null}")
ISSUE_PREFIX=$(jq -r '.issueTracker.prefix // empty' "${MO_CONFIG:-/dev/null}")
BASE_DEFAULT=$(jq -r '.base.default // "main"' "${MO_CONFIG:-/dev/null}")
FRONTEND_ENABLED=$(jq -r '.frontend.enabled // false' "${MO_CONFIG:-/dev/null}")
LANG_CONV=$(jq -r '.language.conversation // "English"' "${MO_CONFIG:-/dev/null}")
LANG_ART=$(jq -r '.language.artifacts // "English"' "${MO_CONFIG:-/dev/null}")
```

If `MO_CONFIG` is missing: ask the user to run `mo-skills init-config` or
point them at `config/mo-config.example.json`. Do not proceed with hardcoded
defaults silently.

**Language policy:** plans, audit tables, evidence blocks, commit messages →
`$LANG_ART`. Conversational replies to the user → `$LANG_CONV`.

## Feature Description

<feature_description> #$ARGUMENTS </feature_description>

If empty, ask: "What should I plan?"

### Upstream routing to `/ce-brainstorm`

If the input describes **what to build** at the product level (primary
user / desired outcome / flow shape still unresolved) rather than
**how to build** a known thing, stop before the ce:plan workflow and
recommend `/ce-brainstorm` first — planning a shape that hasn't been
decided is exactly what produces the "too technical" escalation loop
later. ce:plan also routes here downstream, but catching it upstream
saves the research pass. Signals:

- Input is a question about direction ("should we do X or Y?",
  "what's the right shape for …")
- No clear primary actor or single-sentence user outcome
- Scope is "an area" ("the dock", "the chat experience") rather than
  a specific behavior change

When in doubt, ask the user once — Decision Voice style — whether they
want brainstorm or plan: "看起来形态还没定，我倾向先 `/ce-brainstorm`
把用户路径对齐再回来。要直接进规划吗？"

## Project overlays

### Before starting

Read **authority files first** from `$HARNESS_DIR` (or the plugin's
`templates/harness/` if `harnessDir` is unset), in this order:

1. `DECISIONS.md` — settled architecture decisions. Do not propose anything
   that contradicts an active decision; if the plan must, it must explicitly
   justify overturning the decision.
2. `protocols.md` — action boundaries (free / stop-and-confirm / hard rules).
   Plan units that cross a boundary must mark it.
3. `plan-quality-gate.md` — required fields, Quality Gate checklist, depth
   defaults.

If `ISSUE_PREFIX` is set and `$ARGUMENTS` matches `${ISSUE_PREFIX}-\d+`, call
the project's issue-tracker tool (e.g. `linear-cli`) to fetch the issue.
Failures do not block.

### Filename and frontmatter

Plan files MUST live at `${PLAN_STORE}/YYYY-MM-DD-NNN-<type>-<slug>-plan.md` —
this absolute path regardless of which worktree is currently active. One
canonical plan store, shared across worktrees. Must be gitignored.

```yaml
---
issue: {ISSUE_PREFIX}-NNN   # null if none
type: fix                   # fix | feat | refactor
depth: lightweight          # lightweight | standard | deep
status: draft               # draft | active | completed
created: YYYY-MM-DD
branch: fix/{ISSUE_PREFIX}-NNN-slug
base: {BASE_DEFAULT}        # normally default, main only for emergencies
worktree: null              # absolute path, filled in after worktree creation (standard/deep only)
---
```

### Mandatory units

Every plan must end with these two units in order:

1. **`/simplify`** — run `<commands.test> && <commands.archLint>` before and
   after; both must be green. See `tdd-and-simplify.md` §4.
2. **Plan review** — parallel codex+opencode read-only plan review via
   the pool (see "Codex plan review" section below).

### Worktree creation (standard / deep plans)

For `depth: standard | deep`, create the per-task worktree **at plan time**,
before the Codex review, so review can anchor against real branch code and
`/mo-work` starts editing without a separate setup. Branch off `base:` from
the project's primary repo (`project.primaryRepo` in config). Record the
absolute path back into the plan as `worktree: <abs-path>`. **Stop and ask
the user** if the branch or directory already exists — never reuse or
overwrite without confirmation.

`depth: lightweight` skips this — those go through `/mo-fix` or edit in an
existing worktree.

### TDD execution note

Every feature-bearing unit must carry `Execution note: test-first` and
include the test file path in **Files**.

### Provenance Granularity Check

When the plan introduces any new metadata, flag, marker, or annotation
field, add this section to the plan file (delete entirely when not
triggered — do not write "N/A"):

```markdown
## Provenance Granularity Check

- **Transformation unit:** [per-string-leaf / per-message block / per-file …]
- **Flag storage location:** [thread.metadata.X / message.annotations[] …]
- **Ratio check:** flag [>= / < / =] transformation → [OK / MISMATCH]
- **Adversarial test:** "Among N sibling elements, exactly 1 is transformed — can the flag pinpoint which one?"
  - Answer: [concrete answer; no "probably"]
- **Conclusion:** [GRANULARITY OK / MISMATCH — need to upgrade flag to X]
```

A MISMATCH cannot be deferred — change the design or add a unit that
upgrades the flag granularity.

### Quality Gate Evidence

After the Quality Gate (see `plan-quality-gate.md` §2.2), append this
table to the plan file and mirror it in the conversation:

```markdown
## Quality Gate Evidence

| # | Check | Result | Location / Reason |
|---|-------|--------|-------------------|
| 1 | Phase 0: Problem Frame | ✅ | L## |
| 2 | Phase 0: Requirements Trace | ✅ | R1-R5 referenced by Unit 1-3 |
| 3 | Phase 0: Scope Boundaries | ✅ | L## |
| 4 | Layered architecture | ✅ | Unit 1 api layer |
| 5 | Machine constraints first | N/A | no new architectural decision |
| 6 | TDD red light | ✅ | Unit 1 test-first + test file |
| 7 | Test layering | ✅ | api/lib unit tests |
| 8 | Mobile adaptation | N/A | non-frontend or frontend.enabled=false |
| 9 | Provenance granularity | ✅ | GRANULARITY OK |
| 10 | /simplify | ✅ | Unit N-1 |
| 11 | Codex plan review | ✅ | Unit N |
```

N/A entries must carry a reason. On any ❌, fix the plan before delivering.

### Pool protocol (canonical — referenced by other mo-* skills)

A shared **single tmux session named `pool`** with **6 long-running TUI
panes** in a 3×2 tiled layout, defaulting to a **2 × 2 × 2 mix** of
three TUIs. Each pane runs one TUI; pane index ↔ tool kind is **not**
guaranteed by index alone (`tmux split-window` order varies), so always
discover via `pane_current_command` at runtime.

| Typical pane | TUI | `pane_current_command` match |
|---|---|---|
| 0, 1 | OpenAI codex | `codex*` (e.g. `codex-aarch64-a`) |
| 2, 3 | opencode (sst) | `opencode` |
| 4, 5 | Claude Code | `2.1.123` (claude binary version) or `claude` |

The session + Ghostty window are launched by `~/.local/bin/pool-launch.sh`
(fullscreen on portrait display, panes grouped by tool in rows).
**Reuse panes — never `tmux kill-session -t pool` or kill individual
panes** unless the user explicitly asks to rebuild the pool.

**Targets:** all `tmux send-keys` / `tmux capture-pane` use
`pool:0.<index>` form. Indices are tree-walk order, not row-major —
discover via `pool-task.sh state` or the dashboard, never hardcode.

The pool now runs a queue + dashboard layer. All mo-* skills go through
`pool-task.sh` (`~/.local/bin/pool-task.sh`); raw `tmux list-panes`
acquire loops and `pool_reset` keystroke chords are deprecated.

Other mo-* skills (`/mo-work`, `/mo-fix`, `/mo-debug`, `/mo-research`,
`/mo-swarm`) link back to this section instead of re-defining it.

**1. Acquire a task-bound pane** — block until one is available.

```bash
TASK="MAX-NNN-cdx"    # or "MAX-NNN-opc" for opencode — see naming convention below
T=$(pool-task.sh acquire-for --wait $TASK codex) || { echo "no codex available"; exit 1; }
# T = "pool:0.<idx>"; the dispatcher prefers truly-fresh panes over
# "done" (previously-used) panes, and reuses the same pane on repeat
# calls for the same TASK so phase-to-phase context is preserved.
```

**Task naming convention — `MAX-NNN-cdx` / `MAX-NNN-opc` per agent kind, not per phase.**
Use a single codex slot (`MAX-NNN-cdx`) and a single opencode slot
(`MAX-NNN-opc`) across plan-write → plan-review → impl → code-review →
fix-apply for the same issue. This keeps the entire MAX-NNN lifecycle on
the same two panes — codex's plan-writing context flows into impl, opc's
plan flows into code-review. `pool-task.sh done` only at issue close
(PR merged).

Trade-off: codex reviewing its own implementation lacks independence.
Mitigations: opc runs the parallel pool review independently of cdx;
high-stakes diffs add a `ce-code-review` Claude subagent third pass
(see `/mo-work` § Review). Cross-model sanity tasks (mo-debug second
opinion, mo-research contested-finding check) use their own task names
(`MAX-NNN-debug-2nd-opinion` etc.) so they always get a fresh pane.

`acquire-for --wait` defaults to a 600-second timeout. Pass `--wait 60`
to fail-fast, or `--wait 1800` for slow days. Without `--wait` the call
returns immediately or fails with `no idle <kind> pane`. If you need a
hard wipe of a previously-used pane (rare — fresh-vs-done preference
handles most cases), run `pool-launch.sh respawn codex|opencode` once
and re-acquire.

**2. Send the payload — instruct the TUI to write output to a file,
not to rely on pane scraping.** Two non-negotiable parts:

- **`tmux send-keys "cd <path>"` does NOT change TUI process cwd** —
  the TUI eats it as chat. Embed absolute path in the prompt; let the
  model's shell tool cd.
- **`tmux capture-pane` is unreliable for verdicts** — long outputs
  wrap, scroll out of buffer, mix with spinner glyphs and ANSI styling.
  Pre-allocate an `OUT` file, instruct the TUI to write its complete
  output there, then read the file.

```bash
WORKTREE="<absolute-worktree-path>"
OUT=$(mktemp -t mo-review-${KIND}-XXXXXX.md)
cat > /tmp/mo-prompt-$$.txt <<PROMPT_EOF
Working directory: $WORKTREE
Use your shell tool with that absolute cwd. Run
  git diff origin/${BASE}...HEAD
and do a pre-PR code review.

Output format:
- Numbered findings. For each: file:line → concern → suggestion.
- Tag each [P0] (blocks landing) / [P1] (should fix before merge) / [P2] (nice-to-have).
- Final line, exactly: VERDICT: BLOCK | CHANGES REQUESTED | NITS | LGTM

When done, write your COMPLETE output (findings + VERDICT line) to:
  $OUT
Then reply with EXACTLY one line: DONE $OUT
PROMPT_EOF

pool-task.sh send "$T" /tmp/mo-prompt-$$.txt
rm /tmp/mo-prompt-$$.txt
```

`pool-task.sh send` handles paste-buffer submission. Don't roll your own
send sequence.

**3. Wait for completion** — block until the agent stops spinning, then
read the OUT file.

```bash
pool-task.sh wait "$T" --timeout 600 || echo "timeout — surface pane to user"
[[ -s "$OUT" ]] || {
  # TUI ignored the file-write instruction — fall back to scrape.
  echo "warning: $OUT empty after wait, scraping pane"
  tmux capture-pane -t "$T" -p -S -300 > "$OUT"
}
REVIEW=$(cat "$OUT")
```

`pool-task.sh wait` polls every 2s for the codex spinner glyph in the
pane title (most reliable) plus opencode tail patterns; it returns when
the pane has been quiescent for two consecutive polls. Default timeout
1800s; pass `--timeout 60` for snappier failure on quick prompts.

**4. Release** — call `pool-task.sh done "$T"` once you're finished
with the task. This clears the registry mapping so the dispatcher can
hand the pane to the next caller (the dashboard flips it from yellow
`wait` to cyan `done`). If you intend to follow up with another phase
under the same TASK name, **don't** call done — just `acquire-for` the
same TASK again and you'll get the same pane back with conversation
context intact.

```bash
pool-task.sh done "$T"
```

**Anti-patterns** (collected from real dry-runs — keep updated as new
modes break)

- **Hand-rolling acquire / reset / send sequences** — the queue layer
  (`pool-task.sh`) is now the single entry point. Raw `tmux list-panes`
  acquire loops, manual `/new` resets, and `send-keys ... Enter ×2`
  rituals are deprecated; use `acquire-for --wait`, `send`, `wait`,
  `done` instead. They handle the bracket-paste edit-mode quirk, fresh-vs-done
  pane preference, and task affinity uniformly.
- **`/review` to opencode** — codex-only as of opencode v1.14.30. On
  claude it routes to a user-installed skill. On opencode use free-form.
- **`tmux send-keys "cd <path>"`** — TUI eats it as chat, doesn't
  change process cwd. Embed absolute path in the prompt; let the
  model's shell tool cd.
- **Killing a pool pane** — pool is shared, kills break dispatch.
  Use `pool-launch.sh respawn codex|opencode` to refresh one tier.
- **Falling back to `codex exec` on busy** — both pool and one-shot
  compete for OpenAI quota. Pick one (pool, with `--wait`) and surface "busy".
- **Hex colors `#F…` in tmux pane-border-format** — `#F` is the
  `window_flags` directive (expands to `*`). Hex colors must use
  `##FF…` (escaped `##` = literal `#`). Same for `#H/#W/#T/#S/#I/#P/#D`
  prefixes.
- **Setting pane-border-* at `-wg` global** — they're window-level.
  Existing window-specific values override globals. Use
  `-w -t pool:0` to actually apply on the live pool window.
- **Re-attaching pool from a fresh tmux client** — tmux stays at
  initial 80×24 unless you `tmux refresh-client && tmux resize-window
  -t pool:0 -A` so the panes re-fit Ghostty's actual cell grid.
- **opencode TUI without `permission: "allow"` in opencode.json** —
  shell-tool writes block on interactive `Allow once / always / Reject`
  dialog, breaking the OUT-file contract. The `--dangerously-skip-permissions`
  flag is `opencode run`-only; passing it to TUI mode makes the binary
  exit immediately (pool-launch will silently lose those panes). The
  fix is config-side: `~/.config/opencode/opencode.json` →
  `"permission": "allow"` (or per-tool object). pool-launch.sh assumes
  this is set.

### Codex plan review

After the QG table is written, hand the synthesized plan to **two reviewer
panes in parallel** — codex and opencode (deepseek). Mirror the dispatch
flow used in /mo-work review: same prompt body, distinct OUT files, merge
findings. Single-reviewer plan review misses too much; the policy is two
independent passes minimum. `/review` is for diffs, not for plan documents.

```bash
WORKTREE="<absolute-worktree-path>"
PLAN_FILE="<absolute-path-to-plan.md>"

Tc=$(pool-task.sh acquire-for --wait MAX-NNN-cdx codex)
To=$(pool-task.sh acquire-for --wait MAX-NNN-opc opencode)
# Plan review writes its OUT file via the agent's shell tool; plan mode
# may block file writes, so exit it before sending the review prompt.
# (Idempotent if the pane is already in build mode.)
pool-task.sh plan-mode "$Tc" off
pool-task.sh plan-mode "$To" off
OUT_C=$(mktemp -t mo-plan-review-codex-XXXXXX.md)
OUT_O=$(mktemp -t mo-plan-review-opencode-XXXXXX.md)

make_prompt() {
  local OUT="$1"
  cat <<PROMPT_EOF
Working directory: $WORKTREE
Use your shell tool with that absolute cwd; do not assume relative paths.

You are reviewing an implementation plan. Anchor judgment to the plan's
Acceptance Scenarios / Requirements Trace / Success Criteria — focus on
whether the approach is right, not on unit sizing or test names.

Output format:
- Numbered findings. For each: location in plan → concern → suggestion.
- Tag each [P0] (blocks landing) / [P1] (should fix before /mo-work) / [P2] (nice-to-have).
- Final line, exactly one of:
  VERDICT: APPROACH SOUND | APPROACH NEEDS ADJUSTMENT | RETHINK APPROACH

When done, write your COMPLETE output (findings + VERDICT) to:
  $OUT
Then reply with EXACTLY one line: DONE $OUT

Plan file:
$(cat "$PLAN_FILE")
PROMPT_EOF
}
P_C=$(mktemp -t prompt-cdx-XXXXXX.txt); make_prompt "$OUT_C" > "$P_C"
P_O=$(mktemp -t prompt-opc-XXXXXX.txt); make_prompt "$OUT_O" > "$P_O"
pool-task.sh send "$Tc" "$P_C" && rm "$P_C"
pool-task.sh send "$To" "$P_O" && rm "$P_O"

pool-task.sh wait "$Tc" --timeout 600 &
pool-task.sh wait "$To" --timeout 600 &
wait
[[ -s "$OUT_C" ]] || tmux capture-pane -t "$Tc" -p -S -300 > "$OUT_C"
[[ -s "$OUT_O" ]] || tmux capture-pane -t "$To" -p -S -300 > "$OUT_O"
pool-task.sh done "$Tc"
pool-task.sh done "$To"

REVIEW_CODEX=$(cat "$OUT_C")
REVIEW_OPENCODE=$(cat "$OUT_O")
```

Read both verdicts from the OUT files (not from the panes). Merge: both
flag = high-confidence change; one flag + valid = judge by P-tag; verdicts
disagree = adjudicate against `_planning-guidelines.md` and project
conventions. Tag each returned finding ✅ agree / ⚠️ partially agree /
❌ disagree (with reason), let the user decide, then patch the plan and
regenerate the QG table. `APPROACH NEEDS ADJUSTMENT` or `RETHINK APPROACH`
from either reviewer must be resolved before delivery.

### Output voice — Decision Voice

See `../../references/decision-voice.md`. Every user-facing question raised
during planning (approach fork, scope confirm, plan review verdict
handoff, worktree-conflict confirm) follows the five rules: lead with
your recommendation, frame options as user outcomes (not mechanisms),
≤1 blocking question with ≤2 options, pre-digest reviewer findings
before escalating, stakes-scaled brevity.

Specifically for the parallel plan review handoff above: do not paste
either reviewer's `APPROACH NEEDS ADJUSTMENT: 1/2/3` list verbatim,
and do not surface every disagreement between codex and opencode. For
each finding, decide what you'd do if the user delegated to you — apply
uncontroversial ones silently, escalate only the subset where (a) both
reviewers agree, or (b) reviewers diverge AND the choice meaningfully
changes the plan. Each escalation framed as a user/product outcome.

The Quality Gate Evidence and Provenance Granularity Check tables are
*structured data*, not decisions — write them verbatim regardless of
voice grading. The Decision Voice ask *about* the tables (e.g. "QG has
2 ⚠️, I suggest fixing #4 before delivery — OK?") still follows the
rules.

## What's next

| Situation | Skill |
|-----------|-------|
| Normal feature/fix | `/mo-work` |
| Lightweight small fix | `/mo-fix` (if installed) |
| Frontend post-impl | `/mo-work` → project's design-lint skill |

## Self-revision hook

See `self-revision.md` (in `$HARNESS_DIR` or the plugin's template copy).
Drift dimensions specific to this skill:

- **QG checklist N/A patterns** — same item marked N/A in 3+ runs in a row
  may signal a dead rule worth removing or reworking.
- **Provenance Granularity Check trigger criteria** — refine when false
  positives or false negatives surface.
- **Depth defaults** — if you keep manually overriding the heuristic, the
  heuristic itself needs an update.
