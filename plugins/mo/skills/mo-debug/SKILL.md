---
name: mo-debug
description: "Root-cause investigation before touching code. Reads the project's harness protocols and decisions so the investigation respects what's already settled. Generates ≥3 competing hypotheses, ranks by cost-to-falsify, runs the cheapest test first, and hands off to /mo-fix or /mo-plan once the root cause is identified. Use when asked to 'debug this', 'find the root cause', 'why does X happen', 'mo-debug', or when a bug description is too vague to jump straight to /mo-fix."
argument-hint: "[symptom, stack trace, reproduction steps, or 'don't know yet']"
---

# Mo Debug

> **Upstream of `/mo-fix`.** Use when you don't yet know what broke, let
> alone what failing test to write. `/mo-fix` *starts* by turning a known
> bug into a red-light test. `/mo-debug` *ends* by knowing what that
> failing test should be.

## Config

Load `mo-config.json` (first match wins):

```bash
for p in "${CLAUDE_PROJECT_DIR:-}/.claude/mo-config.json" \
         "$PWD/.claude/mo-config.json" \
         "$HOME/.claude/mo-config.json"; do
  [[ -f "$p" ]] && { MO_CONFIG="$p"; break; }
done

HARNESS_DIR=$(jq -r '.harnessDir // empty' "${MO_CONFIG:-/dev/null}")
TEST_CMD=$(jq -r '.commands.test // "pnpm test"' "${MO_CONFIG:-/dev/null}")
ISSUE_PREFIX=$(jq -r '.issueTracker.prefix // empty' "${MO_CONFIG:-/dev/null}")
LANG_CONV=$(jq -r '.language.conversation // "English"' "${MO_CONFIG:-/dev/null}")
```

**Language policy:** hypotheses, evidence blocks, commit messages →
English. Conversational replies to the user → `$LANG_CONV`.

## Input

<symptom> #$ARGUMENTS </symptom>

If empty, ask: "What's broken, and what have you already tried?"

## Prerequisites — read the harness first

Before generating hypotheses, read from `$HARNESS_DIR` (or the project's
equivalent), in this order:

1. **`DECISIONS.md`** — settled architecture decisions. A surprisingly
   large share of "bugs" are drifts from an active decision. If the
   observed behavior is what happens when someone violates a settled
   decision, the root cause is "the decision was not followed" and the
   fix path is "follow the decision, don't work around it". Read
   before hypothesizing.
2. **`protocols.md`** — action boundaries (free / stop-and-confirm /
   hard rules). If the investigation path would touch DBs, external
   APIs, shared infra, or destructive ops, surface that to the user
   *before* probing. Never run a destructive command to confirm a
   hypothesis.
3. **`tdd-and-simplify.md`** — reminder that the eventual output of
   `/mo-debug` is a concrete, writable failing test (handoff to
   `/mo-fix` Step 1). Keep the investigation scoped tightly enough
   that Step 1 can land on one.

If the input matches `${ISSUE_PREFIX}-\d+` and an issue-tracker
integration is configured, fetch the issue for additional context.
Failures do not block.

---

## Step 1 — Frame the problem

Pin down before you hypothesize:

- **Observed behavior** — what's happening, from the user / logs / stack
  trace / failed test output. Quote verbatim. Paraphrased symptoms lead
  the investigation astray.
- **Expected behavior** — what should happen instead.
- **When it started** — recent deploys, recent commits (`git log --oneline -20`),
  upstream dependency bumps.
- **Reproduction** — can you trigger it? What conditions? If the user
  only reported it secondhand, say so explicitly; don't assume it's
  live.
- **What was already tried** — and what evidence was gathered from each
  attempt (not just "didn't work").
- **Production signal (lightweight, ~5 min cap)** — if the project has
  Sentry / APM / EKS logs / metrics dashboards available AND
  authenticated, glance for the symptom's error signature: how many
  users hit it, first-seen timestamp vs. recent deploys / releases,
  any attached stack trace or request context. This is
  **frame-gathering, not root-cause probing** — the goal is impact
  scale and recent-delta correlation, not diagnosis. Skip cleanly
  if nothing is configured, if access is not available, or if the
  signal is noisy / unrelated; deeper log and metrics dives belong
  in Step 3's cheap-probe list.

