---
name: mo-research
description: "Deep research before planning. Clarifies ambiguity first, launches parallel agents against codebase / docs / web / dependencies / design, then synthesizes findings into actionable context. Use when asked to 'research this', 'dig into X', 'mo-research', or when a /mo-plan input is ambiguous enough that planning would thrash without context. Upstream of /mo-plan."
argument-hint: "[topic or question — free-form, or an issue reference]"
---

# Mo Research

Upstream of `/mo-plan`. Use when a planning input is ambiguous enough
that jumping straight into plan writing would thrash — scope unclear,
multiple plausible approaches, unfamiliar library, or a proposed
solution you want to stress-test before committing.

> **Reference, not replacement.** `mo-research` is a project overlay
> around a generic "clarify → parallel research → synthesize" loop.
> Where `ce` research agents exist (`ce-repo-research-analyst`,
> `ce-learnings-researcher`, `ce-framework-docs-researcher`,
> `ce-best-practices-researcher`, `ce-web-researcher`,
> `ce-slack-researcher`), prefer them over hand-rolled subagent
> prompts — they already carry format and grounding conventions.

## Config

Load `mo-config.json` (first match wins):

```bash
for p in "${CLAUDE_PROJECT_DIR:-}/.claude/mo-config.json" \
         "$PWD/.claude/mo-config.json" \
         "$HOME/.claude/mo-config.json"; do
  [[ -f "$p" ]] && { MO_CONFIG="$p"; break; }
done

HARNESS_DIR=$(jq -r '.harnessDir // empty' "${MO_CONFIG:-/dev/null}")
ISSUE_PREFIX=$(jq -r '.issueTracker.prefix // empty' "${MO_CONFIG:-/dev/null}")
FRONTEND_ENABLED=$(jq -r '.frontend.enabled // false' "${MO_CONFIG:-/dev/null}")
DESIGN_DOCS=$(jq -r '.frontend.designDocs[]? // empty' "${MO_CONFIG:-/dev/null}")
LANG_CONV=$(jq -r '.language.conversation // "English"' "${MO_CONFIG:-/dev/null}")
LANG_ART=$(jq -r '.language.artifacts // "English"' "${MO_CONFIG:-/dev/null}")
```

**Language policy:** research questions, evidence blocks, source
citations, synthesis body → `$LANG_ART`. The AskUserQuestion dialog
and conversational replies → `$LANG_CONV`.

## Input

<topic> #$ARGUMENTS </topic>

If empty, ask: "要研究什么？给我一句话描述问题或贴一个链接/issue
引用即可。"

If the input matches `${ISSUE_PREFIX}-\d+` and an issue-tracker
integration is configured, fetch the issue for additional context
before Step 1. Failures do not block.

## Prerequisites

If `$HARNESS_DIR` is set, skim `DECISIONS.md` once before Step 1 —
not for the research questions themselves, but so you don't
research into settled territory. If an active decision already
answers the research question, surface that as the first finding
and stop.

## How to research

### Step 1 — Clarify before you research (MANDATORY — never skip)

