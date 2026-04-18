---
name: mo-clean
description: "Check if the current worktree branch has been merged into its base, document any learnings via the ce:compound methodology, move any linked tracker issue to its review state, then remove the worktree and its branch. Use when asked to 'clean up this worktree', 'mo-clean', 'close this branch', or 'done with this task'."
argument-hint: "[optional: worktree path if not in a worktree already]"
---

# Mo Clean

Close out a completed worktree: verify it is merged, capture learnings,
then delete the local worktree and branch.

## Config

```bash
for p in "${CLAUDE_PROJECT_DIR:-}/.claude/mo-config.json" \
         "$PWD/.claude/mo-config.json" \
         "$HOME/.claude/mo-config.json"; do
  [[ -f "$p" ]] && { MO_CONFIG="$p"; break; }
done

BASE_DEFAULT=$(jq -r '.base.default // "main"' "${MO_CONFIG:-/dev/null}")
BASE_EMERG=$(jq -r '.base.emergency // ""' "${MO_CONFIG:-/dev/null}")
TRACKER_TYPE=$(jq -r '.issueTracker.type // "none"' "${MO_CONFIG:-/dev/null}")
ISSUE_PREFIX=$(jq -r '.issueTracker.prefix // empty' "${MO_CONFIG:-/dev/null}")
TRACKER_KEY_ENV=$(jq -r '.issueTracker.apiKeyEnv // empty' "${MO_CONFIG:-/dev/null}")
REVIEW_STATE=$(jq -r '.issueTracker.reviewState // "In Review"' "${MO_CONFIG:-/dev/null}")
ENV_FILE=$(jq -r '.envFile // "~/.claude/.env"' "${MO_CONFIG:-/dev/null}")
# Expand ~ in ENV_FILE
ENV_FILE="${ENV_FILE/#\~/$HOME}"
# Protected worktrees, newline-separated
PROTECTED_WORKTREES=$(jq -r '.protectedWorktrees[]? // empty' "${MO_CONFIG:-/dev/null}")
```

## Input

<target> #$ARGUMENTS </target>

If empty, use the current working directory to detect the active worktree.

---

## Step 1 — Identify the worktree

```bash
BRANCH=$(git branch --show-current)
WORKTREE_PATH=$(git rev-parse --show-toplevel)
REPO_ROOT=$(git worktree list | head -1 | awk '{print $1}')
```

If `WORKTREE_PATH` equals `REPO_ROOT`, the user is in the main worktree — not
a feature worktree. Stop and tell the user: "You are in the main worktree.
Run this from inside the feature worktree you want to clean."

If `WORKTREE_PATH` matches any line in `$PROTECTED_WORKTREES`, stop with the
same message.

---

## Step 2 — Verify merged status

Check against both configured base branches:

```bash
for BASE in "$BASE_DEFAULT" "$BASE_EMERG"; do
  [[ -z "$BASE" ]] && continue
  git -C "$REPO_ROOT" branch --merged "$BASE" | grep -q "$BRANCH" && echo "merged:$BASE"
done

gh pr list --head "$BRANCH" --state merged --json number,mergedAt,baseRefName 2>/dev/null
```

**Decision logic:**

| Signal                                                                 | Action                                    |
|------------------------------------------------------------------------|-------------------------------------------|
| Branch merged into any base branch                                     | Proceed to Step 3                         |
| PR shows `merged` state                                                | Proceed to Step 3                         |
| Uncommitted changes exist (`git status --short` is non-empty)          | Stop — tell user to commit or stash first |
| Branch not merged, no merged PR                                        | Stop — show status, ask for confirmation  |

For force-clean (user explicitly confirms on an unmerged branch): skip
Step 3 (no learnings to compound if the work is being abandoned), go
directly to Step 4.

---

## Step 3 — Capture learnings as Claude memory

Preserve institutional knowledge from this worktree session. Same
methodology as `ce:compound` — parallel agents to extract context and
solutions — but write the results into Claude's auto-memory system.

### 3a — Locate the memory directory

```bash
MEMORY_DIR=~/.claude/projects/$(echo "$REPO_ROOT" | sed 's|/|-|g; s|^-||')/memory
```

Read `$MEMORY_DIR/MEMORY.md` to understand what is already documented.
Avoid duplicating existing entries.

### 3b — Run parallel research (ce:compound Phase 1 methodology)

Launch two subagents in parallel. Each returns **text data only** — no
file writes:

**Context Analyzer**
- Review the conversation history for this worktree session
- Identify the problem type, component, and decisions made
- Classify each learning by Claude memory type:
  - `feedback` — corrected assumptions, validated patterns, workflow guidance
  - `project` — decisions, constraints, stakeholder context, deadlines
  - `reference` — pointers to external resources (tickets, runbooks, dashboards)
- Return: a list of candidate memory entries, each with `type`, `name`,
  `description`, and body content

**Solution Extractor**
- Extract non-obvious workarounds, root causes, and prevention strategies
  from the session
- Focus on what a future developer or Claude instance would NOT discover
  by reading the code alone
- Ignore trivial changes (typo fixes, copy-paste, obvious renames)
- Return: distilled body content for each candidate entry — `feedback`
  entries use `rule → **Why:** → **How to apply:**`; `project` entries use
  `fact → **Why:** → **How to apply:**`; `reference` entries are a single
  descriptive sentence with a path or URL.

### 3c — Assemble and write memory files