**Question every "known" fact.** Treat the user's assumptions about the
cause as untested hypotheses. "The backend is returning the wrong data"
is a hypothesis, not an observation — the observation is "the UI shows X
when it should show Y."

---

## Step 2 — Generate ≥3 competing hypotheses

Single-hypothesis debugging is the most common failure mode. The first
plausible theory is almost always wrong *or incomplete*.

For each hypothesis, write:

- **Claim** — one sentence: "X happens because Y at location Z."
- **Predicts** — what else would we see if this were true?
- **Excludes** — what would we NOT see if this were true? (this is the
  discriminator against other hypotheses)
- **Cost to falsify** — low / medium / high, and what the cheapest
  probe would be.

Present hypotheses as a table:

| # | Claim | Predicts | Excludes | Cost |
|---|-------|----------|----------|------|
| 1 | … | … | … | low |
| 2 | … | … | … | medium |
| 3 | … | … | … | low |

Do not rank by plausibility at this stage. Rank by **cost to falsify**.

**Before moving on, check for compound causes.** Many real-world bugs
turn out to be two independent issues colliding (a null-id race *and*
a state-overwrite bug; an auth redirect *and* a stale cache). Ask:

- Are these hypotheses **mutually exclusive**, or could two or more be
  **simultaneously true**?
- If two hypotheses could co-exist without contradiction, add a
  **union row** to the table — treated as its own hypothesis with its
  own `Predicts`, `Excludes`, and `Cost` columns.

Giveaway for compound-bug territory: the user's symptom description
has "and also …" / "plus sometimes …" / "even after X, Y still
happens." When in doubt, add the union row and let Step 3's probes
falsify it.

---

## Step 3 — Cheapest-to-falsify first

Run the lowest-cost probe that discriminates between hypotheses. Use
read-only tools:

- `grep`, `git blame`, `git log -S`, `git show`
- One-off `node -e` / `python -c` snippets
- Reading logs / Sentry / metrics dashboards (Step 2 `protocols.md` may
  restrict which)
- Running a single existing test (`<TEST_CMD> <file>`) — never modify
  tests at this stage
- Asking the user *one* crisp question whose answer cuts the hypothesis
  space in half

**Not at this stage:** code edits, fixes, "let me try flipping this
flag and see," console.log sprinkling across six files.

After each probe, update the hypothesis table:
- ❌ Falsified — the prediction failed
- ✅ Surviving — the prediction held (not "confirmed" — just still alive)
- ❓ Ambiguous — add a sharper discriminator

If all three are falsified, generate three more. Do not force-fit.

---

## Step 4 — Converge on root cause

Only declare a root cause when:

1. **One hypothesis (which may be a union row) is fully consistent
   with every piece of evidence gathered.** A single claim or an
   explicit union of two co-existing claims both qualify; a vague
   "probably some of each" does not.
2. At least two other hypotheses have been actively falsified (not
   just "seems less likely").
3. You can state the cause as a single sentence — or, for a union,
   as two sentences joined with an explicit "and":
   *"X happens because Y at location Z, triggered by W **and** because
   of independent issue Q at location R."* The `and` is load-bearing
   — it forces you to commit to both parts, not hand-wave.

**Compound-cause convergence guard.** Before declaring done, run this
check explicitly:

> Could any falsified or surviving hypothesis **co-exist** with the
> declared root cause without contradicting the evidence? If yes,
> the declared cause is incomplete — return to Step 2 and add the
> missing claim to a union row.

This catches the common "we fixed one layer of a two-layer bug" trap
(the fix passes the original red-light test but a closely related
symptom reappears in QA or production).

If the surviving hypothesis is a decision-drift per the harness
`DECISIONS.md` check, say so explicitly — the fix is "enforce the
decision."

---

## Step 5 — Hand-off

