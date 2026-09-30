#!/usr/bin/env node
/**
 * Design-system scan: runs ESLint against the caller repo's own
 * eslint.config.(js|mjs) and renders just labone-eslint-plugin's design
 * rules (`lab-react-standards/no-raw-text-element`,
 * `lab-react-standards/no-theme-color-literal`) as a PR-friendly report.
 * No per-repo config needed for this base check - these two rule names are
 * a fixed labone-eslint-plugin vocabulary, not something that varies per
 * caller; a caller whose eslint.config doesn't wire either rule up just
 * gets a clean "no violations" report. This base check always runs.
 *
 * Two additional, opt-in capabilities exist for callers whose stack can't
 * use the ESLint rules directly (a non-ESLint scan, or a JSX shape the
 * rules don't understand). Both are gated by env var so existing callers
 * who don't ask for them see no behavior change:
 *
 *   DESIGN_SYSTEM_SHADCN_VENDOR_PATH — when set to a non-empty path (e.g.
 *     `src/design-system/vendor/`), additionally runs a shadcn-usage scan:
 *     flags raw interactive/form HTML elements (<button>, <input>,
 *     <select>, <textarea>) anywhere under `src/**` except that vendor
 *     path, which is where the shadcn/ui primitives themselves legitimately
 *     use those tags. Ported from gamecraft's original
 *     scripts/design-system-scan.mjs (pre-centralization); the vendor path
 *     was gamecraft-specific (`src/design-system/vendor/`) and is now a
 *     config knob instead of a hardcoded constant. Unset (default): this
 *     check does not run.
 *
 *   DESIGN_SYSTEM_RN_MODE — 'true' additionally runs a React Native
 *     regex-based scan replicating the two ESLint rules' intent for RN's
 *     <View>/<Text> JSX shape, which the ESLint rules (built for
 *     web/HTML-JSX) don't handle cleanly. Checks: (1) raw `Text` imported
 *     from 'react-native' used outside the typography component layer, and
 *     (2) raw color literals (hex, rgb()/hsl(), Tailwind default-palette
 *     classes) outside the theme/token source files. Ported from
 *     mc-training-arc-sung-jinwoo-mobile's original
 *     scripts/design-system-scan.ts (see that repo's commit bfcc568 for why
 *     it turned the ESLint rules off repo-wide in favor of this). Unset/
 *     anything else (default): this check does not run.
 *
 *   DESIGN_SYSTEM_RN_EXEMPT_PATHS — comma-separated list of additional
 *     paths (exact match, or a path ending in `/` matched as a prefix)
 *     exempt from the RN check's theme-color rule, appended to the two
 *     built-in token-source exemptions. Only meaningful when
 *     DESIGN_SYSTEM_RN_MODE=true. Defaults to empty (no additional
 *     exemptions) — mc-training passes its own 3 native-API paths (widgets/
 *     notification channel code that must use literal colors) here, so
 *     other future RN callers aren't stuck with mc-training's exemptions.
 *
 * Invoked by scan-with-report's `script-source: labone-actions` mode (see
 * that action's own header) - runs with the caller repo as its cwd, so
 * every path here is deliberately cwd-relative.
 *
 * Usage (from the caller repo's working-directory, via scan-with-report):
 *   node <labone-actions checkout>/scripts/design-system-scan.mjs
 *
 * Exits non-zero if any violation of any active check is found.
 */

import { execFileSync } from 'child_process';
import { readFileSync, readdirSync, writeFileSync } from 'fs';
import { extname, join, relative } from 'path';
import { runScan } from './lib/crash-report.mjs';
import { writeGroupsFile } from './lib/package-cluster.mjs';

const REPORT_PATH = 'design-system-report.md';
const GROUPS_PATH = 'design-system-groups.json';
const ESLINT_RULES = ['lab-react-standards/no-raw-text-element', 'lab-react-standards/no-theme-color-literal'];

const SHADCN_VENDOR_PATH = process.env.DESIGN_SYSTEM_SHADCN_VENDOR_PATH ?? '';
const SHADCN_CHECK_ENABLED = SHADCN_VENDOR_PATH !== '';