For each candidate entry:

1. Check whether a file with the same slug already exists in `$MEMORY_DIR/`.
   If yes, read and update in place; otherwise create a new file.
2. Write (or update) `$MEMORY_DIR/<type>_<slug>.md` with frontmatter:

```markdown
---
name: <short descriptive title>
description: <one-line hook used to decide relevance in future conversations>
type: feedback | project | reference
---

<body content from Solution Extractor>
```

3. Append a one-line pointer to `$MEMORY_DIR/MEMORY.md` under the
   matching section heading (`## Feedback`, `## Project — Active`, or
   `## Reference`). Each line ≤150 chars:

```
- [Title](filename.md) — one-line hook matching the description field
```

Never write content directly into `MEMORY.md`.

If nothing qualifies, note "Nothing to capture: straightforward change"
and skip to Step 4.

---

## Step 4 — Kill services bound to the worktree

Before removing the worktree directory, find and stop any processes (dev
servers, vite, node, etc.) started from inside it.

```bash
LISTEN_PIDS=$(lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk 'NR>1 {split($9,a,":"); ports[$2]=ports[$2] a[length(a)] ","; name[$2]=$1} END {for(p in ports) print p, name[p], ports[p]}')

echo "$LISTEN_PIDS" | while read pid name ports; do
  args=$(ps -p "$pid" -o args= 2>/dev/null || true)
  echo "$args" | grep -q "$WORKTREE_PATH" && echo "PID $pid | $name | port(s): ${ports%,} | $args"
done
```

Processes found → show list, kill (`kill <pid>`, fallback `kill -9` after 3s).
Dev servers started from the worktree are always safe to kill without extra
confirmation — the worktree is being removed.

---

## Step 5 — Remove the worktree and branch

```bash
cd "$REPO_ROOT"
git worktree remove "$WORKTREE_PATH"
# If dirty and user already confirmed force-clean:
# git worktree remove --force "$WORKTREE_PATH"

git branch -d "$BRANCH"
# If -d fails with "not fully merged" and Step 2 passed via merged PR, use -D:
# git branch -D "$BRANCH"

git worktree prune
git remote prune origin 2>/dev/null || true
```

---

## Step 6 — Update linked tracker issue to review state

If the branch name carries an issue ID matching `${ISSUE_PREFIX}-\d+`,
move that issue to `$REVIEW_STATE`. Skip silently if no match or if
`TRACKER_TYPE=none`.

Rationale: the PR has landed (Step 2 confirmed merged) but product
verification may still be pending. `$REVIEW_STATE` — not `Done` — is the
correct signal; the human closing the loop moves it to `Done` once
they've verified the fix in the running product.

### Linear (`tracker.type == "linear"`)

```bash
[[ -f "$ENV_FILE" ]] && { set -a && source "$ENV_FILE" && set +a; }
TRACKER_KEY="${!TRACKER_KEY_ENV:-}"
ISSUE_ID=$(echo "$BRANCH" | grep -oE "${ISSUE_PREFIX}-[0-9]+" | head -1)

if [[ -n "$ISSUE_ID" && -n "$TRACKER_KEY" ]]; then
  STATE_ID=$(curl -s -X POST https://api.linear.app/graphql \
    -H "Content-Type: application/json" \
    -H "Authorization: $TRACKER_KEY" \
    -d "{\"query\": \"{ issue(id: \\\"$ISSUE_ID\\\") { team { states { nodes { id name } } } } }\"}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(next(s['id'] for s in d['data']['issue']['team']['states']['nodes'] if s['name']=='$REVIEW_STATE'))")

  curl -s -X POST https://api.linear.app/graphql \
    -H "Content-Type: application/json" \
    -H "Authorization: $TRACKER_KEY" \
    -d "{\"query\": \"mutation { issueUpdate(id: \\\"$ISSUE_ID\\\", input: { stateId: \\\"$STATE_ID\\\" }) { success issue { identifier state { name } url } } }\"}"
fi
```

Other trackers: swap the curl calls for the tracker's API. Keep the same
decision matrix.

**Decision logic:**

| Signal                                                   | Action                                   |
|----------------------------------------------------------|------------------------------------------|
| Branch has no matching issue token                       | Skip silently                            |
| `TRACKER_KEY` missing from env                           | Warn user, skip — do not block cleanup   |
| Issue already at review state, done, or cancelled        | Leave as-is                              |
| State-ID lookup fails                                    | Warn user with available state names     |

Report the resulting state and tracker URL in Step 7's summary.

---

## Step 7 — Return to a clean state

```bash
cd "$REPO_ROOT"
git worktree list
```

Tell the user:
- What was removed (branch name + worktree path)
- What memory entries were written (file names + one-line descriptions,
  or "nothing to capture")
- Tracker state transition, or "no issue linked"
- Where they are now (repo root path)

---

## Safety rules

- Never `--force` remove a worktree with uncommitted changes without
  explicit per-file confirmation.
- Never delete a path listed in `protectedWorktrees`.
- Never skip ce:compound unless the user explicitly says "skip learning
  capture" or the branch is being abandoned.
- Never delete the remote branch — leave that to PR merge automation or
  the user.

## What's next

| Situation | Action |
|-----------|--------|
| More open worktrees visible | Pick the next task from the list |
| All worktrees clean | Start from `git worktree list` in repo root |
| New learning captured | Consider refreshing related docs |
