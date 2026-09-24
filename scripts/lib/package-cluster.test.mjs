#!/usr/bin/env node
// package-cluster.test.mjs — smoke tests for scripts/lib/package-cluster.mjs.
//
// Plain node built-ins only (no test framework in this repo) — mirrors
// file-linear-ticket.test.sh's PASS/FAIL-per-assertion style so both run
// the same way from CI.
//
// Usage: node scripts/lib/package-cluster.test.mjs

import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { clusterFindings, packageOf, writeGroupsFile } from './package-cluster.mjs';

let fail = false;

function test(name, fn) {
  try {
    fn();
    console.log(`PASS: ${name}`);
  } catch (error) {
    console.log(`FAIL: ${name}`);
    console.log(`  ${error.message}`);
    fail = true;
  }
}

test('packageOf strips a leading packages/ prefix and takes the first segment', () => {
  assert.equal(packageOf('packages/core/src/lib.ts'), 'core');
});

test('packageOf keeps a 2-segment scope for nodes/drivers', () => {
  assert.equal(packageOf('packages/nodes/motor-controller/src/index.ts'), 'nodes/motor-controller');
  assert.equal(packageOf('packages/drivers/can-bus/src/index.ts'), 'drivers/can-bus');
});

test('packageOf falls back to the first segment when there is no packages/ prefix', () => {
  assert.equal(packageOf('apps/web/src/index.ts'), 'apps');
});

test('clusterFindings returns [] at or under the split threshold', () => {
  const records = Array.from({ length: 20 }, (_, i) => ({
    file: `packages/pkg-${i}/file.ts`,
    text: `finding ${i}`,
  }));
  assert.deepEqual(clusterFindings(records, { splitThreshold: 20 }), []);
});

test('clusterFindings splits by package once over the threshold', () => {
  const records = [
    ...Array.from({ length: 6 }, (_, i) => ({ file: `packages/a/file-${i}.ts`, text: `a-${i}` })),
    ...Array.from({ length: 6 }, (_, i) => ({ file: `packages/b/file-${i}.ts`, text: `b-${i}` })),
    ...Array.from({ length: 10 }, (_, i) => ({ file: `packages/c/file-${i}.ts`, text: `c-${i}` })),
  ];
  const groups = clusterFindings(records, { splitThreshold: 20, minPerTicket: 5 });
  assert.equal(groups.length, 3);
  const scopes = groups.map((g) => g.scope).sort();
  assert.deepEqual(scopes, ['a', 'b', 'c']);
  assert.equal(groups.find((g) => g.scope === 'c').count, 10);
});

test('clusterFindings merges under-minPerTicket packages into misc', () => {
  const records = [
    ...Array.from({ length: 2 }, (_, i) => ({ file: `packages/tiny-a/file-${i}.ts`, text: `t-${i}` })),
    ...Array.from({ length: 3 }, (_, i) => ({ file: `packages/tiny-b/file-${i}.ts`, text: `u-${i}` })),
    ...Array.from({ length: 16 }, (_, i) => ({ file: `packages/big/file-${i}.ts`, text: `b-${i}` })),
  ];
  const groups = clusterFindings(records, { splitThreshold: 20, minPerTicket: 5 });
  const scopes = groups.map((g) => g.scope).sort();
  assert.deepEqual(scopes, ['big', 'misc']);
  assert.equal(groups.find((g) => g.scope === 'misc').count, 5);
});

test('writeGroupsFile writes [] to disk when unsplit', () => {
  const dir = mkdtempSync(join(tmpdir(), 'package-cluster-test-'));
  const outPath = join(dir, 'job-groups.json');
  try {
    const groups = writeGroupsFile([{ file: 'packages/a/file.ts', text: 'x' }], outPath, {
      splitThreshold: 20,
    });
    assert.deepEqual(groups, []);
    assert.deepEqual(JSON.parse(readFileSync(outPath, 'utf-8')), []);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

if (fail) {
  console.log('One or more tests FAILED');
  process.exit(1);
}
console.log('All package-cluster.mjs tests passed');
