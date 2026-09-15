#!/usr/bin/env node
/**
 * Duplicate-code scan: runs `jscpd` against the caller repo's own
 * .jscpd.json (path/threshold tuning stays in the caller — this runner is
 * shared) and renders its JSON report as a markdown report, grouped by
 * file pair.
 *
 * Invoked by scan-with-report's `script-source: labone-actions` mode (see
 * that action's own header) — runs with the caller repo as its cwd, so
 * every path here is deliberately cwd-relative.
 *
 * Usage (from the caller repo's working-directory, via scan-with-report):
 *   node <labone-actions checkout>/scripts/duplicate-code-scan.mjs
 *
 * Exits non-zero if jscpd's duplication percentage exceeds the caller's
 * own .jscpd.json `threshold`.
 */

import { execFileSync } from 'child_process';
import { existsSync, readFileSync, writeFileSync } from 'fs';
import { runScan } from './lib/crash-report.mjs';

const REPORT_PATH = 'duplicate-code-report.md';
const JSCPD_REPORT_PATH = 'jscpd-report.json';

function runJscpd() {
  let exceededThreshold = false;

  try {
    execFileSync('npx', ['jscpd', '--config', '.jscpd.json'], { encoding: 'utf-8' });
  } catch {
    // jscpd exits non-zero once its duplication percentage exceeds
    // .jscpd.json's `threshold` — that's expected; the report file is
    // still written to disk either way, so fall through and parse it
    // below rather than treating this as a hard error.
    exceededThreshold = true;
  }

  if (!existsSync(JSCPD_REPORT_PATH)) {
    throw new Error(`jscpd did not produce ${JSCPD_REPORT_PATH}`);
  }

  return { report: JSON.parse(readFileSync(JSCPD_REPORT_PATH, 'utf-8')), exceededThreshold };
}

function formatFragment({ name, start, end }) {
  return `\`${name}\`:${start}-${end}`;
}

function buildReport(report, exceededThreshold) {
  const duplicates = report.duplicates ?? [];
  const percentage = report.statistics?.total?.percentage ?? 0;
  const lines = ['## Duplicate-code scan (jscpd)', ''];

  if (duplicates.length === 0) {
    lines.push('✅ No duplicate code blocks found.', '');
    return lines.join('\n');
  }

  lines.push(
    exceededThreshold
      ? `❌ ${percentage.toFixed(2)}% duplicated — over threshold. Found ${duplicates.length} duplicate block(s).`
      : `✅ ${percentage.toFixed(2)}% duplicated — within threshold. Found ${duplicates.length} pre-existing duplicate block(s), reported below.`,
    '',
  );
  lines.push(
    `<details><summary><strong>Duplicate blocks</strong> — ${duplicates.length}</summary>`,
    '',
  );

  for (const dup of duplicates) {
    const first = formatFragment(dup.firstFile);
    const second = formatFragment(dup.secondFile);
    lines.push(`- ${first} ↔ ${second} (${dup.lines} lines, ${dup.tokens} tokens)`);
  }

  lines.push('', '</details>', '');
  lines.push('See .jscpd.json to tune paths/thresholds or exempt intentional matches.', '');

  return lines.join('\n');
}

function main() {
  const { report, exceededThreshold } = runJscpd();
  const duplicates = report.duplicates ?? [];

  writeFileSync(REPORT_PATH, buildReport(report, exceededThreshold));

  if (exceededThreshold) {
    console.error(
      `Duplication exceeds .jscpd.json's threshold (${duplicates.length} block(s) found) — see ${REPORT_PATH}`,
    );
    process.exit(1);
  }

  console.log(
    duplicates.length > 0
      ? `Duplication within threshold (${duplicates.length} pre-existing block(s)) — see ${REPORT_PATH}`
      : 'No duplicate code blocks found.',
  );
}

runScan(main, REPORT_PATH, 'Duplicate-code scan (jscpd)');
