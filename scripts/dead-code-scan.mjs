#!/usr/bin/env node
/**
 * Dead-code scan: run knip and render its findings as a PR-friendly report.
 *
 * Detects unused files, exports (incl. types/enum members), dependencies,
 * devDependencies, and binaries — per the caller repo's knip.json config.
 *
 * Invoked by scan-with-report's `script-source: labone-actions` mode (see
 * that action's own header) — runs with the caller repo as its cwd (not
 * this checkout), so every path here is deliberately cwd-relative, never
 * __dirname-relative, unlike a script meant to be vendored into the caller
 * repo itself.
 *
 * Usage (from the caller repo's working-directory, via scan-with-report):
 *   node <labone-actions checkout>/scripts/dead-code-scan.mjs
 *
 * Exits non-zero if knip reports any issue.
 */

import { execFileSync } from 'child_process';
import { writeFileSync } from 'fs';
import { runScan } from './lib/crash-report.mjs';

const REPORT_PATH = 'dead-code-report.md';

const CATEGORIES = [
  { key: 'dependencies', title: 'Unused dependencies' },
  { key: 'devDependencies', title: 'Unused devDependencies' },
  { key: 'binaries', title: 'Unused binaries' },
  { key: 'unresolved', title: 'Unresolved imports' },
  { key: 'exports', title: 'Unused exports' },
  { key: 'types', title: 'Unused types' },
  { key: 'enumMembers', title: 'Unused enum members' },
  { key: 'duplicates', title: 'Duplicate exports' },
];

function runKnip() {
  try {
    const stdout = execFileSync('npx', ['knip', '--reporter', 'json'], {
      encoding: 'utf-8',
    });
    return JSON.parse(stdout);
  } catch (error) {
    if (error.stdout) return JSON.parse(error.stdout);
    throw error;
  }
}

function buildReport(report) {
  const fileOnlyRows = report.issues.filter((issue) => Object.keys(issue).length === 1 && 'file' in issue);
  const lines = ['## Dead-code scan (knip)', ''];
  let total = fileOnlyRows.length;

  if (fileOnlyRows.length > 0) {
    lines.push(`<details><summary><strong>Unused files</strong> — ${fileOnlyRows.length}</summary>`, '');
    for (const issue of fileOnlyRows) lines.push(`- \`${issue.file}\``);
    lines.push('', '</details>', '');
  }

  for (const { key, title } of CATEGORIES) {
    const rows = report.issues.filter((issue) => issue[key]?.length);
    if (rows.length === 0) continue;

    const count = rows.reduce((sum, issue) => sum + issue[key].length, 0);
    total += count;

    lines.push(`<details><summary><strong>${title}</strong> — ${count}</summary>`, '');

    for (const issue of rows) {
      lines.push(`- \`${issue.file}\``);
      for (const item of issue[key]) {
        const name = item.symbol ?? item.name ?? '';
        const at = item.line ? `L${item.line}` : '';
        lines.push(`  - ${[at, name].filter(Boolean).join(': ')}`);
      }
    }

    lines.push('', '</details>', '');
  }

  if (total === 0) {
    return { markdown: ['## Dead-code scan (knip)', '', '✅ No dead code found.', ''].join('\n'), total };
  }

  lines.splice(1, 0, `❌ Found ${total} issue(s).`, '');

  return { markdown: lines.join('\n'), total };
}

function main() {
  const report = runKnip();
  const { markdown, total } = buildReport(report);

  writeFileSync(REPORT_PATH, markdown);

  if (total > 0) {
    console.error(`Found ${total} dead-code issue(s) — see ${REPORT_PATH}`);
    process.exit(1);
  }

  console.log('No dead code found.');
}

runScan(main, REPORT_PATH, 'Dead-code scan (knip)');
