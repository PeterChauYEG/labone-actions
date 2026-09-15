#!/usr/bin/env node
/**
 * React tech-debt scan: runs ESLint against the caller repo's own
 * eslint.config.(js|mjs) and renders every `lab-react-standards/*`
 * finding as a PR-friendly report, split into blocking (error-severity)
 * and advisory (warn-severity) sections. No per-repo config needed - the
 * `lab-react-standards/` prefix is a fixed labone-eslint-plugin
 * vocabulary, not something that varies per caller.
 *
 * Deliberately overlaps with design-system-scan.mjs's two rules - this is
 * the broader, advisory-inclusive view (every lab-react-standards rule,
 * whatever severity the caller's own eslint.config gives it);
 * design-system is the narrower, always-blocking one. A caller with none
 * of these rules configured just gets a clean "no findings" report.
 *
 * Invoked by scan-with-report's `script-source: labone-actions` mode (see
 * that action's own header) - runs with the caller repo as its cwd, so
 * every path here is deliberately cwd-relative.
 *
 * Usage (from the caller repo's working-directory, via scan-with-report):
 *   node <labone-actions checkout>/scripts/react-tech-debt-scan.mjs
 *
 * Exits non-zero only if any blocking (error-severity) finding exists -
 * advisory (warn-severity) findings are reported but never fail the job.
 */

import { execFileSync } from 'child_process';
import { writeFileSync } from 'fs';
import { relative } from 'path';
import { runScan } from './lib/crash-report.mjs';

const REPORT_PATH = 'react-tech-debt-report.md';
const RULE_PREFIX = 'lab-react-standards/';

function runEslint() {
  try {
    const stdout = execFileSync('npx', ['eslint', '--format', 'json', '.'], {
      encoding: 'utf-8',
      maxBuffer: 1024 * 1024 * 50,
    });
    return JSON.parse(stdout);
  } catch (error) {
    // eslint exits non-zero once any "error"-severity match is found
    // anywhere in the repo (not just this prefix) - expected; the JSON
    // report is still on stdout, so fall through and parse it below.
    if (error.stdout) return JSON.parse(error.stdout);
    throw error;
  }
}

function collectViolations(results) {
  return results.flatMap((result) =>
    result.messages
      .filter((message) => message.ruleId?.startsWith(RULE_PREFIX))
      .map((message) => ({
        file: relative('.', result.filePath).replace(/\\/g, '/'),
        line: message.line,
        rule: message.ruleId,
        message: message.message,
        severity: message.severity, // 1 = warn (advisory), 2 = error (blocking)
      })),
  );
}

function buildReport(violations) {
  const lines = ['## React tech-debt scan (lab-react-standards)', ''];

  if (violations.length === 0) {
    lines.push('✅ No react-tech-debt findings.', '');
    return { markdown: lines.join('\n'), blockingCount: 0 };
  }

  const blocking = violations.filter((v) => v.severity === 2);
  const advisory = violations.filter((v) => v.severity === 1);

  lines.push(
    blocking.length > 0
      ? `❌ Found ${blocking.length} blocking violation(s) and ${advisory.length} advisory finding(s).`
      : `✅ No blocking violations — ${advisory.length} advisory finding(s) reported below.`,
    '',
  );

  const sections = [
    { title: 'Blocking (error — fails the job)', items: blocking },
    { title: 'Advisory (warn — does not fail the job)', items: advisory },
  ];

  for (const { title, items } of sections) {
    if (items.length === 0) continue;

    lines.push(`<details><summary><strong>${title}</strong> — ${items.length}</summary>`, '');

    const byRule = new Map();
    for (const item of items) {
      if (!byRule.has(item.rule)) byRule.set(item.rule, []);
      byRule.get(item.rule).push(item);
    }

    for (const [rule, ruleViolations] of byRule) {
      lines.push(`- \`${rule}\` — ${ruleViolations.length}`);
      for (const v of ruleViolations) {
        lines.push(`  - \`${v.file}\`:L${v.line}: ${v.message}`);
      }
    }

    lines.push('', '</details>', '');
  }

  return { markdown: lines.join('\n'), blockingCount: blocking.length };
}

function main() {
  const results = runEslint();
  const violations = collectViolations(results);
  const { markdown, blockingCount } = buildReport(violations);

  writeFileSync(REPORT_PATH, markdown);

  if (blockingCount > 0) {
    console.error(`Found ${blockingCount} blocking react-tech-debt violation(s) — see ${REPORT_PATH}`);
    process.exit(1);
  }

  const advisoryCount = violations.length - blockingCount;
  console.log(`No blocking react-tech-debt violations (${advisoryCount} advisory finding(s)) — see ${REPORT_PATH}`);
}

runScan(main, REPORT_PATH, 'React tech-debt scan (lab-react-standards)');
