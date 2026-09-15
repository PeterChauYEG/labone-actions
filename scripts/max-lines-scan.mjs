#!/usr/bin/env node
/**
 * Max-lines scan: runs ESLint with a caller repo's standalone
 * `eslint.max-lines.config.mjs` (kept out of eslint.config.mjs/the `lint`
 * job on purpose — advisory, not a required check) and renders the results
 * as a markdown report, grouped by file, for posting as a sticky PR
 * comment. Invoked by scan-with-report's `script-source: labone-actions`
 * mode (see that action's own header) — the config file (thresholds/
 * excludes) stays in the caller repo since those are repo-specific; only
 * this runner is shared.
 *
 * Usage (from the caller repo's working-directory, via scan-with-report):
 *   node <labone-actions checkout>/scripts/max-lines-scan.mjs
 *
 * Requires `eslint.max-lines.config.mjs` at the caller's cwd. Exits
 * non-zero if any file/function exceeds the configured thresholds.
 */

import { execFileSync } from 'child_process';
import { writeFileSync } from 'fs';
import { relative } from 'path';

const REPORT_PATH = 'max-lines-report.md';
const CONFIG_PATH = 'eslint.max-lines.config.mjs';

// Default execFileSync maxBuffer (1 MB) truncates ESLint's JSON report on a
// repo of any size once there are more than a handful of violations —
// bump it well past what a full-repo report could plausibly reach.
const MAX_BUFFER = 100 * 1024 * 1024;

function runEslint() {
  try {
    const stdout = execFileSync(
      'npx',
      ['eslint', '--config', CONFIG_PATH, '--format', 'json', '.'],
      { encoding: 'utf-8', maxBuffer: MAX_BUFFER },
    );
    return JSON.parse(stdout);
  } catch (error) {
    // eslint exits non-zero once any "error"-severity match is found —
    // that's expected here (both rules are configured at "error"); the
    // JSON report is still on stdout, so fall through and parse it below
    // rather than treating this as a hard failure.
    if (error.stdout) {
      return JSON.parse(error.stdout);
    }
    throw error;
  }
}

function collectViolations(results) {
  return results.flatMap((result) =>
    result.messages
      .filter(
        (message) => message.ruleId === 'max-lines' || message.ruleId === 'max-lines-per-function',
      )
      .map((message) => ({ file: relative(process.cwd(), result.filePath), message })),
  );
}

function formatViolation({ file, message }) {
  return `  - \`${file}:${message.line}\` (\`${message.ruleId}\`) — ${message.message}`;
}

function buildReport(results) {
  const violations = collectViolations(results);
  const lines = ['## Max-lines scan (eslint)', ''];

  if (violations.length === 0) {
    lines.push('✅ No max-lines / max-lines-per-function violations found.', '');
    return { markdown: lines.join('\n'), totalIssues: 0 };
  }

  lines.push(`❌ Found ${violations.length} violation(s).`, '');
  lines.push(`<details><summary><strong>Violations</strong> — ${violations.length}</summary>`, '');
  lines.push(...violations.map(formatViolation));
  lines.push('', '</details>', '');
  lines.push('See eslint.max-lines.config.mjs to tune thresholds.', '');

  return { markdown: lines.join('\n'), totalIssues: violations.length };
}

function main() {
  const results = runEslint();
  const { markdown, totalIssues } = buildReport(results);

  writeFileSync(REPORT_PATH, markdown);

  if (totalIssues > 0) {
    console.error(`Found ${totalIssues} max-lines violation(s) — see ${REPORT_PATH}`);
    process.exit(1);
  }

  console.log('No max-lines / max-lines-per-function violations found.');
}

/**
 * Guarantees a report file exists by the time this process exits, even if
 * something throws before main()'s own `writeFileSync(REPORT_PATH, ...)`
 * call. Without this, an unexpected crash would skip writing REPORT_PATH,
 * which breaks the `sticky-pull-request-comment` CI step downstream — it
 * errors when `path:` points at a file that doesn't exist.
 */
function writeCrashReport(error) {
  const message = error instanceof Error ? (error.stack ?? error.message) : String(error);

  try {
    writeFileSync(
      REPORT_PATH,
      `## Max-lines scan (eslint)\n\n⚠️ Scan failed to run.\n\n\`\`\`\n${message}\n\`\`\`\n`,
    );
  } catch (writeError) {
    console.error('Failed to write crash report:', writeError);
  }
}

try {
  main();
} catch (error) {
  console.error(error);
  writeCrashReport(error);
  process.exit(1);
}
