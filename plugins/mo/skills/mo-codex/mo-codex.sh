#!/usr/bin/env bash
# mo-codex — thin streaming wrapper over codex-companion.mjs
#
# Verbs:
#   review-plan <plan.md> [--effort low|medium|high] [--wait]
#   review-code [--base <ref>] [--since <ref>] [--plan <path>]
#               [--prior-findings <path>] [--max-effort <level>]
#               [--effort ...] [--wait]
#   handoff <"task text"> [--base <ref>] [--write|--read-only] [--resume|--fresh] [--effort ...] [--model ...] [--wait]
#   warm [cwd]
#
# Default mode is background + tail-the-logfile so output streams as it is produced.
# --wait runs the codex-companion command in foreground (no streaming, single final dump).
#
# Always uses the latest installed codex-companion under
# ~/.claude/plugins/cache/openai-codex/codex/<ver>/scripts/codex-companion.mjs

set -u
set -o pipefail

CODEX_ROOT="${HOME}/.claude/plugins/cache/openai-codex/codex"
COMPANION=""
if [[ -d "${CODEX_ROOT}" ]]; then
  LATEST=$(ls "${CODEX_ROOT}" 2>/dev/null | sort -V | tail -1)
  if [[ -n "${LATEST}" ]]; then
    COMPANION="${CODEX_ROOT}/${LATEST}/scripts/codex-companion.mjs"
  fi
fi

if [[ -z "${COMPANION}" || ! -f "${COMPANION}" ]]; then
  echo "mo-codex: cannot find codex-companion.mjs under ${CODEX_ROOT}" >&2
  echo "mo-codex: install the openai-codex plugin first: /plugin marketplace add anthropics/codex" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${SCRIPT_DIR}/format-stream.mjs"

usage() {
  sed -n '2,16p' "$0" >&2
  exit 2
}

# Load a value from mo-config.json by jq path. Config resolution order:
#   1. $CLAUDE_PROJECT_DIR/.claude/mo-config.json
#   2. $PWD/.claude/mo-config.json
#   3. $HOME/.claude/mo-config.json
# Returns $2 (default) if no config or key missing.
load_config_value() {
  local key="$1" default="$2"
  local config_paths=(
    "${CLAUDE_PROJECT_DIR:-}/.claude/mo-config.json"
    "${PWD}/.claude/mo-config.json"
    "${HOME}/.claude/mo-config.json"
  )
  if ! command -v jq >/dev/null 2>&1; then
    echo "${default}"
    return
  fi
  for p in "${config_paths[@]}"; do
    if [[ -n "$p" && -f "$p" ]]; then
      local v
      v=$(jq -r "${key} // empty" "$p" 2>/dev/null)
      if [[ -n "$v" && "$v" != "null" ]]; then
        echo "$v"
        return
      fi
    fi
  done
  echo "${default}"
}

# Walk up from $1 to find a directory that contains `.git`. Echoes the path,
# or empty if none found. This matters because some setups invoke mo-codex
# from a non-git "container" dir and every subsequent git command would exit 128.
resolve_git_root() {
  local start="${1:-$PWD}"
  local dir
  if [[ -f "${start}" ]]; then
    dir=$(cd "$(dirname "${start}")" 2>/dev/null && pwd)
  else
    dir=$(cd "${start}" 2>/dev/null && pwd)
  fi
  while [[ -n "${dir}" && "${dir}" != "/" ]]; do
    if [[ -e "${dir}/.git" ]]; then
      echo "${dir}"
      return 0
    fi
    dir=$(dirname "${dir}")
  done
  return 1
}

VERB="${1:-}"
[[ -z "${VERB}" ]] && usage
shift || true

