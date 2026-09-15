/**
 * Shared crash-report helper for the CI scan scripts under scripts/*.mjs
 * (dead-code-scan, design-system-scan, duplicate-code-scan).
 *
 * Each scan script writes its own report file (`reportPath`) once it has a
 * result. If something throws before that point (the underlying tool
 * crashing instead of just reporting issues, its output not being valid
 * JSON, etc.), the report file would otherwise never get written, which
 * breaks the `sticky-pull-request-comment` CI step downstream — it errors
 * when `path:` points at a file that doesn't exist. This guarantees a
 * report file exists by the time the process exits either way.
 *
 * Extracted out of design-system-scan.mjs/dead-code-scan.mjs, which each
 * carried a near-identical inline copy of this (flagged by
 * `yarn duplicate-code` once duplicate-code-scan.mjs added a third).
 */

import { writeFileSync } from 'fs';

/** Writes a best-effort crash report to `reportPath`, headed by `title`. */
function writeCrashReport(reportPath, title, error) {
  const message = error instanceof Error ? (error.stack ?? error.message) : String(error);

  try {
    writeFileSync(
      reportPath,
      `## ${title}\n\n⚠️ Scan failed to run.\n\n\`\`\`\n${message}\n\`\`\`\n`,
    );
  } catch (writeError) {
    console.error('Failed to write crash report:', writeError);
  }
}

/** Runs `main`, guaranteeing a crash report is written before exiting non-zero on failure. */
export function runScan(main, reportPath, title) {
  try {
    main();
  } catch (error) {
    console.error(error);
    writeCrashReport(reportPath, title, error);
    process.exit(1);
  }
}