const RN_MODE_ENABLED = process.env.DESIGN_SYSTEM_RN_MODE === 'true';
const RN_EXTRA_COLOR_EXEMPT_PATHS = (process.env.DESIGN_SYSTEM_RN_EXEMPT_PATHS ?? '')
  .split(',')
  .map((path) => path.trim())
  .filter(Boolean);

// ---------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------

const EXCLUDED_DIR_SEGMENTS = ['generated', '__tests__'];

function walk(dir, extensions) {
  const entries = readdirSync(dir, { withFileTypes: true });
  const files = [];

  for (const entry of entries) {
    const fullPath = join(dir, entry.name);

    if (entry.isDirectory()) {
      if (EXCLUDED_DIR_SEGMENTS.includes(entry.name)) continue;
      files.push(...walk(fullPath, extensions));
    } else if (extensions.has(extname(entry.name))) {
      files.push(fullPath);
    }
  }

  return files;
}

function lineNumberAt(content, index) {
  return content.slice(0, index).split('\n').length;
}

function buildClusterRecords(violations) {
  return violations.map((v) => ({ file: v.file, text: `- \`${v.file}:${v.line}\` — ${v.message} (\`${v.rule}\`)` }));
}

// ---------------------------------------------------------------------
// Base check: ESLint's design-rule violations
// ---------------------------------------------------------------------

function runEslint() {
  try {
    const stdout = execFileSync('npx', ['eslint', '--format', 'json', '.'], {
      encoding: 'utf-8',
      maxBuffer: 1024 * 1024 * 50,
    });
    return JSON.parse(stdout);
  } catch (error) {
    // eslint exits non-zero once any "error"-severity match is found
    // anywhere in the repo (not just ESLINT_RULES) - expected; the JSON
    // report is still on stdout, so fall through and parse it below.
    if (error.stdout) return JSON.parse(error.stdout);
    throw error;
  }
}

function collectEslintViolations(results) {
  return results.flatMap((result) =>
    result.messages
      .filter((message) => ESLINT_RULES.includes(message.ruleId))
      .map((message) => ({
        file: relative('.', result.filePath).replace(/\\/g, '/'),
        line: message.line,
        rule: message.ruleId,
        message: message.message,
      })),
  );
}

function buildEslintReport(violations) {
  if (violations.length === 0) {
    return [
      '## Design-system scan (eslint)',
      '',
      '✅ No no-raw-text-element / no-theme-color-literal violations found.',
      '',
    ].join('\n');
  }

  const lines = ['## Design-system scan (eslint)', '', `❌ Found ${violations.length} violation(s).`, ''];

  const byRule = new Map();
  for (const violation of violations) {
    if (!byRule.has(violation.rule)) byRule.set(violation.rule, []);
    byRule.get(violation.rule).push(violation);
  }

  for (const [rule, ruleViolations] of byRule) {
    lines.push(`<details><summary><strong>${rule}</strong> — ${ruleViolations.length}</summary>`, '');
    for (const v of ruleViolations) {
      lines.push(`- \`${v.file}:${v.line}\` — ${v.message}`);
    }
    lines.push('', '</details>', '');
  }

  return lines.join('\n');
}

// ---------------------------------------------------------------------
// Opt-in check: shadcn-usage scan (ported from gamecraft)
// ---------------------------------------------------------------------

const SHADCN_SRC_DIR = 'src';
const SHADCN_SCAN_EXTENSIONS = new Set(['.ts', '.tsx', '.js', '.jsx']);
const SHADCN_TAGS = ['button', 'input', 'select', 'textarea'];
const SHADCN_TAG_PATTERN = new RegExp(`<(${SHADCN_TAGS.join('|')})(?=[\\s/>])`, 'g');
const SHADCN_COMPONENT_NAMES = {
  button: 'Button',
  input: 'Input',
  select: 'Select',
  textarea: 'Textarea',
};

/**
 * Blanks out `//` and `/* *\/` comment bodies (replacing each non-newline
 * character with a space) so the shadcn-usage check doesn't fire on a tag
 * name merely *mentioned* in a comment (e.g. "a `<select>` of..."). Preserves
 * every character's original offset/line, so match indices from the blanked
 * string still map correctly back onto the original file for line numbers.
 */
function blankComments(content) {
  return content
    .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
    .replace(/\/\/[^\n]*/g, (m) => ' '.repeat(m.length));
}