DEFAULT_BASE_BRANCH=$(load_config_value '.base.default' 'dev')
BASE="origin/${DEFAULT_BASE_BRANCH}"
EFFORT=""
MAX_EFFORT=""
MODEL=""
WAIT=0
RAW=0
WRITE=""
RESUME=""
SINCE=""
PLAN_FILE=""
PRIOR_FINDINGS=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)            BASE="$2"; shift 2 ;;
    --since)           SINCE="$2"; shift 2 ;;
    --plan)            PLAN_FILE="$2"; shift 2 ;;
    --prior-findings)  PRIOR_FINDINGS="$2"; shift 2 ;;
    --effort)          EFFORT="$2"; shift 2 ;;
    --max-effort)      MAX_EFFORT="$2"; shift 2 ;;
    --model)           MODEL="$2"; shift 2 ;;
    --wait)            WAIT=1; shift ;;
    --raw)             RAW=1; shift ;;
    --write)           WRITE="--write"; shift ;;
    --read-only)       WRITE=""; shift ;;
    --resume)          RESUME="--resume-last"; shift ;;
    --fresh)           RESUME=""; shift ;;
    --) shift; POSITIONAL+=("$@"); break ;;
    -h|--help) usage ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

# Default prior-findings: auto-pick .mo-codex-prior.md in cwd if present.
# Lets the common "2nd round of review" flow work without any flag.
if [[ -z "${PRIOR_FINDINGS}" && -f "${PWD}/.mo-codex-prior.md" ]]; then
  PRIOR_FINDINGS="${PWD}/.mo-codex-prior.md"
fi

# ------- warm verb: prewarm the per-cwd codex broker (no Codex call) -------
if [[ "${VERB}" == "warm" ]]; then
  TARGET_CWD="${POSITIONAL[0]:-$PWD}"
  exec node "${SCRIPT_DIR}/warm-broker.mjs" "${TARGET_CWD}"
fi

# ------- broker pre-flight: remove dirs whose broker PID is dead -------
# A session that crashed or was hard-killed leaves behind
# /var/folders/*/*/T/cxc-*/ (or /tmp/cxc-*/ on Linux) with a stale
# broker.sock. The next job can queue behind those ghosts and hang
# silently. Cheap sweep: only delete dirs whose pidfile refers to a
# process that no longer exists. Never touches live brokers.
for broker_dir in /var/folders/*/*/T/cxc-*/ /tmp/cxc-*/; do
  [[ -d "${broker_dir}" ]] || continue
  pidfile="${broker_dir}broker.pid"
  [[ -f "${pidfile}" ]] || continue
  pid=$(cat "${pidfile}" 2>/dev/null)
  if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
    rm -rf "${broker_dir}" 2>/dev/null || true
  fi
done

# ------- resolve git worktree root (fail fast in non-repo containers) -------
ANCHOR="${PWD}"
if [[ "${VERB}" == "review-plan" && -n "${POSITIONAL[0]:-}" && -f "${POSITIONAL[0]}" ]]; then
  ANCHOR="${POSITIONAL[0]}"
fi
GIT_ROOT=$(resolve_git_root "${ANCHOR}" || true)
if [[ -z "${GIT_ROOT}" ]]; then
  echo "mo-codex: no .git ancestor found starting from ${ANCHOR}" >&2
  echo "mo-codex: you are likely in a non-git container directory." >&2
  echo "mo-codex: cd into a worktree first, then retry." >&2
  exit 2
fi
cd "${GIT_ROOT}"

# Normalize BASE: "--base dev" → "origin/dev"; but if user passed
# "--base origin/dev" or a SHA / remote-qualified ref, leave it.
case "${BASE}" in
  origin/*|upstream/*|refs/*|*/*|[0-9a-f]*) : ;;
  *) BASE="origin/${BASE}" ;;
esac

BASE_BRANCH="${BASE#origin/}"
BASE_BRANCH="${BASE_BRANCH#upstream/}"

