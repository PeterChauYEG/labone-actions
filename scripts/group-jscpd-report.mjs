#!/usr/bin/env node
/**
 * Clusters an existing jscpd JSON report into per-package Linear ticket groups.
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