function scanShadcnFile(path) {
  const content = readFileSync(path, 'utf-8');
  const relPath = relative('.', path).replace(/\\/g, '/');
  const violations = [];

  if (!relPath.startsWith(SHADCN_VENDOR_PATH)) {
    const withoutComments = blankComments(content);
    for (const match of withoutComments.matchAll(SHADCN_TAG_PATTERN)) {
      const tag = match[1];
      violations.push({
        rule: 'shadcn-usage',
        message: `raw <${tag}> — use ${SHADCN_VENDOR_PATH}${tag} (${SHADCN_COMPONENT_NAMES[tag]}) instead`,
        line: lineNumberAt(content, match.index),
      });
    }
  }

  return violations.map((v) => ({ ...v, file: relPath }));
}

function runShadcnCheck() {
  const files = walk(SHADCN_SRC_DIR, SHADCN_SCAN_EXTENSIONS);
  return files.flatMap(scanShadcnFile);
}

function buildShadcnReport(violations) {
  const lines = ['## Design-system scan (shadcn usage)', ''];

  if (violations.length === 0) {
    lines.push('✅ No raw shadcn-eligible elements found.', '');
    return lines.join('\n');
  }

  lines.push(`❌ Found ${violations.length} violation(s).`, '');
  lines.push('<details><summary><strong>Raw elements (shadcn/ui available)</strong></summary>', '');

  const byFile = new Map();
  for (const item of violations) {
    if (!byFile.has(item.file)) byFile.set(item.file, []);
    byFile.get(item.file).push(item);
  }

  for (const [file, fileViolations] of byFile) {
    lines.push(`- \`${file}\``);
    for (const v of fileViolations) {
      lines.push(`  - L${v.line}: ${v.message}`);
    }
  }

  lines.push('', '</details>', '');

  return lines.join('\n');
}

// ---------------------------------------------------------------------
// Opt-in check: React Native typography + theme-color scan (ported from
// mc-training-arc-sung-jinwoo-mobile)
// ---------------------------------------------------------------------

const RN_SRC_DIR = 'src';
const RN_SCAN_EXTENSIONS = new Set(['.ts', '.tsx']);

const RN_TEXT_EXEMPT_PATHS = ['src/components/Text.tsx', 'src/components/typography/'];
// Files exempt from the theme-color rule because they configure a native API
// (an iOS Widget/Live Activity SwiftUI process, or an OS-level Android
// notification channel) that runs outside the themed React tree and cannot
// reference CSS-var-backed theme tokens or NativeWind classNames. The base
// two are structural (the theme/token source files themselves); anything
// beyond that is caller-specific and comes from DESIGN_SYSTEM_RN_EXEMPT_PATHS.
const RN_COLOR_EXEMPT_PATHS = [
  'src/theme/theme-constants.ts',
  'src/components/switch/RGB_COLORS.tsx',
  ...RN_EXTRA_COLOR_EXEMPT_PATHS,
];

const RN_TAILWIND_COLOR_SCALES = [
  'slate', 'gray', 'zinc', 'neutral', 'stone', 'red', 'orange', 'amber',
  'yellow', 'lime', 'green', 'emerald', 'teal', 'cyan', 'sky', 'blue',
  'indigo', 'violet', 'purple', 'fuchsia', 'pink', 'rose',
];
const RN_TAILWIND_COLOR_PREFIXES = [
  'bg', 'text', 'border', 'ring', 'ring-offset', 'fill', 'stroke', 'from',
  'via', 'to', 'outline', 'decoration', 'caret', 'accent', 'shadow',
  'divide', 'placeholder',
];

