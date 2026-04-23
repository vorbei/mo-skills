---
name: mo-plan
description: "Create implementation plan following the project's harness rules. Enforces efficiency rules by depth, Quality Gate checks with on-disk evidence, Provenance granularity check, and strict frontmatter/filename schema. Use when asked to 'plan this', 'make a plan', 'mo-plan', or before implementing a feature/fix."
argument-hint: "[feature description or requirements doc path]"
---

# Mo Plan

> **Reference, not replacement.** This skill is a *project overlay* on `ce:plan`.
> Each section either (a) adds a project-specific constraint ce:plan does not
> have, (b) overrides a ce:plan default with a one-line justification, or
> (c) keeps a concept locally because ce:plan does not own it.

Follow the **`ce:plan` workflow exactly**, then apply the project overlays below.

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
later. `ce:plan` Phase 0.4 will also route here downstream, but
catching it upstream saves the research pass. Signals:

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
2. **`mo-codex review-plan`** — read-only plan review via the `mo-codex`
   skill.

### Worktree creation (standard / deep plans)

For `depth: standard | deep`, create the per-task worktree **at plan time**,
before the Codex review, so review can anchor against real branch code and
`/mo-work` starts editing without a separate setup. Branch off `base:` from
the project's primary repo (`project.primaryRepo` in config). Record the
absolute path back into the plan as `worktree: <abs-path>`. **Stop and ask
the user** if the branch or directory already exists — never reuse or
overwrite without confirmation.

**After the worktree is created, prewarm its Codex broker** so the first
`mo-codex review-plan` or `/mo-work` call inside it is not blocked by the
1–3s broker spawn:

```bash
mo-codex warm <absolute-worktree-path>
```

Idempotent, does not consume Codex credit.

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
| 11 | mo-codex review-plan | ✅ | Unit N |
```

N/A entries must carry a reason. On any ❌, fix the plan before delivering.

### Codex plan review

After the QG table is written, run `mo-codex review-plan <plan-file>`.
The verb-specific prompt inside `mo-codex` owns the review categories and
grounding rules — do not add a custom prompt. Tag each finding ✅ agree /
⚠️ partially agree / ❌ disagree (with reason), let the user decide, then
patch the plan and regenerate the QG table. `NEEDS REVISION` (or
`RETHINK APPROACH`) must be resolved before delivery.

### Output voice — Decision Voice

See `../../references/decision-voice.md`. Every user-facing question raised
during planning (approach fork, scope confirm, Codex `review-plan`
verdict handoff, worktree-conflict confirm) follows the five rules:
lead with your recommendation, frame options as user outcomes (not
mechanisms), ≤1 blocking question with ≤2 options, pre-digest Codex
findings before escalating, stakes-scaled brevity.

Specifically for the Codex `review-plan` handoff above: do not paste
the `APPROACH NEEDS ADJUSTMENT: 1/2/3` list verbatim. For each finding,
decide what you'd do if the user delegated to you — apply the
uncontroversial ones silently, then escalate only the subset where the
user's preference genuinely changes the plan, each framed as a
user/product outcome.

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
