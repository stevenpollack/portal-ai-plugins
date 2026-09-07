#!/bin/bash
# Hook evals: pipe each case's input into a hook and compare the decision.
# Needs only bash and jq. The code-writer agent has its own opt-in check in
# code-writer-eval.sh, since it spends API calls.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$SCRIPT_DIR/../hooks"
FIXTURES="$SCRIPT_DIR/.fixtures"
# Silence from a hook means "no decision", which the harness treats as allow.
GATE_JQ='.hookSpecificOutput.permissionDecision // "allow"'
NUDGE_JQ='if (.hookSpecificOutput.additionalContext // "") == "" then "none" else "nudge" end'
PASSED=0
FAILED=0
TOTAL=0

generate_fixture() {
  local path="$1" lines="$2"
  if [ "$lines" -eq 0 ]; then
    touch "$path"
  else
    seq 1 "$lines" | awk '{print "line "NR}' > "$path"
  fi
}

setup_fixtures() {
  local evals_file="$1"
  rm -rf "$FIXTURES"
  mkdir -p "$FIXTURES"

  local count
  count=$(jq '.evals | length' "$evals_file")

  for ((i = 0; i < count; i++)); do
    local fixture
    fixture=$(jq -r ".evals[$i].fixture" "$evals_file")
    [ "$fixture" = "null" ] && continue

    local lines
    lines=$(jq -r ".evals[$i].fixture.lines" "$evals_file")

    local input_path
    input_path=$(jq -r ".evals[$i].input.tool_input.file_path // empty" "$evals_file")
    if [ -z "$input_path" ]; then
      input_path=$(jq -r ".evals[$i].input.tool_input.command // empty" "$evals_file" | sed -E 's/^(cat|head|tail|less|more) +(-[^ ]+ +)*//' | sed 's/ .*//' | tr -d '"'"'")
    fi
    input_path=$(echo "$input_path" | sed "s|{{FIXTURES}}|$FIXTURES|")

    # Only generate inside the fixtures dir; commands the parser is not meant to
    # extract a path from (grep, git, …) reduce to the command name itself.
    case "$input_path" in
      "$FIXTURES"/*) generate_fixture "$input_path" "$lines" ;;
    esac
  done
}

run_eval() {
  local hook="$1" decision_jq="$2" name="$3" input="$4" expected="$5" reason="$6" env_json="$7"
  TOTAL=$((TOTAL + 1))

  local env_cmd=""
  if [ -n "$env_json" ] && [ "$env_json" != "null" ]; then
    while IFS='=' read -r key val; do
      env_cmd="$env_cmd $key=$val"
    done < <(echo "$env_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
  fi

  local result actual
  result=$(echo "$input" | env $env_cmd bash "$hook" 2>/dev/null)
  actual=$(printf '%s' "${result:-null}" | jq -r "$decision_jq")

  if [ "$actual" = "$expected" ]; then
    printf "  \033[32mPASS\033[0m  %-30s %s\n" "$name" "$reason"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-30s expected=%s got=%s\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

run_suite() {
  local hook="$1" decision_jq="$2" tool="$3" evals_file="$4" label="$5"

  setup_fixtures "$evals_file"

  echo ""
  echo "$label"
  echo "────────────────────────────────────────────────────────────────"

  local count
  count=$(jq '.evals | length' "$evals_file")

  for ((i = 0; i < count; i++)); do
    local name expected reason input env_json
    name=$(jq -r ".evals[$i].name" "$evals_file")
    expected=$(jq -r ".evals[$i].expected_decision" "$evals_file")
    reason=$(jq -r ".evals[$i].reason" "$evals_file")
    input=$(jq -c --arg t "$tool" ".evals[$i].input + {tool_name: \$t}" "$evals_file" | sed "s|{{FIXTURES}}|$FIXTURES|g")
    env_json=$(jq -r ".evals[$i].env // empty" "$evals_file")
    run_eval "$hook" "$decision_jq" "$name" "$input" "$expected" "$reason" "$env_json"
  done

  rm -rf "$FIXTURES"
}

run_suite "$HOOKS/check-read" "$GATE_JQ" Read "$SCRIPT_DIR/hook-evals.json" "Read (check-read)"
run_suite "$HOOKS/check-read" "$GATE_JQ" Bash "$SCRIPT_DIR/bash-hook-evals.json" "Bash (check-read)"
run_suite "$HOOKS/nudge-code-writer" "$NUDGE_JQ" "" "$SCRIPT_DIR/nudge-evals.json" "UserPromptSubmit (nudge-code-writer)"

echo ""
echo "════════════════════════════════════════════════════════════════"
printf "Total: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m, %d total\n" "$PASSED" "$FAILED" "$TOTAL"
echo ""
[ "$FAILED" -gt 0 ] && exit 1
exit 0