const RN_COLOR_PATTERNS = [
  {
    name: 'hex color literal',
    pattern: /(?<!&)#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{4}|[0-9a-fA-F]{3})\b/g,
  },
  {
    name: 'raw color function',
    pattern: /\b(?:rgb|rgba|hsl|hsla)\(/g,
  },
  {
    name: 'Tailwind default-palette class (not a theme color)',
    pattern: new RegExp(
      `\\b(?:${RN_TAILWIND_COLOR_PREFIXES.join('|')})-(?:${RN_TAILWIND_COLOR_SCALES.join('|')})-[0-9]{2,3}\\b`,
      'g',
    ),
  },
];

function findReactNativeTextLocalName(content) {
  const importMatch = content.match(/import\s*\{([^}]*)\}\s*from\s*['"]react-native['"]/);

  if (!importMatch) return null;

  const specifiers = importMatch[1].split(',').map((s) => s.trim());

  for (const specifier of specifiers) {
    const aliasMatch = specifier.match(/^Text\s+as\s+(\w+)$/);
    if (aliasMatch) return aliasMatch[1];
    if (specifier === 'Text') return 'Text';
  }

  return null;
}

function isRnExempt(relPath, exemptPaths) {
  return exemptPaths.some((exempt) => (exempt.endsWith('/') ? relPath.startsWith(exempt) : relPath === exempt));
}

function scanRnFile(path) {
  const content = readFileSync(path, 'utf-8');
  const relPath = relative('.', path).replace(/\\/g, '/');
  const violations = [];

  if (!isRnExempt(relPath, RN_TEXT_EXEMPT_PATHS)) {
    const localName = findReactNativeTextLocalName(content);

    if (localName) {
      const pattern = new RegExp(`<${localName}(?=[\\s/>])`, 'g');
      for (const match of content.matchAll(pattern)) {
        violations.push({
          line: lineNumberAt(content, match.index),
          message: `raw <${localName}> from 'react-native' — import Text from '@/components/Text' or a typography variant instead`,
          rule: 'rn-typography',
        });
      }
    }
  }

  if (!isRnExempt(relPath, RN_COLOR_EXEMPT_PATHS)) {
    for (const { name, pattern } of RN_COLOR_PATTERNS) {
      for (const match of content.matchAll(pattern)) {
        violations.push({
          line: lineNumberAt(content, match.index),
          message: `${name}: \`${match[0]}\` — use a theme token instead`,
          rule: 'rn-theme-color',
        });
      }
    }
  }

  return violations.map((v) => ({ ...v, file: relPath }));
}

function runRnCheck() {
  const files = walk(RN_SRC_DIR, RN_SCAN_EXTENSIONS);
  return files.flatMap(scanRnFile);
}

function buildRnReport(violations) {
  const lines = ['## Design-system scan (react-native typography + theme colors)', ''];

  if (violations.length === 0) {
    lines.push('✅ No raw text elements or non-theme colors found.', '');
    return lines.join('\n');
  }

  lines.push(`❌ Found ${violations.length} violation(s).`, '');

  const ruleGroups = [
    { key: 'rn-typography', title: 'Typography (raw <Text>)' },
    { key: 'rn-theme-color', title: 'Theme colors (raw literals)' },
  ];

  for (const { key, title } of ruleGroups) {
    const items = violations.filter((v) => v.rule === key);
    if (items.length === 0) continue;

    lines.push(`<details><summary><strong>${title}</strong> — ${items.length}</summary>`, '');

    const byFile = new Map();
    for (const item of items) {
      if (!byFile.has(item.file)) byFile.set(item.file, []);
      byFile.get(item.file).push(item);
    }

    for (const [file, fileViolations] of byFile) {
      lines.push(`- \`${file}\``);
      for (const v of fileViolations) {
        lines.push(`  - L${v.line}: ${v.message}`);
      }
    }

    lines.push('', '</details>', '');
  }

  return lines.join('\n');
}

// ---------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------

function main() {
  const reportSections = [];
  const allViolations = [];

  const eslintResults = runEslint();
  const eslintViolations = collectEslintViolations(eslintResults);
  reportSections.push(buildEslintReport(eslintViolations));
  allViolations.push(...eslintViolations);

  if (SHADCN_CHECK_ENABLED) {
    const shadcnViolations = runShadcnCheck();
    reportSections.push(buildShadcnReport(shadcnViolations));
    allViolations.push(...shadcnViolations);
  }

  if (RN_MODE_ENABLED) {
    const rnViolations = runRnCheck();
    reportSections.push(buildRnReport(rnViolations));
    allViolations.push(...rnViolations);
  }

  writeFileSync(REPORT_PATH, reportSections.join('\n'));
  writeGroupsFile(buildClusterRecords(allViolations), GROUPS_PATH);

  if (allViolations.length > 0) {
    console.error(`Found ${allViolations.length} design-system violation(s) — see ${REPORT_PATH}`);
    process.exit(1);
  }

  console.log('No design-system violations found.');
}

runScan(main, REPORT_PATH, 'Design-system scan');
