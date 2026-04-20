#!/usr/bin/env bash
# bootstrap-status.test.sh — TDD test for bootstrap-status.sh
#
# Asserts that bootstrap-status.sh:
#   1. Inserts `status: active` into a frontmatter block lacking status
#   2. Leaves a frontmatter block that already has status untouched
#   3. Leaves a file without frontmatter untouched, AND warns to stderr
#   4. Is idempotent (second run is a no-op on a file already processed)

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOTSTRAP="${SCRIPT_DIR}/bootstrap-status.sh"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

fail=0
ok_n=0
note() { printf '[%s] %s\n' "$1" "$2"; }
ok()   { ok_n=$((ok_n + 1)); note "OK"   "$1"; }
bad()  { fail=$((fail + 1)); note "FAIL" "$1"; }

# --- Fixtures ---
cat > "${TMP}/feedback_no_status.md" <<'EOF'
---
name: Sample feedback without status
description: A short test description
type: feedback
originSessionId: 00000000-0000-0000-0000-000000000001
---
Body content here.
Second line.
EOF

cat > "${TMP}/feedback_has_status.md" <<'EOF'
---
name: Sample feedback already has status
description: A short test description
type: feedback
originSessionId: 00000000-0000-0000-0000-000000000002
status: active
---
Body content here.
EOF

cat > "${TMP}/feedback_no_fm.md" <<'EOF'
This file has no frontmatter at all.
Just plain text.
EOF

# Snapshot for byte-identical assertions
cp "${TMP}/feedback_has_status.md"  "${TMP}/.snap_has_status.md"
cp "${TMP}/feedback_no_fm.md"       "${TMP}/.snap_no_fm.md"

# --- Run bootstrap ---
if [ ! -x "${BOOTSTRAP}" ]; then
  bad "bootstrap-status.sh not executable at ${BOOTSTRAP}"
  echo "FAIL — ${fail} issue(s) (${ok_n} ok)"
  exit 1
fi

stderr_log="${TMP}/.stderr.log"
MEMORY_DIR="${TMP}" "${BOOTSTRAP}" 2> "${stderr_log}"
rc=$?
if [ "$rc" -ne 0 ]; then
  bad "bootstrap exited ${rc}, expected 0"
fi

# --- Assertion 1: no_status gained `status: active` inside frontmatter ---
if awk '/^---$/{c++} c==1 && /^status:[[:space:]]*active$/{print "found"; exit}' \
     "${TMP}/feedback_no_status.md" | grep -q found; then
  ok "no_status: gained 'status: active' inside frontmatter"
else
  bad "no_status: expected 'status: active' inside frontmatter, did not find"
fi

# --- Assertion 2: has_status is byte-identical to snapshot ---
if cmp -s "${TMP}/feedback_has_status.md" "${TMP}/.snap_has_status.md"; then
  ok "has_status: byte-identical (idempotent)"
else
  bad "has_status: file was modified despite already having status"
fi

# --- Assertion 3: no_fm is byte-identical to snapshot ---
if cmp -s "${TMP}/feedback_no_fm.md" "${TMP}/.snap_no_fm.md"; then
  ok "no_fm: byte-identical (no frontmatter to inject into)"
else
  bad "no_fm: file was modified but had no frontmatter"
fi

# --- Assertion 4: stderr warned about no_fm ---
if grep -q "feedback_no_fm.md" "${stderr_log}"; then
  ok "no_fm: warned to stderr"
else
  bad "no_fm: expected stderr warning mentioning filename"
fi

# --- Assertion 5: idempotent re-run is a no-op ---
cp "${TMP}/feedback_no_status.md" "${TMP}/.snap_after_first_run.md"
MEMORY_DIR="${TMP}" "${BOOTSTRAP}" 2>/dev/null
if cmp -s "${TMP}/feedback_no_status.md" "${TMP}/.snap_after_first_run.md"; then
  ok "idempotent: second run left previously-processed file unchanged"
else
  bad "idempotent: second run modified an already-processed file"
fi

# --- Assertion 6: status sits inside frontmatter, not appended after closing --- ---
if awk '
  /^---$/ { fence++; next }
  fence==1 && /^status:/ { inside++ }
  fence==2 && /^status:/ { outside++ }
  END { exit (inside==1 && outside==0) ? 0 : 1 }
' "${TMP}/feedback_no_status.md"; then
  ok "no_status: status: line is inside frontmatter (between fences)"
else
  bad "no_status: status: line landed outside the frontmatter block"
fi

# --- Summary ---
echo
if [ "$fail" -eq 0 ]; then
  echo "PASS — ${ok_n} checks ok"
  exit 0
else
  echo "FAIL — ${fail} issue(s) (${ok_n} ok)"
  exit 1
fi
