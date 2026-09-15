#!/usr/bin/env node
/**
 * Design-system scan: runs ESLint against the caller repo's own
 * eslint.config.(js|mjs) and renders just labone-eslint-plugin's design
 * rules (`lab-react-standards/no-raw-text-element`,
 * `lab-react-standards/no-theme-color-literal`) as a PR-friendly report.
 * No per-repo config needed - these two rule names are a fixed
 * labone-eslint-plugin vocabulary, not something that varies per caller;
 * a caller whose eslint.config doesn't wire either rule up just gets a
 * clean "no violations" report.
 *
 * Invoked by scan-with-report's `script-source: labone-actions` mode (see
 * that action's own header) - runs with the caller repo as its cwd, so
 * every path here is deliberately cwd-relative.
 *
 * Usage (from the caller repo's working-directory, via scan-with-report):
 *   node <labone-actions checkout>/scripts/design-system-scan.mjs
 *
 * Exits non-zero if any violation of either rule is found.
 */

import { execFileSync } from 'child_process';
import { writeFileSync } from 'fs';
import { relative } from 'path';
import { runScan } from './lib/crash-report.mjs';

const REPORT_PATH = 'design-system-report.md';
const RULES = ['lab-react-standards/no-raw-text-element', 'lab-react-standards/no-theme-color-literal'];

function runEslint() {
  try {
    const stdout = execFileSync('npx', ['eslint', '--format', 'json', '.'], {
      encoding: 'utf-8',
      maxBuffer: 1024 * 1024 * 50,
    });
    return JSON.parse(stdout);
  } catch (error) {
    // eslint exits non-zero once any "error"-severity match is found
    // anywhere in the repo (not just RULES) - expected; the JSON report is
    // still on stdout, so fall through and parse it below.
    if (error.stdout) return JSON.parse(error.stdout);
    throw error;
  }
}

function collectViolations(results) {
  return results.flatMap((result) =>
    result.messages
      .filter((message) => RULES.includes(message.ruleId))
      .map((message) => ({
        file: relative('.', result.filePath).replace(/\\/g, '/'),
        line: message.line,
        rule: message.ruleId,
        message: message.message,
      })),
  );
}

function buildReport(violations) {
  if (violations.length === 0) {
    return [
      '## Design-system scan (eslint)',
      '',
      '✅ No no-raw-text-element / no-theme-color-literal violations found.',
      '',
    ].join('\n');
  }

  const lines = ['## Design-system scan (eslint)', '', `❌ Found ${violations.length} violation(s).`, ''];

  const byRule = new Map();
  for (const violation of violations) {
    if (!byRule.has(violation.rule)) byRule.set(violation.rule, []);
    byRule.get(violation.rule).push(violation);
  }

  for (const [rule, ruleViolations] of byRule) {
    lines.push(`<details><summary><strong>${rule}</strong> — ${ruleViolations.length}</summary>`, '');
    for (const v of ruleViolations) {
      lines.push(`- \`${v.file}:${v.line}\` — ${v.message}`);
    }
    lines.push('', '</details>', '');
  }

  return lines.join('\n');
}

function main() {
  const results = runEslint();
  const violations = collectViolations(results);
  const markdown = buildReport(violations);

  writeFileSync(REPORT_PATH, markdown);

  if (violations.length > 0) {
    console.error(`Found ${violations.length} design-system violation(s) — see ${REPORT_PATH}`);
    process.exit(1);
  }

  console.log('No design-system violations found.');
}

runScan(main, REPORT_PATH, 'Design-system scan (eslint)');