Before reading a single file or launching any agent, use
`AskUserQuestion` (call `ToolSearch` with `select:AskUserQuestion`
first if its schema isn't loaded). Read the input and identify every
place where you have 2+ plausible interpretations — scope, intent,
constraints, approach, priority. Ask about those specifically.

**How to ask** — follow `../_shared/decision-voice.md`:

- Present choices tailored to the actual input, not generic
  categories. Options come from the ambiguities in *this* input
- Lead with your take: "我倾向 A，理由是 Y — 对吗？"
- Each option is phrased as an outcome the user cares about, not
  an implementation axis
- Keep questions short; use choices, not open prompts ("Which of
  these is closer?" beats "Can you describe your constraints?")
- "Other / none of these" is always a valid escape hatch

Good trigger conditions for asking:

- Input describes a symptom but not a root cause — ask what they
  think the cause is, with options
- Input proposes a solution — ask if the solution is required or a
  starting hypothesis
- Scope is fuzzy — ask targeted-fix vs broader-rethink, with
  examples of each
- Multiple approaches exist with real tradeoffs — ask which
  tradeoff matters most
- The change could affect related systems — ask if those are in
  scope
- Any constraint (time, backwards-compat, dependency, team
  conventions) is unstated — ask

Ask as many questions as the ambiguity warrants — but batch them
into a **single** `AskUserQuestion` call so the user responds once.

**Do not launch any agents until you have the answers.**

### Step 2 — Parse intent

With the answers in hand, read critically:

- What is the **core problem** — distinct from the proposed
  solution?
- Does any answer change the scope or approach from what was
  originally described?
- Are there remaining ambiguities? If yes, use `AskUserQuestion`
  again — don't bank on assumptions.
- Frame 2-4 specific research questions around the problem.

Then immediately launch parallel research — do **not** confirm the
research questions with the user first.

### Step 3 — Launch parallel research

Spawn sub-agents to work simultaneously. Match agent count to
complexity — not all are always needed. Prefer existing `ce`
research agents over hand-rolled prompts:

| Agent | Tool / ce equivalent | When |
|---|---|---|
| **Codebase** | `ce-repo-research-analyst` (preferred) or Grep/Glob/Read manually | Almost always — find patterns, existing impls, deps in this project |
| **Institutional learnings** | `ce-learnings-researcher` | When prior solutions in `docs/solutions/` may apply |
| **Docs / framework** | `ce-framework-docs-researcher`, else Context7 MCP (`mcp__context7__*`), else WebSearch + WebFetch of official docs | Libraries / frameworks involved |
| **Best-practices / prior art** | `ce-best-practices-researcher` or `ce-web-researcher` | The problem isn't purely local; external patterns matter |
| **Dependencies** | Read lockfiles + cross-ref with docs agent | Version compat / breaking changes / config options in play |
| **UI** (frontend only, gated on `frontend.enabled`) | Inspect `$DESIGN_DOCS`, then `impeccable:*` skills when available | Change affects visual design — layout, hierarchy, spacing, responsive, motion, consistency |
| **UX** (frontend only) | Grep existing interaction patterns + WebSearch established patterns | User flows, cognitive load, affordances, error states, WCAG / a11y |
| **Delight** (frontend only) | Grep existing delight patterns; bar: "would a user notice and think 'nice'?" | Anything a user sees or interacts with — micro-interactions, smart defaults, empty states, transitions |
| **Slack context** | `ce-slack-researcher` — user-requested only, never auto-dispatched | User explicitly asks for organizational context |

**Research the problem, not the proposal.** If the input includes a
proposed solution, every agent researches the underlying problem
first. Don't anchor on the proposed approach — it may be correct,
but verify.

Each agent returns: what it found, where it found it (repo-relative
file paths or URLs), and key snippets. Never accept "looks fine" —
demand quotes + paths.

### Step 4 — Check in after research (MANDATORY)

After agents return, use `AskUserQuestion` before synthesizing.
Summarize the key finding in a sentence or two, then surface
anything unexpected and ask the user to react. Present specific
choices about how to proceed — don't just ask "does this make
sense?" Per Decision Voice, lead with your leaning.

If findings contradict the user's stated understanding of the
problem, that's especially important to surface before moving
forward — call it out with one sentence and one option to pivot.

### Step 5 — Synthesize

Combine all agent findings. Resolve contradictions. Identify what
is **confirmed** vs **uncertain**.

**If the input included a proposed solution:** explicitly evaluate
it. Is it the best approach, or is there a simpler way? If the
proposal is unnecessary, overly complex, or solves the wrong thing,
say so and recommend the better path — again per Decision Voice,
lead with your take.

### Step 6 — Stress-test the recommendation

Actively look for downsides of the recommended approach:

- What UX does it degrade?
- What edge cases does it miss?
- What maintenance burden does it create?
- What could it break?

Be specific. "This could be slow" is useless; "this adds an N+1
query on every page load" is useful.

## Output format

Keep it tight. No filler.

### Answer

Direct response to what was asked. Concise for simple questions,
thorough when complexity demands it.

### Evidence

Code snippets, doc quotes, or data that back up the answer. Use
code blocks with repo-relative file paths.

### Sources

- Repo-relative file paths for codebase findings
- URLs for web / doc findings

### Related

Gotchas, related patterns, upcoming deprecations, alternative
approaches the user should know about. Skip if nothing worth
mentioning.

### Downsides & Risks

What could go wrong with the recommended approach? Be specific.
Skip if the solution is trivially safe.

## Handoff — Decision Voice

After presenting findings, route the user to the right next step.
Per `../_shared/decision-voice.md`, lead with your recommendation
and cap the choice at ≤2 options:

- **Default (non-trivial work):** recommend `/mo-plan` with this
  research as the input. A durable plan file beats relying on the
  chat transcript.
- **Small / obvious fix:** recommend `/mo-fix` directly — research
  may have resolved the ambiguity that previously required
  planning.
- **Still exploratory:** call `EnterPlanMode` so the user stays in
  Claude Code's lightweight plan dialog without producing a plan
  document.

Present these as one ask. Example:

> 建议先 `/mo-plan`，把这份研究作为 origin 输入；如果你觉得方向已经
> 够具体可以直接 `/mo-fix`。要进 `EnterPlanMode` 做轻量讨论也行。

Wait for the user's choice. Don't auto-pivot into any of them.

## What's next

| Situation | Skill |
|-----------|-------|
| Research done, need a durable plan | `/mo-plan` |
| Research resolved the ambiguity, single-file fix | `/mo-fix` |
| Still exploratory, want lightweight plan dialog | `EnterPlanMode` |
| Research revealed a settled decision answers this | Point the user at the relevant `DECISIONS.md` entry, stop |
| Cross-model sanity check on a contested finding | `mo-codex handoff` (opt-in — see `mo-codex` SKILL perf note) |

## Rules

- **AskUserQuestion fires at Steps 1 and 4 at minimum.** More is
  fine — the bar for asking is low.
- **Questions must be specific to the input.** No generic category
  buckets. Options come from the ambiguities in what was asked.
- **Use choices, not open prompts.** "Which of these is closer?" >
  "Can you describe X?"
- **Never launch agents before completing Step 1.** Never.
- **Never confirm research questions with the user before launching
  agents** — just launch them after Step 2.
- **Prefer primary sources** (official docs, source code) over
  blog posts.
- **If you find conflicting information**, say so and state which
  source you trust more, with evidence.
- **Never pad the output.** Simple question → simple output. Don't
  invent sections to fill the template.
- **Match agent count to problem size.** Don't launch 4 agents for
  a one-file bug; don't launch 1 agent for a cross-layer refactor.
- **Every user-facing question** — Steps 1, 4, and the handoff —
  follows `../_shared/decision-voice.md`.

## Self-revision hook

See `self-revision.md` (in `$HARNESS_DIR` or the plugin's template
copy). Drift dimensions specific to this skill:

- **Agent-count calibration** — if you keep launching 4+ agents and
  half return "nothing material", tighten the Step 3 trigger
  conditions.
- **Clarifying-question quality** — if Step 1 questions repeatedly
  get "none of these" answers, the option-generation heuristic is
  off; study the misses and adjust.
- **Handoff routing accuracy** — track whether users accept the
  default `/mo-plan` recommendation or override to `/mo-fix` /
  `EnterPlanMode`. Consistent override signals the recommendation
  heuristic needs tuning.