# ------- auto-select effort / set handoff defaults -------
if [[ -z "${EFFORT}" ]]; then
  case "${VERB}" in
    review-plan)
      plan_path_eff="${POSITIONAL[0]:-}"
      if [[ -f "${plan_path_eff}" ]]; then
        plan_lines=$(wc -l < "${plan_path_eff}" 2>/dev/null | tr -d ' ')
        if [[ -n "${plan_lines}" && "${plan_lines}" -ge 100 ]]; then
          EFFORT="medium"
        else
          EFFORT="low"
        fi
        echo "mo-codex: auto-effort=${EFFORT} (plan=${plan_lines:-0} lines)" >&2
      else
        EFFORT="low"
      fi
      ;;
    review-code)
      git fetch --quiet origin "${BASE_BRANCH}" 2>/dev/null || true
      DIFF_REF="${SINCE:-${BASE}}"
      shortstat=$(git diff --shortstat "${DIFF_REF}...HEAD" 2>/dev/null || true)
      ins=$(printf '%s' "${shortstat}" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || true)
      dels=$(printf '%s' "${shortstat}" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || true)
      total=$(( ${ins:-0} + ${dels:-0} ))
      if (( total < 50 )); then
        EFFORT="low"
      elif (( total < 500 )); then
        EFFORT="medium"
      else
        EFFORT="high"
      fi
      echo "mo-codex: auto-effort=${EFFORT} (diff=${total} lines vs ${DIFF_REF})" >&2
      ;;
  esac
fi

# Cap auto-effort at the user-specified ceiling. Lets you force a fast
# turnaround even when the diff is big (e.g. mass rename / refactor noise).
if [[ -n "${MAX_EFFORT}" && -n "${EFFORT}" ]]; then
  rank() { case "$1" in low) echo 0 ;; medium) echo 1 ;; high) echo 2 ;; *) echo -1 ;; esac; }
  if (( $(rank "${EFFORT}") > $(rank "${MAX_EFFORT}") )); then
    echo "mo-codex: capping effort ${EFFORT} → ${MAX_EFFORT} (--max-effort)" >&2
    EFFORT="${MAX_EFFORT}"
  fi
fi

if [[ "${VERB}" == "handoff" && -z "${WRITE}" && -z "${RESUME}" ]]; then
  WRITE="--write"
fi

# ------- build the prompt for each verb -------
build_prompt() {
  case "${VERB}" in
    review-plan)
      local plan_path="${POSITIONAL[0]:-}"
      if [[ -z "${plan_path}" || ! -f "${plan_path}" ]]; then
        echo "mo-codex review-plan: plan file not found: ${plan_path}" >&2
        exit 2
      fi
      plan_path=$(cd "$(dirname "${plan_path}")" && pwd)/$(basename "${plan_path}")
      cat <<EOF
Review the implementation plan at ${plan_path}.

