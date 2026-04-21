#!/usr/bin/env bash
# regen-indexes.sh — rewrite MEMORY-feedback.md and MEMORY-antipattern.md from
# the source-of-truth frontmatter on each feedback_*.md.
#
# Active entries → MEMORY-feedback.md (preserves the legacy plain-text
# subsection verbatim — those entries have no underlying file and must not be
# regenerated).
#
# Anti-pattern entries → MEMORY-antipattern.md (table with reason +
# superseded_by columns).

set -u
set -o pipefail

DIR="${MEMORY_DIR:?MEMORY_DIR env var required — pass the path to your Claude memory dir}"
FEEDBACK_INDEX="${DIR}/MEMORY-feedback.md"
ANTI_INDEX="${DIR}/MEMORY-antipattern.md"

if [ ! -d "${DIR}" ]; then
  echo "regen-indexes: memory dir not found: ${DIR}" >&2
  exit 2
fi

# Frontmatter parser: print one line `KEY=value` for each known key in the
# block between the first two `---`.
parse_fm() {
  local f="$1"
  awk '
    BEGIN { fence=0 }
    /^---$/ {
      fence++
      if (fence == 2) exit
      next
    }
    fence == 1 {
      if (match($0, /^[a-zA-Z_]+:/)) {
        key = substr($0, 1, RLENGTH - 1)
        val = substr($0, RLENGTH + 1)
        sub(/^[ \t]+/, "", val)
        # Keep only the keys we care about.
        if (key ~ /^(name|description|status|superseded_by|deprecated|reason)$/) {
          gsub(/\r/, "", val)
          printf "%s=%s\n", key, val
        }
      }
    }
  ' "$f"
}

# Capture existing legacy section (everything from the H3 line to EOF).
legacy_section=""
if [ -f "${FEEDBACK_INDEX}" ]; then
  legacy_section=$(awk '
    /^### Feedback \(in mono-worktree project memory, still valid\)/ { keep=1 }
    keep { print }
  ' "${FEEDBACK_INDEX}")
fi

# Build the new MEMORY-feedback.md (active section).
TMP_FB=$(mktemp)
trap 'rm -f "${TMP_FB}" "${TMP_AP:-}"' EXIT

cat > "${TMP_FB}" <<'EOF'
# Memory — Feedback Catalog

Full feedback catalog. Auto-loaded only when explicitly read; the top
[MEMORY.md](MEMORY.md) "Always obey" surface carries the most load-bearing
subset inline.

## Feedback
EOF

# Stable order: ascending by filename.
shopt -s nullglob
for f in $(ls "${DIR}"/feedback_*.md 2>/dev/null | sort); do
  base=$(basename "$f")
  fm=$(parse_fm "$f")
  status=$(printf '%s\n' "$fm" | sed -n 's/^status=//p' | head -1)
  description=$(printf '%s\n' "$fm" | sed -n 's/^description=//p' | head -1)
  # Skip non-active in the feedback index.
  if [ "${status}" != "active" ]; then
    continue
  fi
  printf -- '- [%s](%s) — %s\n' "$base" "$base" "$description" >> "${TMP_FB}"
done

# Append legacy section verbatim (with one blank line separator).
if [ -n "${legacy_section}" ]; then
  printf '\n%s\n' "${legacy_section}" >> "${TMP_FB}"
fi

mv "${TMP_FB}" "${FEEDBACK_INDEX}"
echo "wrote ${FEEDBACK_INDEX}"

# Build MEMORY-antipattern.md
TMP_AP=$(mktemp)
cat > "${TMP_AP}" <<'EOF'
# Memory — Anti-pattern Catalog

Rules we tried, learned were wrong, and now actively avoid. Each entry
preserves the original feedback so future agents (and future-you) can see
*what we tried* and *why it didn't work* — re-running the same dead end is
a real cost. **Read this file before assuming an old approach is still
valid.**

## Anti-patterns

| File | Deprecated | Superseded by | Reason |
|------|------------|---------------|--------|
EOF

n_anti=0
for f in $(ls "${DIR}"/feedback_*.md 2>/dev/null | sort); do
  base=$(basename "$f")
  fm=$(parse_fm "$f")
  status=$(printf '%s\n' "$fm" | sed -n 's/^status=//p' | head -1)
  if [ "${status}" != "anti-pattern" ]; then
    continue
  fi
  deprecated=$(printf '%s\n' "$fm" | sed -n 's/^deprecated=//p' | head -1)
  superseded_by=$(printf '%s\n' "$fm" | sed -n 's/^superseded_by=//p' | head -1)
  reason=$(printf '%s\n' "$fm" | sed -n 's/^reason=//p' | head -1)
  # Sanitize for table cell (replace pipes and newlines).
  reason_safe=$(printf '%s' "${reason}" | tr -d '\r' | sed 's/|/\\|/g')
  superseded_link=""
  if [ -n "${superseded_by}" ] && [ "${superseded_by}" != "none" ]; then
    superseded_link="[${superseded_by}](${superseded_by})"
  fi
  printf -- '| [%s](%s) | %s | %s | %s |\n' \
    "$base" "$base" "${deprecated:-—}" "${superseded_link:-—}" "${reason_safe:-—}" >> "${TMP_AP}"
  n_anti=$((n_anti + 1))
done

if [ "${n_anti}" -eq 0 ]; then
  echo "" >> "${TMP_AP}"
  echo "_No anti-patterns yet. Use \`/mo-memory-triage\` to mark candidates._" >> "${TMP_AP}"
fi

mv "${TMP_AP}" "${ANTI_INDEX}"
echo "wrote ${ANTI_INDEX} (${n_anti} anti-pattern entries)"
