#!/usr/bin/env node
// Reads the Istanbul `coverage-summary.json` this job's own test:coverage
// step produced (see action.yml's `--coverageReporters=json-summary`
// requirement), and the `coverage-badge.json` a PREVIOUS run already
// committed (if any), then (re)writes `coverage-badge.json` ONLY when the
// overall statement-coverage percentage actually changed.
//
// Without that guard, `updatedAt` would differ on every single
// push-to-main run even when coverage didn't move a single percentage
// point - forcing a commit (with a diff nobody can see any real content
// in) on every merge. The downstream consumer this file exists for
// (company-system's maintenance-ticket scanner, see the PR this shipped in)
// only cares about the number, so a stable file when the number is stable
// is the right contract.
//
// `coverage-badge.json` shape: { "statements": <number>, "updatedAt":
// "<ISO8601>" } - this is the machine-readable contract; the README badge
// istanbul-badges-readme writes is only the human-visible half.
import fs from 'node:fs';
import path from 'node:path';

const [, , coverageSummaryPath, badgeDataPath] = process.argv;

if (!coverageSummaryPath || !badgeDataPath) {
  console.error('Usage: write-badge-data.mjs <coverage-summary.json path> <coverage-badge.json path>');
  process.exit(1);
}

if (!fs.existsSync(coverageSummaryPath)) {
  console.error(
    `::error::Coverage summary not found at ${coverageSummaryPath} - did the test step run with --coverageReporters=json-summary?`,
  );
  process.exit(1);
}

const summary = JSON.parse(fs.readFileSync(coverageSummaryPath, 'utf8'));
const pct = summary?.total?.statements?.pct;

if (typeof pct !== 'number') {
  console.error(`::error::Could not read total.statements.pct out of ${coverageSummaryPath}`);
  process.exit(1);
}

let previous = null;
if (fs.existsSync(badgeDataPath)) {
  try {
    previous = JSON.parse(fs.readFileSync(badgeDataPath, 'utf8'));
  } catch {
    previous = null; // Corrupt/hand-edited file - treat as "no previous value", same as first run.
  }
}

const githubOutput = process.env.GITHUB_OUTPUT;
const setOutput = (name, value) => {
  if (githubOutput) {
    fs.appendFileSync(githubOutput, `${name}=${value}\n`);
  }
};

setOutput('statements_pct', pct);

if (previous && previous.statements === pct) {
  console.log(`Coverage unchanged at ${pct}% - leaving ${badgeDataPath} as-is`);
  setOutput('data_changed', 'false');
  process.exit(0);
}

fs.mkdirSync(path.dirname(badgeDataPath), { recursive: true });
fs.writeFileSync(
  badgeDataPath,
  `${JSON.stringify({ statements: pct, updatedAt: new Date().toISOString() }, null, 2)}\n`,
);
console.log(`Coverage changed to ${pct}% (was ${previous?.statements ?? 'n/a'}%) - wrote ${badgeDataPath}`);
setOutput('data_changed', 'true');
