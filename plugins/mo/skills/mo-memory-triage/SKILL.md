---
name: mo-memory-triage
description: "Periodic triage of accumulated feedback memory files. Cluster by topic and shared file paths, mark obsolete feedbacks as anti-pattern (preserved with reason, not deleted) so the institutional 'why we don't do this anymore' lesson survives. Use when asked to 'triage memory', 'review feedback memory', 'clean up memory', 'memory triage', 'mo-memory-triage', or after a major refactor that may have invalidated old guidance."
argument-hint: "[optional: path to a specific memory dir; default resolved from current repo]"
---

# Mo Memory Triage

Walk the user through a periodic review of accumulated `feedback_*.md`
memory files in the Claude Code per-project memory dir. Cluster by
signal, surface candidates, let the user mark anti-patterns. Never
delete: anti-pattern entries are preserved as first-class memory so the
lesson *"we tried this, it didn't work, here's why"* outlives the
original feedback.

## Input

<target> #$ARGUMENTS </target>

If the user passed a directory path, treat it as `MEMORY_DIR`. Otherwise
compute it from the current repo root:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -n "$REPO_ROOT" ]]; then
  MEMORY_DIR=~/.claude/projects/$(echo "$REPO_ROOT" | sed 's|/|-|g; s|^-||')/memory
else
  echo "No git repo detected. Pass an explicit memory dir as \$ARGUMENTS." >&2
  exit 2
