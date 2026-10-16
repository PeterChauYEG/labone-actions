#!/usr/bin/env bash
set -euo pipefail

report_md="${1:-dead-code-report.md}"

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
