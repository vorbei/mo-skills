---
name: mo-codex
description: "Streaming wrapper over the Codex companion runtime. Fast, thin alternative to /codex:rescue that avoids the subagent + skill-loading + foreground-blocking overhead. Use when you want Codex to (a) review a plan document, (b) review the current branch's diff against a base ref, or (c) take over a substantial coding task — and you want output to start streaming within ~1s instead of arriving only after the entire Codex turn finishes. Trigger: 'mo-codex', 'let codex review the plan', 'ask codex to handoff this', 'codex review against dev'."
---

# mo-codex — Streaming Codex wrapper

A thin shell wrapper around `codex-companion.mjs` (the official Codex
Claude Code plugin runtime). It exists for one reason: **early streaming
output**. The `/codex:rescue` subagent path adds 5–15s of subagent +
skill-loading overhead and then blocks foregroundly on the entire Codex
turn before the user sees anything. `mo-codex` skips all of that:

- Direct shell call from the main thread (no subagent indirection).
- Always launches the Codex job with `task --background --json`, so the
  runtime returns within ~1s with `{ jobId, logFile }`.
- Then `tail -f`s the log file so the Codex stream renders as it is
  produced.
- On `Ctrl-C` it cancels the underlying job via
  `codex-companion cancel <jobId>`.

All actual review / task execution still goes through the official
`codex-companion.mjs` — no reimplementation of the Codex protocol.

## Prerequisites

The openai-codex plugin must be installed:

```
/plugin marketplace add anthropics/codex
/plugin install codex
```

`codex-companion.mjs` lives under
`~/.claude/plugins/cache/openai-codex/codex/<ver>/scripts/`. `mo-codex`
picks the latest version automatically.

## When to use

> **Performance note.** Despite the `--background` + streaming design,
> `mo-codex` is slow in practice and the Codex broker frequently
> stalls. **Do not default to `review-code`** for every fix/feature
> pipeline — `/mo-fix` and `/mo-work` now default to
> `ce-code-review mode:headless` for code review and reserve mo-codex
> as an opt-in cross-model gate. `review-plan` is the exception: it
> has no `ce` equivalent for approach-level plan judgment and is
> worth the wait since it runs once per plan, not per commit.

| Scenario | Verb |
|---|---|
| You just wrote a plan with `/mo-plan` and want a second opinion on **whether the approach is the right one** (not on unit sizing, test names, or other implementation details) before `/mo-work` | `review-plan` (primary use — no ce equivalent) |
| Cross-model sanity check on a high-stakes change (security, migration, contract break) before PR — after `ce-code-review` has already run | `review-code` (opt-in only) |
| The current Claude thread is stuck, or the task is open-ended and would burn this thread's context | `handoff` |

For trivial questions or quick edits, do not invoke `mo-codex` — just
answer or edit directly. For routine code review, prefer
`ce-code-review mode:headless`.

## Verbs

```
mo-codex review-plan <plan.md> [--effort low|medium|high] [--wait] [--raw]
mo-codex review-code [--base <ref>] [--since <ref>] [--plan <path>]
                     [--prior-findings <path>] [--max-effort <level>]
                     [--effort ...] [--wait] [--raw]
mo-codex handoff "<task text>" [--base <ref>] [--write|--read-only] [--resume|--fresh] [--effort ...] [--model ...] [--wait] [--raw]
mo-codex warm [cwd]
```

### `review-code` iteration flags

The default `review-code` diffs `origin/<base>...HEAD` and reviews with
no prior context — fine for the first review pass on a branch. On
repeat rounds a few flags keep the review fast and focused:

- `--since <ref>` — diff `<ref>...HEAD` instead of
  `origin/<base>...HEAD`. Pass the SHA of the last-reviewed commit so
  round 2 only sees the work added after round 1. Avoids re-reading
  the full branch on every round; shrinks auto-effort too.
- `--plan <path>` — include a plan file as context. Codex anchors its
  judgment to the plan's **Acceptance Scenarios / Requirements Trace /
  Success Criteria**. Findings outside the plan's stated scope get
  filed as P2 (scope), not as P0/P1 blockers. Cuts scope creep in
  review rounds.
- `--prior-findings <path>` — path to last round's verdict text. Codex
  tags each finding `[NEW]` or `[REPEAT: <prior ref>]` and is
  instructed to prefer P2 / NITS for repeats the author consciously
  declined. Defaults to `./.mo-codex-prior.md` if that file exists, so
  saving the previous verdict as that filename makes iteration
  automatic.
- `--max-effort low|medium|high` — cap the auto-selected effort. Use
  when a PR has a big line count (rename / mass refactor) but the
  actual review scope is small. `--max-effort medium` trades thinking
  depth for turnaround.

Severity schema the prompt now enforces: every finding is tagged
**[P0]** (blocks landing), **[P1]** (should fix before merge, arguable),
or **[P2]** (nice-to-have). Verdict is driven by the highest severity:
`BLOCK` / `CHANGES REQUESTED` / `NITS` / `LGTM`.