fi
```

Abort with a clear message if `$MEMORY_DIR` does not exist — the user is
probably in the wrong directory or hasn't built up any memory for this
project yet.

---

## Step 1 — Preflight: existing index integrity

If the memory dir carries a `check-index.sh` validator, run it first.
If it fails, the catalog is already broken and triage cannot reason
about state — fix the catalog first.

```bash
[[ -x "$MEMORY_DIR/check-index.sh" ]] && bash "$MEMORY_DIR/check-index.sh"
```

Expect exit 0. If non-zero, tell the user *exactly* which invariant
failed and stop — do not continue to Step 2. If the validator is
absent, note that to the user and proceed; the rest of the workflow
does not depend on it.

---

## Step 2 — Bootstrap status frontmatter (only if needed)

Run the cluster report and read the "Status distribution" block. The
bundled scripts live alongside this SKILL.md at `scripts/`; invoke them
relative to this skill's directory:

```bash
MEMORY_DIR="$MEMORY_DIR" bash "$(dirname "$0")/scripts/triage-cluster.sh"
```

(In practice the skill runner resolves `$0` to the SKILL.md's own
directory; adjust if your runner exposes a different variable.)

If `(missing status): 0` — skip to Step 3.

If `(missing status): N > 0` — tell the user:

> "N feedback files lack a `status:` field. Run `bootstrap-status.sh`
> to add `status: active` to all of them? (yes / no)"

On `yes`:

```bash
MEMORY_DIR="$MEMORY_DIR" bash "$(dirname "$0")/scripts/bootstrap-status.sh"
```

Re-run `triage-cluster.sh`; verify `(missing status): 0`. If any file
was warned to stderr (no proper frontmatter), surface those filenames
to the user as triage candidates that need manual frontmatter fix
before they can be classified.

---

## Step 3 — Render the cluster report

Display the full output of `triage-cluster.sh` to the user. The report
has four sections:

1. **Status distribution** — total counts.
2. **Clusters by filename prefix** — same-topic feedback families
   (e.g. all `codex_*` together).
3. **Clusters by shared file-path mention** — different feedbacks
   talking about the same source file. *Often where conflicts hide.*
4. **Anti-patterns (current)** — feedbacks already marked.

---

## Step 4 — Guided cluster walk

For each multi-member cluster (prefix or file-path), ask the user
**one question per cluster**:

> "In the `codex_*` cluster (4 members), is anything superseded,
> conflicting, or anti-pattern? Reply with filenames to mark, or
> `skip` to move on."

If the user lists files, for each file:

1. **Read the feedback** end to end so you can frame the next question.
2. Ask:
   > "What's the reason this is now anti-pattern? (one to two
   > sentences — the 'we tried this and learned X' record)"
3. Ask:
   > "Is there a successor feedback that supersedes this one?
   > (filename, or `none`)"
4. **Edit the file's frontmatter** via the `Edit` tool:
   - **Change** the existing `status: active` line to
     `status: anti-pattern` (use Edit's exact-match replace; do not
     insert a second status line).
   - **Insert** the new metadata immediately before the closing `---`:
     ```
     deprecated: <today YYYY-MM-DD>
     superseded_by: <filename or omit if none>
     reason: <one-line user-provided reason — preserve exact wording>
     ```

5. **Insert a body banner** immediately after the closing `---` so an
   agent that reads the file directly (skipping frontmatter) cannot
   mistake it for active guidance. Insert literally these two lines as
   the first content under the frontmatter:
   ```
   > ⚠️ **ANTI-PATTERN — DO NOT FOLLOW.** Superseded by `<successor or "no successor">`.
   > Reason: <one-line user-provided reason>
   ```

Repeat for every cluster. Do not push the user; if they reply `skip`,
move on without nagging.

---

## Step 5 — Regenerate indexes

Once all decisions for this session are recorded:

```bash
MEMORY_DIR="$MEMORY_DIR" bash "$(dirname "$0")/scripts/regen-indexes.sh"
```

This rewrites:
- `MEMORY-feedback.md` (active entries only; legacy plain-text section
  preserved verbatim)
- `MEMORY-antipattern.md` (table of anti-patterns with reason +
  superseded_by)

---

## Step 6 — Validate

Re-run the index validator if one exists:

```bash
[[ -x "$MEMORY_DIR/check-index.sh" ]] && bash "$MEMORY_DIR/check-index.sh"
```

If it fails, surface the exact failing invariant and ask the user how
to proceed (typically: undo the most recent `Edit` or fix a typo in the
frontmatter you just inserted).

---

## Step 7 — Summary

Tell the user:

> "Marked N feedback(s) as anti-pattern. `MEMORY-antipattern.md`
> updated; `MEMORY-feedback.md` regenerated. All check-index
> invariants PASS."

If anything was deferred or skipped, list those clusters by name so the
user knows what they postponed.

---

## Topic tags (optional but encouraged)

Feedbacks that belong to the same feature/flow can carry a `topics:`
field in their frontmatter to make them recall together:

```yaml
---
name: ...
status: active
topics: [post-login-handoff]   # inline YAML list; kebab-case
---
```

`triage-cluster.sh` reports a "Clusters by topic tag" section so these
groups are discoverable during review. Topics are emergent (no
registry): coin a new one when a second feedback shares a flow with an
existing standalone, back-tag the original. Multi-tag is allowed
(`topics: [post-login-handoff, auth]`).

During Step 4's guided cluster walk, if a cluster's members clearly
belong to a named flow, offer to tag them — one small frontmatter edit
per file, no status change. Singletons are surfaced as "possible typo
or seed for a future cluster" in the report.

## Conventions

- **Never delete** a `feedback_*.md` file. Anti-pattern is the only
  retirement.
- **Reason field is mandatory** when flipping `active → anti-pattern`.
  Without the *why*, the file becomes another piece of clutter; with
  it, it becomes institutional memory.
- **Be conservative.** If the user is unsure whether a feedback is
  truly superseded, leave it `active`. False anti-patterns silently
  mislead future agents in the opposite direction.
- **Manual trigger only.** This skill never schedules itself. Run when
  memory feels noisy, after a major refactor, or as a periodic monthly
  hygiene pass.

## Common cluster patterns to look for

- **Same library, different angles** — e.g. `radix_*` (z-index issue +
  overlay pointer-events): probably both still active and
  complementary, not conflicting.
- **Old vs new** — e.g. older `landing_*` feedback advocating
  conservatism vs newer project entries about an aggressive redesign
  that shipped: candidate for anti-pattern (old advice no longer
  applies).
- **Duplicate/near-duplicate** — e.g. two feedbacks about the same
  file, written months apart with overlapping content: keep the more
  complete one active, mark the other as anti-pattern with
  `superseded_by:`.

## What's next

| Situation | Skill |
|-----------|-------|
| Implementing a new feature | `/mo-plan` then `/mo-work` |
| Fixing a bug | `/mo-fix` |
| Cleaning up a finished worktree | `/mo-clean` |
