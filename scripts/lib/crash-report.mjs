/**
 * Shared crash-report helper for the CI scan scripts under scripts/*.mjs.
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
