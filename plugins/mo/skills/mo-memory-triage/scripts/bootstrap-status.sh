#!/usr/bin/env bash
# bootstrap-status.sh — one-time: insert `status: active` into existing YAML
# frontmatter of every feedback_*.md in the memory dir.
#
# Idempotent. Skips files that already have `status:`. Warns to stderr (does
# NOT mutate) any file lacking a proper `---` frontmatter block — those are
# triage candidates for the user, not auto-fix targets.

set -u
set -o pipefail

DIR="${MEMORY_DIR:?MEMORY_DIR env var required — pass the path to your Claude memory dir}"

if [ ! -d "${DIR}" ]; then
  echo "bootstrap-status: memory dir not found: ${DIR}" >&2
  exit 2
fi

modified=0
skipped_has_status=0
skipped_no_fm=0

shopt -s nullglob
for f in "${DIR}"/feedback_*.md; do
  base=$(basename "$f")

  # Find the two `---` fences. We require the opening fence on line 1 and a
  # closing fence somewhere later. Anything else = "no proper frontmatter".
  # (Avoid `mapfile` — not in macOS bash 3.2.)
  fences=$(grep -n '^---$' "$f" | head -2 | cut -d: -f1)
  open_line=$(printf '%s\n' "$fences" | sed -n '1p')
  close_line=$(printf '%s\n' "$fences" | sed -n '2p')

  if [ -z "$open_line" ] || [ -z "$close_line" ] || [ "$open_line" != "1" ]; then
    echo "warn: ${base}: no proper frontmatter (--- on line 1 + closing ---); skipped" >&2
    skipped_no_fm=$((skipped_no_fm + 1))
    continue
  fi

  # Inside the frontmatter block, check for an existing `status:` key.
  if sed -n "$((open_line + 1)),$((close_line - 1))p" "$f" | grep -qE '^status:[[:space:]]'; then
    skipped_has_status=$((skipped_has_status + 1))
    continue
  fi

  # Insert `status: active` immediately before the closing fence.
  tmp=$(mktemp)
  awk -v cl="${close_line}" 'NR==cl { print "status: active" } { print }' "$f" > "${tmp}" && mv "${tmp}" "$f"
  modified=$((modified + 1))
done

echo "modified: ${modified}"
echo "skipped_has_status: ${skipped_has_status}"
echo "skipped_no_fm (warned to stderr): ${skipped_no_fm}"
