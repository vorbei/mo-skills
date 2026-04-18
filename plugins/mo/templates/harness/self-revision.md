# Self-revision hook (shared)

When a skill's output disappoints — the user corrects you, the same mistake
reappears, or a rule produces false positives — do NOT silently absorb the
lesson into your next prompt. Propose a conservative edit to the relevant
`SKILL.md` so the next agent benefits, then sync the change to every live
copy.

## Triggers (any one)

1. **Direct correction**: user says "don't do this", "next time avoid X",
   "stop including Y", or rephrases your output multiple times.
2. **Repeat in memory**: the same correction appears in the project's
   feedback memory file two or more times in the last 30 days.
3. **Dead rule**: a checklist item or guard was marked N/A or skipped three
   or more runs in a row — the rule itself may no longer apply.
4. **False positive**: a guard fired but turned out to be wrong ("this is
   fine, the rule is too aggressive").

## Conservative principles

- **Scope**: edit only the section directly implicated. No drive-by refactors.
- **Evidence**: cite a specific failure from this session or a concrete
  memory entry. No hunches.
- **One rule at a time**: add one constraint, remove one ambiguity, or
  reword one sentence. Don't rewrite the skill.
- **Preserve over delete**: never delete a rule unless it hit trigger (3)
  "Dead rule". Reword instead.
- **Ask first**: show the user the diff and the reason before editing
  `SKILL.md`. They may prefer to keep the skill as-is and add a memory
  feedback entry instead.

## SKILL.md vs memory — which one?

- **SKILL.md** describes how the skill should behave **every time** (process,
  defaults, mandatory steps, format).
- **Project feedback memory** describes **codebase-specific incidents and
  one-off facts** (this file uses pattern X, this hook contaminates Y).

If the correction is "this codebase needs X" → memory.
If the correction is "the skill should always check Y" → SKILL.md.

## Sync after editing

After user-confirmed edits to `SKILL.md`, copy to every live location of
that skill and verify with `diff` — drift between copies is the most common
silent failure of this hook.

## Surface the change

After editing, mention it once at the top of the next response:
`Updated <skill> SKILL.md §<section>: <one-line summary>. Reason: <evidence>.`
So the user knows the skill mutated.
