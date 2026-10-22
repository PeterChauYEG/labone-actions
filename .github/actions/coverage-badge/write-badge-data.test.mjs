#!/usr/bin/env node
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptPath = fileURLToPath(new URL('./write-badge-data.mjs', import.meta.url));

let fail = false;

function test(name, fn) {
  try {
    fn();
    console.log(`PASS: ${name}`);
  } catch (error) {
    console.log(`FAIL: ${name}`);
    console.log(`  ${error.stack ?? error.message}`);
    fail = true;
  }
}

function withTempDir(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'write-badge-data-test-'));
  try {
    fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function writeSummary(dir, pct) {
  const summaryPath = join(dir, 'coverage-summary.json');
  writeFileSync(summaryPath, JSON.stringify({ total: { statements: { pct } } }));
  return summaryPath;
}

function run(summaryPath, badgeDataPath) {
  return execFileSync('node', [scriptPath, summaryPath, badgeDataPath], { encoding: 'utf8' });
}

test('exits 1 with no coverage-summary.json', () => {
  withTempDir((dir) => {
    const summaryPath = join(dir, 'coverage-summary.json');
    const badgeDataPath = join(dir, 'coverage-badge.json');
    assert.throws(() => run(summaryPath, badgeDataPath), /exit code 1|Command failed/);
  });
});

test('exits 1 when total.statements.pct is missing', () => {
  withTempDir((dir) => {
    const summaryPath = join(dir, 'coverage-summary.json');
    writeFileSync(summaryPath, JSON.stringify({ total: {} }));
    const badgeDataPath = join(dir, 'coverage-badge.json');
    assert.throws(() => run(summaryPath, badgeDataPath));
  });
});

test('first run writes statements + a fresh updatedAt', () => {
  withTempDir((dir) => {
    const summaryPath = writeSummary(dir, 83.2);
    const badgeDataPath = join(dir, 'coverage', 'coverage-badge.json');
    run(summaryPath, badgeDataPath);
    const written = JSON.parse(readFileSync(badgeDataPath, 'utf8'));
    assert.equal(written.statements, 83.2);
    assert.match(written.updatedAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
  });
});

test('creates the badge-data-path parent directory if missing', () => {
  withTempDir((dir) => {
    const summaryPath = writeSummary(dir, 50);
    const badgeDataPath = join(dir, 'nested', 'deeper', 'coverage-badge.json');
    run(summaryPath, badgeDataPath);
    assert.equal(JSON.parse(readFileSync(badgeDataPath, 'utf8')).statements, 50);
  });
});

test('unchanged percentage leaves the previous file (including updatedAt) untouched', () => {
  withTempDir((dir) => {
    const summaryPath = writeSummary(dir, 90);
    const badgeDataPath = join(dir, 'coverage-badge.json');
    run(summaryPath, badgeDataPath);
    const firstWrite = readFileSync(badgeDataPath, 'utf8');

    // Re-run with the identical pct - the script must not rewrite the file
    // (and in particular must not bump updatedAt), or every push-to-main
    // run would force a commit even when coverage never moved.
    run(summaryPath, badgeDataPath);
    const secondWrite = readFileSync(badgeDataPath, 'utf8');
    assert.equal(secondWrite, firstWrite);
  });
});

test('a changed percentage overwrites the previous file', () => {
  withTempDir((dir) => {
    const badgeDataPath = join(dir, 'coverage-badge.json');
    run(writeSummary(dir, 70), badgeDataPath);
    run(writeSummary(dir, 75), badgeDataPath);
    assert.equal(JSON.parse(readFileSync(badgeDataPath, 'utf8')).statements, 75);
  });
});

test('a corrupt previous badge-data file is treated as "no previous value"', () => {
  withTempDir((dir) => {
    const summaryPath = writeSummary(dir, 60);
    const badgeDataPath = join(dir, 'coverage-badge.json');
    writeFileSync(badgeDataPath, 'not json');
    run(summaryPath, badgeDataPath);
    assert.equal(JSON.parse(readFileSync(badgeDataPath, 'utf8')).statements, 60);
  });
});

if (fail) {
  console.log('One or more tests FAILED');
  process.exit(1);
}
console.log('All write-badge-data.mjs tests passed');
