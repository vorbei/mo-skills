---
name: mo-handoff
description: "Synthesize current session state into a clean resume prompt, then copy it to clipboard via pbcopy. Use when context is getting messy, after completing a plan but before starting implementation in a fresh session, or when asked to 'mo-handoff', 'handoff', 'clean context', 'start fresh', or 'copy resume prompt'."
argument-hint: "[optional: focus hint, e.g. 'frontend unit only' or 'skip completed units']"
---

# Mo Handoff

Compress the current session into a tight, self-contained resume prompt
for a fresh Claude session. The fresh session should be able to pick up
exactly where this one left off without needing any context from this
conversation.

## Config

```bash
for p in "${CLAUDE_PROJECT_DIR:-}/.claude/mo-config.json" \
         "$PWD/.claude/mo-config.json" \
         "$HOME/.claude/mo-config.json"; do
  [[ -f "$p" ]] && { MO_CONFIG="$p"; break; }
done

PLAN_STORE=$(jq -r '.planStore // "docs/plans"' "${MO_CONFIG:-/dev/null}")
BASE_DEFAULT=$(jq -r '.base.default // "main"' "${MO_CONFIG:-/dev/null}")
```

## Input

<focus_hint> #$ARGUMENTS </focus_hint>

---

## Step 1 — Locate the active plan

```bash
ls -t "$PLAN_STORE"/*.md 2>/dev/null | head -5
```

Read the plan file. Extract:
- **Frontmatter**: `issue`, `branch`, `base`, `depth`, `status`
- **Implementation Units**: which are `- [x]` (done) vs `- [ ]` (pending)
- **Scope Boundaries** section: what is explicitly out of scope
- **Deferred to Implementation** section: any open questions

If no plan exists (bare prompt session), construct the state summary
from git log and conversation context.

---

## Step 2 — Extract current git state

```bash
BRANCH=$(git branch --show-current)
BASE=$(git rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null | sed 's|origin/||' || echo "$BASE_DEFAULT")

git log --oneline "origin/$BASE..HEAD" 2>/dev/null | head -10
git status --short
```

---

## Step 3 — Extract key decisions from this conversation

Scan the current conversation for decisions that are NOT already written
into the plan file — things the fresh session would otherwise have to
rediscover:

- Architectural choices made during implementation
- Deferred questions that got resolved
- Gotchas encountered
- Any open questions still unresolved

If `focus_hint` is provided, only include decisions relevant to that scope.

---

## Step 4 — Compose the resume prompt

Assemble a prompt a cold Claude instance can use immediately, with no
prior context.

**Template:**

```
Resume work on [branch-name] ([issue if any]).

**Plan:** <plan-file-path>
**Branch:** [branch] (base: [base])
**Worktree:** [absolute path]

**Completed units:**
[List of ✅ units with one-line summary of what was done]

**Next unit:** [unit name and goal]

**Key decisions made this session (not in plan):**
[Bullet list of decisions, only the non-obvious ones]

**Open questions:**
[Anything unresolved that the fresh session should know about upfront]

**Start by:** Reading the plan file, verifying the completed units are in
git, then continue from "[next unit name]".
```

Rules for the prompt:
- **No pleasantries.** Start with "Resume work on…" — not "Hi Claude, could you please…"
- **No duplication.** If something is in the plan file, say "see plan".
- **Concrete next action.** Last line tells the fresh session exactly what
  to do first.
- **Under 400 words.** A longer handoff is a sign too much context is
  being transferred — trim mercilessly.

---

## Step 5 — Copy to clipboard

```bash
cat << 'HANDOFF_EOF' | pbcopy
[assembled prompt from Step 4]
HANDOFF_EOF
```

(On Linux, replace `pbcopy` with `xclip -selection clipboard` or
`wl-copy`. The skill should detect the clipboard tool at runtime.)

Print the full prompt to the conversation so the user can review it,
then confirm it has been copied:

```
--- Resume prompt (copied to clipboard) ---

[prompt text]

---
✓ Copied to clipboard. Paste into a new Claude Code session to continue.
```

---

## When to use each mode

| Situation                                   | What to include                                               |
|---------------------------------------------|---------------------------------------------------------------|
| Plan written, about to start implementing   | All units pending, key technical decisions from planning      |
| Mid-implementation, context degraded        | Completed units, next unit, surprises found during impl       |
| Debug session got long                      | Root cause so far, what was tried, specific reproduction step |
| Post-review, addressing comments            | PR number, review comments that need fixing, which are done   |

---

## Principles

- The handoff prompt is a **pointer to artifacts**, not a transcript.
  The plan file, git log, and branch state are the source of truth — the
  prompt tells the fresh session where to look.
- **Omit everything the fresh session can discover itself.** If it's in
  the plan file or in git, reference it. Only include things that would
  otherwise be lost when this conversation ends.
- A good handoff prompt fits in one screen. If it doesn't, the session
  has too much undocumented state — consider updating the plan file
  before handing off.
