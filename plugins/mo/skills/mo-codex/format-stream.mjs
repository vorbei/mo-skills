#!/usr/bin/env node
// mo-codex format-stream — filter codex-companion log into a scannable live stream.
//
// Input: codex-companion log lines (from `tail -f <logfile>`).
// Log format per codex-companion/lib/tracked-jobs.mjs:
//   [<iso-timestamp>] <message>\n                                (single line)
//   \n[<iso-timestamp>] <title>\n<body...>\n                     (block)
//
// This filter:
//   - Drops low-signal single-liners ("Turn started (...)", "Thread started...", etc.)
//   - Highlights block titles and passes their bodies through verbatim
//   - Emits a heartbeat every 15s of stream idleness

const TIMESTAMP_RE = /^\[\d{4}-\d{2}-\d{2}T[\d:.]+Z?\]\s+/;

const SKIP_PREFIX = [
  'Starting ',
  'Turn started',
  'Thread ',
  'Subagent ',
  'Assistant message captured',
  'Reasoning summary captured',
  'Review output captured',
  'Queued for background execution',
];

const BLOCK_TITLES = new Set([
  'Assistant message',
  'Reasoning summary',
  'Review output',
  'Final output',
]);

const start = Date.now();
let lastActivity = Date.now();
let inBlock = false;

const HEARTBEAT_IDLE_MS = 15000;
const heartbeat = setInterval(() => {
  const idle = Date.now() - lastActivity;
  if (idle >= HEARTBEAT_IDLE_MS) {
    const elapsed = Math.round((Date.now() - start) / 1000);
    process.stdout.write(`· ${elapsed}s elapsed, still running...\n`);
    lastActivity = Date.now();
  }
}, 5000);

let buffer = '';
process.stdin.on('data', (chunk) => {
  buffer += chunk.toString();
  const lines = buffer.split('\n');
  buffer = lines.pop() ?? '';
  for (const line of lines) handleLine(line);
});
process.stdin.on('end', () => {
  if (buffer) handleLine(buffer);
  clearInterval(heartbeat);
});

function handleLine(line) {
  lastActivity = Date.now();

  const m = line.match(TIMESTAMP_RE);
  if (m) {
    const rest = line.slice(m[0].length);
    if (BLOCK_TITLES.has(rest)) {
      inBlock = true;
      const header = rest === 'Final output' ? `\n═══ Final output ═══` : `\n── ${rest} ──`;
      process.stdout.write(`${header}\n`);
      return;
    }
    inBlock = false;
    for (const p of SKIP_PREFIX) {
      if (rest.startsWith(p)) return;
    }
    process.stdout.write(`• ${rest}\n`);
  } else if (inBlock) {
    process.stdout.write(`${line}\n`);
  }
}
