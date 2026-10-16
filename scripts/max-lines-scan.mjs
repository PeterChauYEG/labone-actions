#!/usr/bin/env node
/**
 * Max-lines scan: runs ESLint with the caller's eslint.max-lines.config.mjs
 * and renders the results as a markdown report, grouped by file.
 */

import { execFileSync } from 'child_process';
import { writeFileSync } from 'fs';
import { relative } from 'path';
import { writeGroupsFile } from './lib/package-cluster.mjs';

const REPORT_PATH = 'max-lines-report.md';
const GROUPS_PATH = 'max-lines-groups.json';
const CONFIG_PATH = 'eslint.max-lines.config.mjs';

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

function buildClusterRecords(results) {
  return collectViolations(results).map(({ file, message }) => ({
    file,
    text: formatViolation({ file, message }),
  }));
}

function main() {
  const results = runEslint();
  const { markdown, totalIssues } = buildReport(results);

  writeFileSync(REPORT_PATH, markdown);
  writeGroupsFile(buildClusterRecords(results), GROUPS_PATH);

  if (totalIssues > 0) {
    console.error(`Found ${totalIssues} max-lines violation(s) — see ${REPORT_PATH}`);
    process.exit(1);
  }

  console.log('No max-lines / max-lines-per-function violations found.');
}

/**
 * Guarantees a report file exists even if something throws before main() writes one.
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
