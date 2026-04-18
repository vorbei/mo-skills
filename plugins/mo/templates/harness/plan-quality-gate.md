# Plan Quality Gate

> Authoritative source for plan rules that `/mo-plan` enforces.
>
> **This file is a template.** Copy into your project's `harness/` dir and
> adjust. The sections below are the minimum contract; add project-specific
> checks as needed.

## 2.0 Plans never committed (HARD RULE)

Plan files written by `/mo-plan` (or `/ce-plan`) MUST land at the absolute
path configured as `planStore` in `mo-config.json`, regardless of which
worktree is currently active. That directory MUST be gitignored.

- Do not write plans into per-task worktrees — they scatter and get deleted on cleanup.
- If you want to share a plan, paste it into a PR description or issue — never commit the file.
- Quality Gate must explicitly confirm "plan file created, not staged".

## 2.1 Required fields

A plan must include each of these, or the Quality Gate fails:

| Field                         | Requirement                                       | Location               |
|-------------------------------|---------------------------------------------------|------------------------|
| `Execution note: test-first`  | On every feature-bearing unit                     | Unit body              |
| `/simplify` unit              | Second-to-last implementation unit                | Implementation Units   |
| `mo-codex review-plan` unit   | Last implementation unit                          | Implementation Units   |
| Issue reference               | In filename and frontmatter when applicable       | Filename / frontmatter |
| Test file path                | On every feature unit                             | `Files:` field         |
| Provenance check              | When introducing any flag or annotation field     | Before Units           |

## 2.2 Quality Gate checklist

Every plan must produce an evidence table covering these items:

- [ ] **Phase 0 coverage**: problem frame, success criteria, scope boundaries
- [ ] **Layered architecture**: each unit names the layers it touches; no cross-layer violations
- [ ] **Machine constraints first**: any new architectural decision creates a lint or test rule in its own unit before code
- [ ] **TDD red light**: every feature unit has a test file path and `Execution note: test-first`
- [ ] **Test layering**: unit tests are at lib/api/stores/hooks granularity as specified in `tdd-and-simplify.md`
- [ ] **Mobile adaptation**: frontend units include mobile checks at the configured `frontend.mobileWidth`
- [ ] **Provenance granularity**: write-time flags are at least as fine-grained as the transformation they record
- [ ] `/simplify` is the second-to-last unit
- [ ] `mo-codex review-plan` is the last unit

**Evidence output (mandatory):** after the plan is written, emit a table with
one row per checklist item, each carrying ✅ / ❌ / N/A plus a line number or
unit reference. Missing evidence = gate not executed.

## 2.3 Depth defaults

| Task type | Default depth |
|-----------|---------------|
| Bug fix   | Lightweight   |
| Feature   | Standard      |
| Refactor  | Standard      |

Override only with a one-line justification in the plan frontmatter.
