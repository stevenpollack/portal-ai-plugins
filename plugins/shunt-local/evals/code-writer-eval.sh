#!/bin/bash
# Opt-in end-to-end check of the code-writer agent: runs it headless against the
# fixtures and asserts the output contract (one-line reply, file on disk matching
# the reference's structure). Spends real API calls, so run.sh does not call it.
#
# Usage: bash evals/code-writer-eval.sh
# Needs the plugin loaded: installed, or pass CLAUDE_ARGS="--plugin-dir plugins/shunt-local".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX="$SCRIPT_DIR/fixtures"
OUT="$(mktemp -d)"
TARGET="$OUT/user-service.test.ts"
trap 'rm -rf "$OUT"' EXIT

# acceptEdits: print mode cannot answer a Write permission prompt. It only covers
# the working directory, so the temp target dir is granted with --add-dir.
# The prompt goes on stdin: --add-dir is variadic and would swallow a positional one.
# shellcheck disable=SC2086
reply=$(claude -p ${CLAUDE_ARGS:-} --agent shunt-local:code-writer --permission-mode acceptEdits --add-dir "$OUT" <<EOF
Spec: Write unit tests for UserService following the exact same patterns, structure, and assertions as the OrderService tests.
Source under test: $FIX/user-service.ts
Reference (match its style exactly): $FIX/order-service.test.ts
Target: $TARGET
EOF
)

FAILED=0
check() {
  if eval "$2" 2>/dev/null; then printf "  \033[32mPASS\033[0m  %s\n" "$1"
  else printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAILED=1; fi
}

echo "code-writer (headless, $FIX)"
echo "────────────────────────────────────────────────────────────────"
check "reply is one line"            '[ "$(printf "%s" "$reply" | wc -l | tr -d " ")" -eq 0 ]'
check "reply matches contract"       'grep -qE "^wrote .+ \([0-9]+ lines\)$" <<<"$reply"'
check "target written"               '[ -s "$TARGET" ]'
check "same imports as reference"    '[ "$(grep -c "^import" "$TARGET")" -eq "$(grep -c "^import" "$FIX/order-service.test.ts")" ]'
check "describes UserService"        'grep -q "describe(.UserService." "$TARGET"'
check "uses reference assertion style" 'grep -q "rejects.toThrow" "$TARGET"'

echo ""
echo "reply: $reply"
exit "$FAILED"
