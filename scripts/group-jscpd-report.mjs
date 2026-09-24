#!/usr/bin/env node
/**
 * group-jscpd-report.mjs — clusters an existing jscpd JSON report into
 * per-package Linear ticket groups, for callers that run jscpd directly
 * (e.g. godot-develop-ci.yml's duplicate-code job) rather than through
 * duplicate-code-scan.mjs. Uses the same lib/jscpd-cluster.mjs extraction
 * and lib/package-cluster.mjs clustering as that script, so both paths
 * produce identically-shaped groups files.
 *
 * Usage: node group-jscpd-report.mjs <jscpd-report.json path> <groups output path>
 * Writes [] (no split) if the input report is missing or unreadable, so a
 * caller whose jscpd config doesn't emit a JSON reporter (or hasn't run yet)
 * degrades safely to today's flat single-ticket behavior instead of
 * erroring the job.
 */

import { existsSync, readFileSync } from 'fs';
import { buildClusterRecords } from './lib/jscpd-cluster.mjs';
import { writeGroupsFile } from './lib/package-cluster.mjs';

const [, , reportPath = 'report/jscpd-report.json', outPath = 'duplicate-code-groups.json'] = process.argv;

if (!existsSync(reportPath)) {
  writeGroupsFile([], outPath);
  process.exit(0);
}

try {
  const report = JSON.parse(readFileSync(reportPath, 'utf-8'));
  writeGroupsFile(buildClusterRecords(report), outPath);
} catch (error) {
  console.error(`Failed to cluster ${reportPath}:`, error);
  writeGroupsFile([], outPath);
}