### 5a — User-facing summary (Decision Voice)

Before the routing table below, present the result to the user
following `../../references/decision-voice.md`. The hypothesis table from
Step 2 and the evidence log from Step 3 are *internal reasoning* —
they do not go to the user in the ask. Collapse to:

```
最可能的原因: <one sentence, file:line 可选>
置信度: 高 / 中 / 低 — <why, one line>

建议: <cheapest next step phrased as outcome, e.g. "让 /mo-fix 写一条
回归用例并修掉"> / <alternative if one exists, else omit>

(需要你拍板的一件事: <one question, or omit if none>)
```

The full hypothesis table + evidence log still flow *internally* to the
downstream skill (`/mo-fix` or `/mo-plan`) via the handoff packet — they
need the detail, the user does not. If the investigation is
inconclusive, the user ask is still one sentence + one proposed next
probe, not the full table.

### 5b — Routing

Root cause known → route to the right follow-up skill:

| Situation | Skill | Why |
|-----------|-------|-----|
| Single file, minimal local fix | `/mo-fix` | Step 1 can now write the red-light test straight from the root-cause sentence |
| Fix would match one of `/mo-fix`'s 2a systemic triggers (design system, API contract, provenance field, 3+ sites) | `/mo-plan` | Needs full Quality Gate, not a bug flow |
| Decision drift — the "bug" is a violation of an active `DECISIONS.md` entry | `/mo-fix` with the decision cited in the commit message | Signal that the code moved toward the decision, not away from it |
| Investigation inconclusive after two hypothesis rounds | Surface status to user, do NOT guess | Capture what's known, what's been ruled out, and what probe would cut the remaining space |
| Second opinion needed | `codex exec` (in the worktree) | Hand off the hypothesis table and current evidence, ask Codex to poke holes — see snippet below |

Pass the hypothesis table + evidence log forward in the handoff so
`/mo-fix` or `/mo-plan` doesn't repeat the investigation.

For the second-opinion case, **`cd` into the repo first** — `codex
exec` reads the current working directory; do not rely on `-C` /
`--cd` flags:

```bash
cd "<repo-or-worktree>"
codex exec "$(cat <<'PROMPT'
Second opinion on a root-cause investigation. Below are competing
hypotheses, supporting evidence, and falsified candidates. Poke holes:

- Which surviving hypotheses are weakest, and what cheap probe would
  discriminate them next?
- Which hypotheses is the investigator likely missing (compound causes,
  decision drift, environmental factors)?
- Is the convergence guard satisfied, or could two surviving claims
  co-exist as a union root cause?

Investigation packet:
PROMPT
)

<paste hypothesis table and evidence log>"
```

---

## Anti-patterns

- **"Let me try flipping this flag and see."** — No hypothesis ranking
  step. Each "let me try" is a cycle of wasted time compared to a
  cheap discriminating probe.
- **"The code looks right."** — Reading code is not evidence. Run the
  code, inspect state, observe behavior.
- **"It's definitely the cache."** — Single-hypothesis trap. Force
  yourself to name two other plausible causes.
- **"It works on my machine, ship it."** — Didn't pin down what was
  different between environments. The investigation is not finished.
- **Jumping straight to a fix without a red-light test.** — That's
  `/mo-fix` Step 1. Come back with a concrete hypothesis first.
- **Hypothesizing against only the user's stated symptom.** — Widen:
  what else does this hypothesis predict? If nothing, it's too narrow.

## Self-revision hook

Drift dimensions specific to this skill:

- **Hypothesis-count floor** — when root causes keep being found with
  only 2 hypotheses, maybe 3 is too many. When they keep coming from
  the 4th or 5th hypothesis, raise the floor.
- **Harness read list** — if a project-specific rule file
  (e.g. security-boundaries.md, data-privacy.md) would have prevented
  a class of wasted investigation, add it to Step 2's read order.
- **Handoff routing** — track how often `/mo-fix` receives the handoff
  vs. `/mo-plan`. Skew → adjust the 2a trigger wording so the
  distinction is clearer.
