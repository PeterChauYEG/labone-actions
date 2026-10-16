#!/usr/bin/env node
/**
 * Duplicate-code scan: runs `jscpd` and renders its JSON report as markdown, grouped by file pair.
 */

import { execFileSync } from 'child_process';
import { existsSync, readFileSync, writeFileSync } from 'fs';
import { runScan } from './lib/crash-report.mjs';
import { writeGroupsFile } from './lib/package-cluster.mjs';
import { formatFragment, buildClusterRecords } from './lib/jscpd-cluster.mjs';

const REPORT_PATH = 'duplicate-code-report.md';
const JSCPD_REPORT_PATH = 'jscpd-report.json';
const GROUPS_PATH = 'duplicate-code-groups.json';

function runJscpd() {
  let exceededThreshold = false;

  try {
    execFileSync('npx', ['jscpd', '--config', '.jscpd.json'], { encoding: 'utf-8' });
  } catch {
    exceededThreshold = true;
  }

  if (!existsSync(JSCPD_REPORT_PATH)) {
    throw new Error(`jscpd did not produce ${JSCPD_REPORT_PATH}`);
  }

  return { report: JSON.parse(readFileSync(JSCPD_REPORT_PATH, 'utf-8')), exceededThreshold };
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
  writeGroupsFile(buildClusterRecords(report), GROUPS_PATH);

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
