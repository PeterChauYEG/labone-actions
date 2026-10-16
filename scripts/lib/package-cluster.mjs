/**
 * Shared clustering engine for splitting a large CI quality-scan report
 * into per-package Linear ticket groups.
 */

import { writeFileSync } from 'fs';

const DEFAULT_SPLIT_THRESHOLD = 20;
const DEFAULT_MIN_PER_TICKET = 5;

/** Derives the clustering scope for a workspace-relative file path. */
export function packageOf(file) {
  const parts = file.replace(/^packages\//, '').split('/');

  if (['nodes', 'drivers'].includes(parts[0]) && parts.length > 1) {
    return `${parts[0]}/${parts[1]}`;
  }

  return parts[0];
}

function renderBucket(bucket) {
  return `## ${bucket.scope} — ${bucket.count} finding(s)\n\n${bucket.records
    .map((record) => record.text)
    .join('\n\n')}`;
}

/**
 * Clusters `records` into per-package ticket groups, or returns [] when
 * there are too few findings to bother splitting.
 */
export function clusterFindings(
  records,
  { splitThreshold = DEFAULT_SPLIT_THRESHOLD, minPerTicket = DEFAULT_MIN_PER_TICKET } = {},
) {
  if (records.length <= splitThreshold) {
    return [];
  }

  const byPackage = new Map();
  for (const record of records) {
    const pkg = packageOf(record.file);
    if (!byPackage.has(pkg)) byPackage.set(pkg, []);
    byPackage.get(pkg).push(record);
  }

  const buckets = [...byPackage.entries()]
    .map(([scope, bucketRecords]) => ({ scope, records: bucketRecords, count: bucketRecords.length }))
    .sort((a, b) => b.count - a.count || a.scope.localeCompare(b.scope));

  const big = buckets.filter((bucket) => bucket.count >= minPerTicket);
  const small = buckets.filter((bucket) => bucket.count < minPerTicket);

  const merged = [...big];
  if (small.length > 0) {
    merged.push({
      scope: 'misc',
      records: small.flatMap((bucket) => bucket.records),
      count: small.reduce((sum, bucket) => sum + bucket.count, 0),
    });
  }

  return merged.map((bucket) => ({
    scope: bucket.scope,
    count: bucket.count,
    description: renderBucket(bucket),
  }));
}

/**
 * Clusters `records` and writes the result to `outPath` as JSON.
 */
export function writeGroupsFile(records, outPath, options) {
  const groups = clusterFindings(records, options);
  writeFileSync(outPath, JSON.stringify(groups, null, 2));
  return groups;
}
