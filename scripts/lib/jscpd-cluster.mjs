/**
 * Turns a parsed jscpd JSON report into {file, text} records for package-cluster.mjs.
 */

export function formatFragment({ name, start, end }) {
  return `\`${name}\`:${start}-${end}`;
}

export function buildClusterRecords(report) {
  const duplicates = report.duplicates ?? [];
  return duplicates.map((dup) => ({
    file: dup.firstFile.name,
    text: `- ${formatFragment(dup.firstFile)} ↔ ${formatFragment(dup.secondFile)} (${dup.lines} lines, ${dup.tokens} tokens)`,
  }));
}
