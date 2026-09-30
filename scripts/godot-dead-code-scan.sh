#!/usr/bin/env bash
# godot-dead-code-scan.sh — flags GDScript functions and classes that have
# no reference anywhere else in the project (best-effort static usage
# check, not a real symbol resolver — GDScript has no cargo-machete/knip
# equivalent, same tooling-gap category as develop-rust-ci.yml's
# cargo-machete dead-code scan).
#
# Bash script for Godot 4/GDScript callers of godot-develop-ci.yml/
# godot-pr.yml — see those workflows' `dead_code_script_source` input
# (`'labone-actions'`, the default, runs this script directly;
# `'repo'` runs the caller's own vendored `dead_code_script` path instead,
# e.g. gdscript-lsp-shaped repos that already have their own
# scripts/dead-code-scan.sh).
#
# Detects two things:
#   * `func <name>(...)` definitions with zero references to `<name>`
#     anywhere else in the project (skips well-known Godot engine
#     lifecycle callbacks, e.g. `_ready`/`_process`, which the engine
#     invokes without any textual call site).
#   * `class_name <Name>` declarations with zero references to `<Name>`
#     anywhere else in the project.
#
# This is a heuristic text scan, not a real parser: a name reused as a
# member on an unrelated object, or referenced only via a string built at
# runtime (e.g. `call(computed_name)`), can produce false
# positives/negatives either way. Exceptions belong in the caller's own
# review of the report, not in this script's logic.
#
# Invoked with the caller's Godot project already as cwd (via the
# workflow's `working-directory:` on the step that runs this) — every path
# here is deliberately cwd-relative, matching design-system-scan.mjs's
# convention for scan-with-report's `script-source: labone-actions` mode.
#
# Usage: godot-dead-code-scan.sh [report.md]
set -euo pipefail

report_md="${1:-dead-code-report.md}"

# Godot engine lifecycle/virtual callbacks — invoked by the engine itself,
# never via a textual call site, so they'd otherwise always false-positive
# as "unused".
engine_callbacks='^(_ready|_process|_physics_process|_input|_unhandled_input|_unhandled_key_input|_gui_input|_draw|_enter_tree|_exit_tree|_init|_notification|_get_property_list|_property_can_revert|_property_get_revert|_set|_get|_to_string|_get_configuration_warnings|_validate_property|_static_init)$'

mapfile -t gd_files < <(find . -name '*.gd' -not -path '*/.git/*' -not -path '*/.godot/*' | sort)

dead_functions=()
dead_classes=()

if [[ ${#gd_files[@]} -gt 0 ]]; then
  while IFS=: read -r file line name; do
    [[ -z "$name" ]] && continue
    if [[ "$name" =~ $engine_callbacks ]]; then
      continue
    fi
    other_defs=$(printf '%s\n' "${gd_files[@]}" | xargs grep -o "\\b${name}\\b" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$other_defs" -le 1 ]]; then
      dead_functions+=("${file}:${line} — func ${name}")
    fi
  done < <(grep -rnHoE '^[[:space:]]*(static[[:space:]]+)?func[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' -- "${gd_files[@]}" \
    | sed -E 's/^([^:]+:[0-9]+):.*func[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)/\1:\2/')

  while IFS=: read -r file line name; do
    [[ -z "$name" ]] && continue
    other_defs=$(printf '%s\n' "${gd_files[@]}" | xargs grep -o "\\b${name}\\b" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$other_defs" -le 1 ]]; then
      dead_classes+=("${file}:${line} — class_name ${name}")
    fi
  done < <(grep -rnHoE '^[[:space:]]*class_name[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' -- "${gd_files[@]}" \
    | sed -E 's/^([^:]+:[0-9]+):.*class_name[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)/\1:\2/')
fi

total=$(( ${#dead_functions[@]} + ${#dead_classes[@]} ))

{
  echo "## Dead Code Report (GDScript)"
  echo
  echo "> Best-effort static usage scan for GDScript functions/classes with no reference elsewhere in the project — not a real symbol resolver, review findings before deleting anything."
  echo
  if [[ "$total" -eq 0 ]]; then
    echo "No unreferenced functions or classes found. ✅"
  else
    echo "**${total} potentially unused symbol(s) found:**"
    echo
    if [[ ${#dead_functions[@]} -gt 0 ]]; then
      echo "<details><summary><strong>Unreferenced functions</strong> — ${#dead_functions[@]}</summary>"
      echo
      printf -- '- `%s`\n' "${dead_functions[@]}"
      echo
      echo "</details>"
    fi
    if [[ ${#dead_classes[@]} -gt 0 ]]; then
      echo "<details><summary><strong>Unreferenced classes</strong> — ${#dead_classes[@]}</summary>"
      echo
      printf -- '- `%s`\n' "${dead_classes[@]}"
      echo
      echo "</details>"
    fi
  fi
} > "$report_md"

echo "[godot-dead-code-scan] wrote $report_md (${total} potentially unused symbol(s))"

if [[ "$total" -ne 0 ]]; then
  exit 1
fi
exit 0
