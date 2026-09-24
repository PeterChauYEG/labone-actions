/**
 * package-cluster.mjs — shared clustering engine for splitting a large CI
 * quality-scan report into per-package Linear ticket groups, deterministically
 * (no agent/LLM judgment — see file-linear-ticket.sh's header comment). This
 * is the JS port of mecha-industries/mecha10's
 * scripts/ci/lib-package-cluster.jq (PRs #822/#824), adapted to this repo's
 * .mjs scan scripts.
 *
 * Used by duplicate-code-scan.mjs and dead-code-scan.mjs, so every job's
 * clustering behaves identically even though each job's own extraction
 * (turning its tool's output into the {file, text} records this operates
 * on) is necessarily job-specific.
 *
 * Input: an array of {file, text} records — one per violation/finding.
 * `file` (a workspace-relative path, e.g. "packages/core/src/lib.ts") drives
 * clustering; `text` is a ready-to-render markdown blurb for that one
 * finding.
 *
 * Output: [] if `records.length <= splitThreshold` (small enough to file as
 * a single flat ticket, today's/every-other-job's behavior). Otherwise one
 * {scope, count, description} object per package bucket — packages with
 * fewer than `minPerTicket` findings are merged into one shared "misc"
 * bucket rather than each getting a tiny one-off ticket (matches the
 * historical human-curated "remaining smaller packages" ticket pattern).
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
 * Clusters `records` and writes the result to `outPath` as JSON — the
 * `<job-name>-groups.json` file file-linear-ticket.sh's grouped mode reads.
 * Always writes a file (`[]` when unsplit) so a downstream step can assume
 * its existence rather than branching on it.
 */
export function writeGroupsFile(records, outPath, options) {
  const groups = clusterFindings(records, options);
  writeFileSync(outPath, JSON.stringify(groups, null, 2));
  return groups;
}
