# TDD Execution + /simplify

> Authoritative source for TDD evidence rules and the mandatory `/simplify`
> step that `/mo-work` enforces.
>
> **This file is a template.** Copy into your project's `harness/` dir. The
> shell commands below come from `mo-config.json → commands.*` — adjust the
> config, not this file, if your project uses different tooling.

## 3. TDD execution

### 3.1 Red / green evidence — two independent runs

Red and green must be **two independent executions**, not two screenshots of
the same run.

```
1. Write the test file
2. <commands.test>             → confirm FAIL (paste tail output)
3. Implement the code
4. <commands.test>             → confirm PASS (paste tail output)
5. <commands.typecheck> && <commands.archLint>
```

When delegating TDD to a subagent, require verbatim command output for both
red and green phases. A self-report of "tests pass" without command output is
unreliable and must be re-run.

### 3.2 Implementation choices

For **parsing / transformation modules** (Markdown, HTML, JSON schema, etc.),
prefer a mature parser library over a hand-rolled regex pipeline. Hand-rolled
regex can pass TDD's happy path but long-tail LLM / user input breaks in
production. The plan's Key Technical Decisions should name the library or
justify why a hand-rolled approach is acceptable here.

### 3.3 Common mistakes

- **Polling:** use `setTimeout` chains with backoff. Never `setInterval` —
  it stacks calls when the previous request has not finished.
- **Provenance flags:** write-time flags must be at least as fine-grained as
  the transformation they record. A "per-message" flag cannot identify which
  element inside the message was transformed — this is an irreversible data
  decision and must be resolved at plan time.

### 3.4 Test layering

Default layering (adjust per project):

| Layer            | Test type                       | File extension |
|------------------|---------------------------------|----------------|
| lib/             | Pure-function unit tests        | `.test.ts`     |
| api/             | Protocol / schema unit tests    | `.test.ts`     |
| stores/          | State unit tests                | `.test.ts`     |
| hooks/           | Behaviour unit tests            | `.test.ts`     |
| components/      | No render tests — lift logic    | `.test.ts`     |
| Architecture     | Static audit tests              | `.test.ts`     |
| E2E              | Project-specific runner         | —              |

## 4. /simplify — MANDATORY

Every plan ends with a `/simplify` unit. It is not optional.

```bash
<commands.test> && <commands.archLint>   # Before simplify: must be fully green
# Run /simplify
<commands.test> && <commands.archLint>   # After simplify: must still be fully green
```

If `/simplify` was skipped during execution, run it before code review.