**Do NOT auto-invoke** the \`document-review\`, \`adversarial-document-reviewer\`,
\`feasibility-reviewer\`, \`coherence-reviewer\`, \`scope-guardian-reviewer\`,
\`design-lens-reviewer\`, \`security-lens-reviewer\`, or \`product-lens-reviewer\`
skills. Those persona reviewers are designed to nitpick implementation details
(unit sizing, edge cases, test coverage wording) — exactly what this review
must NOT focus on. Read the plan directly and judge it yourself.

Your job is to evaluate **whether the proposed approach is the right one** —
NOT to nitpick the plan's implementation details, unit granularity, task
breakdown, test wording, file paths, or acceptance-signal phrasing. Assume the
author is a competent engineer who can handle the mechanics once the direction
is correct. Trust the plan's low-level choices unless they reveal a flaw in the
approach itself.

Read the plan in full, sample the relevant parts of the repo to ground your
judgment, then focus strictly on approach-level questions:

1. **Problem framing.** Is the plan solving the real problem, or a proxy /
   symptom of it? Is there a simpler problem statement that dissolves most of
   the work?
2. **Solution choice.** Among plausible approaches, is this the right one for
   this codebase and constraints? What alternative approach (if any) would be
   materially simpler, safer, or more aligned with existing patterns — and why
   was it presumably rejected?
3. **Fit with the system.** Does the approach compose cleanly with the
   existing architecture, data flow, and invariants, or does it fight them?
   Does it introduce a new abstraction / layer / concept that the problem
   does not actually require?
4. **Scope and leverage.** Is the plan doing too much (scope creep, premature
   generalization) or too little (missing a load-bearing piece that will
   force a rewrite later)?
5. **Load-bearing risks.** What single assumption, if wrong, would invalidate
   the whole approach? Is that assumption verified or merely hoped for?

If the repo has project-specific architecture or policy docs (e.g. a
harness/DECISIONS.md or harness/protocols.md), read them first and apply
them to the judgment — do not invent rules that are not there.

Explicitly DO NOT comment on: unit size, TDD step ordering, test file names,
naming nits, whether a helper should be extracted, minor edge cases that a
careful implementer will catch during coding, or stylistic preferences. If
your only concerns are at that level, say so and return LGTM.

Do not edit any files. Return:
- A short paragraph stating whether the approach is sound.
- At most 3–5 approach-level concerns, ordered by how much they would change
  the plan if taken seriously. Each concern must name the alternative or the
  specific risk, not just flag a worry.
- Final verdict line: APPROACH SOUND / APPROACH NEEDS ADJUSTMENT / RETHINK APPROACH.
EOF
      ;;

    review-code)
      git fetch --quiet origin "${BASE_BRANCH}" 2>/dev/null || true
      local diff_ref="${SINCE:-${BASE}}"
      local diff_stat
      diff_stat=$(git diff --stat "${diff_ref}...HEAD" 2>/dev/null || echo "(no git diff available)")

      local plan_section=""
      if [[ -n "${PLAN_FILE}" && -f "${PLAN_FILE}" ]]; then
        plan_section=$'\n\n## Acceptance criteria from the plan\n\n'
        plan_section+="The plan at \`${PLAN_FILE}\` captures the author's intended behaviour. "
        plan_section+="**Anchor your judgment to the plan's Acceptance Scenarios / Requirements "
        plan_section+="Trace / Success Criteria** — those are the bar this PR is trying to clear, "
        plan_section+="not your own re-derivation. Findings that fall outside the plan's stated "
        plan_section+=$'scope should be filed as P2 (scope) rather than P0/P1 (blocking).\n\n'
        plan_section+="Read \`${PLAN_FILE}\` now, in full, before reading the diff."
      fi

      local prior_section=""
      if [[ -n "${PRIOR_FINDINGS}" && -f "${PRIOR_FINDINGS}" ]]; then
        prior_section=$'\n\n## Prior review findings\n\n'
        prior_section+="The file \`${PRIOR_FINDINGS}\` lists what was raised on the last review pass. "
        prior_section+="For every finding you report, tag it either **[NEW]** (not in the prior review) "
        prior_section+="or **[REPEAT: <short ref to prior item>]** (same concern resurfacing). "
        prior_section+="Repeat findings must justify why they still matter after the author already saw them once — "
        prior_section+="if the author consciously declined and the justification is weak, prefer tagging them P2 / NITS "
        prior_section+=$'over repeating a P0/P1. Do NOT re-litigate settled decisions.\n\n'
        prior_section+="Read \`${PRIOR_FINDINGS}\` now, before reading the diff."
      fi

      cat <<EOF
Review the current branch's code changes against base ref \`${diff_ref}\`.

Important: \`${BASE}\` is the authoritative target. Do NOT substitute the
local branch of the same name — local refs are often stale after rebases.

Start by running:
  git diff ${diff_ref}...HEAD
  git log --oneline ${diff_ref}..HEAD

Diff stat preview:
${diff_stat}

If the repo has project-specific architecture or policy docs (e.g. a
harness/ directory, AGENTS.md, or CLAUDE.md), read them first and apply
their rules to the diff — do not invent rules that are not there.${plan_section}${prior_section}

Evaluate the diff for:
- Correctness, edge cases, error propagation.
- Cross-service contracts and trust boundaries (sanitize errors at any
  externally-visible edge — WebSocket, public API, logs).
- Architecture fit (as defined by the project's own decisions / arch-lint).
- Test coverage of the changed lines.
- Anything that should block landing.

Do not edit any files. Return **each finding tagged with a severity**:

- **[P0]** blocks landing — production bug, data loss, security hole,
  contract break. If any P0 is present the verdict is CHANGES REQUESTED.
- **[P1]** should be fixed before merge but the author could argue —
  correctness gaps in edge cases, missing tests on risky code, arch-lint
  violations.
- **[P2]** nice-to-have — style, naming, minor refactor suggestions,
  scope-expansion candidates. These are FYI, not blocking.

Order findings within each severity by the cost of ignoring them. Each
finding must name the exact file:line, state the concrete risk (not a
vague worry), and propose a fix.

Final verdict line, chosen by the highest-severity finding:
  BLOCK (P0, and it's unrecoverable without structural rework) /
  CHANGES REQUESTED (any P0 or multiple P1) /
  NITS (only P2, author's call) /
  LGTM (nothing worth noting).
EOF
      ;;

    handoff)
      local task_text="${POSITIONAL[*]:-}"
      if [[ -z "${task_text}" ]]; then
        echo "mo-codex handoff: missing task text" >&2
        exit 2
      fi
      cat <<EOF
${task_text}

Working against base branch \`${BASE}\`. Follow the repository's CLAUDE.md
and any harness / AGENTS.md rules that exist. Make the smallest correct
change. When done, leave a short summary of what you changed and what you
intentionally did not change.
EOF
      ;;

    *)
      echo "mo-codex: unknown verb '${VERB}'" >&2
      usage
      ;;
  esac
}

PROMPT=$(build_prompt)

# ------- assemble codex-companion args -------
ARGS=(task --json)
[[ -n "${WRITE}"  ]] && ARGS+=("${WRITE}")
[[ -n "${RESUME}" ]] && ARGS+=("${RESUME}")
[[ -n "${EFFORT}" ]] && ARGS+=(--effort "${EFFORT}")
[[ -n "${MODEL}"  ]] && ARGS+=(--model "${MODEL}")

if (( WAIT )); then
  exec node "${COMPANION}" "${ARGS[@]}" "${PROMPT}"
fi

ARGS+=(--background)
JSON=$(node "${COMPANION}" "${ARGS[@]}" "${PROMPT}")
RC=$?
if (( RC != 0 )); then
  echo "${JSON}" >&2
  exit "${RC}"
fi

JOB_ID=$(printf '%s' "${JSON}" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{try{console.log(JSON.parse(s).jobId||"")}catch(e){}})')
LOG_FILE=$(printf '%s' "${JSON}" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{try{console.log(JSON.parse(s).logFile||"")}catch(e){}})')

if [[ -z "${JOB_ID}" || -z "${LOG_FILE}" ]]; then
  echo "mo-codex: codex-companion did not return jobId/logFile:" >&2
  echo "${JSON}" >&2
  exit 1
fi

echo "mo-codex: job ${JOB_ID}  (verb=${VERB} base=${BASE}${EFFORT:+ effort=${EFFORT}})" >&2
echo "mo-codex: cwd ${GIT_ROOT}" >&2
echo "mo-codex: log ${LOG_FILE}" >&2
echo "mo-codex: Ctrl-C to cancel" >&2
echo >&2

cleanup() {
  echo >&2
  echo "mo-codex: cancelling job ${JOB_ID}" >&2
  node "${COMPANION}" cancel "${JOB_ID}" >/dev/null 2>&1 || true
  exit 130
}
trap cleanup INT TERM

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "${LOG_FILE}" ]] && break
  sleep 0.2
done

if (( RAW )); then
  tail -n +1 -f "${LOG_FILE}" &
else
  tail -n +1 -f "${LOG_FILE}" | node "${FILTER}" &
fi
TAIL_PID=$!

while :; do
  sleep 2
  STATUS=$(node "${COMPANION}" status "${JOB_ID}" --json 2>/dev/null \
    | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{try{const j=JSON.parse(s);console.log((j.job&&j.job.status)||j.status||"")}catch(e){}})')
  case "${STATUS}" in
    succeeded|failed|cancelled|completed|error|"") break ;;
  esac
done

sleep 0.5
kill "${TAIL_PID}" 2>/dev/null || true
wait "${TAIL_PID}" 2>/dev/null || true

echo >&2
RESULT=$(node "${COMPANION}" result "${JOB_ID}" 2>/dev/null || true)
VERDICT=$(printf '%s' "${RESULT}" | grep -oE '\b(LGTM|NITS|CHANGES REQUESTED|BLOCK|APPROACH SOUND|APPROACH NEEDS ADJUSTMENT|RETHINK APPROACH)\b' | tail -1 || true)
if [[ -n "${VERDICT}" ]]; then
  echo "═══ VERDICT: ${VERDICT} ═══" >&2
  echo >&2
fi
echo "mo-codex: final result --" >&2
printf '%s\n' "${RESULT}"
