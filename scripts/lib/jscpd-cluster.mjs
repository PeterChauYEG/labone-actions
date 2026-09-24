/**
 * jscpd-cluster.mjs — turns a parsed jscpd JSON report into the {file, text}
 * records package-cluster.mjs's clusterFindings/writeGroupsFile expect.
 * Shared by duplicate-code-scan.mjs (runs jscpd itself) and
 * group-jscpd-report.mjs (clusters a report jscpd already wrote, for callers
 * that invoke jscpd directly rather than through duplicate-code-scan.mjs —
 * see godot-develop-ci.yml's duplicate-code job).
 */

export function formatFragment({ name, start, end }) {
  return `\`${name}\`:${start}-${end}`;
}

// One record per duplicate block, scoped to its first file's package — a
// jscpd duplicate is always a pair (firstFile/secondFile), unlike
// cargo-dupes' n-way clone groups, so there's no "majority package" to pick
// among more than two members; firstFile is a deterministic, stable choice.
export function buildClusterRecords(report) {
  const duplicates = report.duplicates ?? [];
  return duplicates.map((dup) => ({
    file: dup.firstFile.name,
    text: `- ${formatFragment(dup.firstFile)} ↔ ${formatFragment(dup.secondFile)} (${dup.lines} lines, ${dup.tokens} tokens)`,
  }));
}