**Relay voice (calling skill's responsibility).** `mo-codex` prints
the raw finding list and verdict — that is for the calling agent, not
the user. When the calling skill (`/mo-fix`, `/mo-work`, `/mo-plan`)
forwards findings to the user, it must pre-digest per
`../../references/decision-voice.md`: apply uncontroversial P1/P2 findings
silently, reject NITS you disagree with silently, and escalate only
the subset where the user's preference materially changes the fix —
each framed as a user/product outcome with a leading recommendation.
Do not paste the raw `[P1] 1. … 2. … 3. …` block into the user-facing
conversation.

### Broker pre-flight

Every invocation sweeps dead broker dirs under
`/var/folders/*/*/T/cxc-*/` and `/tmp/cxc-*/` before submitting the
job. A pidfile pointing at a non-existent PID marks a zombie from a
previous interrupted session; those queued behind real brokers and
silently stalled new jobs in prior versions. Live brokers are never
touched.

`warm` prewarms the per-cwd Codex broker without submitting a task.
Idempotent (no-op if already alive). Does not consume Codex credit. Call
it right after creating a new worktree so the first real `mo-codex ...`
in that worktree skips the 1–3s broker spawn. `/mo-plan` invokes this
automatically after creating standard/deep worktrees.

- `--base` defaults to `origin/<base.default>` from `mo-config.json`
  (falling back to `origin/dev` if no config). **Never a plain local
  branch name** — local refs are frequently stale after rebases and
  produce phantom diffs. The script auto-runs
  `git fetch origin <base>` before building the diff prompt for
  `review-code`. Pass `--base main` (or whatever `base.emergency` is
  configured to) only for emergency fixes.
- `--effort` is **auto-selected** when you do not pass it explicitly:
  - `review-plan`: plan file ≥100 lines → `medium`, else `low`.
  - `review-code`: `git diff --shortstat <base>...HEAD` total
    additions+deletions — <50 → `low`, <500 → `medium`, else `high`.
  - `handoff`: unset (Codex picks).
  The chosen effort is printed to stderr as
  `mo-codex: auto-effort=… (…)`. Pass `--effort` to override.
- `--wait` runs the Codex command in foreground mode. No streaming; you
  only see the final result. Use this when you want a single clean
  final answer to capture, or when the caller really needs a blocking
  call.
- `--raw` disables the stream filter so you see the raw
  `codex-companion` log. Default mode pipes through `format-stream.mjs`,
  which drops low-signal lines, highlights block titles, and emits a
  `· Ns elapsed, still running...` heartbeat every 15s of idle output.
- `--resume` adds `--resume-last` so Codex picks up the last task thread
  for this workspace. `--fresh` is the default.
- `handoff` defaults to write-capable (`--write`); pass `--read-only`
  for diagnosis-only handoffs.

## How to invoke

The main Claude thread runs the script directly via `Bash`. **Do not**
wrap this in `/codex:rescue` or any other subagent — the whole point is
to skip that layer.

```bash
<plugin-root>/skills/mo-codex/mo-codex.sh review-plan <plan.md>
<plugin-root>/skills/mo-codex/mo-codex.sh review-code --base origin/dev
<plugin-root>/skills/mo-codex/mo-codex.sh handoff "Refactor the dock store to drop getState() inside render callbacks."
```

`<plugin-root>` is the installed plugin directory (usually
`~/.claude/plugins/cache/<marketplace>/mo-skills/`). The skill front-end
resolves this automatically; only the script path matters if you invoke
it from a bash command.

stdout streams the Codex turn's progress events (filtered unless
`--raw`). After the job terminates, the script extracts the verdict
line (`LGTM` / `NITS` / `CHANGES REQUESTED` / `BLOCK` /
`APPROACH SOUND` / `APPROACH NEEDS ADJUSTMENT` / `RETHINK APPROACH`)
and prints it on a `═══ VERDICT: … ═══` banner to stderr before dumping
the full final result.

## What it does NOT do

- It does **not** call `codex review` / `codex adversarial-review`
  natively. Those code paths only support foreground execution in
  `codex-companion.mjs`, so they cannot stream. `mo-codex review-code`
  instead uses `task --background` with a review prompt that asks Codex
  to run `git diff <base>...HEAD` itself. If you specifically need the
  native review tooling, call `codex review` directly.
- It does **not** start the stop-time review gate. That gate is
  disabled by default and should stay disabled
  (`/codex:setup --disable-review-gate`).
- It does **not** reshape or "improve" the user's prompt with another
  LLM pass. The verb-specific prompt template is fixed and English-only.

## Failure modes

- If `~/.claude/plugins/cache/openai-codex/codex/` is missing or empty,
  the script exits 2 with a clear message — install the openai-codex
  plugin first.
- If the Codex auth has expired, the background job will fail almost
  immediately. The tail will show the failure and the final `result`
  block will explain. Run `/codex:setup` to re-auth.
- If the Codex broker for the cwd is missing, the first call will spawn
  one (~1–3s extra). Subsequent calls in the same workspace reuse it.
