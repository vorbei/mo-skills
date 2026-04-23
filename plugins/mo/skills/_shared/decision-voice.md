# Decision Voice

Shared reference for every Mo skill that pauses to ask the user for a
decision. These rules exist because past sessions showed the agent
dumping technical option lists the user couldn't engage with — either
silently surrendering ("就按你说的"), re-framing the question
themselves, or pivoting to a screenshot. Decision Voice fixes the ask
shape so the user can read, decide, and reply in one short sentence.

## The five rules

1. **Lead with your recommendation.** Open every escalation with one
   sentence: *"我倾向 X，理由是 Y"* (or English in committed artifacts
   per the language policy). The user should be able to reply "就这样"
   and proceed. Withholding a recommendation in the name of neutrality
   is the most common failure mode — neutrality is an internal
   deliberation step, not a user-facing output.

2. **Frame options as user-visible outcomes.** Each option describes
   *what a user sees, feels, or can do* — not the code mechanism.
   Mechanism goes in parentheses at the end if it goes anywhere.
   - ✅ "A: loader 留在左栏（感觉聚焦，不抖）；B: loader 铺满视口
      （保留当前 app-loading 感，但会盖到 dock）"
   - ❌ "A: 把 loader 改成 `absolute inset-0`；B: 下移到 ChatArea 内部；
      C: 用 `absolute` 覆盖 chat 列"

   If you can't phrase an option as a user outcome, the fork is
   probably an internal implementation choice — decide it yourself.

3. **One blocking question, at most two options.** If you have four
   unknowns, resolve three by stating a default assumption
   ("我按 X 理解，如果不对喊停") and ask only about the one axis where
   the user's answer materially changes the product. Never batch
   multiple orthogonal axes in a single ask. Three-option menus almost
   always collapse to two once you strip the implementation-variant
   third.

4. **Pre-digest review/tool findings.** Never forward a Codex or review
   tool's finding list raw to the user. For each finding, decide what
   you would do if the user delegated to you: accept silently, reject
   silently, or escalate. Only the last category enters the Decision
   Voice ask — and even there, lead with your take, then cite the tool
   in one line.

5. **Stakes-scaled brevity.** Match length to decision weight.
   - *Routine* (unit sizing, commit scope, naming): one sentence, no
     option list.
   - *Notable* (multi-file blast radius, departure from baseline
     pattern): one short paragraph, conclusion first.
   - *Critical* (architecture, contracts, user-visible behavior
     reversal, provenance): full frame — user outcome → recommendation
     → one alternative → one-line residual risk. Code snippets and
     diffs live in an artifact or fold, not the ask body.

## When Decision Voice applies

Every user-facing question a Mo skill raises:

- `/mo-plan` — approach choice, worktree conflict confirmation,
  Codex `review-plan` verdict handoff
- `/mo-fix` — medium-fix proposal, 2a-trigger escalation, Codex
  `review-code` finding escalation
- `/mo-work` — scope expansion, merge conflict resolution, subagent
  divergence, PR creation confirmation
- `/mo-debug` — root-cause handoff (hypothesis table collapsed into
  one-sentence cause + cheapest next step)
- `/mo-codex` — any finding the calling skill forwards to the user
  goes through the pre-digest rule

**Out of scope:** internal agent↔agent handoffs (plan-unit dispatch to
a subagent, Codex prompt construction, TDD evidence blocks) get full
technical detail because the receiver is another agent, not the user.

## Pre-send checklist

Before sending any user-facing question:

- [ ] Leads with "我倾向 X, 理由是 Y" (recommendation first)
- [ ] Every option is phrased as a user outcome, mechanism only in parens
- [ ] One question, ≤2 options, other axes defaulted with "按 X 理解"
- [ ] Tool findings are pre-digested — no raw relay of Codex/review output
- [ ] Length matches decision stakes (routine = one sentence)
- [ ] User can reply in one short sentence to unblock

If any box is unchecked, rewrite before sending.

## Structured-data exceptions

Tables that exist as *evidence artifacts* (Quality Gate Evidence,
Provenance Granularity Check, TDD red/green evidence, hypothesis
tables inside `/mo-debug`) are written verbatim regardless of Decision
Voice — they are not decisions, they are record-keeping. The Decision
Voice ask *about* the evidence is still subject to the five rules.
