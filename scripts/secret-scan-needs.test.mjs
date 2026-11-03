#!/usr/bin/env node
// Regression test for LAB-5175: every `secret-scan` job in a reusable CI
// workflow must depend on (at least) whatever its sibling `security-scan`
// job in the same file depends on. Without that, `secret-scan` gets
// scheduled immediately instead of after `changes` (and `setup`, where
// present) resolves.
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const WORKFLOWS_DIR = join(import.meta.dirname, '..', '.github', 'workflows');

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

// Pulls the body of a top-level (2-space indented) job out of a workflow
// file's `jobs:` map, stopping at the next 2-space-indented key.
export function extractJobBlock(yaml, jobName) {
  const lines = yaml.split('\n');
  const startPattern = new RegExp(`^  ${jobName}:\\s*$`);
  const startIndex = lines.findIndex((line) => startPattern.test(line));
  if (startIndex === -1) return null;

  const bodyLines = [lines[startIndex]];
  for (let i = startIndex + 1; i < lines.length; i++) {
    const line = lines[i];
    // Next top-level job (or end of `jobs:` map) is another 2-space-indented
    // `key:` line that isn't further indented.
    if (/^  [A-Za-z0-9_-]+:\s*$/.test(line)) break;
    bodyLines.push(line);
  }
  return bodyLines.join('\n');
}

// Extracts the set of job names a job's `needs:` key lists. Handles every
// form actually used in these workflows: a bare scalar (`needs: changes`),
// an inline array (`needs: [a, b]`), and a block array - whether its items
// start right after `needs:` (`needs:\n  - a\n  - b`) or after a `[` on its
// own line (`needs:\n  [\n    a,\n    b,\n  ]`).
export function parseNeeds(jobBlock) {
  if (!jobBlock) return new Set();

  const inlineMatch = jobBlock.match(/^\s*needs:\s*\[([^\]]*)\]\s*$/m);
  if (inlineMatch) {
    return new Set(
      inlineMatch[1]
        .split(',')
        .map((item) => item.trim())
        .filter(Boolean),
    );
  }

  const scalarMatch = jobBlock.match(/^\s*needs:\s*([^\s[\]#][^\n#]*?)\s*$/m);
  if (scalarMatch) {
    return new Set([scalarMatch[1].trim()]);
  }

  const blockMatch = jobBlock.match(/^\s*needs:\s*\n([\s\S]*?)(?=\n\s*[A-Za-z0-9_-]+:\s*\n|\n\s*\w+:)/m);
  if (blockMatch) {
    const items = [...blockMatch[1].matchAll(/^\s*-\s*([A-Za-z0-9_-]+)\s*$/gm)].map((m) => m[1]);
    if (items.length > 0) return new Set(items);

    const bracketItems = [...blockMatch[1].matchAll(/^\s*([A-Za-z0-9_-]+),?\s*$/gm)]
      .map((m) => m[1])
      .filter((item) => item !== '[' && item !== ']');
    if (bracketItems.length > 0) return new Set(bracketItems);
  }

  return new Set();
}

const workflowFiles = readdirSync(WORKFLOWS_DIR).filter((file) => file.endsWith('.yml') || file.endsWith('.yaml'));

for (const file of workflowFiles) {
  const yaml = readFileSync(join(WORKFLOWS_DIR, file), 'utf8');
  const securityScanBlock = extractJobBlock(yaml, 'security-scan');
  const secretScanBlock = extractJobBlock(yaml, 'secret-scan');

  // Only applies to files that actually have both sibling jobs.
  if (!securityScanBlock || !secretScanBlock) continue;

  test(`${file}: secret-scan's needs cover security-scan's needs`, () => {
    const securityScanNeeds = parseNeeds(securityScanBlock);
    const secretScanNeeds = parseNeeds(secretScanBlock);

    const missing = [...securityScanNeeds].filter((need) => !secretScanNeeds.has(need));
    assert.deepEqual(
      missing,
      [],
      `secret-scan is missing needs ${JSON.stringify(missing)} that security-scan has: ` +
        `security-scan needs=${JSON.stringify([...securityScanNeeds])}, ` +
        `secret-scan needs=${JSON.stringify([...secretScanNeeds])}`,
    );
  });
}

if (fail) {
  process.exit(1);
}
