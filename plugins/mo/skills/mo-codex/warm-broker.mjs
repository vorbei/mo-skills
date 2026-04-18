#!/usr/bin/env node
// mo-codex warm-broker — prewarm the codex broker for a given cwd.
//
// Codex spawns a per-cwd broker process (~1–3s first-hit cost) and then
// reuses it for every subsequent task. This script hits the same internal
// ensureBrokerSession() the task flow uses, but without submitting a task:
// idempotent, cheap, and does not burn Codex credit. Call it right after
// creating a new worktree so the FIRST `mo-codex ...` in that cwd is warm.
//
// Usage: warm-broker.mjs [cwd]   (defaults to process.cwd())

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const CODEX_ROOT = path.join(os.homedir(), '.claude/plugins/cache/openai-codex/codex');

function findLatestBrokerLifecycle() {
  if (!fs.existsSync(CODEX_ROOT)) return null;
  const versions = fs.readdirSync(CODEX_ROOT).sort();
  const latest = versions[versions.length - 1];
  if (!latest) return null;
  const p = path.join(CODEX_ROOT, latest, 'scripts/lib/broker-lifecycle.mjs');
  return fs.existsSync(p) ? p : null;
}

const cwd = process.argv[2] || process.cwd();
const resolvedCwd = path.resolve(cwd);

if (!fs.existsSync(resolvedCwd) || !fs.statSync(resolvedCwd).isDirectory()) {
  console.error(`warm-broker: cwd does not exist or is not a directory: ${resolvedCwd}`);
  process.exit(2);
}

const brokerPath = findLatestBrokerLifecycle();
if (!brokerPath) {
  console.error(`warm-broker: cannot find broker-lifecycle.mjs under ${CODEX_ROOT} — install the openai-codex plugin first.`);
  process.exit(2);
}

const start = Date.now();
try {
  const { ensureBrokerSession } = await import(brokerPath);
  const session = await ensureBrokerSession(resolvedCwd);
  const elapsed = Date.now() - start;
  if (!session) {
    console.error(`warm-broker: broker failed to start for ${resolvedCwd} (${elapsed}ms)`);
    process.exit(1);
  }
  console.log(`warm-broker: ready in ${elapsed}ms  pid=${session.pid}  cwd=${resolvedCwd}`);
} catch (err) {
  console.error(`warm-broker: ${err.message}`);
  process.exit(1);
}
