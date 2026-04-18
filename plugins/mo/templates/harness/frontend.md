# Frontend + E2E

> Authoritative source for frontend rules when `frontend.enabled: true` in
> `mo-config.json`. If your project has no frontend, delete this file and
> set `frontend.enabled: false`.

## 7. Frontend change rules

When a change touches frontend source (components, routes, hooks with UI
dependencies), `/mo-work` will enforce the following:

1. **Read design docs first.** Every file listed under `frontend.designDocs`
   in `mo-config.json` must be read before implementing a frontend unit.
   Typically one token/style doc and one UX principles doc.
2. **Token audit.** No hardcoded colors, spacing, radii, or font sizes.
   Mobile font sizes must use semantic tokens — no ad-hoc pixel overrides.
   Provide a `scripts/audit-tokens.sh` (or equivalent) and call it from the
   project's lint flow.
3. **Mobile verification.** Every new or modified UI surface must be
   verified at the viewport width configured as `frontend.mobileWidth`
   (default: 375px). Portals / floating windows / popups use the project's
   `Adaptive`-style wrapper.
4. **Container / view separation (hard check).** When a commit touches the
   glob configured as `frontend.containerGlob`, run
   `frontend.containerCheckCommand` before marking the unit complete. Do
   not rely on global green — the container check is a dedicated gate.
   Container files should not inline JSX; JSX lives in the view file.
5. **E2E coverage.** Behaviour verification goes through the project's E2E
   runner; unit tests cover pure logic extracted out of components.

## 8. E2E (entry point only)

Full rules live in the project's E2E directory (e.g. `e2e/CLAUDE.md` and
`e2e/AGENTS.md`). `/mo-e2e` (separate skill) wraps run / write / debug
modes and includes safety gates and fallback behaviour.

Example runner invocation:

```bash
cd <project-e2e-dir>
<project-e2e-command> --all flows/smoke/
```
