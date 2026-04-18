# mo-skills

Opinionated planning + TDD + handoff skills for Claude Code. A thin, configurable
overlay on top of [compound-engineering](https://github.com/every/every-marketplace)
and the [openai-codex](https://github.com/anthropics/codex) plugins.

Ships five skills:

| Skill | What it does |
|---|---|
| `mo-plan` | Writes an implementation plan to a gitignored plan store, enforces a Quality Gate with on-disk evidence, and ends every plan with a `/simplify` unit plus a Codex plan review. |
| `mo-work` | Executes a plan with strict red-green TDD (two independent runs required), resumes from `- [x]` checkpoints, and routes PR review through `mo-codex review-code`. |
| `mo-clean` | Verifies the current worktree branch is merged, captures session learnings into Claude's auto-memory (ce:compound-style), moves any linked tracker issue to its review state, then removes the worktree and branch. |
| `mo-codex` | Streaming shell wrapper over `codex-companion.mjs`. Streams within ~1s instead of blocking on the full Codex turn. Three verbs: `review-plan`, `review-code`, `handoff`. |
| `mo-handoff` | Compresses the current session into a self-contained resume prompt, copied to your clipboard. |

## Install

```
/plugin marketplace add vorbei/mo-skills
/plugin install mo@mo-skills
```

### External dependencies

`mo-plan` and `mo-work` are *overlays* on `ce:plan` / `ce:work`, and
`mo-clean` borrows the `ce:compound` methodology. `mo-codex` requires the
openai-codex plugin.

```
/plugin marketplace add every/every-marketplace
/plugin install compound-engineering

/plugin marketplace add anthropics/codex
/plugin install codex
```

## Configure

All five skills read `mo-config.json`. Resolution order (first match wins):

1. `$CLAUDE_PROJECT_DIR/.claude/mo-config.json`
2. `$PWD/.claude/mo-config.json`
3. `~/.claude/mo-config.json`

Start from one of the bundled examples:

```bash
# Find the installed copy (version suffix may vary)
PLUGIN_ROOT=$(ls -d ~/.claude/plugins/cache/mo-skills/mo/*/ | tail -1)

# Minimal config — adjust paths, then save as .claude/mo-config.json
cp "$PLUGIN_ROOT/config/mo-config.minimal.json" .claude/mo-config.json

# Full example showing every key
cp "$PLUGIN_ROOT/config/mo-config.example.json" .claude/mo-config.json
```

### Keys

| Key | Required | Notes |
|---|---|---|
| `project.name` | no | Shown in prompts; defaults to repo basename |
| `project.primaryRepo` | no | Absolute path to the main git repo |
| `planStore` | **yes** | Absolute dir for plan files. **Must be gitignored.** |
| `harnessDir` | no | Dir containing `DECISIONS.md`, `protocols.md`, `plan-quality-gate.md`, `tdd-and-simplify.md`, `frontend.md`. If absent, skills read from the bundled `templates/harness/`. |
| `commands.test` | no | Default `pnpm test` |
| `commands.typecheck` | no | Default `pnpm typecheck` |
| `commands.archLint` | no | Empty string disables the arch-lint gate |
| `commands.extraLinters` | no | e.g. `["uvx ruff check --fix", "uvx ruff format"]` |
| `issueTracker.type` | no | `linear` / `github` / `jira` / `none` (default) |
| `issueTracker.prefix` | no | e.g. `MAX` → matches `MAX-123` in branch names |
| `issueTracker.apiKeyEnv` | no | e.g. `LINEAR_API_KEY` |
| `issueTracker.reviewState` | no | Default `In Review` |
| `branchNaming.bugfix` | no | Template, default `fix/{issue}-{slug}` |
| `branchNaming.feature` | no | Template, default `feat/{slug}` |
| `base.default` | no | Default `dev` |
| `base.emergency` | no | Default `main` |
| `frontend.enabled` | no | Default `false`. When `true`, `mo-work` enforces design-doc reads, mobile viewport checks, and the container/view split. |
| `frontend.designDocs` | no | Paths (relative to `primaryRepo`) of design docs to read before frontend units |
| `frontend.mobileWidth` | no | Default `375` |
| `frontend.containerCheckCommand` | no | e.g. `pnpm test -- src/components/architecture.test.ts` |
| `frontend.containerGlob` | no | e.g. `client/webapp/src/components/**/*.tsx` |
| `commitScopes` | no | Array of valid Conventional Commit scopes |
| `protectedWorktrees` | no | Absolute paths `mo-clean` refuses to delete |
| `envFile` | no | Default `~/.claude/.env`. Sourced before external API calls. |
| `language.artifacts` | no | Default `English` |
| `language.conversation` | no | Default `English` |

Full schema: `config/mo-config.schema.json`.

## Philosophy

- **Plans never committed.** They live at `planStore`, which must be
  gitignored. Shareable via PR description or issue, not as a commit.
- **Red/green TDD is two independent runs.** Subagent self-reports of
  "tests pass" without command output are unreliable.
- **Architecture is enforced statically.** `commands.archLint` runs on
  every `/simplify` and acts as a hard gate.
- **Codex review is streamed, not delegated.** `mo-codex` skips the
  subagent indirection so output appears within ~1s.
- **English for artifacts, the user's language for conversation.**
  Controlled by `language.{artifacts,conversation}`.

## Customising the harness

The bundled `templates/harness/` files (`DECISIONS.md`, `protocols.md`,
`plan-quality-gate.md`, `tdd-and-simplify.md`, `frontend.md`,
`self-revision.md`) are starting points. Copy them into your project
(typically under `<repo>/harness/`), point `harnessDir` at that
directory in `mo-config.json`, and replace the example decisions with
your team's real ones.

Both `mo-plan` and `mo-work` read those files every run — they are the
authority your skills enforce. Keeping them in version control is a
good idea; the skills do not require it.

## Typical loop

```
idea
  → /mo-plan       (writes plan to $planStore, passes Quality Gate, runs mo-codex review-plan)
  → /mo-work       (strict TDD, resumes from checkpoints, ends with /simplify)
  → /mo-codex review-code --base origin/<base.default>
  → user confirms → PR
  → /mo-clean      (after merge: capture learnings, remove worktree + branch)
```

Switch threads midway? `/mo-handoff` copies a tight resume prompt to your
clipboard.

## Development

```bash
git clone https://github.com/vorbei/mo-skills.git ~/vorbei/mo-skills

# Install from local path for testing
claude plugin marketplace add ~/vorbei/mo-skills
claude plugin install mo@mo-skills

# Or validate without installing
claude plugin validate ~/vorbei/mo-skills
claude plugin validate ~/vorbei/mo-skills/plugins/mo
```

## License

MIT © vorbei
